import Foundation

/// Browser profile used by a site probe.
enum ProbeDeviceMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// 1280 × 800, Safari desktop user agent.
    case desktop
    /// 393 × 852, mobile Safari user agent.
    case iphone
}

/// A user action during a probe ("Page load", "Click · Open a repo", "Switched to iPhone").
struct ProbeStep: Hashable, Codable, Sendable {
    /// Seconds since the probe started.
    var at: TimeInterval
    var label: String
    var url: String?
}

/// Every host a probe touched, with its activity window relative to the probe start.
struct ProbeHost: Identifiable, Hashable, Codable, Sendable {
    var host: String
    /// Seconds since probe start of the first connection.
    var firstAt: TimeInterval
    /// Seconds since probe start of the last activity.
    var lastAt: TimeInterval
    var requestCount: Int
    var ips: [String]
    /// Index into `ProbeSession.steps` of the step that first reached this host.
    var step: Int

    var id: String { host }
}

/// A finished (or running) site probe (rows in `probe_sessions` / `probe_hosts`).
struct ProbeSession: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var deviceID: DeviceID
    var url: String
    var host: String
    var mode: ProbeDeviceMode
    var startedAt: Date
    var endedAt: Date?
    var steps: [ProbeStep]
    var hosts: [ProbeHost]

    var duration: TimeInterval { (endedAt ?? .now).timeIntervalSince(startedAt) }
    var ipCount: Int { hosts.reduce(0) { $0 + $1.ips.count } }
    var requestCount: Int { hosts.reduce(0) { $0 + $1.requestCount } }
}
