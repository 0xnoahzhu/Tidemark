import AppKit
import Foundation
import Testing
@testable import Tidemark

/// An alert's Show Request: History on the alert's host or IP while the request is read, the filters that list it, where
/// History starts for one deep in its host's history, the pages it reads to find it, and what it shows without it.
@MainActor
struct RequestsRevealTests {
    typealias M = UIMainFixtures

    static let start = Date(timeIntervalSince1970: 1_729_750_000)

    /// Cursor's request `id` to `host`, `seconds` after `start`.
    static func row(_ id: Int64, host: String = "api2.cursor.sh", ip: String? = "104.18.19.125", seconds: Double,
                    device: DeviceID = M.thisMac, app: AppID? = M.cursor.id) -> RequestRecord {
        M.record(id: id, host: host, ip: ip, device: device, appID: app, startedAt: start.addingTimeInterval(seconds))
    }

    @Test func opensHistoryOnTheAlertsHostWhileItFindsTheRequest() {
        let nav = Navigation()
        nav.open(.requests)
        nav.requestsLive = false
        nav.selectedRequest = M.record(id: 9).key
        nav.requestSearch = "node"
        nav.history.range = .lastHour
        nav.history.policy = "DIRECT"
        nav.history.status = .failed
        nav.history.endedWithError = true
        nav.history.until = Self.start

        let target = RequestTarget(rowID: 42, kind: .domain, value: " API2.Cursor.sh ", appID: M.cursor.id)
        nav.openRequest(target)
        #expect(nav.page == .requests && !nav.requestsLive)
        // The inspector keeps the request it shows until the one asked for replaces it: closing it would clear that.
        #expect(nav.selectedRequest == M.record(id: 9).key)
        #expect(nav.history.host == "api2.cursor.sh" && nav.history.remoteIP == nil && nav.history.appID == M.cursor.id)
        #expect(nav.history.range == .all && nav.history.until == nil && nav.history.policy == nil)
        #expect(nav.history.status == .any && !nav.history.endedWithError && nav.requestSearch.isEmpty)
        #expect(nav.revealing?.target == target && nav.revealing?.phase == .finding)

        // An IP alert opens on the requests that reached the IP; each ask is its own.
        let first = nav.revealing?.id
        nav.openRequest(RequestTarget(rowID: 42, kind: .ip, value: "104.18.19.125", appID: M.cursor.id))
        #expect(nav.history.remoteIP == "104.18.19.125" && nav.history.host == nil)
        #expect(nav.revealing?.id != first)

        // Any other way into History forgets the request it was to show.
        nav.openRequests(forHost: "api.github.com")
        #expect(nav.revealing == nil && nav.history.until == nil)

        // From another page no request stays selected.
        nav.open(.notifications)
        nav.openRequest(target)
        #expect(nav.page == .requests && nav.selectedRequest == nil)
    }

    @Test func findsTheRequestAmongItsHostsRequestsByItsApp() async throws {
        let rows = [Self.row(1, seconds: 0), Self.row(2, seconds: 10), Self.row(3, host: "api.github.com", seconds: 20), Self.row(4, seconds: 30)]
        let database = ShellDemoDatabase(rows: rows)
        let target = RequestTarget(rowID: 1, kind: .domain, value: "api2.cursor.sh", appID: M.cursor.id)
        guard case .found(let record, let query) = await RequestReveal.locate(target, scope: .all, database: database) else {
            Issue.record("the request is stored")
            return
        }
        #expect(record.key == rows[0].key)
        #expect(query == RequestQuery(scope: .all, range: .all, appID: M.cursor.id, host: "api2.cursor.sh"))
        // Few requests above it: History's first page lists it as it is.
        #expect(try await database.queryRequests(query).rows.map(\.key.surgeID) == [4, 2, 1])
    }

    /// A request deep in its host's history (a first contact is its app's oldest request to the host) is on the first
    /// page of History that ends `rowsAbove` rows above it.
    @Test func startsALittleAboveARequestDeepInItsHost() async throws {
        let newer = (2...800).map { Self.row(Int64($0), seconds: Double($0)) }
        let database = ShellDemoDatabase(rows: [Self.row(1, seconds: 0)] + newer)
        let target = RequestTarget(rowID: 1, kind: .domain, value: "api2.cursor.sh", appID: M.cursor.id)
        guard case .found(let record, let query) = await RequestReveal.locate(target, scope: .all, database: database) else {
            Issue.record("the request is stored")
            return
        }
        #expect(query.until == Self.start.addingTimeInterval(Double(RequestReveal.rowsAbove + 1)))
        let page = try await database.queryRequests(RequestQuery(range: query.range, appID: query.appID, host: query.host, until: query.until))
        #expect(page.rows.firstIndex { $0.key == record.key } == RequestReveal.rowsAbove)
    }

