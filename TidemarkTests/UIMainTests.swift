import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Tidemark

/// Builds request records for the main-window tests.
enum UIMainFixtures {
    static let thisMac = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!
    static let otherMac = UUID(uuidString: "00000000-0000-0000-0000-0000000000F2")!

    static let cursor = MonitoredApp(
        id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!, name: "Cursor", path: "/Applications/Cursor.app",
        bundleID: nil, tileLetter: "C", tileHue: 260, includeChildren: true, alertRule: .site, alertNewIP: true,
        archivedAt: nil, createdAt: .distantPast
    )

    static func record(
        id: Int64,
        host: String = "api2.cursor.sh",
        ip: String? = "104.18.19.125",
        method: String = "HTTPS",
        state: RequestState = .completed,
        device: DeviceID = thisMac,
        chain: [ProcessLink] = [],
        appID: AppID? = nil,
        bundle: String? = nil,
        policy: [String] = ["DIRECT"],
        startedAt: Date = Date(timeIntervalSince1970: 1_729_750_000),
        processPath: String? = nil
    ) -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device, session: 1, surgeID: id), rowID: id, startedAt: startedAt,
            setupCompletedAt: nil, completedAt: state == .active ? nil : startedAt.addingTimeInterval(0.2),
            method: method, host: host, port: 443, url: host + ":443", remoteIP: ip, remoteAddress: ip, geo: nil,
            policyPath: policy, rule: nil, state: state, inBytes: 1000, outBytes: 24, pid: chain.last?.pid,
            processPath: processPath ?? chain.last?.path, bundlePath: bundle, chain: chain, appID: appID, localAddress: nil,
            interface: nil, notes: [], isNew: false, writtenAt: nil, probeSessionID: nil
        )
    }

    static let cursorChain = [
        ProcessLink(name: "Cursor", pid: 812, path: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        ProcessLink(name: "Cursor Helper (Plugin)", pid: 851, path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"),
        ProcessLink(name: "node", pid: 1201, path: "/usr/local/bin/node"),
    ]

    static func identity(_ record: RequestRecord) -> AppIdentity {
        if record.appID == cursor.id {
            return AppIdentity(name: "Cursor", bundlePath: cursor.path, letter: "C", hue: 260, isMonitored: true, appID: cursor.id)
        }
        return AppIdentity(name: record.processName, bundlePath: nil, letter: "?", hue: nil, isMonitored: false, appID: nil)
    }
}

struct RequestsPresentationTests {
    typealias F = UIMainFixtures

    @Test func filtersLiveRowsByScopeAndSearch() {
        let rows = [
            F.record(id: 1, host: "api2.cursor.sh", chain: F.cursorChain, appID: F.cursor.id),
            F.record(id: 2, host: "github.com", ip: "20.205.243.166", device: F.otherMac),
            F.record(id: 3, host: "res.wx.qq.com", ip: "58.251.111.103", chain: [ProcessLink(name: "WeChat", pid: 9, path: "/Applications/WeChat.app/Contents/MacOS/WeChat")]),
        ]
        let all = RequestsPresentation.liveRows(rows, scope: .all, search: "", identity: F.identity)
        #expect(all.map(\.key.surgeID) == [1, 2, 3])

        let thisMac = RequestsPresentation.liveRows(rows, scope: .device(F.thisMac), search: "", identity: F.identity)
        #expect(thisMac.map(\.key.surgeID) == [1, 3])

        #expect(RequestsPresentation.liveRows(rows, scope: .all, search: "20.205", identity: F.identity).map(\.key.surgeID) == [2])
        #expect(RequestsPresentation.liveRows(rows, scope: .all, search: " WECHAT ", identity: F.identity).map(\.key.surgeID) == [3])
        #expect(RequestsPresentation.liveRows(rows, scope: .all, search: "node", identity: F.identity).map(\.key.surgeID) == [1])
        #expect(RequestsPresentation.liveRows(rows, scope: .all, search: "cursor", identity: F.identity).map(\.key.surgeID) == [1])
        #expect(RequestsPresentation.liveRows(rows, scope: .all, search: "", monitoredOnly: true, identity: F.identity).map(\.key.surgeID) == [1])
    }

    @Test func hidesAppleServices() {
        let apsd = F.record(id: 1, host: "courier.push.apple.com", chain: [ProcessLink(name: "apsd", pid: 4, path: "/System/Library/PrivateFrameworks/ApplePushService.framework/apsd")])
        let icloud = F.record(id: 2, host: "p57-contacts.icloud.com")
        let other = F.record(id: 3, host: "notapple.com")
        #expect(RequestsPresentation.isAppleService(apsd))
        #expect(RequestsPresentation.isAppleService(icloud))
        #expect(!RequestsPresentation.isAppleService(other))
        let visible = RequestsPresentation.liveRows([apsd, icloud, other], scope: .all, search: "", hideAppleServices: true, identity: F.identity)
        #expect(visible.map(\.key.surgeID) == [3])
    }

    @Test func mapsStatus() {
        #expect(RequestsPresentation.status(of: F.record(id: 1, method: "HTTPS")) == .tunnel)
        #expect(RequestsPresentation.status(of: F.record(id: 1, method: "GET")) == .completed)
        #expect(RequestsPresentation.status(of: F.record(id: 1, state: .active)) == .active)
        #expect(RequestsPresentation.status(of: F.record(id: 1, state: .failed)) == .failed)
        #expect(RequestsPresentation.status(of: F.record(id: 1, state: .rejected)).isError)
    }

    @Test func describesAttribution() {
        let rolled = F.record(id: 1, chain: F.cursorChain, appID: F.cursor.id)
        #expect(RequestsPresentation.attribution(for: rolled, app: F.cursor, displayName: "Cursor") == .rolledUp(app: "Cursor", parents: 2))

        let direct = F.record(id: 2, chain: [F.cursorChain[0]], appID: F.cursor.id)
        #expect(RequestsPresentation.attribution(for: direct, app: F.cursor, displayName: "Cursor") == .direct(app: "Cursor"))

        let helper = F.record(id: 3, chain: Array(F.cursorChain.prefix(2)), appID: F.cursor.id)
        #expect(RequestsPresentation.attribution(for: helper, app: F.cursor, displayName: "Cursor") == .rolledUp(app: "Cursor", parents: 1))

        let spotify = F.record(id: 4, chain: [ProcessLink(name: "Spotify", pid: 7, path: "/Applications/Spotify.app/Contents/MacOS/Spotify")])
        #expect(RequestsPresentation.attribution(for: spotify, app: nil, displayName: "Spotify") == .unmonitored(app: "Spotify"))
    }

    @Test func fallsBackToTheLeafWithoutAChain() {
        let record = F.record(id: 1, chain: [], processPath: "/usr/bin/curl")
        let links = RequestsPresentation.chainLinks(for: record)
        #expect(links.count == 1)
        #expect(links[0].name == "curl")
    }

    @Test func leavesUnknownProcessesToTheView() {
        // QUIC / UDP flows can arrive without a PID: no chain, no path, no bundle.
        let quic = F.record(id: 1, host: "apple-relay.cloudflare.com", method: "QUIC")
        #expect(RequestsPresentation.processName(of: quic) == nil)
        #expect(RequestsPresentation.chainLinks(for: quic).map(\.name) == [""])
        #expect(RequestsPresentation.hostContext(for: quic, appName: nil).processName == nil)

        let placeholder = AppIdentity(name: "Unknown", bundlePath: nil, letter: "U", hue: nil, isMonitored: false, appID: nil)
        #expect(RequestsPresentation.isUnattributed(quic, identity: placeholder))
        let shown = RequestsPresentation.displayIdentity(placeholder, for: quic, unknownName: "未知进程")
        #expect(shown.name == "未知进程")
        #expect(shown.letter == "?")

        // The placeholder is not data: searching for it finds nothing, and CSV leaves the column empty.
        #expect(!RequestsPresentation.matches(quic, needle: "unknown", appName: ""))
        let line = RequestsCSV.line(for: quic, appName: nil, deviceName: nil)
        #expect(line.split(separator: ",", omittingEmptySubsequences: false)[3] == "")

        // Anything that names the sender keeps its identity.
        let curl = F.record(id: 2, processPath: "/usr/bin/curl")
        let curlIdentity = AppIdentity(name: "curl", bundlePath: nil, letter: "c", hue: nil, isMonitored: false, appID: nil)
        #expect(RequestsPresentation.processName(of: curl) == "curl")
        #expect(RequestsPresentation.displayIdentity(curlIdentity, for: curl, unknownName: "?") == curlIdentity)
        let spotify = F.record(id: 3, bundle: "/Applications/Spotify.app")
        let spotifyIdentity = AppIdentity(name: "Spotify", bundlePath: "/Applications/Spotify.app", letter: "S", hue: nil, isMonitored: false, appID: nil)
        #expect(!RequestsPresentation.isUnattributed(spotify, identity: spotifyIdentity))
    }

    @MainActor
    @Test func localizesTheUnknownProcess() {
        let suite = "tidemark-tests-\(UUID().uuidString)"
        let model = AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: suite)!))
        let quic = F.record(id: 1, method: "QUIC")
        let saved = Localizer.shared.preference
        defer {
            Localizer.shared.preference = saved
            UserDefaults.standard.removePersistentDomain(forName: suite)
        }

        Localizer.shared.preference = .english
        #expect(model.requestsIdentity(for: quic).name == "Unknown process")
        Localizer.shared.preference = .chinese
        guard Localizer.shared.bundle != nil else { return }
        #expect(model.requestsIdentity(for: quic).name == "未知进程")
    }

    @Test func detectsFreshRows() {
        let start = Date(timeIntervalSince1970: 1_000)
        let record = F.record(id: 1, startedAt: start)
        #expect(RequestsPresentation.isFresh(record, now: start.addingTimeInterval(1)))
        #expect(!RequestsPresentation.isFresh(record, now: start.addingTimeInterval(2)))
    }

    @Test func encodesJSON() throws {
        let json = RequestsPresentation.json(for: F.record(id: 42, host: "api.github.com"))
        let object = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        #expect(object["host"] as? String == "api.github.com")
        #expect(json.contains("\n"))
    }
}

