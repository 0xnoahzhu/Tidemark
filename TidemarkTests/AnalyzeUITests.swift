import Foundation
import Testing
@testable import Tidemark

// Tests for the Analyze pages (monitored app, Domains & IPs, Site Probe, Egress IP).

private func host(_ value: String, kind: HostKind = .domain, site: String? = nil, ageHours: Double = 48, requests: Int64 = 1,
                  direct: Bool = false, hosts: [String] = [], now: Date) -> AppHost {
    AppHost(appID: UUID(), kind: kind, value: value, site: site,
            firstSeen: now.addingTimeInterval(-ageHours * 3600), lastSeen: now, requestCount: requests,
            processName: nil, policy: nil, geo: nil, isDirect: direct, hosts: hosts)
}

private func naiveSite(_ host: String) -> String { NaiveSiteClassifier().site(for: host) }

@Suite @MainActor struct AnalyzeColumnsLayoutTests {
    @Test func sharesFlexibleSpaceByWeight() {
        let widths = AnalyzeColumnsLayout.widths(for: [.fixed(100), .flexible(weight: 1), .flexible(weight: 1.5)], spacing: 10, total: 620)
        #expect(widths[0] == 100)
        #expect(abs(widths[1] - 200) < 0.001)
        #expect(abs(widths[2] - 300) < 0.001)
    }

    @Test func pinsFlexibleColumnsAtTheirMinimum() {
        let widths = AnalyzeColumnsLayout.widths(for: [.fixed(300), .flexible(weight: 1, min: 120), .flexible(weight: 3)], spacing: 0, total: 500)
        #expect(widths[1] == 120)
        #expect(abs(widths[2] - 80) < 0.001)
    }

    @Test func neverReturnsNegativeWidths() {
        let widths = AnalyzeColumnsLayout.widths(for: [.fixed(400), .flexible()], spacing: 10, total: 200)
        #expect(widths[1] == 0)
    }
}

@Suite @MainActor struct AnalyzeCSVTests {
    @Test func escapesSeparatorsQuotesAndNewlines() {
        #expect(AnalyzeCSV.escape("plain") == "plain")
        #expect(AnalyzeCSV.escape("a,b") == "\"a,b\"")
        #expect(AnalyzeCSV.escape("say \"hi\"") == "\"say \"\"hi\"\"\"")
        #expect(AnalyzeCSV.escape("two\nlines") == "\"two\nlines\"")
    }

    @Test func writesHeaderAndRowsWithCRLF() {
        let csv = AnalyzeCSV.make(header: ["a", "b"], rows: [["1", "x,y"]])
        #expect(csv == "a,b\r\n1,\"x,y\"\r\n")
    }

    @Test func exportsAppInventoryWithMutesAndDirectIPs() {
        let now = Date()
        let hosts = [
            host("api.github.com", site: "github.com", ageHours: 2, requests: 12, now: now),
            host("149.154.175.60", kind: .ip, direct: true, now: now),
        ]
        let lines = AnalyzeCSV.appHosts(hosts, mutes: ["*.github.com"], now: now).components(separatedBy: "\r\n")
        #expect(lines[0].hasPrefix("kind,value,site,first_seen"))
        let domain = lines[1].components(separatedBy: ",")
        #expect(domain[0] == "domain" && domain[1] == "api.github.com" && domain[2] == "github.com")
        #expect(domain[5] == "12" && domain[6] == "yes" && domain[7] == "yes")
        let ip = lines[2].components(separatedBy: ",")
        #expect(ip[0] == "ip" && ip[8] == "yes" && ip[7] == "no")
    }
}

@Suite @MainActor struct AppDetailInventorySummaryTests {
    @Test func groupsDomainsBySiteWithNewSitesFirst() {
        let now = Date()
        let hosts = [
            host("api2.cursor.sh", requests: 900, now: now),
            host("api3.cursor.sh", ageHours: 3, requests: 50, now: now),
            host("raw.githubusercontent.com", ageHours: 1, requests: 2, now: now),
            host("objects.githubusercontent.com", ageHours: 5, requests: 40, now: now),
            host("104.18.19.125", kind: .ip, requests: 10, hosts: ["api2.cursor.sh"], now: now),
            host("149.154.175.60", kind: .ip, ageHours: 2, direct: true, now: now),
        ]
        let summary = AppDetailInventorySummary(hosts: hosts, search: "", now: now, site: naiveSite)
        #expect(summary.domainCount == 4)
        #expect(summary.siteCount == 2)
        #expect(summary.ipCount == 2)
        #expect(summary.directIPCount == 1)
        #expect(summary.newCount == 4)
        #expect(summary.groups.map(\.site) == ["githubusercontent.com", "cursor.sh"])
        #expect(summary.groups[0].isNewSite)
        #expect(!summary.groups[1].isNewSite)
        // New hosts first inside a site, then by requests.
        #expect(summary.groups[1].hosts.map(\.value) == ["api3.cursor.sh", "api2.cursor.sh"])
        #expect(summary.groups[0].requests == 42)
        #expect(summary.directIPs.map(\.value) == ["149.154.175.60"])
        #expect(summary.resolvedIPs.map(\.value) == ["104.18.19.125"])
        #expect(summary.headline.contains("4") && summary.headline.contains("1"))
    }

