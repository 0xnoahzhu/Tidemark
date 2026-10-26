import AppIntents
import Foundation
import Testing
@testable import Tidemark

struct IntentsIPTests {
    @Test(arguments: ["104.16.27.34", " 8.8.8.8\n", "2001:db8::1", "[2606:4700::6810:1b22]", "::1", "fe80::1%4", "::ffff:192.0.2.1"])
    func acceptsAddresses(_ value: String) {
        #expect(IntentsText.normalizedIP(value) != nil)
    }

    @Test(arguments: ["", "github.com", "999.1.1.1", "1.2.3", "abc", ":", "12345::1", "1:2:3:4:5:6:7:8:9"])
    func rejectsNonAddresses(_ value: String) {
        #expect(IntentsText.normalizedIP(value) == nil)
    }

    @Test func trimsBrackets() {
        #expect(IntentsText.normalizedIP("[2001:db8::1]") == "2001:db8::1")
        #expect(IntentsText.normalizedIP(" 1.1.1.1 ") == "1.1.1.1")
    }
}

@MainActor
struct IntentsTextTests {
    @Test func formatsLookups() {
        let result = IPLookupResult(ip: "104.16.27.34", country: "us", asn: 13335, organization: "Cloudflare, Inc.", networkType: "Hosting · anycast", reverseDNS: nil)
        #expect(IntentsText.lookupLine(result) == "104.16.27.34 · US · AS13335 Cloudflare · Hosting · anycast")
    }

    @Test func explainsEmptyLookups() {
        let line = IntentsText.lookupLine(IPLookupResult(ip: "10.0.0.1", networkType: "  "))
        #expect(line == trf("No details found for %@.", "Intents", "10.0.0.1"))
    }

    @Test func summarizesToday() {
        let text = IntentsText.summary(IntentsTodayFigures(requests: 12_345, newDestinations: 7))
        let parts = text.components(separatedBy: " · ")
        #expect(parts.count == 2)
        #expect(parts[0].contains("12,345"))
        #expect(parts[1].contains("7"))
        #expect(IntentsText.summary(IntentsTodayFigures(requests: 1, newDestinations: 0)).hasSuffix(tr("no new destinations", "Intents")))
    }

    @Test func describesRecordingState() {
        #expect(IntentsText.recordingDialog(isOn: true) != IntentsText.recordingDialog(isOn: false))
    }
}

struct IntentsTodayFiguresTests {
    private func alert(_ value: String, kind: HostKind = .domain, device: DeviceID, at date: Date) -> AlertItem {
        AlertItem(id: Int64.random(in: 1...1_000_000), deviceID: device, appID: UUID(), kind: kind, scope: .host, value: value,
                  processName: "node", isDirect: false, createdAt: date)
    }

    @Test func countsDistinctDestinationsSinceStartOfDay() {
        let me = UUID(), other = UUID()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let alerts = [
            alert("linear.app", device: me, at: start.addingTimeInterval(60)),
            alert("Linear.app", device: me, at: start.addingTimeInterval(120)),
            alert("104.16.27.34", kind: .ip, device: me, at: start.addingTimeInterval(5)),
            alert("old.example", device: me, at: start.addingTimeInterval(-60)),
            alert("elsewhere.example", device: other, at: start.addingTimeInterval(60)),
        ]
        #expect(IntentsTodayFigures.newDestinations(in: alerts, since: start, device: me) == 2)
        #expect(IntentsTodayFigures.newDestinations(in: [], since: start, device: me) == 0)
    }

    /// Rows and alerts are written under this Mac's device row, which the live Today counter also follows; the
    /// summary counts that device, not the alerts other Macs found.
    @MainActor
    @Test func countsThisMac() async {
        let suite = "tidemark-tests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { TestDefaults.remove(suite) }
        let preferences = Preferences(defaults: defaults)
        let model = AppModel(preferences: preferences)
        let me = preferences.thisDeviceID

        let now = Date.now
        model.alerts.items = [
            alert("linear.app", device: me, at: now),
            alert("104.16.27.34", kind: .ip, device: me, at: now),
            alert("other-mac.example", device: UUID(), at: now),
        ]
        model.live.todayCount = 42
        // The placeholder database is offline, so the figures come from the live state alone.
        let figures = await IntentsTodayFigures.load(model, now: now)
        #expect(figures.requests == 42)
        #expect(figures.newDestinations == 2)
    }
}