@MainActor
struct RequestsRowTintTests {
    typealias F = UIMainFixtures

    /// A row view with a separator-like view and two cells, the first hosting the tint anchor.
    private func makeRow() -> (row: NSTableRowView, firstCell: NSTableCellView, anchor: RequestsRowTintAnchor) {
        let row = NSTableRowView(frame: NSRect(x: 0, y: 0, width: 600, height: 24))
        row.addSubview(NSView(frame: row.bounds))
        let firstCell = NSTableCellView(frame: NSRect(x: 16, y: 0, width: 86, height: 24))
        let secondCell = NSTableCellView(frame: NSRect(x: 119, y: 0, width: 200, height: 24))
        row.addSubview(firstCell)
        row.addSubview(secondCell)
        let host = NSView(frame: firstCell.bounds)
        firstCell.addSubview(host)
        let anchor = RequestsRowTintAnchor(frame: host.bounds)
        host.addSubview(anchor)
        return (row, firstCell, anchor)
    }

    private func band(in row: NSTableRowView) -> RequestsRowBand? {
        row.subviews.compactMap { $0 as? RequestsRowBand }.first
    }

    @Test func tintsTheWholeRowBelowTheCells() throws {
        let (row, firstCell, anchor) = makeRow()
        anchor.apply(key: F.record(id: 1).key, isFresh: true, animated: true)

        let band = try #require(band(in: row))
        #expect(band.alphaValue == 1)
        #expect(band.frame == row.bounds.insetBy(dx: RequestsRowBand.horizontalInset, dy: 0))
        let bandIndex = try #require(row.subviews.firstIndex(of: band))
        let cellIndex = try #require(row.subviews.firstIndex(of: firstCell))
        #expect(bandIndex < cellIndex)
        #expect(bandIndex > 0, "above the row's own background views")

        // Updating again reuses the same band.
        anchor.apply(key: F.record(id: 1).key, isFresh: true, animated: true)
        #expect(row.subviews.filter { $0 is RequestsRowBand }.count == 1)
    }

    @Test func clearsAtOnceForAnotherRequest() throws {
        let (row, _, anchor) = makeRow()
        anchor.apply(key: F.record(id: 1).key, isFresh: true, animated: true)
        let band = try #require(band(in: row))

        // The row view now shows another request that is not fresh: no fade, no leftover tint.
        anchor.apply(key: F.record(id: 2).key, isFresh: false, animated: true)
        #expect(band.alphaValue == 0)
        #expect(band.key == F.record(id: 2).key)

        // The same request aging out fades to clear.
        anchor.apply(key: F.record(id: 3).key, isFresh: true, animated: true)
        #expect(band.alphaValue == 1)
        anchor.apply(key: F.record(id: 3).key, isFresh: false, animated: true)
        #expect(band.alphaValue == 0)
    }

    @Test func doesNothingOutsideATableRow() {
        let anchor = RequestsRowTintAnchor(frame: .zero)
        anchor.apply(key: F.record(id: 1).key, isFresh: true, animated: true)
        #expect(anchor.subviews.isEmpty)
    }
}