    @Test func searchFiltersRowsButNotCounts() {
        let now = Date()
        let hosts = [
            host("api.github.com", now: now),
            host("github.com", now: now),
            host("api.notion.com", now: now),
            host("20.205.243.166", kind: .ip, hosts: ["github.com"], now: now),
        ]
        let summary = AppDetailInventorySummary(hosts: hosts, search: "github", now: now, site: naiveSite)
        #expect(summary.domainCount == 3)
        #expect(summary.groups.map(\.site) == ["github.com"])
        #expect(summary.groups[0].hosts.count == 2)
        #expect(summary.resolvedIPs.count == 1)
    }

    @Test func selectionHighlightsResolvedIPs() {
        let now = Date()
        let hosts = [
            host("api2.cursor.sh", now: now),
            host("104.18.19.125", kind: .ip, hosts: ["api2.cursor.sh"], now: now),
            host("104.18.18.125", kind: .ip, hosts: ["api3.cursor.sh"], now: now),
        ]
        let summary = AppDetailInventorySummary(hosts: hosts, search: "", now: now, site: naiveSite)
        #expect(summary.selectedHost("api2.cursor.sh") == "api2.cursor.sh")
        #expect(summary.selectedHost("gone.example.com") == nil)
        #expect(summary.visibleIPCount(selectedHost: "api2.cursor.sh") == 1)
        #expect(summary.visibleIPCount(selectedHost: nil) == 2)
    }

    /// "x of y" counts only the groups the Direct / From domains switch lists.
    @Test func ipCountFollowsTheDirectAndResolvedFilter() {
        let now = Date()
        let hosts = [
            host("api2.cursor.sh", now: now),
            host("104.18.19.125", kind: .ip, hosts: ["api2.cursor.sh"], now: now),
            host("104.18.18.125", kind: .ip, hosts: ["api3.cursor.sh"], now: now),
            host("149.154.175.60", kind: .ip, direct: true, now: now),
        ]
        let summary = AppDetailInventorySummary(hosts: hosts, search: "", now: now, site: naiveSite)
        #expect(summary.visibleIPCount(selectedHost: nil, filter: .all) == 3)
        #expect(summary.visibleIPCount(selectedHost: nil, filter: .direct) == 1)
        #expect(summary.visibleIPCount(selectedHost: nil, filter: .resolved) == 2)
        #expect(summary.visibleIPCount(selectedHost: "api2.cursor.sh", filter: .direct) == 0)
        #expect(summary.visibleIPCount(selectedHost: "api2.cursor.sh", filter: .resolved) == 1)
        #expect(summary.ipCount == 3, "the total stays every IP")
    }

    @Test func headlineMentionsDirectIPsOnlyWhenThereAreSome() {
        let now = Date()
        let resolved = host("104.18.19.125", kind: .ip, hosts: ["api2.cursor.sh"], now: now)
        let none = AppDetailInventorySummary(hosts: [host("api2.cursor.sh", now: now), resolved], search: "", now: now, site: naiveSite)
        #expect(!none.headline.contains("(") && !none.headline.contains("（"))
        let some = AppDetailInventorySummary(hosts: [resolved, host("149.154.175.60", kind: .ip, direct: true, now: now)],
                                             search: "", now: now, site: naiveSite)
        #expect(some.headline.contains("(") || some.headline.contains("（"))
        #expect(AppDetailInventorySummary().groups.isEmpty)
    }

    @Test func listsWholeHostNamesThenACount() {
        #expect(AppDetailInventoryFormat.domains(["api.anthropic.com", "claude.ai"]) == "api.anthropic.com, claude.ai")
        #expect(AppDetailInventoryFormat.domains(["a.com", "b.com", "c.com", "d.com", "e.com"]) == "a.com, b.com, c.com +2")
        let geo = GeoInfo(countryCode: "us", asn: 399358, organization: "Anthropic, PBC")
        #expect(AppDetailInventoryFormat.fullGeo(geo) == "US · AS399358 Anthropic, PBC")
        #expect(AppDetailInventoryFormat.fullGeo(GeoInfo(countryCode: nil, asn: nil, organization: nil)) == "")
    }
}

@Suite @MainActor struct AppDetailStatsTests {
    @Test func catalogCountersOnlyDescribeTheSidebarScope() {
        let mac = UUID()
        let catalog = AppStats(domains: 0, requests: 0)
        let loaded = AppStats(domains: 12, requests: 340)
        // The app isn't on the selected Mac: the page shows every Mac, the catalog only that Mac.
        #expect(AppDetailView.displayedStats(catalog: catalog, loaded: loaded, pageScope: .all, sidebarScope: .device(mac)) == loaded)
        #expect(AppDetailView.displayedStats(catalog: catalog, loaded: nil, pageScope: .all, sidebarScope: .device(mac)) == AppStats())
        // Same scope: the catalog wins, the page's own query fills in until it arrives.
        #expect(AppDetailView.displayedStats(catalog: catalog, loaded: loaded, pageScope: .device(mac), sidebarScope: .device(mac)) == catalog)
        #expect(AppDetailView.displayedStats(catalog: nil, loaded: loaded, pageScope: .all, sidebarScope: .all) == loaded)
    }
}