struct IntentsEntityTests {
    private func app(_ name: String, created: TimeInterval, archived: Bool = false, bundleID: String? = nil) -> MonitoredApp {
        MonitoredApp(id: UUID(), name: name, path: "/Applications/\(name).app", bundleID: bundleID, tileLetter: String(name.prefix(1)),
                     tileHue: 240, includeChildren: true, alertRule: .site, alertNewIP: true,
                     archivedAt: archived ? Date(timeIntervalSince1970: created + 1) : nil,
                     createdAt: Date(timeIntervalSince1970: created))
    }

    @Test func suggestsActiveAppsFirst() {
        let apps = [app("Raycast", created: 30), app("Zed", created: 5, archived: true), app("Cursor", created: 10), app("Arc", created: 1, archived: true)]
        let names = MonitoredAppQuery.suggested(from: apps).map(\.name)
        #expect(names == ["Cursor", "Raycast", "Arc", "Zed"])
    }

    @Test func matchesNameBundleIDAndBundleName() {
        let entity = MonitoredAppEntity(app: app("Visual Studio Code", created: 0, bundleID: "com.microsoft.VSCode"))
        #expect(entity.matches("studio"))
        #expect(entity.matches("microsoft"))
        #expect(entity.matches(""))
        #expect(!entity.matches("cursor"))
        // A bundle missing on this Mac is named after its file.
        let renamed = MonitoredAppEntity(app: MonitoredApp(id: UUID(), name: "Docs", path: "/Applications/Tidemark Missing Notion.app", tileLetter: "N", tileHue: 0,
                                                          includeChildren: true, alertRule: .off, alertNewIP: false, createdAt: .now))
        #expect(renamed.matches("missing notion"))
        #expect(!renamed.matches(".app"))
        // An installed bundle matches by the name Finder shows for it, and by its file name in any system language.
        let finderPath = "/System/Library/CoreServices/Finder.app"
        let finder = MonitoredAppEntity(app: MonitoredApp(id: UUID(), name: "Files", path: finderPath + "/", tileLetter: "F", tileHue: 0,
                                                         includeChildren: true, alertRule: .off, alertNewIP: false, createdAt: .now))
        #expect(finder.matches(AppNaming.displayName(forBundlePath: finderPath)))
        #expect(finder.matches("finder"))
    }

    @Test func keepsTheAppIdentity() {
        let source = app("Cursor", created: 0, archived: true, bundleID: "com.todesktop.cursor")
        let entity = MonitoredAppEntity(app: source)
        #expect(entity.id == source.id)
        #expect(entity.path == "/Applications/Cursor.app")
        #expect(entity.isArchived)
    }
}

struct IntentsMetadataTests {
    @Test func runInTheMainApp() {
        #expect(ToggleRecordingIntent.allowedExecutionTargets == .main)
        #expect(TodaySummaryIntent.allowedExecutionTargets == .main)
        #expect(LookUpIPIntent.allowedExecutionTargets == .main)
        #expect(OpenMonitoredAppIntent.allowedExecutionTargets == .main)
        #expect(MonitoredAppQuery.allowedExecutionTargets == .main)
    }

    @Test func onlyOpeningAnAppComesToTheForeground() {
        #expect(ToggleRecordingIntent.supportedModes == .background)
        #expect(TodaySummaryIntent.supportedModes == .background)
        #expect(LookUpIPIntent.supportedModes == .background)
        #expect(OpenMonitoredAppIntent.supportedModes == .foreground(.immediate))
    }

    @MainActor
    @Test func wrapsErrorsForShortcuts() {
        let invalid = TidemarkIntentError.invalidIP("nope")
        #expect(invalid.kind == .invalidIP)
        #expect(invalid.message.contains("nope"))
        #expect(TidemarkIntentError.appNotFound.kind == .appNotFound)
        #expect(!invalid.appIntentError.description.isEmpty)
    }
}