@MainActor
struct RequestsTableLayoutTests {
    /// The Remote IP column is fixed to the widest IPv4 address in the cell's 11 pt SF Mono, with the few
    /// points of inset the fixed Time column also leaves around its text, so a rebuilt table can't squeeze it.
    @Test func remoteIPColumnFitsEveryIPv4Address() {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let widest = ("255.255.255.255" as NSString).size(withAttributes: [.font: font]).width
        #expect(widest + 6 <= RequestsTable.remoteIPWidth)
        #expect(RequestsTable.remoteIPWidth <= 124, "the column stays narrow; App · Process and Host get the rest")
    }

    /// A rebuilt table leaves Policy at its minimum, which still shows the group and enough of the final policy
    /// to tell nodes with the same protocol apart (`AI › …kNerd-Hysteria2`, not `AI › …Hysteria2`).
    @Test func policyColumnKeepsTheGroupAndTheEndOfThePolicy() {
        let font = NSFont.systemFont(ofSize: 11, weight: .medium)
        let group = ("AI › " as NSString).size(withAttributes: [.font: font]).width
        let leafEnd = ("…kNerd-Hysteria2" as NSString).size(withAttributes: [.font: font]).width
        // 6 pt chip padding on each side.
        #expect(group + leafEnd + 12 <= RequestsTable.policyMinWidth)
        #expect(RequestsTable.policyMinWidth >= 84, "at least the design's column")
    }

    /// At its minimum the App · Process column still shows the tile, an app name like `Brave Browser` and the
    /// start of the process.
    @Test func appColumnKeepsTheAppName() {
        let name = ("Brave Browser" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .medium)]).width
        let process = (" › …" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12)]).width
        // 16 pt tile and 6 pt spacing.
        #expect(22 + name + process <= RequestsTable.appMinWidth)
    }

    /// "Open <App>" from a request (inspector and row menu) shows the app's Domains & IPs, as in the design.
    @Test func openingAnAppShowsItsDomainsAndIPs() {
        #expect(RequestsPresentation.openAppTab == .inventory)
    }
}

/// The live table's backfill and a History page reach the table as hundreds of rows in one update. With
/// NSTableView's estimated row heights, which SwiftUI turns on, more than 200 rows arriving at a table without
/// cached row heights re-enter AppKit's row height cache, which AppKit logs (and will assert on).
@MainActor
struct RequestsTableRowHeightTests {
    typealias F = UIMainFixtures

    @Test func hundredsOfRowsArriveWithoutReenteringTheTable() async throws {
        #expect(UserDefaults.standard.object(forKey: TableRowHeightDefaults.canEstimateRowHeightsKey) as? Bool == false)

        let suite = "tidemark-tests-\(UUID().uuidString)"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: suite)!))
        func liveTable(_ rows: [RequestRecord]) -> RequestsTable {
            RequestsTable(model: model, rows: rows, selection: .constant(nil), timeStyle: .clock, now: .now)
        }
        let host = NSHostingView(rootView: liveTable([]))
        // Never ordered in: the table updates and lays out off screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 500), styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        defer { window.close() }
        try await Self.waitUntil { host.layoutSubtreeIfNeeded(); return Self.table(in: host) != nil }
        let table = try #require(Self.table(in: host))

        let marker = "tidemark-row-heights-\(UUID().uuidString)"
        let output = await Self.capturingStandardError {
            NSLog("%@", marker)
            // Fresh rows, so the row tint runs too.
            host.rootView = liveTable((1...300).map { F.record(id: $0, startedAt: .now) })
            try? await Self.waitUntil { host.layoutSubtreeIfNeeded(); return table.numberOfRows == 300 }
        }
        #expect(output.contains(marker), "NSLog reaches standard error, so the check below can see AppKit's warning")
        #expect(table.numberOfRows == 300)
        #expect(!output.contains("reentrant operation"))
    }

    private static func table(in view: NSView) -> NSTableView? {
        if let table = view as? NSTableView { return table }
        return view.subviews.lazy.compactMap { table(in: $0) }.first
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<250 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }

    /// What the process writes to standard error (NSLog included) while `body` runs; it is passed on afterwards.
    private static func capturingStandardError(_ body: @MainActor () async -> Void) async -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidemark-stderr-\(UUID().uuidString).log")
        guard FileManager.default.createFile(atPath: url.path, contents: nil),
              let file = try? FileHandle(forWritingTo: url) else { return "" }
        defer { try? FileManager.default.removeItem(at: url) }
        fflush(nil)
        let saved = dup(STDERR_FILENO)
        dup2(file.fileDescriptor, STDERR_FILENO)
        await body()
        fflush(nil)
        dup2(saved, STDERR_FILENO)
        close(saved)
        try? file.close()
        let output = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        FileHandle.standardError.write(Data(output.utf8))
        return output
    }
}

struct RequestsCSVTests {
    typealias F = UIMainFixtures

    @Test func escapesFields() {
        #expect(RequestsCSV.escape("plain") == "plain")
        #expect(RequestsCSV.escape("a,b") == "\"a,b\"")
        #expect(RequestsCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(RequestsCSV.escape("two\nlines") == "\"two\nlines\"")
    }

    @Test func writesOneLinePerRecord() {
        let record = F.record(id: 7, host: "api.github.com", chain: F.cursorChain, appID: F.cursor.id, policy: ["Proxy", "HK-01"])
        let line = RequestsCSV.line(for: record, appName: "Cursor", deviceName: "MacBook Pro")
        #expect(line.hasSuffix("\r\n"))
        let fields = line.dropLast(2).split(separator: ",", omittingEmptySubsequences: false)
        #expect(fields.count == RequestsCSV.columns.count)
        #expect(fields[1] == "MacBook Pro")
        #expect(fields[2] == "Cursor")
        #expect(fields[3] == "node")
        #expect(fields[6] == "api.github.com")
        #expect(fields[9] == "Proxy > HK-01")
        #expect(fields[14] == "200")
    }

    @Test func namesUnmonitoredAppsAfterTheirBundle() {
        let record = F.record(id: 1, bundle: "/Applications/Spotify.app")
        #expect(RequestsCSV.appName(for: record, names: [:]) == "Spotify")
        #expect(RequestsCSV.appName(for: F.record(id: 2), names: [:]) == nil)
        // The same display name as the table's App column, trailing slash or not.
        let finder = "/System/Library/CoreServices/Finder.app"
        #expect(RequestsCSV.appName(for: F.record(id: 3, bundle: finder + "/"), names: [:]) == AppNaming.displayName(forBundlePath: finder))
        #expect(RequestsCSV.appName(for: F.record(id: 4, bundle: finder), names: [:])?.hasSuffix(".app") == false)
        // A monitored app keeps its own name.
        #expect(RequestsCSV.appName(for: F.record(id: 5, appID: F.cursor.id, bundle: finder), names: [F.cursor.id: "Cursor"]) == "Cursor")
    }