@Suite @MainActor struct AppDetailRequestTests {
    private func record(chain: [ProcessLink]) -> RequestRecord {
        RequestRecord(key: RequestKey(deviceID: UUID(), session: 1, surgeID: 1), rowID: 7, startedAt: .now,
                      method: "CONNECT", host: "registry.npmjs.org", policyPath: ["Proxy", "HK-01"], state: .completed,
                      inBytes: 0, outBytes: 0, pid: chain.last?.pid, processPath: chain.last?.path, chain: chain,
                      notes: [], isNew: false)
    }

    private let cursor = MonitoredApp(id: UUID(), name: "Cursor", path: "/Applications/Cursor.app", tileLetter: "C", tileHue: 260,
                                      includeChildren: true, alertRule: .site, alertNewIP: false, createdAt: .now)

    @Test func countsParentsBetweenTheAppAndTheSender() {
        let chain = [
            ProcessLink(name: "Cursor", pid: 812, path: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
            ProcessLink(name: "Cursor Helper (Plugin)", pid: 851, path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)"),
            ProcessLink(name: "node", pid: 1201, path: "/usr/local/bin/node"),
        ]
        #expect(AppDetailRequestCard.parentHops(record(chain: chain), app: cursor) == 2)
        #expect(AppDetailRequestCard.chainText(record(chain: chain)) == "Cursor (812)  →  Cursor Helper (Plugin) (851)  →  node (1201)")
    }

    @Test func ignoresAncestorsAboveTheApp() {
        let chain = [
            ProcessLink(name: "zsh", pid: 90, path: "/bin/zsh"),
            ProcessLink(name: "Cursor", pid: 812, path: "/Applications/Cursor.app/Contents/MacOS/Cursor"),
        ]
        #expect(AppDetailRequestCard.parentHops(record(chain: chain), app: cursor) == 0)
        #expect(AppDetailRequestCard.parentHops(record(chain: [chain[1]]), app: cursor) == 0)
    }

    @Test func filtersByHostIPAndProcess() {
        var r = record(chain: [ProcessLink(name: "node", pid: 1201, path: nil)])
        r.remoteIP = "104.16.27.34"
        #expect(AppDetailRequestsTab.matches(r, "npmjs"))
        #expect(AppDetailRequestsTab.matches(r, "104.16"))
        #expect(AppDetailRequestsTab.matches(r, "node"))
        #expect(!AppDetailRequestsTab.matches(r, "github"))
    }
}

@Suite @MainActor struct AppDetailProcessPathTests {
    @Test func shortensHelpersInsideTheBundle() {
        let app = "/Applications/Cursor.app"
        #expect(AppDetailProcessPath.display("/Applications/Cursor.app/Contents/MacOS/Cursor", depth: 0, appPath: app)
                == "/Applications/Cursor.app/Contents/MacOS/Cursor")
        #expect(AppDetailProcessPath.display("/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)",
                                             depth: 1, appPath: app) == "…/Frameworks/Cursor Helper (Renderer).app")
        #expect(AppDetailProcessPath.display("/Applications/WeChat.app/Contents/MacOS/WeChatAppEx Helper", depth: 1, appPath: "/Applications/WeChat.app/")
                == "…/MacOS/WeChatAppEx Helper")
    }

    @Test func showsTheInnermostBundleOfNestedHelpers() {
        let wechat = "/Applications/WeChat.app"
        let helper = "/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app/Contents/Frameworks/WeChatAppEx Framework.framework/Versions/C/Helpers/WeChatAppEx Helper.app/Contents/MacOS/WeChatAppEx Helper"
        #expect(AppDetailProcessPath.display(helper, depth: 2, appPath: wechat) == "…/Helpers/WeChatAppEx Helper.app")
        #expect(AppDetailProcessPath.display("/Applications/WeChat.app/Contents/MacOS/WeChatAppEx.app/Contents/MacOS/WeChatAppEx", depth: 1, appPath: wechat)
                == "…/MacOS/WeChatAppEx.app")
        #expect(AppDetailProcessPath.display("/Applications/Cursor.app/Contents/Frameworks/Electron Framework.framework/Versions/A/Helpers/chrome_crashpad_handler",
                                             depth: 1, appPath: "/Applications/Cursor.app") == "…/Helpers/chrome_crashpad_handler")
    }

    @Test func abbreviatesTheHomeFolder() {
        #expect(AppDetailProcessPath.display("/Users/you/Library/node/bin/node", depth: 1, appPath: "/Applications/Raycast.app", home: "/Users/you")
                == "~/Library/node/bin/node")
        #expect(AppDetailProcessPath.display("/usr/bin/git", depth: 2, appPath: "/Applications/Cursor.app", home: "/Users/you") == "/usr/bin/git")
    }
}

@Suite @MainActor struct AppDetailProcessTreeTests {
    private func node(_ name: String, depth: Int, pid: Int32 = 1, device: DeviceID? = nil, running: Bool = false) -> ProcessNode {
        ProcessNode(id: "\(name)-\(depth)", name: name, pid: pid, startTime: Date(timeIntervalSince1970: 1_000), path: "/x/\(name)",
                    depth: depth, domainCount: 0, requestCount: 0, isRunning: running, deviceID: device)
    }

