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
