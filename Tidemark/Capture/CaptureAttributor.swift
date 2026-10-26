import Foundation

/// Resolves a request's process ancestry and the monitored app it rolls up to.
///
/// Chains are cached by `(pid, start time)`. A request belongs to the nearest process in its chain (leaf
/// first) whose executable lives inside a monitored app's bundle; apps that don't include children only
/// match the leaf.
struct CaptureAttributor {
    /// Outcome of attributing one request.
    struct Attribution: Hashable, Sendable {
        /// Ancestry, root → leaf.
        var chain: [ProcessLink]
        var appID: AppID?
        /// Index into `chain` of the process that matched the app (nil when attributed by
        /// `pathForStatistics` or not at all).
        var matchedIndex: Int?
        var bundlePath: String?
    }

    /// Identifies a process across PID reuse.
    struct ProcessKey: Hashable, Sendable {
        var pid: Int32
        var startTime: Date
    }

    /// Apps requests may be attributed to (archived apps excluded).
    private(set) var apps: [MonitoredApp] = []
    /// Bumped whenever `apps` changes, so callers can re-attribute live requests.
    private(set) var appsVersion = 0
    let cacheLimit: Int

    private var chains: [ProcessKey: [ProcessLink]] = [:]
    private var latestKey: [Int32: ProcessKey] = [:]

    init(cacheLimit: Int = 4096) {
        self.cacheLimit = cacheLimit
    }

    mutating func setApps(_ apps: [MonitoredApp]) {
        let usable = apps.filter { !$0.isArchived }
        guard usable != self.apps else { return }
        self.apps = usable
        appsVersion &+= 1
    }

    /// Process ancestry for a request (root → leaf). Falls back to a single link built from Surge's
    /// process path when the process is gone or the PID was reused.
    mutating func chain(pid: Int32?, processPath: String?, startedAt: Date, inspector: any ProcessInspecting) -> [ProcessLink] {
        let fallback = Self.fallbackChain(pid: pid, processPath: processPath)
        guard let pid, pid > 0 else { return fallback }

        if let live = inspector.process(pid: pid), live.startTime <= startedAt.addingTimeInterval(1) {
            let key = ProcessKey(pid: pid, startTime: live.startTime)
            // A process that `exec`s keeps its PID and start time but runs another binary (`sh` → `node`):
            // the cached chain only stands while its leaf still names the live executable.
            if let cached = chains[key], live.path == nil || cached.last?.path == live.path { return cached }
            let chain = inspector.chain(pid: pid, notAfter: startedAt)
            guard !chain.isEmpty else { return fallback }
            store(chain, for: key)
            return chain
        }
        // Exited or reused: the last chain seen for this PID still applies if it started before the request.
        if let key = latestKey[pid], key.startTime <= startedAt.addingTimeInterval(1), let cached = chains[key] {
            return cached
        }
        return fallback
    }

    /// Finds the monitored app for a chain.
    func attribute(chain: [ProcessLink], pathForStatistics: String?) -> Attribution {
        let bundle = CaptureRecordMapper.bundlePath(chain: chain, pathForStatistics: pathForStatistics)
        if let match = Self.match(chain: chain, apps: apps) {
            return Attribution(chain: chain, appID: match.appID, matchedIndex: match.index, bundlePath: bundle)
        }
        // Without a real ancestry, Surge's own attribution (the top-level bundle) stands in for the parents.
        if chain.count <= 1, let stats = pathForStatistics, !stats.isEmpty,
           let app = apps.first(where: { $0.includeChildren && $0.contains(processPath: stats.hasSuffix("/") ? stats : stats + "/") }) {
            return Attribution(chain: chain, appID: app.id, matchedIndex: nil, bundlePath: bundle)
        }
        return Attribution(chain: chain, appID: nil, matchedIndex: nil, bundlePath: bundle)
    }

    /// Nearest process (leaf first) inside a monitored app; apps without `includeChildren` only match the leaf.
    static func match(chain: [ProcessLink], apps: [MonitoredApp]) -> (appID: AppID, index: Int)? {
        for index in chain.indices.reversed() {
            guard let path = chain[index].path else { continue }
            let isLeaf = index == chain.count - 1
            // Prefer the most specific bundle when apps are nested (a helper app monitored on its own).
            let candidates = apps.filter { ($0.includeChildren || isLeaf) && $0.contains(processPath: path) }
            if let best = candidates.max(by: { $0.path.count < $1.path.count }) { return (best.id, index) }
        }
        return nil
    }

    static func fallbackChain(pid: Int32?, processPath: String?) -> [ProcessLink] {
        guard let processPath, !processPath.isEmpty else { return [] }
        return [ProcessLink(name: CaptureRecordMapper.processName(for: processPath), pid: pid ?? 0, path: processPath, startTime: nil)]
    }

    private mutating func store(_ chain: [ProcessLink], for key: ProcessKey) {
        if chains.count >= cacheLimit {
            chains.removeAll(keepingCapacity: true)
            latestKey.removeAll(keepingCapacity: true)
        }
        chains[key] = chain
        latestKey[key.pid] = key
    }
}