    @Test func checksThisMacsProcessesLiveInAnyScope() {
        let thisMac = UUID(), otherMac = UUID()
        let live: (Int32, Date) -> Bool = { pid, _ in pid == 42 }
        // This Mac's process: libproc decides, even when the page shows every Mac.
        #expect(AppDetailProcessTree.isRunning(node("node", depth: 1, pid: 42, device: thisMac), thisDeviceID: thisMac,
                                               pageShowsOnlyThisMac: false, check: live))
        #expect(!AppDetailProcessTree.isRunning(node("node", depth: 1, pid: 7, device: thisMac, running: true), thisDeviceID: thisMac,
                                                pageShowsOnlyThisMac: false, check: live))
        // Another Mac's process keeps its stored state.
        #expect(AppDetailProcessTree.isRunning(node("node", depth: 1, pid: 7, device: otherMac, running: true), thisDeviceID: thisMac,
                                               pageShowsOnlyThisMac: true, check: live))
        // No Mac recorded: checked only when the page shows this Mac alone.
        #expect(AppDetailProcessTree.isRunning(node("node", depth: 1, pid: 42), thisDeviceID: thisMac, pageShowsOnlyThisMac: true, check: live))
        #expect(!AppDetailProcessTree.isRunning(node("node", depth: 1, pid: 42), thisDeviceID: thisMac, pageShowsOnlyThisMac: false, check: live))
    }

    @Test func filtersKeepingParents() {
        let nodes = [
            node("Cursor", depth: 0), node("Cursor Helper (Plugin)", depth: 1), node("node", depth: 2),
            node("Cursor Helper (Renderer)", depth: 1), node("git", depth: 1),
        ]
        #expect(AppDetailProcessTree.filter(nodes, query: "").count == 5)
        #expect(AppDetailProcessTree.filter(nodes, query: " NODE ").map(\.name) == ["Cursor", "Cursor Helper (Plugin)", "node"])
        #expect(AppDetailProcessTree.filter(nodes, query: "renderer").map(\.name) == ["Cursor", "Cursor Helper (Renderer)"])
        #expect(AppDetailProcessTree.filter(nodes, query: "zsh").isEmpty)
    }
}

@Suite @MainActor struct ProbeWaterfallModelTests {
    private func session() -> ProbeSession {
        ProbeSession(id: UUID(), deviceID: UUID(), url: "https://github.com/", host: "github.com", mode: .desktop,
                     startedAt: .now, endedAt: nil,
                     steps: [ProbeStep(at: 0, label: "Page load"), ProbeStep(at: 6, label: "Click · /apple/swift")],
                     hosts: [
                         ProbeHost(host: "github.com", firstAt: 0, lastAt: 9.2, requestCount: 18, ips: ["20.205.243.166"], step: 0),
                         ProbeHost(host: "github.githubassets.com", firstAt: 0.18, lastAt: 2.4, requestCount: 64, ips: ["a", "b"], step: 0),
                         ProbeHost(host: "avatars.githubusercontent.com", firstAt: 6.3, lastAt: 7, requestCount: 9, ips: ["c"], step: 1),
                         ProbeHost(host: "late.example.com", firstAt: 11, lastAt: 12, requestCount: 1, ips: [], step: 5),
                     ])
    }

    @Test func axisGrowsInFourSecondSteps() {
        #expect(ProbeWaterfallModel.axis(for: 0) == 12)
        #expect(ProbeWaterfallModel.axis(for: 9.6) == 12)
        #expect(ProbeWaterfallModel.axis(for: 10.6) == 16)
        #expect(ProbeWaterfallModel.axis(for: 30) == 32)
    }

    @Test func placesHostsUnderTheirStepAndClipsToElapsed() {
        let model = ProbeWaterfallModel(session: session(), elapsed: 8, site: naiveSite)
        #expect(model.axis == 12)
        #expect(model.steps.count == 2)
        #expect(model.steps[0].rows.map(\.host) == ["github.com", "github.githubassets.com"])
        #expect(model.steps[1].rows.map(\.host) == ["avatars.githubusercontent.com"])
        // github.com is still active: its bar ends at the elapsed time.
        #expect(abs(model.steps[0].rows[0].width - 8.0 / 12) < 0.0001)
        #expect(model.steps[0].rows[0].sameSite)
        #expect(!model.steps[0].rows[1].sameSite)
        #expect(model.marks == [0.5])
        #expect(model.tickLabels == ["0s", "3s", "6s", "9s", "12s"])
    }

    @Test func putsHostsOfUnknownStepsUnderTheLastStep() {
        let model = ProbeWaterfallModel(session: session(), elapsed: 14, site: naiveSite)
        #expect(model.steps[1].rows.map(\.host).contains("late.example.com"))
    }
}

@Suite @MainActor struct ProbeWebSessionTests {
    @Test func normalizesTypedAddresses() {
        #expect(ProbeWebSession.normalizedURL("www.bilibili.com")?.absoluteString == "https://www.bilibili.com")
        #expect(ProbeWebSession.normalizedURL(" http://example.com/a ")?.absoluteString == "http://example.com/a")
        #expect(ProbeWebSession.normalizedURL("") == nil)
        #expect(ProbeWebSession.normalizedURL("ftp://example.com") == nil)
        #expect(ProbeWebSession.normalizedURL("https://") == nil)
    }

    @Test func namesClickStepsByPath() throws {
        #expect(ProbeWebSession.stepTitle(for: try #require(URL(string: "https://github.com/apple/swift?tab=readme"))) == "/apple/swift?tab=readme")
        #expect(ProbeWebSession.stepTitle(for: try #require(URL(string: "https://github.com/"))) == "github.com")
        #expect(ProbeWebSession.stepTitle(for: try #require(URL(string: "https://app.example.com/#/inbox"))) == "/#/inbox")
    }

