import Foundation

/// One domain or IP in a monitored app's inventory (row in `app_hosts`).
struct AppHost: Identifiable, Hashable, Codable, Sendable {
    var appID: AppID
    var kind: HostKind
    var value: String
    /// Registrable domain for domains (`githubusercontent.com`), nil for IPs.
    var site: String?
    var firstSeen: Date
    var lastSeen: Date
    var requestCount: Int64
    /// Process that first contacted it (domains).
    var processName: String?
    /// Latest policy display, e.g. `AI › US-West`.
    var policy: String?
    var geo: GeoInfo?
    /// IP reached without any hostname.
    var isDirect: Bool
    /// For IPs: domains that resolved to it.
    var hosts: [String]
    /// Mac that made first contact (`app_hosts.first_device_id`).
    var firstDeviceID: DeviceID? = nil

    var id: String { "\(kind.rawValue):\(value)" }

    func isNew(now: Date = .now) -> Bool { now.timeIntervalSince(firstSeen) < 24 * 3600 }
}

/// Where a global inventory entry was seen.
struct InventorySource: Hashable, Codable, Sendable {
    /// App name, process name or `Probe · github.com`.
    var title: String
    /// Process path, or `Site probe · github.com`.
    var path: String
    var appID: AppID?
    var probeSessionID: UUID?
    /// Bundle path used to render the app icon when available.
    var bundlePath: String?
}

/// Row of the global "Domains & IPs" page, deduplicated across every app and probe.
struct InventoryEntry: Identifiable, Hashable, Sendable {
    var kind: HostKind
    var value: String
    var sources: [InventorySource]
    var firstSeen: Date
    var lastSeen: Date
    var requestCount: Int64
    var geo: GeoInfo?

    var id: String { "\(kind.rawValue):\(value)" }
}

/// A process that reached one of a monitored app's domains or IPs: the `host_sources` rows of its executable path for
/// that address and app, one per Mac, merged (`merge`).
struct HostProcess: Identifiable, Hashable, Sendable {
    /// One Mac's `host_sources` row of a process for an address.
    struct Sighting: Hashable, Sendable {
        var deviceID: DeviceID
        /// Executable path; empty (or `unknown`, in rows of early versions) when Surge never named the process.
        var path: String
        /// Process name; the Mac's name for a process Surge never named.
        var title: String
        var firstSeen: Date
        var lastSeen: Date
        var requestCount: Int64
    }

    /// Executable path; empty when Surge never named the process.
    var path: String
    /// The name the Mac that saw it last gave it.
    var name: String
    var firstSeen: Date
    var lastSeen: Date
    /// Every Mac's requests, also in a list of one Mac's processes.
    var requestCount: Int64
    /// The Macs that reported it, the one that saw it last first.
    var deviceIDs: [DeviceID]

    var id: String { path }

    /// Surge never named the process of these requests.
    var isUnreported: Bool { path.isEmpty }

    /// It first reached the address in the last 24 hours, as a domain or IP stays NEW.
    func isNew(now: Date = .now) -> Bool { now.timeIntervalSince(firstSeen) < 24 * 3600 }

    /// The most processes listed for one address.
    static let limit = 200

    /// One process per executable path, every Mac's sightings merged: their requests added up, the earliest first seen
    /// and the latest last seen, the latest name, and the Macs. A `scope` of one Mac keeps the processes that Mac
    /// reported, still with every Mac's counts and dates, as the address's own row has. Ordered like the tab's domains:
    /// what first reached the address in the last 24 hours, then the busiest, so the process that does most of the
    /// talking leads; then the most recent, then by path. Requests whose process Surge never named come last, being no
    /// process at all.
    static func merge(_ sightings: [Sighting], scope: DeviceScope = .all, now: Date = .now, limit: Int = limit) -> [HostProcess] {
        var byPath: [String: (process: HostProcess, seen: [DeviceID: Date])] = [:]
        // The latest first, so a path's first sighting names it.
        for sighting in sightings.sorted(by: { $0.lastSeen > $1.lastSeen }) {
            let path = sighting.path == "unknown" ? "" : sighting.path
            guard var entry = byPath[path] else {
                byPath[path] = (HostProcess(path: path, name: sighting.title, firstSeen: sighting.firstSeen, lastSeen: sighting.lastSeen,
                                            requestCount: sighting.requestCount, deviceIDs: []),
                                [sighting.deviceID: sighting.lastSeen])
                continue
            }
            entry.process.firstSeen = min(entry.process.firstSeen, sighting.firstSeen)
            entry.process.requestCount += sighting.requestCount
            entry.seen[sighting.deviceID] = max(entry.seen[sighting.deviceID] ?? .distantPast, sighting.lastSeen)
            byPath[path] = entry
        }
        let processes = byPath.values.compactMap { entry -> HostProcess? in
            if let device = scope.deviceID, entry.seen[device] == nil { return nil }
            var process = entry.process
            process.deviceIDs = entry.seen.sorted { a, b in a.value != b.value ? a.value > b.value : a.key.uuidString < b.key.uuidString }.map(\.key)
            return process
        }
        return Array(processes.sorted { a, b in
            if a.isUnreported != b.isUnreported { return !a.isUnreported }
            let newA = a.isNew(now: now), newB = b.isNew(now: now)
            if newA != newB { return newA }
            if a.requestCount != b.requestCount { return a.requestCount > b.requestCount }
            if a.lastSeen != b.lastSeen { return a.lastSeen > b.lastSeen }
            return a.path < b.path
        }
        .prefix(max(0, limit)))
    }
}

/// A node of an app's process tree (aggregated by executable path under its parent).
struct ProcessNode: Identifiable, Hashable, Sendable {
    var id: String
    var name: String
    /// Latest PID seen for this executable.
    var pid: Int32
    var startTime: Date?
    var path: String?
    var depth: Int
    var domainCount: Int
    var requestCount: Int64
    var isRunning: Bool
    /// Mac of the latest PID, so the UI can re-check Running/Exited for this Mac's processes.
    var deviceID: DeviceID? = nil
}
