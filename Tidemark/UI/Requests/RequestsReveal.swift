import Foundation

/// What an alert's Show Request opens: the request that raised the alert, and the alert's new host or IP and app, which
/// History lists when the request is gone.
struct RequestTarget: Hashable, Sendable {
    /// The request's row in `requests`; nil for an alert stored without it.
    var rowID: Int64?
    var kind: HostKind
    /// The new domain, or the IP the app reached.
    var value: String
    var appID: AppID?

    init(rowID: Int64?, kind: HostKind, value: String, appID: AppID?) {
        self.rowID = rowID
        self.kind = kind
        self.value = value
        self.appID = appID
    }

    init(_ alert: AlertItem) {
        self.init(rowID: alert.requestRowID, kind: alert.kind, value: alert.value, appID: alert.appID)
    }
}

/// A stored request History is to show (`Navigation.openRequest`), from the moment it is asked for until History has
/// selected it, or has said why it cannot.
///
/// History first waits while the request is read and placed (`locate`): its filters become the ones that list it, and
/// when it sits deeper than `rowsAbove` rows in them, History ends at the start of the request that many rows above it
/// (`RequestQuery.until`), so it is on the first page. Once that page has arrived History selects it (`step`), reading a
/// few more pages if requests that arrived meanwhile pushed it down, and the table scrolls it into the middle.
struct RequestReveal: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        /// Reading the request and where it sits; History holds its query meanwhile.
        case finding
        /// History's filters list the request: it is selected once their first page has arrived, reading `pagesLeft`
        /// more pages at most.
        case showing(RequestKey, pagesLeft: Int)
        /// History lists the alert's host or IP instead (`fallback`), and says why.
        case missing(Missing, fallback: RequestQuery)
    }

    /// Why History cannot show the request.
    enum Missing: Equatable, Sendable {
        /// The alert was stored without its request, or no row has its ID any more (its Mac's rows were merged into
        /// another's, say).
        case notStored
        /// The request is stored, but History did not list it in the pages it read.
        case notListed
        /// Reading the request failed: why, in the UI language.
        case unreadable(String)
    }

    /// Rows History lists above a request it opens on, when there are that many.
    static let rowsAbove = 200
    /// Pages History reads after the first when the request is not on it.
    static let extraPages = 3

    /// Tells two asks for the same request apart.
    let id = UUID()
    var target: RequestTarget
    var phase: Phase = .finding

    /// What `locate` found.
    enum Location: Equatable, Sendable {
        /// The request, and History's filters and Mac scope that list it.
        case found(RequestRecord, RequestQuery)
        case missing(Missing)
    }

    /// Reads the request and the filters that list it: the alert's IP when the request reached it, otherwise the
    /// request's own host, with its app (none when the request lost it with its app), over all time, and every Mac when
    /// `scope` leaves out the request's. When more than `rowsAbove` matching requests are newer, the filters end at the
    /// start of the one `rowsAbove` rows above it.
    @MainActor
    static func locate(_ target: RequestTarget, scope: DeviceScope, database: any TidemarkDatabase) async -> Location {
        guard let rowID = target.rowID else { return .missing(.notStored) }
        let record: RequestRecord?
        do {
            record = try await database.request(id: rowID)
        } catch {
            return .missing(.unreadable(CaptureEngine.message(for: error)))
        }
        guard let record else { return .missing(.notStored) }
        var query = RequestQuery(scope: scope.includes(record.deviceID) ? scope : .all, range: .all, appID: record.appID)
        let value = RequestsHostFilter.normalized(target.value)
        if target.kind == .ip, record.remoteIP.map(RequestsHostFilter.normalized) == value {
            query.remoteIP = value
        } else {
            query.host = RequestsHostFilter.normalized(record.host)
        }
        // Without the walk History still finds the request in the pages it reads, when it is near the top.
        if let starts = try? await database.newerRequestStarts(than: record, matching: query, limit: rowsAbove), starts.count == rowsAbove {
            query.until = starts.last
        }
        return .found(record, query)
    }

    /// What History does next for the request `key` it is to show.
    enum Step: Equatable {
        /// Its page has not arrived yet.
        case wait
        case select
        case loadMore
        /// It is not in the pages read: History shows the alert's host or IP instead.
        case giveUp
        /// The page failed to load, which History already says: nothing to select.
        case stop
    }

    /// The next step once History's query has rows (`pageArrived`) or failed, `rows` being every row it read.
    static func step(for key: RequestKey, rows: [RequestRecord], pageArrived: Bool, failed: Bool, loadingMore: Bool,
                     canLoadMore: Bool, pagesLeft: Int) -> Step {
        if failed { return .stop }
        guard pageArrived, !loadingMore else { return .wait }
        if rows.contains(where: { $0.key == key }) { return .select }
        return canLoadMore && pagesLeft > 0 ? .loadMore : .giveUp
    }
}