    @Test func streamsEveryPageToDisk() async throws {
        let base = Date.now.addingTimeInterval(-600)
        let rows = (0..<12_345).map { F.record(id: Int64($0), startedAt: base.addingTimeInterval(Double($0) * 0.01)) }
        let database = ShellDemoDatabase(rows: rows)
        var query = RequestQuery()
        query.range = .lastHour
        let snapshot = RequestsCSVSnapshot(query: query, database: database, appNames: [:], deviceNames: [F.thisMac: "MacBook Pro"])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidemark-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }

        let manager = ProgressManager(totalCount: 1)
        try await RequestsCSVWriter().write(snapshot: snapshot, to: url, previous: nil, progress: manager.subprogress(assigningCount: 1))

        let text = try String(contentsOf: url, encoding: .utf8)
        let lines = text.split(separator: "\r\n")
        #expect(lines.count == rows.count + 1)
        #expect(lines.first.map(String.init) == RequestsCSV.columns.joined(separator: ","))
        #expect(manager.fractionCompleted == 1)
    }

    @Test func ordersRowsByKeysetCursor() {
        let t = Date(timeIntervalSince1970: 1_000)
        let cursor = RequestCursor(startedAt: t, rowID: 50)
        #expect(RequestsCSV.isOlder(F.record(id: 49, startedAt: t), than: cursor))
        #expect(!RequestsCSV.isOlder(F.record(id: 50, startedAt: t), than: cursor))
        #expect(!RequestsCSV.isOlder(F.record(id: 10, startedAt: t.addingTimeInterval(1)), than: cursor))
        #expect(RequestsCSV.isOlder(F.record(id: 99, startedAt: t.addingTimeInterval(-1)), than: cursor))
        #expect(RequestsCSV.cursor(after: [F.record(id: 7, startedAt: t), F.record(id: 3, startedAt: t)]) == RequestCursor(startedAt: t, rowID: 3))
        #expect(RequestsCSV.cursor(after: []) == nil)
    }

    /// Rows recorded while the export runs land on top of the newest-first order; offset paging would shift
    /// and repeat rows, the keyset cursor neither repeats nor skips any.
    @Test func keepsPagesStableWhileRowsArrive() async throws {
        let base = Date.now.addingTimeInterval(-1_800)
        let original = (0..<12_000).map { F.record(id: Int64($0), startedAt: base.addingTimeInterval(Double($0) * 0.1)) }
        let store = RequestsGrowingStore(rows: original, nextID: 100_000)
        let database = RequestsStubDatabase(query: { query in
            await store.addNewRows(250)
            return try await ShellDemoDatabase(rows: store.rows).queryRequests(query)
        })
        var query = RequestQuery()
        query.range = .lastHour
        let ids = try await exportedRowIDs(query: query, database: database)

        #expect(ids.count == Set(ids).count, "no row is written twice")
        #expect(Set(original.compactMap(\.rowID)).isSubset(of: Set(ids)), "every row that existed is written")
        #expect(await store.queries > 1)
    }

    /// A database that ignores the cursor would hand back the first page forever; the export continues with
    /// offsets instead and still writes every row once while new rows arrive.
    @Test func fallsBackToOffsetsWhenTheCursorIsIgnored() async throws {
        let base = Date.now.addingTimeInterval(-1_800)
        let original = (0..<12_000).map { F.record(id: Int64($0), startedAt: base.addingTimeInterval(Double($0) * 0.1)) }
        let store = RequestsGrowingStore(rows: original, nextID: 100_000)
        let database = RequestsStubDatabase(query: { query in
            await store.addNewRows(250)
            var ignoringCursor = query
            ignoringCursor.before = nil
            return try await ShellDemoDatabase(rows: store.rows).queryRequests(ignoringCursor)
        })
        var query = RequestQuery()
        query.range = .lastHour
        let ids = try await exportedRowIDs(query: query, database: database)

        #expect(ids.count == Set(ids).count, "no row is written twice")
        #expect(Set(original.compactMap(\.rowID)).isSubset(of: Set(ids)), "every row that existed is written")
    }

    @Test func pagesThroughSmallResultsOnce() async throws {
        let rows = (0..<7).map { F.record(id: Int64($0), startedAt: Date.now.addingTimeInterval(-Double($0))) }
        let database = RequestsStubDatabase(query: { query in try await ShellDemoDatabase(rows: rows).queryRequests(query) })
        var pager = RequestsCSVPager(query: RequestQuery(), database: database, pageSize: 3)
        var ids = try await pager.first().rows.compactMap(\.rowID)
        while let next = try await pager.next() { ids += next.compactMap(\.rowID) }
        #expect(ids == [0, 1, 2, 3, 4, 5, 6])
    }

    private func exportedRowIDs(query: RequestQuery, database: any TidemarkDatabase) async throws -> [Int64] {
        let snapshot = RequestsCSVSnapshot(query: query, database: database, appNames: [:], deviceNames: [:])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("tidemark-export-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: url) }
        let manager = ProgressManager(totalCount: 1)
        try await RequestsCSVWriter().write(snapshot: snapshot, to: url, previous: nil, progress: manager.subprogress(assigningCount: 1))
        #expect(manager.fractionCompleted == 1)
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\r\n").dropFirst()
        return lines.compactMap { line in line.split(separator: ",", omittingEmptySubsequences: false).last.flatMap { Int64($0) } }
    }
}

/// Request rows that keep growing at the top, like a live database during an export.
private actor RequestsGrowingStore {
    private(set) var rows: [RequestRecord]
    private(set) var queries = 0
    private var nextID: Int64

    init(rows: [RequestRecord], nextID: Int64) {
        self.rows = rows
        self.nextID = nextID
    }

    func addNewRows(_ count: Int) {
        queries += 1
        let now = Date.now
        for i in 0..<count {
            rows.append(UIMainFixtures.record(id: nextID, startedAt: now.addingTimeInterval(Double(i) * 0.001)))
            nextID += 1
        }
    }
}

@MainActor
struct RequestsHistoryModelTests {
    typealias F = UIMainFixtures

    @Test func pagesThroughResults() async {
        let base = Date.now.addingTimeInterval(-60)
        let rows = (0..<1_200).map { F.record(id: Int64($0), startedAt: base.addingTimeInterval(Double($0) * 0.01)) }
        let database = ShellDemoDatabase(rows: rows)
        let history = RequestsHistoryModel()
        var query = RequestQuery()
        query.range = .lastHour

        await history.load(query, database: database)
        #expect(history.rows.count == RequestsHistoryModel.pageSize)
        #expect(history.totalCount == 1_200)
        #expect(history.histogram?.counts.count == RequestsHistoryModel.histogramBuckets)
        #expect(history.canLoadMore)

        await history.loadMore(database: database)
        await history.loadMore(database: database)
        #expect(history.rows.count == 1_200)
        #expect(!history.canLoadMore)
        #expect(Set(history.rows.map(\.key)).count == 1_200)
    }