    @Test func usesSafariUserAgents() {
        #expect(ProbeWebSession.userAgent(for: .desktop).contains("Macintosh"))
        #expect(ProbeWebSession.userAgent(for: .iphone).contains("iPhone"))
        #expect(ProbeWebSession.userAgent(for: .iphone).contains("Mobile/"))
    }

    @Test func isOffWhileReadingARemoteSurge() {
        #expect(ProbeWebSession.unavailableReason(remoteSurge: "") == nil)
        #expect(ProbeWebSession.unavailableReason(remoteSurge: "  ") == nil)
        #expect(ProbeWebSession.unavailableReason(remoteSurge: "192.168.1.20:6170") != nil)
    }

    /// WebKit traps when a page still bound to one `WebView` is given to another, so the page only moves
    /// once the view that showed it is gone.
    @Test func movesThePageOnlyAfterTheOldWebViewIsGone() async throws {
        let session = ProbeWebSession()
        #expect(session.host == .inline && !session.isPoppedOut)
        session.webViewDidAppear(in: .inline)
        var opened = false
        session.popOut { opened = true }
        #expect(opened)
        #expect(session.isPoppedOut && session.host == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(session.host == nil)

        session.webViewDidDisappear(from: .inline)
        try await Self.waitUntil { session.host == .window }

        session.webViewDidAppear(in: .window)
        session.windowDidClose()
        #expect(!session.isPoppedOut && session.host == nil)
        session.webViewDidDisappear(from: .window)
        try await Self.waitUntil { session.host == .inline }
    }

    /// The probe controller clears `running` before it saves a stopped session; until `stop()` returns, a new
    /// probe must not start, or the old `stop()` would tear the new page down.
    @Test func refusesToStartWhileTheLastProbeIsStillStopping() async throws {
        let model = AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: "tidemark-tests-\(UUID().uuidString)")!))
        let actions = SlowStopProbeActions(model: model)
        model.probeActions = actions
        model.probe.running = ProbeSession(id: UUID(), deviceID: model.preferences.thisDeviceID, url: "https://example.com", host: "example.com",
                                           mode: .desktop, startedAt: .now, endedAt: nil, steps: [], hosts: [])
        let session = ProbeWebSession()
        session.urlDraft = "https://example.com"

        let stopping = Task { await session.stop(model: model) }
        try await Self.waitUntil { actions.stopCalls == 1 }
        #expect(session.isStopping && session.isBusy)
        #expect(!model.probe.isRunning, "the controller already cleared the running probe")

        try await session.start(model: model)
        #expect(actions.startCalls == 0, "Start is refused while the stop is saving")
        await session.stop(model: model)
        #expect(actions.stopCalls == 1, "a second Stop is ignored")

        actions.finishStop()
        await stopping.value
        #expect(!session.isStopping && !session.isBusy)
        #expect(session.page == nil && session.port == nil)
    }

    private static func waitUntil(_ condition: @MainActor () -> Bool) async throws {
        for _ in 0..<100 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition())
    }
}

/// Probe actions whose `stopProbe()` clears the running probe and then waits (like the controller's grace
/// period and save) until the test lets it finish.
@MainActor
private final class SlowStopProbeActions: ProbeActions {
    let model: AppModel
    private(set) var startCalls = 0
    private(set) var stopCalls = 0
    private var release: CheckedContinuation<Void, Never>?

    init(model: AppModel) {
        self.model = model
    }

    func startProbe(url: String, mode: ProbeDeviceMode, tail: Bool) async throws -> UInt16 {
        startCalls += 1
        throw CancellationError()
    }

    func recordStep(label: String, url: String?) {}
    func pageDidFinishLoading() {}

    func stopProbe() async -> ProbeSession? {
        stopCalls += 1
        guard var session = model.probe.running else { return nil }
        model.probe.running = nil
        await withCheckedContinuation { release = $0 }
        session.endedAt = .now
        return session
    }

    func finishStop() {
        release?.resume()
        release = nil
    }

    func deleteProbe(_ id: UUID) async {}
}

@Suite @MainActor struct InventoryGroupTests {
    private func entry(_ value: String, kind: HostKind = .domain, requests: Int64, geo: GeoInfo? = nil, source: String) -> InventoryEntry {
        InventoryEntry(kind: kind, value: value,
                       sources: [InventorySource(title: source, path: "/Applications/\(source).app", appID: nil, probeSessionID: nil, bundlePath: nil)],
                       firstSeen: .now, lastSeen: .now, requestCount: requests, geo: geo)
    }

    @Test func groupsDomainsBySiteAndIPsByNetwork() {
        let cloudflare = GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare, Inc.")
        let groups = InventoryGroup.make([
            entry("api.github.com", requests: 10, source: "Cursor"),
            entry("github.com", requests: 5, source: "Raycast"),
            entry("api.notion.com", requests: 1, source: "Raycast"),
            entry("104.18.19.125", kind: .ip, requests: 30, geo: cloudflare, source: "Cursor"),
            entry("104.16.27.34", kind: .ip, requests: 3, geo: cloudflare, source: "Cursor"),
            entry("10.0.0.1", kind: .ip, requests: 2, source: "Docker"),
        ], site: naiveSite, unknownNetwork: "Unknown network")
        #expect(groups.map(\.name) == ["AS13335 Cloudflare", "github.com", "Unknown network", "notion.com"])
        #expect(groups[0].names == ["104.18.19.125", "104.16.27.34"])
        #expect(groups[0].sources.count == 1)
        #expect(groups[1].sources.map(\.title) == ["Cursor", "Raycast"])
        #expect(groups[1].requests == 15)
    }

