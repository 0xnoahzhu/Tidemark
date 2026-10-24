import Foundation
import Testing
@testable import Tidemark

@MainActor
struct CaptureEngineTests {
    let temp = CaptureTempDirectory()

    func makeEngine(database: CaptureFakeDatabase = CaptureFakeDatabase()) -> (CaptureEngine, AppModel) {
        let defaults = UserDefaults(suiteName: "tidemark-tests-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        preferences.systemNotifications = false
        let model = AppModel(preferences: preferences)
        model.database = database
        let engine = CaptureEngine(model: model, surge: CaptureFakeSurge(), database: database, processes: CaptureFakeProcesses(),
                                   classifier: CaptureFakeClassifier(), spool: CaptureSpool(directory: temp.url, limit: 1000))
        model.capture = engine
        return (engine, model)
    }

    func row(_ id: Int64, device: DeviceID, started: Date) -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device, session: 1, surgeID: id), rowID: nil, startedAt: started, setupCompletedAt: nil,
            completedAt: nil, method: "HTTPS", host: "h\(id).com", port: 443, url: nil, remoteIP: nil, remoteAddress: nil, geo: nil,
            policyPath: ["DIRECT"], rule: nil, state: .active, inBytes: 0, outBytes: 0, pid: nil, processPath: nil, bundlePath: nil,
            chain: [], appID: nil, localAddress: nil, interface: nil, notes: [], isNew: false, writtenAt: nil, probeSessionID: nil
        )
    }

    @Test func appliesCoalescedUpdatesToTheLiveState() {
        let (engine, model) = makeEngine()
        let device = model.preferences.thisDeviceID
        let now = Date(timeIntervalSince1970: 1_792_000_000)

        var first = CaptureUIUpdate()
        first.records = [row(1, device: device, started: now), row(2, device: device, started: now.addingTimeInterval(1))]
        first.fresh = Set(first.records.map(\.key))
        first.newRequests = 2
        first.rowsWritten = 2
        first.bufferedRows = 7
        first.speed = SurgeSpeed(in: 2048, out: 512, downloadSpeedHistory: nil, uploadSpeedHistory: nil)
        engine.apply(first, now: now)
        #expect(model.live.rows.map(\.key.surgeID) == [2, 1])
        #expect(model.live.writtenThisSession == 2)
        #expect(model.live.totalRows == 2)
        #expect(model.live.bufferedRows == 7)
        #expect(model.live.downloadSpeed == 2048 && model.live.uploadSpeed == 512)
        #expect(model.live.todayCount == 2)

        // Updates of rows that scrolled away must not come back to the top.
        var second = CaptureUIUpdate()
        var updated = row(1, device: device, started: now)
        updated.inBytes = 99
        second.records = [updated, row(3, device: device, started: now.addingTimeInterval(-600))]
        engine.apply(second, now: now.addingTimeInterval(1))
        #expect(model.live.rows.map(\.key.surgeID) == [2, 1])
        #expect(model.live.rows.last?.inBytes == 99)
        #expect(model.live.rateHistory.last == 2, "the closed second holds both new requests")
    }

    @Test func listsNewAlertsForTheScope() {
        let (engine, model) = makeEngine()
        let me = model.preferences.thisDeviceID
        let alert = AlertItem(id: 41, deviceID: me, appID: UUID(), kind: .domain, scope: .site, value: "api.notion.com", site: "notion.com",
                              host: "api.notion.com", ip: nil, geo: nil, processName: "node", isDirect: false, requestRowID: 1,
                              createdAt: .now, readAt: nil)
        var update = CaptureUIUpdate()
        update.alerts = [alert]
        engine.apply(update)
        #expect(model.alerts.items.map(\.id) == [41])
        #expect(model.alerts.unreadCount == 1)

        model.devices.scope = .device(UUID())
        var other = CaptureUIUpdate()
        var hidden = alert
        hidden.id = 42
        other.alerts = [hidden]
        engine.apply(other)
        #expect(model.alerts.items.map(\.id) == [41], "another Mac's scope hides this Mac's alerts")
    }

    @Test func monitorsAnAppFromItsBundle() async throws {
        let database = CaptureFakeDatabase()
        let (engine, model) = makeEngine(database: database)
        let app = try await engine.monitorApp(path: "/Applications/Imaginary Tool.app/", includeChildren: true, alertOnDomain: false,
                                              alertOnIP: true, backfill: false)
        #expect(app.path == "/Applications/Imaginary Tool.app")
        #expect(app.name == "Imaginary Tool")
        #expect(app.tileLetter == "I")
        #expect(CaptureDeviceInfo.tilePalette.contains(app.tileHue))
        #expect(app.alertRule == .off && app.alertNewIP)
        #expect(model.catalog.apps.map(\.id) == [app.id])

        let again = try await engine.monitorApp(path: "/Applications/Imaginary Tool.app", includeChildren: true, alertOnDomain: true,
                                                alertOnIP: true, backfill: false)
        #expect(again.id == app.id, "a bundle is monitored once")

        engine.setMonitoring(app.id, enabled: false)
        #expect(model.catalog.paused == [app.id])
        #expect(!model.catalog.isMonitoring(app.id))

        model.nav.open(.app(app.id))
        try await engine.deleteApp(app.id)
        #expect(model.catalog.apps.isEmpty && model.catalog.paused.isEmpty)
        #expect(model.nav.page == .requests)
    }

    @Test func readsBundleNames() {
        let identity = CaptureEngine.bundleIdentity(at: "/System/Applications/Calculator.app")
        #expect(identity.bundleID == "com.apple.calculator")
        #expect(!identity.name.isEmpty && identity.letter.count == 1)
        #expect(CaptureEngine.normalizedBundlePath("/Applications//Cursor.app/") == "/Applications/Cursor.app")
    }

    @Test func mutesAndDismissesAnAlert() async {
        let database = CaptureFakeDatabase()
        let (engine, model) = makeEngine(database: database)
        model.alerts.items = [AlertItem(id: 7, deviceID: UUID(), appID: UUID(), kind: .ip, scope: .ip, value: "104.16.98.215", site: nil,
                                        host: nil, ip: "104.16.98.215", geo: nil, processName: "docker", isDirect: false, requestRowID: nil,
                                        createdAt: .now, readAt: nil)]
        model.alerts.unreadCount = 1
        await engine.mute("104.16.98.215", dismissingAlert: 7)
        #expect(model.alerts.mutes == ["104.16.98.215"])
        #expect(model.alerts.items.isEmpty && model.alerts.unreadCount == 0)
        #expect(await database.mutesList == ["104.16.98.215"])
        await engine.unmute("104.16.98.215")
        #expect(model.alerts.mutes.isEmpty)
    }

    @Test func marksAlertsRead() async {
        let (engine, model) = makeEngine()
        let alerts = (1...3).map { id in
            AlertItem(id: Int64(id), deviceID: UUID(), appID: UUID(), kind: .domain, scope: .host, value: "h\(id).com", site: nil, host: nil,
                      ip: nil, geo: nil, processName: "p", isDirect: false, requestRowID: nil, createdAt: .now, readAt: nil)
        }
        model.alerts.items = alerts
        model.alerts.unreadCount = 3
        await engine.markAlertsRead([1, 3])
        #expect(model.alerts.items.map(\.isUnread) == [false, true, false])
        #expect(model.alerts.unreadCount == 1)
    }

    @Test func testsTheDatabaseConnection() async throws {
        Localizer.shared.preference = .english
        let (engine, _) = makeEngine()
        let result = await engine.testDatabaseConnection()
        #expect(try result.get() == "Connected · PostgreSQL 18.3 · 2 ms")

        let failing = CaptureFakeDatabase()
        await failing.setFailing(true)
        let (offline, _) = makeEngine(database: failing)
        guard case .failure = await offline.testDatabaseConnection() else {
            Issue.record("an unreachable database must fail")
            return
        }
    }

    @Test func connectsAndLoadsTheSharedState() async {
        let database = CaptureFakeDatabase()
        let (engine, model) = makeEngine(database: database)
        #expect(await engine.connectDatabase())
        #expect(model.live.database == .connected(detail: "PostgreSQL 18.3"))
        #expect(model.live.serverVersion == "18.3")
        #expect(await engine.pipeline.isOnline)

        let failing = CaptureFakeDatabase()
        await failing.setFailing(true)
        let (offline, offlineModel) = makeEngine(database: failing)
        #expect(await offline.connectDatabase() == false)
        if case .failed = offlineModel.live.database {} else { Issue.record("expected a failed link status") }
    }

    @Test func describesThisMac() {
        #expect(CaptureDeviceInfo.modelDescription(product: "Mac mini (2024)", chip: "M4") == "Mac mini · M4")
        #expect(CaptureDeviceInfo.modelDescription(product: nil, chip: nil) == nil)
        #expect(CaptureDeviceInfo.shortName(name: "Noah’s MacBook Pro", product: "MacBook Pro (14-inch, 2023)") == "MBP")
        #expect(CaptureDeviceInfo.shortName(name: "Studio Desk", product: "Mac Studio (2023)") == "Std")
        let me = UUID()
        #expect(CaptureDeviceInfo.remoteDeviceID(thisDevice: me, remote: "10.0.0.2:6171") == CaptureDeviceInfo.remoteDeviceID(thisDevice: me, remote: "10.0.0.2:6171"))
        #expect(CaptureDeviceInfo.remoteDeviceID(thisDevice: me, remote: "10.0.0.2:6171") != CaptureDeviceInfo.remoteDeviceID(thisDevice: me, remote: "10.0.0.3:6171"))
        #expect(CaptureDeviceInfo.hue(for: me) == CaptureDeviceInfo.hue(for: me))
    }
}
