import Foundation

/// Time window for the History view.
enum HistoryRange: String, CaseIterable, Sendable, Hashable {
    case lastHour
    case last24Hours
    case last7Days
    case last30Days
    case all

    func lowerBound(now: Date = .now) -> Date? {
        switch self {
        case .lastHour: now.addingTimeInterval(-3600)
        case .last24Hours: now.addingTimeInterval(-24 * 3600)
        case .last7Days: now.addingTimeInterval(-7 * 24 * 3600)
        case .last30Days: now.addingTimeInterval(-30 * 24 * 3600)
        case .all: nil
        }
    }
}

/// Status filter for the History view.
enum StatusFilter: String, CaseIterable, Sendable, Hashable {
    case any
    case completed
    case active
    case failed
}

/// Filter applied to request queries (History view, app request history).
struct RequestQuery: Hashable, Sendable {
    var scope: DeviceScope = .all
    var range: HistoryRange = .last24Hours
    var appID: AppID?
    /// Final policy name (`policy` column), nil = all.
    var policy: String?
    var status: StatusFilter = .any
    /// Matches host, remote IP and process name (case-insensitive substring).
    var search: String = ""
    /// Only requests to exactly this host (domain or IP literal), nil = all.
    var host: String? = nil
    /// Only requests that reached exactly this IP address, nil = all: those whose remote IP it is, whatever host they
    /// named, as Domains & IPs count an IP. A request to an IP literal has the literal as its remote IP.
    var remoteIP: String? = nil
    /// Only requests whose connection ended with an error (`RequestEndReason`), whatever their `status`: Surge
    /// marks resets and broken pipes completed.
    var endedWithError = false
    var limit: Int = 500
    var offset: Int = 0
}

/// A page of request rows with the total match count and query timing.
struct RequestPage: Sendable {
    var rows: [RequestRecord]
    var totalCount: Int64
    var elapsed: Duration
}

/// Request counts over evenly spaced time buckets (History histogram).
struct Histogram: Sendable, Hashable {
    var start: Date
    var end: Date
    var counts: [Int64]
}
