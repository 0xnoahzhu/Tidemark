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

    @Test func abbreviatesTheHomeFolder() {
        #expect(AppDetailProcessPath.display("/Users/you/Library/node/bin/node", depth: 1, appPath: "/Applications/Raycast.app", home: "/Users/you")
                == "~/Library/node/bin/node")
        #expect(AppDetailProcessPath.display("/usr/bin/git", depth: 2, appPath: "/Applications/Cursor.app", home: "/Users/you") == "/usr/bin/git")
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

@Suite @MainActor struct AnalyzeLocalizationTests {
    /// Every catalog compiles into the app with a Chinese translation for each key.
    @Test func chineseCatalogsAreComplete() throws {
        let lproj = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj"))
        for table in ["AppDetail", "Inventory", "SiteProbe", "Egress"] {
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
