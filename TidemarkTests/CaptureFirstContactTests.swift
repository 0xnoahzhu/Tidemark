import Foundation
import Testing
@testable import Tidemark

struct CaptureFirstContactTests {
    let classifier = CaptureFakeClassifier()
    let device = UUID()

    func record(host: String, ip: String?, app: MonitoredApp, process: String = "node") -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device, session: 1, surgeID: Int64.random(in: 1...1_000_000)), rowID: nil, startedAt: .now,
            setupCompletedAt: nil, completedAt: nil, method: "HTTPS", host: host, port: 443, url: nil, remoteIP: ip, remoteAddress: nil,
            geo: GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare, Inc."), policyPath: ["Proxy", "HK-01"], rule: nil,
            state: .active, inBytes: 0, outBytes: 0, pid: 1, processPath: "/usr/local/bin/\(process)", bundlePath: app.path,
            chain: [ProcessLink(name: process, pid: 1, path: "/usr/local/bin/\(process)", startTime: nil)], appID: app.id,
            localAddress: nil, interface: nil, notes: [], isNew: false, writtenAt: nil, probeSessionID: nil
        )
    }

    @Test func aFirstHostOfANewSiteAlertsWithSiteScope() {
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        var known = CaptureKnownHosts(loaded: [raycast.id: ["backend.raycast.com", "ip:76.76.21.21"]], classifier: classifier)
        let contact = CaptureFirstContactDetector.evaluate(record: record(host: "api.notion.com", ip: "104.18.22.110", app: raycast),
                                                           app: raycast, known: &known, classifier: classifier)
        #expect(contact.hosts.map(\.id) == ["domain:api.notion.com", "ip:104.18.22.110"])
        #expect(contact.hosts.first?.site == "notion.com")
        #expect(contact.hosts.first?.policy == "Proxy › HK-01")
        #expect(contact.hosts.last?.hosts == ["api.notion.com"])
        #expect(contact.alert?.scope == .site)
        #expect(contact.alert?.site == "notion.com")
        #expect(contact.alert?.ip == "104.18.22.110")
        #expect(contact.alert?.geo?.display == "US · AS13335 Cloudflare")
        #expect(contact.touches.isEmpty)
        #expect(known.containsDomain("api.notion.com", appID: raycast.id), "recorded optimistically")
    }

    @Test func aNewHostOfAKnownSiteHasHostScope() {
        let cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app")
        var known = CaptureKnownHosts(loaded: [cursor.id: ["domain:objects.githubusercontent.com", "185.199.108.133"]], classifier: classifier)
        let contact = CaptureFirstContactDetector.evaluate(record: record(host: "raw.githubusercontent.com", ip: "185.199.108.133", app: cursor),
                                                           app: cursor, known: &known, classifier: classifier)
        #expect(contact.alert?.scope == .host)
        #expect(contact.alert?.value == "raw.githubusercontent.com")
        #expect(contact.hosts.map(\.kind) == [.domain])
        #expect(contact.touches.map(\.id) == ["ip:185.199.108.133"], "the known IP is touched")
    }

    @Test func siteRuleOnlyAlertsForNewSites() {
        let cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app", rule: .site, alertNewIP: false)
        var known = CaptureKnownHosts(loaded: [cursor.id: ["api2.cursor.sh"]], classifier: classifier)
        let sameSite = CaptureFirstContactDetector.evaluate(record: record(host: "api3.cursor.sh", ip: "104.18.18.125", app: cursor),
                                                            app: cursor, known: &known, classifier: classifier)
        #expect(sameSite.hosts.count == 2, "still recorded")
        #expect(sameSite.alert == nil, "new host under a known site is only marked NEW")

        let newSite = CaptureFirstContactDetector.evaluate(record: record(host: "api.openai.com", ip: "162.159.140.245", app: cursor),
                                                           app: cursor, known: &known, classifier: classifier)
        #expect(newSite.alert?.scope == .site)
    }

    @Test func offRuleNeverAlertsOnDomains() {
        let docker = CaptureFixtures.app("Docker", path: "/Applications/Docker.app", rule: .off, alertNewIP: false)
        var known = CaptureKnownHosts()
        let contact = CaptureFirstContactDetector.evaluate(record: record(host: "index.docker.io", ip: "54.198.86.24", app: docker),
                                                           app: docker, known: &known, classifier: classifier)
        #expect(contact.hosts.count == 2)
        #expect(contact.alert == nil)
    }

    @Test func aNewIPOfAKnownHostAlertsWithIPScope() {
        let docker = CaptureFixtures.app("Docker", path: "/Applications/Docker.app")
        var known = CaptureKnownHosts(loaded: [docker.id: ["production.cloudflare.docker.com", "104.16.99.215"]], classifier: classifier)
        let contact = CaptureFirstContactDetector.evaluate(record: record(host: "production.cloudflare.docker.com", ip: "104.16.98.215", app: docker),
                                                           app: docker, known: &known, classifier: classifier)
        #expect(contact.alert?.scope == .ip)
        #expect(contact.alert?.value == "104.16.98.215")
        #expect(contact.alert?.host == "production.cloudflare.docker.com")
        #expect(contact.alert?.isDirect == false)
        #expect(contact.touches.map(\.id) == ["domain:production.cloudflare.docker.com"])
    }

    @Test func anIPLiteralIsADirectContact() {
        let wechat = CaptureFixtures.app("WeChat", path: "/Applications/WeChat.app")
        var known = CaptureKnownHosts(loaded: [wechat.id: ["szextshort.weixin.qq.com"]], classifier: classifier)
        let contact = CaptureFirstContactDetector.evaluate(record: record(host: "157.148.69.80", ip: "157.148.69.80", app: wechat, process: "WeChat"),
                                                           app: wechat, known: &known, classifier: classifier)
        #expect(contact.hosts.map(\.id) == ["ip:157.148.69.80"])
        #expect(contact.hosts.first?.isDirect == true)
        #expect(contact.hosts.first?.hosts == [])
        #expect(contact.alert?.isDirect == true)
        #expect(contact.alert?.host == nil)
    }

    /// Nothing is muted: the hosts earlier versions silenced by default (`*.apple.com`, `*.icloud.com`,
    /// `*.mzstatic.com`) alert like any other, and so do their IPs.
    @Test func appleHostsAlertLikeAnyOther() {
        let app = CaptureFixtures.app("Safari", path: "/Applications/Safari.app")
        var known = CaptureKnownHosts()
        let contact = CaptureFirstContactDetector.evaluate(record: record(host: "gateway.icloud.com", ip: "17.248.186.67", app: app),
                                                           app: app, known: &known, classifier: classifier)
        #expect(contact.hosts.count == 2)
        #expect(contact.alert?.value == "gateway.icloud.com")
        #expect(contact.fallback?.value == "17.248.186.67")

        let byIP = CaptureFirstContactDetector.evaluate(record: record(host: "17.253.144.10", ip: "17.253.144.10", app: app),
                                                        app: app, known: &known, classifier: classifier)
        #expect(byIP.hosts.count == 1 && byIP.alert?.value == "17.253.144.10")
    }

    @Test func aKnownHostAndIPOnlyTouch() {
        let app = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        var known = CaptureKnownHosts(loaded: [app.id: ["api.github.com", "20.205.243.168"]], classifier: classifier)
        let contact = CaptureFirstContactDetector.evaluate(record: record(host: "API.github.com", ip: "20.205.243.168", app: app),
                                                           app: app, known: &known, classifier: classifier)
        #expect(contact.hosts.isEmpty && contact.alert == nil)
        #expect(contact.touches.count == 2)
    }

    @Test func secondRequestDoesNotFireTwice() {
        let app = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        var known = CaptureKnownHosts()
        let r = record(host: "api.linear.app", ip: "104.18.32.12", app: app)
        let first = CaptureFirstContactDetector.evaluate(record: r, app: app, known: &known, classifier: classifier)
        let second = CaptureFirstContactDetector.evaluate(record: r, app: app, known: &known, classifier: classifier)
        #expect(first.alert != nil && first.hosts.count == 2)
        #expect(second.alert == nil && second.hosts.isEmpty && second.touches.count == 2)
    }

    @Test func aNewDomainKeepsItsNewIPAlertAsAFallback() throws {
        let app = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        var known = CaptureKnownHosts()
        let r = record(host: "api.linear.app", ip: "104.18.32.12", app: app)
        let contact = CaptureFirstContactDetector.evaluate(record: r, app: app, known: &known, classifier: classifier)
        #expect(contact.alert?.kind == .domain)
        let fallback = try #require(contact.fallback)
        #expect(fallback.kind == .ip && fallback.value == "104.18.32.12" && fallback.fallbackFor == "domain:api.linear.app")
        #expect(contact.hosts.allSatisfy { $0.firstDeviceID == device }, "the recording Mac made first contact")
    }

    @Test func exportsTheIndexForTheLocalSnapshot() {
        let app = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        var known = CaptureKnownHosts(loaded: [app.id: ["api.github.com", "ip:20.205.243.168"]], classifier: classifier)
        known.merge([app.id: ["raw.githubusercontent.com"]], classifier: classifier)
        let copy = CaptureKnownHosts(loaded: known.exported, classifier: classifier)
        #expect(copy.containsDomain("raw.githubusercontent.com", appID: app.id) && copy.containsIP("20.205.243.168", appID: app.id))
        #expect(copy.containsSite("githubusercontent.com", appID: app.id))
        #expect(known.count == 3)
    }

    @Test func decodesKnownHostForms() {
        #expect(CaptureKnownHosts.decode("domain:api.github.com") == (.domain, "api.github.com"))
        #expect(CaptureKnownHosts.decode("ip:2001:db8::1") == (.ip, "2001:db8::1"))
        #expect(CaptureKnownHosts.decode("104.18.19.125") == (.ip, "104.18.19.125"))
        #expect(CaptureKnownHosts.decode("github.com") == (.domain, "github.com"))
    }

    @Test func draftsBecomeAlertItems() throws {
        let app = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app")
        var known = CaptureKnownHosts()
        let contact = CaptureFirstContactDetector.evaluate(record: record(host: "repo42.cursor.sh", ip: nil, app: app),
                                                           app: app, known: &known, classifier: classifier)
        let draft = try #require(contact.alert)
        let item = draft.item(deviceID: device, requestRowID: 42, createdAt: .distantPast)
        #expect(item.kind == .domain && item.scope == .site && item.value == "repo42.cursor.sh" && item.site == "cursor.sh")
        #expect(item.requestRowID == 42 && item.isUnread && item.processName == "node" && item.ip == nil)
        #expect(draft.hostID == "domain:repo42.cursor.sh")
    }
}