    @Test func previewsFourNamesThenACount() {
        let group = InventoryGroup(name: "hdslb.com", kind: .domain, names: ["a", "b", "c", "d", "e", "f"], sources: [], requests: 0)
        #expect(group.preview == "a  ·  b  ·  c  ·  d  ·  +2")
    }

    @Test func filtersByKindAndSortsWithTheTableOrder() {
        let entries = [
            entry("api.github.com", requests: 10, source: "Cursor"),
            entry("104.18.19.125", kind: .ip, requests: 30, source: "Cursor"),
            entry("github.com", requests: 5, source: "Raycast"),
        ]
        let byRequests = [KeyPathComparator(\InventoryEntry.requestCount, order: .reverse)]
        #expect(InventoryPresentation.visible(entries, kind: nil, sortOrder: byRequests).map(\.value)
                == ["104.18.19.125", "api.github.com", "github.com"])
        #expect(InventoryPresentation.visible(entries, kind: .domain, sortOrder: [KeyPathComparator(\InventoryEntry.value)]).map(\.value)
                == ["api.github.com", "github.com"])
        #expect(InventoryPresentation.visible(entries, kind: .ip, sortOrder: byRequests).map(\.value) == ["104.18.19.125"])
    }
}

@Suite @MainActor struct EgressOrderingTests {
    @Test func putsTheCurrentEgressFirst() {
        func sample(_ policy: String, current: Bool) -> EgressSample {
            EgressSample(policyPath: [policy], ip: nil, location: nil, network: nil, latencyMs: nil, isCurrent: current, checkedAt: .now, error: nil)
        }
        let ordered = EgressView.ordered([sample("DIRECT", current: false), sample("Proxy", current: true), sample("AI", current: false)])
        #expect(ordered.map(\.policyDisplay) == ["Proxy", "DIRECT", "AI"])
    }
}

@Suite @MainActor struct EgressFormatTests {
    private let chinese = Locale(identifier: "zh-Hans")

    @Test func localizesCountryCodesAndEnglishNames() {
        #expect(EgressFormat.location("US", languageCode: "en") == "United States")
        #expect(EgressFormat.location("us", languageCode: "zh-Hans") == chinese.localizedString(forRegionCode: "US"))
        // English names written by earlier checks.
        #expect(EgressFormat.location("Hong Kong", languageCode: "zh-Hans") == chinese.localizedString(forRegionCode: "HK"))
        #expect(EgressFormat.location("Hong Kong", languageCode: "en") == "Hong Kong")
        // `City, CC`: English keeps it, Chinese names the country.
        #expect(EgressFormat.location("Los Angeles, US", languageCode: "en") == "Los Angeles, US")
        let city = EgressFormat.location("Los Angeles, US", languageCode: "zh-Hans") ?? ""
        #expect(city.contains("Los Angeles") && city.contains(chinese.localizedString(forRegionCode: "US") ?? "?"))
        #expect(EgressFormat.location("Atlantis", languageCode: "zh-Hans") == "Atlantis")
        #expect(EgressFormat.location(" ", languageCode: "en") == nil)
        #expect(EgressFormat.location(nil) == nil)
    }

    @Test func describesNetworkTypes() {
        #expect(EgressFormat.networkType("hosting") == tr("hosting network", "Egress"))
        #expect(EgressFormat.networkType("Hosting · proxy") == tr("hosting network", "Egress") + " · " + tr("proxy", "Egress"))
        #expect(EgressFormat.networkType("Satellite") == "Satellite")
        #expect(EgressFormat.networkType("  ") == nil)
        #expect(EgressFormat.type("Hosting · anycast") == tr("Hosting", "Egress") + " · " + tr("anycast", "Egress"))
        #expect(EgressFormat.type(nil) == nil)
    }

    @Test func translatesInterfaceKindsButNotNetworkNames() {
        #expect(EgressFormat.interface("Wired") == tr("Wired", "SurgeCLI"))
        #expect(EgressFormat.interface("Ethernet") == tr("Ethernet", "Egress"))
        #expect(EgressFormat.interface("Wi-Fi “Office-5G”") == "Wi-Fi “Office-5G”")
        #expect(EgressFormat.interface("Wired “Dock”") == tr("Wired", "SurgeCLI") + " “Dock”")
    }

    @Test func namesWhatRoutesTheCurrentEgress() {
        #expect(EgressFormat.ruleLabel(proxyMode: 2, currentRule: nil) == trf("Rule %@", "Egress", "FINAL"))
        #expect(EgressFormat.ruleLabel(proxyMode: 2, currentRule: "DOMAIN-SUFFIX,example.com") == trf("Rule %@", "Egress", "DOMAIN-SUFFIX,example.com"))
        #expect(EgressFormat.ruleLabel(proxyMode: 1, currentRule: "Global · AI") == tr("Global proxy", "Egress"))
        #expect(EgressFormat.ruleLabel(proxyMode: 0, currentRule: nil) == nil)
        #expect(EgressFormat.ruleLabel(proxyMode: nil, currentRule: nil) == nil)
        #expect(EgressFormat.modeLabel(2) == tr("· rule mode", "Egress"))
        #expect(EgressFormat.modeLabel(nil) == nil)
    }

