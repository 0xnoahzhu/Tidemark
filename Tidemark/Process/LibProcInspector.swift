import Darwin
import Foundation
import Synchronization

/// `ProcessInspecting` backed by libproc.
///
/// `proc_pidinfo(PROC_PIDTBSDINFO)` gives the parent PID, the start time and the name; it fails with EPERM
/// for processes of other users (root daemons such as `mDNSResponder`), which fall back to
/// `sysctl(KERN_PROC_PID)`. `proc_pidpath` gives the executable path for both.
///
/// `chain(pid:notAfter:)` runs for every new request (~10 per second), so each resolved hop is cached by
/// `(pid, start time)` behind a `Mutex`: after the first request of a process, a chain costs one
/// `proc_pidinfo` call for the leaf. Cached hops also keep a chain intact after a parent exits.
final class LibProcInspector: ProcessInspecting {
    /// Longest chain returned; deeper ancestry is cut at the top.
    static let maxDepth = 32
    /// Start times from the kernel and from Surge may differ slightly.
    static let startTolerance: TimeInterval = 1
    /// The cache is cleared when it grows beyond this many processes.
    static let cacheLimit = 8192

    private let cache = Mutex<[ProcessKey: Node]>([:])

    init() {}

    func process(pid: Int32) -> LiveProcess? {
        guard let snapshot = Self.read(pid) else { return nil }
        let link = Self.link(for: snapshot, path: Self.executablePath(pid))
        return LiveProcess(pid: pid, parentPID: snapshot.parentPID, name: link.name, path: link.path, startTime: snapshot.startTime)
    }

    func chain(pid: Int32, notAfter: Date?) -> [ProcessLink] {
        guard pid > 1, let leaf = Self.read(pid) else { return [] }
        if let notAfter, leaf.startTime.timeIntervalSince(notAfter) > Self.startTolerance { return [] }

        var links: [ProcessLink] = []
        var visited: Set<Int32> = []
        var next: Lookup? = .live(leaf)
        while let lookup = next, links.count < Self.maxDepth {
            guard let resolved = resolve(lookup, refreshingPath: links.isEmpty),
                  visited.insert(resolved.node.link.pid).inserted
            else { break }
            links.append(resolved.node.link)
            if let parent = resolved.parent {
                next = .live(parent)
            } else {
                next = resolved.node.parent.map(Lookup.cached)
            }
        }
        return links.reversed()
    }

    func isRunning(pid: Int32, startTime: Date) -> Bool {
        guard pid > 0, let snapshot = Self.read(pid), !snapshot.isZombie else { return false }
        return abs(snapshot.startTime.timeIntervalSince(startTime)) <= Self.startTolerance
    }

    // MARK: - Chain resolution

    /// A process identity that survives PID reuse.
    private struct ProcessKey: Hashable {
        var pid: Int32
        /// Start time in microseconds since 1970.
        var start: Int64
    }

    /// A resolved hop: the process and its parent's key (nil when the parent is launchd or the kernel).
    private struct Node {
        var link: ProcessLink
        var parent: ProcessKey?
    }

    /// The live process table entry of one PID.
    private struct Snapshot {
        var pid: Int32
        var parentPID: Int32
        var start: Int64
        var name: String
        var isZombie: Bool

        var key: ProcessKey { ProcessKey(pid: pid, start: start) }
        var startTime: Date { Date(timeIntervalSince1970: Double(start) / 1_000_000) }
    }

    private enum Lookup {
        /// Freshly read from the process table.
        case live(Snapshot)
        /// Known by key only: the cached entry, else the live process if it is still the same one.
        case cached(ProcessKey)
    }

    /// Resolves a hop, reading the parent from the process table when the hop is not cached yet.
    /// Returns the parent's snapshot too, so the next hop needs no second read.
    ///
    /// `refreshingPath` re-reads the executable of a cached leaf: a process that calls `exec` keeps its PID
    /// and start time but runs another binary (`sh` wrappers that `exec node`).
    private func resolve(_ lookup: Lookup, refreshingPath: Bool) -> (node: Node, parent: Snapshot?)? {
        let snapshot: Snapshot
        switch lookup {
        case .live(let live):
            if var hit = cache.withLock({ $0[live.key] }) {
                if refreshingPath, let path = Self.executablePath(live.pid), path != hit.link.path {
                    hit.link = Self.link(for: live, path: path)
                    let refreshed = hit
                    cache.withLock { $0[live.key] = refreshed }
                }
                return (hit, nil)
            }
            snapshot = live
        case .cached(let key):
            if let hit = cache.withLock({ $0[key] }) { return (hit, nil) }
            // Not cached: the process must still be the one the child pointed at.
            guard let live = Self.read(key.pid), live.key == key else { return nil }
            snapshot = live
        }

        var parent: Snapshot?
        if snapshot.parentPID > 1, let candidate = Self.read(snapshot.parentPID),
           // A parent that started after its child is a reused PID (the child was just reparented).
           Double(candidate.start - snapshot.start) / 1_000_000 <= Self.startTolerance {
            parent = candidate
        }
        let node = Node(link: Self.link(for: snapshot, path: Self.executablePath(snapshot.pid)), parent: parent?.key)
        cache.withLock { cache in
            if cache.count >= Self.cacheLimit { cache.removeAll(keepingCapacity: true) }
            cache[snapshot.key] = node
        }
        return (node, parent)
    }

    private static func link(for snapshot: Snapshot, path: String?) -> ProcessLink {
        // The executable's file name is the full process name ("Cursor Helper (Plugin)"); the kernel's
        // copy is cut at 16 or 32 bytes.
        let name = path.map { URL(filePath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 } ?? snapshot.name
        return ProcessLink(name: name, pid: snapshot.pid, path: path, startTime: snapshot.startTime)
    }

    // MARK: - Process table

    private static func read(_ pid: Int32) -> Snapshot? {
        guard pid > 0 else { return nil }
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        if proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size {
            let name = string(fromCString: info.pbi_name)
            return Snapshot(
                pid: pid,
                parentPID: Int32(bitPattern: info.pbi_ppid),
                start: Int64(info.pbi_start_tvsec) * 1_000_000 + Int64(info.pbi_start_tvusec),
                name: name.isEmpty ? string(fromCString: info.pbi_comm) : name,
                isZombie: info.pbi_status == UInt32(SZOMB)
            )
        }
        // EPERM for other users' processes: the sysctl process table is readable for every process.
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var process = kinfo_proc()
        var length = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, UInt32(mib.count), &process, &length, nil, 0) == 0, length > 0 else { return nil }
        let start = process.kp_proc.p_un.__p_starttime
        return Snapshot(
            pid: pid,
            parentPID: process.kp_eproc.e_ppid,
            start: Int64(start.tv_sec) * 1_000_000 + Int64(start.tv_usec),
            name: string(fromCString: process.kp_proc.p_comm),
            isZombie: process.kp_proc.p_stat == CChar(SZOMB)
        )
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [UInt8](repeating: 0, count: Int(4 * MAXPATHLEN))
        let length = proc_pidpath(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(decoding: buffer.prefix(Int(length)), as: UTF8.self)
    }

    /// Reads a fixed-size C `char[]` (imported as a tuple) up to its terminating NUL.
    private static func string<Tuple>(fromCString tuple: Tuple) -> String {
        withUnsafeBytes(of: tuple) { bytes in
            String(decoding: bytes.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