    /// An IP alert lists the requests that reached its IP when the request did, else the request's own host; the request
    /// of another Mac shows every Mac, and one that lost its app (with the app) every app.
    @Test func filtersThatListTheRequest() async {
        let rows = [
            Self.row(1, host: "production.cloudflare.docker.com", ip: "104.16.98.215", seconds: 0),
            Self.row(2, host: "registry.npmjs.org", ip: "104.16.27.34", seconds: 0, device: M.otherMac, app: nil),
        ]
        let database = ShellDemoDatabase(rows: rows)
        let reached = RequestTarget(rowID: 1, kind: .ip, value: "104.16.98.215", appID: M.cursor.id)
        if case .found(_, let query) = await RequestReveal.locate(reached, scope: .device(M.thisMac), database: database) {
            #expect(query.remoteIP == "104.16.98.215" && query.host == nil && query.scope == .device(M.thisMac))
        } else {
            Issue.record("the request is stored")
        }
        let elsewhere = RequestTarget(rowID: 2, kind: .ip, value: "104.16.98.215", appID: M.cursor.id)
        if case .found(_, let query) = await RequestReveal.locate(elsewhere, scope: .device(M.thisMac), database: database) {
            #expect(query.host == "registry.npmjs.org" && query.remoteIP == nil)
            #expect(query.scope == .all && query.appID == nil)
        } else {
            Issue.record("the request is stored")
        }
    }

    @Test func saysWhyItCannotFindTheRequest() async {
        Localizer.shared.override = "en"
        let database = ShellDemoDatabase(rows: [Self.row(1, seconds: 0)])
        let noRow = RequestTarget(rowID: nil, kind: .domain, value: "api2.cursor.sh", appID: M.cursor.id)
        #expect(await RequestReveal.locate(noRow, scope: .all, database: database) == .missing(.notStored))
        let gone = RequestTarget(rowID: 99, kind: .domain, value: "api2.cursor.sh", appID: M.cursor.id)
        #expect(await RequestReveal.locate(gone, scope: .all, database: database) == .missing(.notStored))
        let offline = await RequestReveal.locate(gone, scope: .all, database: OfflineDatabase())
        guard case .missing(.unreadable(let message)) = offline else {
            Issue.record("an unreadable request says why")
            return
        }
        #expect(!message.isEmpty)
    }

    @Test func stepsThroughThePagesToTheRequest() {
        let rows = [Self.row(2, seconds: 10), Self.row(1, seconds: 0)]
        let key = rows[1].key
        let other = Self.row(9, seconds: -10).key
        func step(_ key: RequestKey, arrived: Bool = true, failed: Bool = false, loadingMore: Bool = false, more: Bool = true,
                  pagesLeft: Int = 3) -> RequestReveal.Step {
            RequestReveal.step(for: key, rows: rows, pageArrived: arrived, failed: failed, loadingMore: loadingMore, canLoadMore: more,
                               pagesLeft: pagesLeft)
        }
        #expect(step(key, arrived: false) == .wait)
        #expect(step(key) == .select)
        #expect(step(other) == .loadMore)
        #expect(step(other, loadingMore: true) == .wait)
        #expect(step(other, pagesLeft: 0) == .giveUp)
        #expect(step(other, more: false) == .giveUp)
        #expect(step(key, arrived: false, failed: true) == .stop)
    }

    /// History tells whether the rows it has are a query's, which the request is looked for in, once its page arrived.
    @Test func historyTellsWhenAQuerysPageArrived() async {
        let history = RequestsHistoryModel()
        var query = RequestQuery(range: .all, host: "api2.cursor.sh", until: Self.start)
        #expect(!history.hasPage(for: query))
        await history.load(query, database: ShellDemoDatabase(rows: [Self.row(1, seconds: 0)]))
        #expect(history.hasPage(for: query) && !history.failed(query))
        query.until = nil
        #expect(!history.hasPage(for: query))
        await history.load(query, database: RequestsStubDatabase())
        #expect(!history.hasPage(for: query) && history.failed(query))
    }

    /// The row is scrolled into the middle of the rows the table shows, or as near as its ends allow.
    @Test func centersTheRowInTheTable() throws {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 400, height: 300))
        let table = NSTableView(frame: scroll.bounds)
        table.addTableColumn(NSTableColumn(identifier: .init("time")))
        table.rowHeight = 20
        let rows = Rows()
        table.dataSource = rows
        scroll.documentView = table
        window.contentView = scroll
        table.reloadData()
        let clip = scroll.contentView

        func shownMiddle() -> CGFloat {
            let insets = clip.contentInsets
            return clip.bounds.minY + insets.top + (clip.bounds.height - insets.top - insets.bottom) / 2
        }
        RequestsTableHandle.center(row: 200, in: table)
        #expect(abs(table.rect(ofRow: 200).midY - shownMiddle()) < 1)
        RequestsTableHandle.center(row: 1, in: table)
        #expect(clip.constrainBoundsRect(clip.bounds).origin == clip.bounds.origin)
        #expect(table.visibleRect.contains(table.rect(ofRow: 1)))
        RequestsTableHandle.center(row: 399, in: table)
        #expect(table.visibleRect.contains(table.rect(ofRow: 399)))
        #expect(shownMiddle() < table.rect(ofRow: 399).minY)
    }

    /// 400 rows of nothing.
    private final class Rows: NSObject, NSTableViewDataSource {
        func numberOfRows(in tableView: NSTableView) -> Int { 400 }
    }
}