    @Test func seedsTheLookupFromTheLastCheck() {
        let sample = EgressSample(policyPath: ["Proxy", "HK-01"], ip: "103.152.220.41", location: "HK", network: "AS9009 M247 Europe SRL",
                                  latencyMs: 42, isCurrent: true, checkedAt: .now, error: nil, networkType: "hosting", hasIPv6: false)
        let seed = EgressFormat.lookupSeed(from: sample)
        #expect(seed?.ip == "103.152.220.41")
        #expect(seed?.asn == 9009 && seed?.organization == "M247 Europe SRL")
        #expect(seed?.country == "HK" && seed?.networkType == "hosting")
        var unchecked = sample
        unchecked.ip = nil
        #expect(EgressFormat.lookupSeed(from: unchecked) == nil)
        #expect(EgressFormat.detail(sample).hasSuffix(tr("hosting network", "Egress")))
    }

    /// Stored check errors are English (surge-cli's and the timeout's descriptions); the page shows them short
    /// and in the UI language.
    @Test func shortensAndTranslatesCheckErrors() {
        let timeout = CaptureTimeoutError(seconds: 20).errorDescription ?? ""
        #expect(EgressFormat.error(timeout, languageCode: "en") == trf("Timed out after %lld s", "Egress", 20))
        let failed = SurgeError.commandFailed(command: "test-policy-external-ip POLICY::abc", message: "HTTP request timeout").errorDescription ?? ""
        #expect(EgressFormat.error(failed, languageCode: "en") == tr("Timed out", "Egress"))
        let unknownPolicy = SurgeError.commandFailed(command: "test-policy-external-ip X", message: "Policy does not exist.").errorDescription ?? ""
        #expect(EgressFormat.error(unknownPolicy, languageCode: "en") == tr("Policy not found", "Egress"))
        let other = SurgeError.commandFailed(command: "test-policy-external-ip X", message: "TLS handshake failed").errorDescription ?? ""
        #expect(EgressFormat.error(other, languageCode: "en") == "TLS handshake failed", "Surge's own reason, without the command")
        #expect(EgressFormat.error(other, languageCode: "zh-Hans") == tr("Surge couldn't check this policy", "Egress"))
        #expect(EgressFormat.error(SurgeError.timedOut(command: "test-policy X").errorDescription ?? "", languageCode: "en")
                == tr("surge-cli did not answer in time", "Egress"))
        #expect(EgressFormat.error(SurgeError.cliNotFound(path: "/x").errorDescription ?? "", languageCode: "en") == tr("surge-cli not found", "Egress"))
        #expect(EgressFormat.error("Something odd", languageCode: "en") == "Something odd")
        #expect(EgressFormat.error("Something odd", languageCode: "zh-Hans") == tr("The check failed", "Egress"))
    }

    /// `egress_checks.error` holds English whatever the UI language, since other Macs and later versions read it.
    @Test func storesCheckErrorsInAStableEnglishForm() {
        Localizer.shared.preference = .chinese
        defer { Localizer.shared.preference = .english }
        #expect(EgressMonitor.storedError(CaptureTimeoutError(seconds: 20)) == "Timed out after 20 s.")
        #expect(EgressMonitor.storedError(SurgeError.cliNotFound(path: "/x/surge-cli")) == "surge-cli was not found at /x/surge-cli.")
        #expect(EgressMonitor.storedError(SurgeError.commandFailed(command: "test-policy-external-ip X", message: "Policy does not exist."))
                == "surge-cli test-policy-external-ip X failed: Policy does not exist.")
        #expect(EgressMonitor.storedError(SurgeError.decoding(command: "geoip 1.1.1.1", message: "no address in the reply"))
                == "Could not read the output of surge-cli geoip 1.1.1.1: no address in the reply")
        #expect(EgressMonitor.storedError(SurgeError.timedOut(command: "test-policy X")) == "surge-cli test-policy X timed out.")
        #expect(EgressMonitor.storedError(CancellationError()) == "CancellationError()")
    }

    /// Every stored form reads in Chinese; only Surge's unknown reasons fall back to a general sentence.
    @Test func translatesStoredCheckErrorsIntoChinese() {
        Localizer.shared.preference = .chinese
        defer { Localizer.shared.preference = .english }
        guard Localizer.shared.bundle != nil else { return }
        let zh = "zh-Hans"
        #expect(EgressFormat.error("Timed out after 20 s.", languageCode: zh) == "20 秒后超时")
        #expect(EgressFormat.error("surge-cli was not found at /x/surge-cli.", languageCode: zh) == "找不到 surge-cli")
        #expect(EgressFormat.error("Could not read the output of surge-cli geoip 1.1.1.1: bad", languageCode: zh) == "无法读取 surge-cli 的输出")
        #expect(EgressFormat.error("surge-cli test-policy X timed out.", languageCode: zh) == "surge-cli 没有及时响应")
        #expect(EgressFormat.error("surge-cli test-policy-external-ip X failed: HTTP request timeout", languageCode: zh) == "超时")
        #expect(EgressFormat.error("surge-cli test-policy-external-ip X failed: Policy does not exist.", languageCode: zh) == "找不到这个策略")
        #expect(EgressFormat.error("surge-cli test-policy-external-ip X failed: No outgoing interface", languageCode: zh) == "没有可用的出站接口")
        #expect(EgressFormat.error("surge-cli test-policy-external-ip X failed: TLS handshake failed", languageCode: zh) == "Surge 无法检测这个策略")
    }

    @Test func translatesSurgeModesAlsoWithoutTheOutboundMode() {
        #expect(EgressFormat.surgeMode("Enhanced mode · rule-based") == tr("Enhanced mode · rule-based", "SurgeCLI"))
        #expect(EgressFormat.surgeMode("Enhanced mode") == tr("Enhanced mode", "SurgeCLI"))
        #expect(EgressFormat.surgeMode("System proxy") == tr("System proxy", "SurgeCLI"))
        #expect(EgressFormat.surgeMode("Rule-based") == tr("Rule-based", "SurgeCLI"))
        #expect(EgressFormat.surgeMode("Something new") == "Something new")

        // Every value `SurgeOutputParser.surgeMode` can return is in the SurgeCLI table.
        let lproj = Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").map { URL(fileURLWithPath: $0) }
        let chinese = lproj.flatMap { NSDictionary(contentsOf: $0.appendingPathComponent("SurgeCLI.strings")) as? [String: String] } ?? [:]
        var modes: Set<String> = []
        for mode in ["rule", "proxy", "direct", nil] {
            for (enhanced, systemProxy) in [(true, false), (false, true), (false, false)] {
                let status = SurgeStatus(mode: mode, features: ["enhanced-mode": enhanced, "system-proxy": systemProxy])
                if let text = SurgeOutputParser.surgeMode(for: status) { modes.insert(text) }
            }
        }
        #expect(modes.contains("Enhanced mode") && modes.contains("System proxy"))
        for mode in modes {
            #expect(chinese[mode] != nil, "\(mode)")
        }

        Localizer.shared.preference = .chinese
        defer { Localizer.shared.preference = .english }
        guard Localizer.shared.bundle != nil else { return }
        #expect(EgressFormat.surgeMode("Enhanced mode") == "增强模式")
        #expect(EgressFormat.surgeMode("System proxy · something new") == "系统代理 · something new")
    }

    /// The lookup card names the IP info service and where to turn it off, and says where reverse DNS comes from.
    @Test func namesTheIPInfoServiceAndWhereToTurnItOff() {
        let on = EgressFormat.sourcesNote(service: .proxycheck)
        #expect(on.contains("proxycheck.io"))
        let off = EgressFormat.sourcesNote(service: .off)
        #expect(off.contains("proxycheck.io") && off != on)
    }

    @Test func translatesEveryReasonTheMonitorWrites() throws {
        #expect(EgressView.localizedReason("Profile reloaded") == tr("Profile reloaded", "Egress"))
        #expect(EgressView.localizedReason("Egress changed") == tr("Egress changed", "Egress"))
        #expect(EgressView.localizedReason("Network changed to Ethernet") == trf("Network changed to %@", "Egress", tr("Ethernet", "Egress")))
        #expect(EgressView.localizedReason("Network changed to Wi-Fi “Office-5G”") == trf("Network changed to %@", "Egress", "Wi-Fi “Office-5G”"))
        #expect(EgressView.localizedReason("Something else") == "Something else")

        let lproj = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        let chinese = NSDictionary(contentsOf: URL(fileURLWithPath: lproj).appendingPathComponent("Egress.strings")) as? [String: String]
        let reasons = [EgressSignal.policyChanged, .profileReloaded, .surgeRestarted].compactMap(\.reason) + ["Egress changed"]
        for key in reasons + ["Network changed to %@", "Ethernet", "Cellular"] {
            #expect(chinese?[key] != nil, "\(key)")
        }
    }
}