    @Test func reportsErrors() async {
        Localizer.shared.preference = .english
        let history = RequestsHistoryModel()
        await history.load(RequestQuery(), database: RequestsStubDatabase())
        #expect(history.errorMessage == "PostgreSQL is unreachable: connection refused")
        #expect(history.rows.isEmpty)
        #expect(!history.canLoadMore)
        #expect(!history.isLoading)
        #expect(!history.isLoadingHistogram)

        // The failure reads in a language chosen after it.
        Localizer.shared.preference = .chinese
        defer { Localizer.shared.preference = .english }
        guard Localizer.shared.bundle != nil else { return }
        #expect(history.errorMessage == "连不上 PostgreSQL：connection refused")
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    /// A page with one row whose ID tells the queries apart (`old` → 1, anything else → 2).
    private nonisolated static func page(_ query: RequestQuery) -> RequestPage {
        RequestPage(rows: [F.record(id: query.search == "old" ? 1 : 2)], totalCount: 1, elapsed: .milliseconds(4))
    }

    private nonisolated static let oldChart = Histogram(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600), counts: [1, 0])
    private nonisolated static let newChart = Histogram(start: Date(timeIntervalSince1970: 0), end: Date(timeIntervalSince1970: 3600), counts: [0, 1])

    @Test func showsRowsBeforeTheHistogram() async {
        let gate = RequestsGate()
        let database = RequestsStubDatabase(
            query: { query in Self.page(query) },
            buckets: { _, _ in
                await gate.wait()
                return Self.newChart
            }
        )
        let history = RequestsHistoryModel()
        let load = Task { await history.load(RequestQuery(), database: database) }
        #expect(await eventually { history.rows.count == 1 })
        #expect(history.totalCount == 1)
        #expect(!history.isLoading)
        #expect(history.isLoadingHistogram)
        #expect(history.histogram == nil)

        await gate.open()
        await load.value
        #expect(history.histogram == Self.newChart)
        #expect(!history.isLoadingHistogram)
        #expect(history.histogramError == nil)
    }

    @Test func keepsRowsWhenTheHistogramFails() async {
        let rows = (0..<600).map { F.record(id: Int64($0)) }
        let failing = RequestsStubDatabase(
            query: { query in try await ShellDemoDatabase(rows: rows).queryRequests(query) },
            buckets: { _, _ in throw DatabaseError.unreachable("Query timed out") }
        )
        let history = RequestsHistoryModel()
        var query = RequestQuery()
        query.range = .all

        await history.load(query, database: failing)
        #expect(history.rows.count == RequestsHistoryModel.pageSize)
        #expect(history.totalCount == 600)
        #expect(history.errorMessage == nil)
        #expect(history.histogram == nil)
        #expect(history.histogramError == CaptureEngine.message(for: DatabaseError.unreachable("Query timed out")))
        #expect(history.canLoadMore)
        await history.loadMore(database: failing)
        #expect(history.rows.count == 600)

        // The next load that gets a histogram clears the note.
        await history.load(query, database: ShellDemoDatabase(rows: rows))
        #expect(history.histogramError == nil)
        #expect(history.histogram?.counts.reduce(0, +) == 600)
    }

    @Test func aFailedPageTakesTheChartWithIt() async {
        // The histogram arrives first, then the page fails.
        let pageGate = RequestsGate()
        let pageLast = RequestsStubDatabase(
            query: { _ in
                await pageGate.wait()
                throw DatabaseError.unreachable("connection refused")
            },
            buckets: { _, _ in Self.newChart }
        )
        let history = RequestsHistoryModel()
        let load = Task { await history.load(RequestQuery(), database: pageLast) }
        #expect(await eventually { history.histogram == Self.newChart })
        await pageGate.open()
        await load.value
        #expect(history.errorMessage != nil)
        #expect(history.histogram == nil)
        #expect(!history.isLoadingHistogram)

        // The page fails first: the histogram is cancelled, and one that finishes anyway is dropped.
        let chartGate = RequestsGate()
        let chartLast = RequestsStubDatabase(
            buckets: { _, _ in
                await chartGate.wait()
                if Task.isCancelled { await chartGate.noteCancellation() }
                return Self.newChart
            }
        )
        let fresh = RequestsHistoryModel()
        let second = Task { await fresh.load(RequestQuery(), database: chartLast) }
        #expect(await eventually { fresh.errorMessage != nil })
        #expect(!fresh.isLoading)
        #expect(!fresh.isLoadingHistogram)
        await chartGate.open()
        await second.value
        #expect(await chartGate.cancellations == 1)
        #expect(fresh.histogram == nil)
        #expect(fresh.histogramError == nil)
        #expect(fresh.rows.isEmpty)
    }

    @Test func aNewerLoadCancelsTheOlderHistogram() async {
        let gate = RequestsGate()
        let database = RequestsStubDatabase(
            query: { query in Self.page(query) },
            buckets: { query, _ in
                guard query.search == "old" else { return Self.newChart }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await gate.noteCancellation()
                    throw error
                }
                return Self.oldChart
            }
        )
        let history = RequestsHistoryModel()
        var old = RequestQuery()
        old.search = "old"
        let first = Task { await history.load(old, database: database) }
        #expect(await eventually { history.rows.first?.rowID == 1 })
        #expect(history.isLoadingHistogram)

