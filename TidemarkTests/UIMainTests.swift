import Foundation
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
        let history = RequestsHistoryModel()
        await history.load(RequestQuery(), database: RequestsFailingDatabase())
        #expect(history.errorMessage != nil)
        #expect(history.rows.isEmpty)
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

/// A database whose request queries always fail.
private struct RequestsFailingDatabase: TidemarkDatabase {
    func queryRequests(_ query: RequestQuery) async throws -> RequestPage { throw DatabaseError.unreachable("connection refused") }
    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram { throw DatabaseError.unreachable("connection refused") }

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
    func requestsWritten(after cursor: Date, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] { [] }
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
        #expect(RequestsHistogramBin.axisDates(of: histogram) == [start, start.addingTimeInterval(2400), start.addingTimeInterval(4800)])
    }

    @Test func labelsTheAxisByRange() {
        let date = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 23, hour: 14, minute: 0))!
        let english = Locale(identifier: "en")
        #expect(RequestsHistogramBin.axisLabel(date, span: 3600, locale: english) == "14:00")
        #expect(RequestsHistogramBin.axisLabel(date, span: 86400, locale: english) == "Oct 23 14:00")
        #expect(RequestsHistogramBin.axisLabel(date, span: 30 * 86400, locale: english) == "Oct 23")
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
        #expect(SidebarStatusText.help(.failed(message: "connection refused")) == "connection refused")
        #expect(SidebarStatusText.help(.idle) == nil)
    }
}
