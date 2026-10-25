import Foundation
import Testing
@testable import Tidemark

@MainActor
struct CaptureNotifierTests {
    let device = UUID()

    func alert(_ id: Int64, app: AppID, scope: AlertScope, value: String, site: String? = nil, host: String? = nil,
               ip: String? = nil, direct: Bool = false) -> AlertItem {
        AlertItem(id: id, deviceID: device, appID: app, kind: scope == .ip ? .ip : .domain, scope: scope, value: value, site: site,
                  host: host, ip: ip, geo: GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare, Inc."),
                  processName: "node", isDirect: direct, requestRowID: nil, createdAt: .now, readAt: nil)
    }

    @Test func groupsBurstsPerAppWithinTheWindow() {
        var grouper = CaptureBurstGrouper(window: 30)
        let cursor = UUID()
        let docker = UUID()
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)

        guard case .post(let first) = grouper.add(alert(1, app: cursor, scope: .host, value: "a.com"), now: t0) else {
            Issue.record("first alert should post")
            return
        }
        guard case .post = grouper.add(alert(2, app: docker, scope: .ip, value: "1.1.1.1"), now: t0) else {
            Issue.record("another app posts on its own")
            return
        }
        let third = grouper.add(alert(3, app: cursor, scope: .host, value: "b.com"), now: t0.addingTimeInterval(10))
        guard case .aggregate(let identifier, let head, let extra) = third else {
            Issue.record("same app within 30 s aggregates")
            return
        }
        #expect(identifier == first)
        #expect(head.id == 1)
        #expect(extra.map(\.id) == [3])

        var elsewhere = alert(5, app: cursor, scope: .host, value: "d.com")
        elsewhere.deviceID = UUID()
        guard case .post = grouper.add(elsewhere, now: t0.addingTimeInterval(12)) else {
            Issue.record("another Mac's alert posts on its own, naming that Mac")
            return
        }

        let later = grouper.add(alert(4, app: cursor, scope: .host, value: "c.com"), now: t0.addingTimeInterval(31))
        guard case .post(let next) = later else {
            Issue.record("a new window posts again")
            return
        }
        #expect(next != first)
    }

    /// The design's banner: "Raycast reached a new site" over "notion.com · first host api.notion.com · via node".
    @Test func wordsAlertsLikeTheDesignsBanner() {
        Localizer.shared.preference = .english
        let app = UUID()
        let site = alert(1, app: app, scope: .site, value: "api.notion.com", site: "notion.com", ip: "104.18.22.110")
        #expect(CaptureAlertText.title(appName: "Raycast", alert: site) == "Raycast reached a new site")
        #expect(CaptureAlertText.details(alert: site) == "notion.com · first host api.notion.com · via node")

        let host = alert(2, app: app, scope: .host, value: "raw.githubusercontent.com", ip: "185.199.108.133")
        #expect(CaptureAlertText.title(appName: "Cursor", alert: host) == "Cursor contacted a new host")
        #expect(CaptureAlertText.details(alert: host) == "raw.githubusercontent.com · via node")

        let ip = alert(3, app: app, scope: .ip, value: "104.16.98.215", host: "production.cloudflare.docker.com", ip: "104.16.98.215")
        #expect(CaptureAlertText.title(appName: "Docker", alert: ip) == "Docker connected to a new IP")
        #expect(CaptureAlertText.details(alert: ip, deviceName: "Mac mini (Office)") == "Mac mini (Office) · 104.16.98.215 · via node")

        var direct = alert(4, app: app, scope: .ip, value: "157.148.69.80", ip: "157.148.69.80", direct: true)
        #expect(CaptureAlertText.title(appName: "WeChat", alert: direct) == "WeChat connected straight to a new IP")
        direct.processName = "Unknown"
        #expect(CaptureAlertText.details(alert: direct) == "157.148.69.80", "no process to name")
    }

    @Test func translatesAlertsToChinese() {
        Localizer.shared.preference = .chinese
        defer { Localizer.shared.preference = .english }
        guard Localizer.shared.bundle != nil else { return }
        let site = alert(1, app: UUID(), scope: .site, value: "api.notion.com", site: "notion.com")
        #expect(CaptureAlertText.title(appName: "Raycast", alert: site) == "Raycast 访问了新站点")
        #expect(CaptureAlertText.details(alert: site) == "notion.com · 首个主机 api.notion.com · 经由 node")
        let direct = alert(2, app: UUID(), scope: .ip, value: "157.148.69.80", direct: true)
        #expect(CaptureAlertText.title(appName: "WeChat", alert: direct) == "WeChat 直接连接了新 IP")
    }

    @Test func measuresTheRate() {
        var meter = CaptureRateMeter(historyLength: 5, window: 2)
        let t0 = Date(timeIntervalSince1970: 1_792_000_000)
        meter.record(3, now: t0)
        meter.record(1, now: t0.addingTimeInterval(0.5))
        meter.record(2, now: t0.addingTimeInterval(1.2))
        meter.record(0, now: t0.addingTimeInterval(3.1))
        // Seconds: t0 → 4, t0+1 → 2, t0+2 → 0 (idle)
        #expect(meter.history == [0, 0, 4, 2, 0])
        #expect(meter.rate == 1)
    }
}