        await history.load(RequestQuery(), database: database)
        await first.value
        #expect(await gate.cancellations == 1)
        #expect(history.rows.map(\.rowID) == [2])
        #expect(history.histogram == Self.newChart)
        #expect(history.histogramError == nil)
        #expect(!history.isLoadingHistogram)
    }

    @Test func dropsAnOlderHistogramThatFinishesLate() async {
        let gate = RequestsGate()
        // The old histogram ignores cancellation, like a server still working on the statement.
        let database = RequestsStubDatabase(
            query: { query in Self.page(query) },
            buckets: { query, _ in
                guard query.search == "old" else { return Self.newChart }
                await gate.wait()
                return Self.oldChart
            }
        )
        let history = RequestsHistoryModel()
        var old = RequestQuery()
        old.search = "old"
        let first = Task { await history.load(old, database: database) }
        #expect(await eventually { history.rows.first?.rowID == 1 })

        await history.load(RequestQuery(), database: database)
        #expect(history.histogram == Self.newChart)
        await gate.open()
        await first.value
        #expect(history.histogram == Self.newChart)
        #expect(history.rows.map(\.rowID) == [2])
        #expect(!history.isLoading)
        #expect(!history.isLoadingHistogram)
    }

    @Test func stopsLoadingWhenItsCallerIsCancelled() async {
        let gate = RequestsGate()
        let database = RequestsStubDatabase(
            query: { query in Self.page(query) },
            buckets: { _, _ in
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    await gate.noteCancellation()
                    throw error
                }
                return Self.newChart
            }
        )
        let history = RequestsHistoryModel()
        let load = Task { await history.load(RequestQuery(), database: database) }
        #expect(await eventually { !history.rows.isEmpty })
        load.cancel()
        await load.value
        #expect(await gate.cancellations == 1)
        #expect(!history.isLoadingHistogram)
        #expect(history.histogramError == nil)
    }

    @Test func zoomsIntoAnInterval() async {
        let now = Date.now
        let rows = (0..<600).map { F.record(id: Int64($0), startedAt: now.addingTimeInterval(-Double($0) * 10)) }
        let database = ShellDemoDatabase(rows: rows)
        let history = RequestsHistoryModel()
        var query = RequestQuery()
        query.range = .last24Hours
        let window = DateInterval(start: now.addingTimeInterval(-3_000), end: now.addingTimeInterval(-1_000))
        query.interval = window

        await history.load(query, database: database)
        #expect(history.query.interval == window)
        #expect(!history.rows.isEmpty)
        #expect(history.rows.allSatisfy { window.start <= $0.startedAt && $0.startedAt < window.end })
        #expect(history.totalCount == 200)
        #expect(history.histogram?.start == window.start)
        #expect(history.histogram?.end == window.end)
        #expect(history.histogram?.counts.reduce(0, +) == 200)
    }

    @Test func labelsQueryTime() {
        #expect(RequestsHistoryLabels.milliseconds(.milliseconds(38)) == "38 ms")
        #expect(RequestsHistoryLabels.milliseconds(.seconds(1.5)) == "1500 ms")
    }

    @Test func namesExportsAfterTheTime() {
        let name = RequestsHistoryView.exportFilename()
        #expect(name.hasPrefix("Tidemark Requests "))
        #expect(name.hasSuffix(".csv"))
    }
}

/// Holds the stub database's queries until the test opens it, and counts queries that were cancelled.
private actor RequestsGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var cancellations = 0

    /// Returns once the gate is open, whether or not the caller was cancelled meanwhile.
    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }

    func noteCancellation() { cancellations += 1 }
}

/// A database whose request queries are answered by closures; by default they fail.
private struct RequestsStubDatabase: TidemarkDatabase {
    var query: @Sendable (RequestQuery) async throws -> RequestPage = { _ in throw DatabaseError.unreachable("connection refused") }
    var buckets: @Sendable (RequestQuery, Int) async throws -> Histogram = { _, _ in throw DatabaseError.unreachable("connection refused") }

    func queryRequests(_ query: RequestQuery) async throws -> RequestPage { try await self.query(query) }
    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram { try await self.buckets(query, buckets) }

    func connect() async throws {}
    func migrate() async throws -> Int { 0 }
    func ping() async throws -> (roundTrip: Duration, serverVersion: String) { (.zero, "") }
    func schemaVersion() async throws -> Int { 0 }
    func tableNames() async throws -> [String] { [] }
    func upsertDevice(_ device: Device) async throws {}
    func devices() async throws -> [Device] { [] }
    func renameDevice(_ id: DeviceID, name: String) async throws {}
    func apps() async throws -> [MonitoredApp] { [] }
    func insertApp(_ app: MonitoredApp) async throws {}
    func updateApp(_ app: MonitoredApp) async throws {}
    func deleteApp(_ id: AppID) async throws {}
    func setInstalled(appID: AppID, deviceID: DeviceID, installed: Bool) async throws {}
    func installs() async throws -> [AppID: [DeviceID: Bool]] { [:] }
    func appStats(_ id: AppID, scope: DeviceScope) async throws -> AppStats { AppStats() }
    func countRequests(inBundle bundlePath: String) async throws -> Int64 { 0 }
    func backfill(appID: AppID, bundlePath: String) async throws -> Int64 { 0 }
    func upsertRequests(_ rows: [RequestRecord]) async throws -> [RequestKey: Int64] { [:] }
    func requestsWritten(after cursor: RequestWriteCursor, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] { [] }
    func requestWritePosition() async throws -> RequestWriteCursor { .start }
    func distinctPolicies(since: Date?) async throws -> [String] { [] }
    func countRequests(since: Date, scope: DeviceScope) async throws -> Int64 { 0 }
    func estimatedRequestCount() async throws -> Int64 { 0 }
    func deleteRequests(olderThan: Date, deviceID: DeviceID?) async throws -> Int64 { 0 }
    func upsertProcessChain(deviceID: DeviceID, chain: [ProcessLink], appID: AppID?) async throws -> Int64? { nil }
    func processTree(appID: AppID, scope: DeviceScope) async throws -> [ProcessNode] { [] }
    func knownHosts() async throws -> [AppID: Set<String>] { [:] }
    func insertAppHosts(_ hosts: [AppHost]) async throws -> [AppHost] { [] }
    func touchAppHosts(_ hosts: [AppHost]) async throws {}
    func appHosts(_ appID: AppID, scope: DeviceScope) async throws -> [AppHost] { [] }
    func touchHostSources(_ sources: [HostSourceTouch]) async throws {}
    func inventory(kind: HostKind?, search: String, scope: DeviceScope) async throws -> [InventoryEntry] { [] }
    func ipInfo(_ ip: String) async throws -> GeoInfo? { nil }
    func saveIPInfo(_ ip: String, geo: GeoInfo) async throws {}
    func insertAlerts(_ alerts: [AlertItem]) async throws -> [AlertItem] { [] }
    func alerts(filter: AlertFilter, appID: AppID?, scope: DeviceScope, limit: Int) async throws -> [AlertItem] { [] }
    func alerts(after id: Int64, excluding: DeviceID?) async throws -> [AlertItem] { [] }
    func unreadAlertCount(scope: DeviceScope) async throws -> Int { 0 }
    func markAlertsRead(_ ids: [Int64]) async throws {}
    func markAllAlertsRead(appID: AppID?, scope: DeviceScope) async throws {}
    func deleteAlert(_ id: Int64) async throws {}
    func mutes() async throws -> [String] { [] }
    func addMute(_ pattern: String) async throws {}
    func removeMute(_ pattern: String) async throws {}
    func saveProbeSession(_ session: ProbeSession) async throws {}
    func probeSessions(limit: Int) async throws -> [ProbeSession] { [] }
    func deleteProbeSession(_ id: UUID) async throws {}
    func hostInsight(_ host: String, language: String) async throws -> HostInsight? { nil }
    func saveHostInsight(_ insight: HostInsight) async throws {}
    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws {}
    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample] { [] }
    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws {}
    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange] { [] }
}