@Suite @MainActor struct AnalyzeLocalizationTests {
    /// Every catalog compiles into the app with a Chinese translation for each key.
    @Test func chineseCatalogsAreComplete() throws {
        let lproj = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        for table in ["AppDetail", "Inventory", "SiteProbe", "Egress", "Capture"] {
            let url = URL(fileURLWithPath: lproj).appendingPathComponent("\(table).strings")
            let strings = try #require(NSDictionary(contentsOf: url) as? [String: String], "missing \(table).strings")
            #expect(strings.count > 30)
            for (key, value) in strings {
                #expect(!value.isEmpty, "\(table): \(key)")
                // Formats must take the same arguments in both languages.
                #expect(Self.specifiers(key) == Self.specifiers(value), "\(table): \(key)")
            }
        }
    }

    @Test func formatsRelativeDays() {
        let now = Date()
        #expect(AnalyzeFormat.seen(now, now: now).hasSuffix(Fmt.hm(now)))
        #expect(AnalyzeFormat.seen(now, timeOnlyToday: true, now: now) == Fmt.hm(now))
    }

    private static func specifiers(_ format: String) -> [String] {
        let regex = /%(?:\d+\$)?(?:lld|@|d)/
        return format.matches(of: regex).map { String($0.output) }.sorted()
    }
}
