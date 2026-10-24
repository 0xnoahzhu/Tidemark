import Foundation

/// What made an alert fire.
enum AlertScope: String, Codable, Sendable, Hashable {
    /// First host of a site (registrable domain) the app never touched.
    case site
    /// A new host (under any rule `anyHost`).
    case host
    /// A new IP address.
    case ip
}

/// First contact of a monitored app with a new site, host or IP (row in `alerts`).
struct AlertItem: Identifiable, Hashable, Codable, Sendable {
    var id: Int64
    var deviceID: DeviceID
    var appID: AppID
    var kind: HostKind
    var scope: AlertScope
    /// Host name for domain alerts, the IP for IP alerts.
    var value: String
    /// Registrable domain for domain alerts.
    var site: String?
    /// Hostname associated with an IP alert (empty when the app connected straight to the IP).
    var host: String?
    var ip: String?
    var geo: GeoInfo?
    var processName: String
    /// The app reached this IP with no hostname at all.
    var isDirect: Bool
    var requestRowID: Int64?
    var createdAt: Date
    var readAt: Date?

    var isUnread: Bool { readAt == nil }
}

/// Filter segments on the Notifications page.
enum AlertFilter: String, CaseIterable, Sendable, Hashable {
    case all
    case unread
    case domain
    case ip
}