struct RequestsHistogramTests {
    @Test func splitsTheRangeIntoBins() {
        let start = Date(timeIntervalSince1970: 0)
        let histogram = Histogram(start: start, end: start.addingTimeInterval(4800), counts: [1, 2, 3, 4])
        let bins = RequestsHistogramBin.bins(of: histogram)
        #expect(bins.count == 4)
        #expect(bins[1].start == start.addingTimeInterval(1200))
        #expect(bins[1].end == start.addingTimeInterval(2400))
        #expect(bins.last?.isLast == true)
        #expect(bins[2].contains(start.addingTimeInterval(2500)))
        #expect(!bins[2].contains(start.addingTimeInterval(3600)))
    }

    private let english = Locale(identifier: "en")

    private func date(_ day: Int, _ hour: Int, _ minute: Int, _ second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute, second: second))!
    }

    private func labels(from start: Date, to end: Date, now: Date) -> [String] {
        let histogram = Histogram(start: start, end: end, counts: Array(repeating: 1, count: 48))
        return RequestsHistogramBin.axisTicks(of: histogram, now: now, locale: english, nowLabel: "Now").map(\.label)
    }

    @Test func labelsTheLastDayOnWholeHours() {
        // The design: `Oct 23 14:00 · 20:00 · Oct 24 02:00 · 08:00 · Now`.
        let now = date(24, 13, 48, 12)
        #expect(labels(from: now.addingTimeInterval(-86400), to: now, now: now) == ["Oct 23 14:00", "20:00", "Oct 24 02:00", "08:00", "Now"])
        let ticks = RequestsHistogramBin.axisTicks(of: Histogram(start: now.addingTimeInterval(-86400), end: now, counts: [1]), now: now, locale: english, nowLabel: "Now")
        #expect(ticks.first?.date == date(23, 14, 0))
        #expect(ticks.last?.date == now)
    }

    @Test func labelsShorterAndLongerRanges() {
        let now = date(24, 14, 48)
        #expect(labels(from: now.addingTimeInterval(-3600), to: now, now: now) == ["14:00", "14:15", "14:30", "Now"])
        #expect(labels(from: now.addingTimeInterval(-7 * 86400), to: now, now: now) == ["Oct 18", "Oct 20", "Oct 22", "Now"])
        #expect(labels(from: now.addingTimeInterval(-30 * 86400), to: now, now: now) == ["Sep 25", "Oct 2", "Oct 9", "Oct 16", "Now"])
    }

    @Test func labelsAZoomedWindowWithItsEnd() {
        // A window that does not end now is labelled with its end time.
        #expect(labels(from: date(24, 9, 5), to: date(24, 11, 50), now: date(24, 14, 0)) == ["10:00", "11:00", "11:50"])
        // The date appears where the day changes.
        #expect(labels(from: date(23, 22, 10), to: date(24, 1, 40), now: date(24, 14, 0)) == ["23:00", "Oct 24 00:00", "01:00", "01:40"])
        // Seconds appear once the ticks are less than a minute apart.
        #expect(labels(from: date(24, 10, 0, 5), to: date(24, 10, 1, 35), now: date(24, 14, 0)) == ["10:00:30", "10:01:00", "10:01:35"])
    }

    @Test func zoomsOnlyIntoDeliberateDrags() {
        let start = Date(timeIntervalSince1970: 0)
        let histogram = Histogram(start: start, end: start.addingTimeInterval(86400), counts: Array(repeating: 0, count: 48))
        let window = RequestsHistogramBin.zoomWindow(for: start.addingTimeInterval(3600)...start.addingTimeInterval(7200), in: histogram)
        #expect(window == DateInterval(start: start.addingTimeInterval(3600), end: start.addingTimeInterval(7200)))
        // Clamped to the chart.
        let clamped = RequestsHistogramBin.zoomWindow(for: start.addingTimeInterval(-600)...start.addingTimeInterval(3600), in: histogram)
        #expect(clamped?.start == start)
        // Shorter than half a 30-minute bar: a click, not a drag.
        #expect(RequestsHistogramBin.zoomWindow(for: start.addingTimeInterval(3600)...start.addingTimeInterval(4000), in: histogram) == nil)
    }

    @Test func labelsWindows() {
        #expect(RequestsHistogramBin.windowLabel(date(24, 14, 0), date(24, 14, 30), locale: english) == "14:00–14:30")
        #expect(RequestsHistogramBin.windowLabel(date(24, 14, 0, 5), date(24, 14, 1, 5), locale: english) == "14:00:05–14:01:05")
        #expect(RequestsHistogramBin.windowLabel(date(23, 22, 0), date(24, 1, 30), locale: english) == "Oct 23 22:00–Oct 24 01:30")
    }
}

struct NotificationsPresentationTests {
    private func alert(_ id: Int64, kind: HostKind, scope: AlertScope, value: String, read: Bool = false, at date: Date = .now,
                       site: String? = nil, host: String? = nil, ip: String? = nil, direct: Bool = false) -> AlertItem {
        AlertItem(id: id, deviceID: UIMainFixtures.thisMac, appID: UIMainFixtures.cursor.id, kind: kind, scope: scope, value: value,
                  site: site, host: host, ip: ip, geo: GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare, Inc."),
                  processName: "node", isDirect: direct, requestRowID: nil, createdAt: date, readAt: read ? date : nil)
    }

    @Test func filtersAndSortsNewestFirst() {
        let now = Date.now
        let items = [
            alert(1, kind: .domain, scope: .host, value: "a.com", read: true, at: now.addingTimeInterval(-30)),
            alert(2, kind: .ip, scope: .ip, value: "1.1.1.1", at: now.addingTimeInterval(-10)),
            alert(3, kind: .domain, scope: .site, value: "api.linear.app", at: now.addingTimeInterval(-20)),
        ]
        #expect(NotificationsPresentation.filter(items, by: .all).map(\.id) == [2, 3, 1])
        #expect(NotificationsPresentation.filter(items, by: .unread).map(\.id) == [2, 3])
        #expect(NotificationsPresentation.filter(items, by: .domain).map(\.id) == [3, 1])
        #expect(NotificationsPresentation.filter(items, by: .ip).map(\.id) == [2])
    }

