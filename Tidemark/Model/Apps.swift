import Foundation

/// When a monitored app reaches something new, what should alert.
enum AlertRule: String, Codable, Sendable, CaseIterable, Hashable {
    /// Alert on a new site (registrable domain); new hosts under a known site are only marked NEW.
    case site
    /// Alert on every host the app has never contacted before.
    case anyHost = "any"
    /// Never alert; new hosts are still recorded and marked NEW.
    case off
}

/// An app Tidemark monitors (row in `apps`). Shared by every Mac writing to the database.
struct MonitoredApp: Identifiable, Hashable, Codable, Sendable {
    var id: AppID
    var name: String
    /// Bundle path, e.g. `/Applications/Cursor.app`. Every Mac with the same path monitors it.
    var path: String
    var bundleID: String?
    /// Fallback tile letter when the real icon is unavailable on this Mac.
    var tileLetter: String
    /// OKLCH hue (0–360) of the fallback tile.
    var tileHue: Double
    /// Roll helpers, node, git… anything it launches up to this app.
    var includeChildren: Bool
    var alertRule: AlertRule
    var alertNewIP: Bool
    var archivedAt: Date?
    /// "Monitoring since".
    var createdAt: Date

    var isArchived: Bool { archivedAt != nil }

    /// `true` when `processPath` lives inside this app's bundle.
    func contains(processPath: String) -> Bool {
        let root = path.hasSuffix("/") ? path : path + "/"
        return processPath.hasPrefix(root)
    }
}

/// Counters shown in an app's header and sidebar badge.
struct AppStats: Hashable, Sendable {
    var domains: Int = 0
    var ips: Int = 0
    var requests: Int64 = 0
    var processes: Int = 0
    /// Domains and IPs first seen in the last 24 hours.
    var newIn24h: Int = 0
    var newDomainsIn24h: Int = 0
    var sites: Int = 0
    var directIPs: Int = 0
}

/// A running (or chosen) application that could be monitored, shown in the "Monitor an App" sheet.
struct AppCandidate: Identifiable, Hashable, Sendable {
    var id: String { path }
    var name: String
    var path: String
    var bundleID: String?
    /// Requests already in the database that would be backfilled.
    var pastRequests: Int64
}