    @Test func groupsTodayAndEarlier() {
        let now = Date.now
        let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
        let groups = NotificationsPresentation.group([alert(1, kind: .domain, scope: .host, value: "a.com", at: now), alert(2, kind: .domain, scope: .host, value: "b.com", at: yesterday)], now: now)
        #expect(groups.today.map(\.id) == [1])
        #expect(groups.earlier.map(\.id) == [2])
    }

    @Test func wordsHeadlines() {
        let classifier = NaiveSiteClassifier()
        let site = alert(1, kind: .domain, scope: .site, value: "api.linear.app")
        #expect(NotificationsPresentation.headline(for: site, appName: "Raycast", site: classifier.site(for:)) == .newSite(app: "Raycast", site: "linear.app"))
        let host = alert(2, kind: .domain, scope: .host, value: "raw.githubusercontent.com")
        #expect(NotificationsPresentation.headline(for: host, appName: "Cursor", site: classifier.site(for:)) == .newHost(app: "Cursor", host: "raw.githubusercontent.com"))
        let ip = alert(3, kind: .ip, scope: .ip, value: "104.16.98.215", host: "production.cloudflare.docker.com")
        #expect(NotificationsPresentation.headline(for: ip, appName: "Docker", site: classifier.site(for:)) == .newIP(app: "Docker", ip: "104.16.98.215"))
        let direct = alert(4, kind: .ip, scope: .ip, value: "157.148.69.80", direct: true)
        #expect(NotificationsPresentation.headline(for: direct, appName: "WeChat", site: classifier.site(for:)) == .directIP(app: "WeChat", ip: "157.148.69.80"))
    }

    @Test func listsDetails() {
        let geo = NotificationsPresentation.Detail.text("US · AS13335 Cloudflare")
        #expect(NotificationsPresentation.details(for: alert(1, kind: .domain, scope: .site, value: "api.linear.app")) == [.firstHost("api.linear.app"), .via("node"), geo])
        #expect(NotificationsPresentation.details(for: alert(2, kind: .domain, scope: .host, value: "x.com", ip: "185.199.108.133")) == [.via("node"), .text("185.199.108.133"), geo])
        #expect(NotificationsPresentation.details(for: alert(3, kind: .ip, scope: .ip, value: "1.2.3.4", host: "a.docker.com")) == [.text("a.docker.com"), .via("node"), geo])
        #expect(NotificationsPresentation.details(for: alert(4, kind: .ip, scope: .ip, value: "1.2.3.4", direct: true)) == [.noHostname, .via("node"), geo])
    }

    @Test func leavesOutUnknownProcesses() {
        var unknown = alert(1, kind: .domain, scope: .host, value: "apple-relay.cloudflare.com", ip: "162.159.196.66")
        unknown.processName = "Unknown"
        #expect(NotificationsPresentation.details(for: unknown) == [.text("162.159.196.66"), .text("US · AS13335 Cloudflare")])
        unknown.processName = ""
        #expect(!NotificationsPresentation.details(for: unknown).contains(.via("")))
        #expect(!NotificationsPresentation.isUnknownProcessName("node"))
    }
}

@MainActor
struct ShellTests {
    @Test func mapsTheGlassPreference() {
        let clear = SidebarGlassStyle(preference: 0)
        #expect(clear.isClear)
        #expect(clear.washOpacity == 0)
        #expect(clear.designOpacity == 0.42)
        #expect(clear.designBlur == 14)

        let tinted = SidebarGlassStyle(preference: 100)
        #expect(!tinted.isClear)
        #expect(abs(tinted.designOpacity - 0.92) < 0.0001)
        #expect(tinted.designBlur == 40)
        #expect(tinted.washOpacity > SidebarGlassStyle(preference: 60).washOpacity)
        #expect(tinted.washOpacity <= 0.62)

        #expect(SidebarGlassStyle(preference: 250).amount == 1)
        #expect(SidebarGlassStyle(preference: -5).amount == 0)
    }

    @Test func listsMacsWithThisMacFirst() {
        Localizer.shared.preference = .english
        let state = DeviceState(thisDeviceID: UIMainFixtures.thisMac)
        state.devices = [
            Device(id: UIMainFixtures.otherMac, name: "Mac mini (Office)", model: nil, shortName: "mini", hue: 150, isRemoteSurge: false, rowCount: 0, lastWriteAt: .now, createdAt: .now),
            Device(id: UIMainFixtures.thisMac, name: "MacBook Pro", model: nil, shortName: "MBP", hue: 240, isRemoteSurge: false, rowCount: 0, lastWriteAt: nil, createdAt: .now),
        ]
        let options = SidebarMacOption.options(in: state, matching: "")
        #expect(options.map(\.scope) == [.all, .device(UIMainFixtures.thisMac), .device(UIMainFixtures.otherMac)])
        #expect(options[2].detail == "Online")
        #expect(SidebarMacOption.options(in: state, matching: "mini").map(\.scope) == [.device(UIMainFixtures.otherMac)])

        #expect(SidebarMacOption.current(in: state).detail == "2 Macs")
        state.scope = .device(UIMainFixtures.thisMac)
        #expect(SidebarMacOption.current(in: state).label == "MacBook Pro")
        #expect(SidebarMacOption.current(in: state).detail == "This Mac")
    }

    @Test func describesLinkStatus() {
        Localizer.shared.preference = .english
        #expect(SidebarStatusText.surge(.connected(detail: "")) == "watching requests")
        #expect(SidebarStatusText.database(.connected(detail: ""), totalRows: 1_284_093) == "1,284,093 rows")
        #expect(SidebarStatusText.help(.failed(DatabaseError.unreachable("connection refused"))) == "PostgreSQL is unreachable: connection refused")
        #expect(SidebarStatusText.help(.failed(CaptureSurgeFailure.shuttingDown)) == "Surge is shutting down")
        #expect(SidebarStatusText.help(.connected(detail: "Surge 6.10.0")) == "Surge 6.10.0")
        #expect(SidebarStatusText.help(.idle) == nil)

        // A failed link keeps its error: equal errors make equal statuses, so views only update on a new failure.
        #expect(LinkStatus.failed(DatabaseError.notConfigured) == .failed(DatabaseError.notConfigured))
        #expect(LinkStatus.failed(DatabaseError.notConfigured) != .failed(DatabaseError.invalidURL("x")))
        #expect(LinkStatus.failed(CaptureServerRejection(message: "disk full")) == .failed(CaptureServerRejection(message: "disk full")))
        #expect(LinkStatus.failed(CaptureServerRejection(message: "disk full")) != .failed(CaptureServerRejection(message: "read-only")))
        #expect(LinkStatus.failed(CaptureTimeoutError(seconds: 20)) != .failed(DatabaseError.notConfigured))
        #expect(LinkStatus.failed(DatabaseError.notConfigured) != .connecting)
    }
}
