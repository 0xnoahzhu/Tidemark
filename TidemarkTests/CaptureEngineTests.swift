import Foundation
import Testing
@testable import Tidemark

@MainActor
struct CaptureEngineTests {
    let temp = CaptureTempDirectory()

    func makeEngine(database: CaptureFakeDatabase = CaptureFakeDatabase(), surge: CaptureFakeSurge = CaptureFakeSurge()) -> (CaptureEngine, AppModel) {
        let defaults = UserDefaults(suiteName: "tidemark-tests-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        preferences.systemNotifications = false
        preferences.surgeReconnect = false
        let model = AppModel(preferences: preferences)
        model.database = database
        let engine = CaptureEngine(model: model, surge: surge, database: database, processes: CaptureFakeProcesses(),
                                   classifier: CaptureFakeClassifier(), spool: CaptureSpool(directory: temp.url, limit: 1000))
        // Never read the Keychain from tests.
        engine.settingsDatabaseURL = { "postgresql://tide@db-a.invalid/tidemark" }
        model.capture = engine
        return (engine, model)
    }

    /// Polls `condition` until it holds or the timeout passes.
    func eventually(_ timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
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

    // MARK: Credentials

    @Test func reconnectRebuildsTheDatabaseWhenItsURLOrPasswordChanged() async {
        let (engine, model) = makeEngine()
        let built = CaptureBox<[String]>([])
        let replacement = CaptureFakeDatabase()
        engine.adoptDatabaseURL("postgresql://tide@db-a.invalid/tidemark")
        engine.makeDatabase = { url in
            built.value.append(url)
            return replacement
        }
        let original = model.database as? CaptureFakeDatabase

        engine.reconnect()
        #expect(await eventually { model.live.database.isHealthy })
        #expect(built.value.isEmpty, "unchanged settings keep the client")
        #expect((model.database as? CaptureFakeDatabase) === original)

        // A new Keychain password changes the full URL, not the stored one.
        engine.settingsDatabaseURL = { "postgresql://tide@db-b.invalid/tidemark" }
        engine.reconnect()
        #expect(await eventually { (model.database as? CaptureFakeDatabase) === replacement })
        #expect(built.value == ["postgresql://tide@db-b.invalid/tidemark"])
        #expect(await eventually { (await engine.pipeline.database as? CaptureFakeDatabase) === replacement })
        #expect(await eventually { model.live.database.isHealthy })
    }

    @Test func testingNewSettingsUsesAThrowawayClient() async {
        let (engine, model) = makeEngine()
        let original = model.database as? CaptureFakeDatabase
        let candidate = CaptureFakeDatabase()
        await candidate.setFailing(true)
        let retired = CaptureRetiredDatabases()
        engine.adoptDatabaseURL("postgresql://tide@db-a.invalid/tidemark")
        engine.settingsDatabaseURL = { "postgresql://tide@db-b.invalid/tidemark" }
        engine.makeDatabase = { _ in candidate }
        engine.retireDatabase = { database in await retired.add(database) }

        guard case .failure = await engine.testDatabaseConnection() else {
            Issue.record("the new settings point at an unreachable server")
            return
        }
        #expect((model.database as? CaptureFakeDatabase) === original, "the live connection keeps recording")
        #expect(await retired.count == 1)
    }

    @Test func reconnectRebuildsTheSurgeClientOnlyWhenTheEndpointChanged() async {
        let (engine, model) = makeEngine()
        let made = CaptureBox<[SurgeEndpoint]>([])
        model.preferences.surgeCLIPath = "/opt/test/surge-cli"
        engine.makeSurgeClient = { endpoint in
            made.value.append(endpoint)
            return CaptureFakeSurge(cliPath: endpoint.cliPath)
        }
        engine.reconnect()
        #expect(await eventually { made.value.count == 1 && engine.surge.endpoint.cliPath == "/opt/test/surge-cli" })
        #expect(model.surge.endpoint.cliPath == "/opt/test/surge-cli")

        engine.reconnect()
        try? await Task.sleep(for: .milliseconds(200))
        #expect(made.value.count == 1, "the same endpoint keeps its client")
    }

    // MARK: Surge stream

    @Test func aRestartedEngineRestartsTheStream() async {
        let surge = CaptureFakeSurge()
        surge.update {
            $0.silentStream = true
            $0.startTime = 1_792_000_000
        }
        let (engine, model) = makeEngine(surge: surge)
        engine.startStream()
        #expect(await eventually { model.live.surge.isHealthy })
        #expect(await engine.pipeline.currentSession == 1_792_000_000_000)

        // Same session: nothing happens.
        await engine.checkSurgeSession()
        #expect(surge.snapshot.eventsCalls == 1)

        surge.update { $0.startTime = 1_792_000_600 }
        await engine.checkSurgeSession()
        #expect(await eventually { await engine.pipeline.currentSession == 1_792_000_600_000 })
        #expect(surge.snapshot.eventsCalls == 2)
        await engine.stopStream()
    }

    @Test func aSilentStreamIsRestarted() async {
        let surge = CaptureFakeSurge()
        surge.update { $0.silentStream = true }
        let (engine, model) = makeEngine(surge: surge)
        engine.startStream()
        #expect(await eventually { model.live.surge.isHealthy && surge.snapshot.eventsCalls == 1 })

        surge.emit(.speed(SurgeSpeed(in: 10, out: 1, downloadSpeedHistory: nil, uploadSpeedHistory: nil)))
        try? await Task.sleep(for: .milliseconds(50))
        await engine.checkStreamLiveness(now: .now.addingTimeInterval(5))
        #expect(surge.snapshot.eventsCalls == 1, "events keep arriving")

        await engine.checkStreamLiveness(now: .now.addingTimeInterval(20))
        #expect(await eventually { surge.snapshot.eventsCalls == 2 })
        await engine.stopStream()
    }

    // MARK: Alerts and notifications

    @Test func alertsFromOtherMacsSkipMutedHostsAndArchivedApps() async {
        let database = CaptureFakeDatabase()
        let (engine, model) = makeEngine(database: database)
        let cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app")
        var docker = CaptureFixtures.app("Docker", path: "/Applications/Docker.app")
        docker.archivedAt = .now
        await database.setApps([cursor, docker])
        await database.setMutes(["*.muted.example"])
        #expect(await engine.connectDatabase())

        let other = UUID()
        func alert(_ id: Int64, _ app: MonitoredApp, _ value: String) -> AlertItem {
            AlertItem(id: id, deviceID: other, appID: app.id, kind: .domain, scope: .host, value: value, site: nil, host: value, ip: nil,
                      geo: nil, processName: "node", isDirect: false, requestRowID: nil, createdAt: .now, readAt: nil)
        }
        await database.setOtherMacAlerts([alert(1, cursor, "ok.example"), alert(2, cursor, "x.muted.example"), alert(3, docker, "y.example")])
        await engine.pollOtherMacAlerts()
        #expect(model.alerts.items.map(\.value) == ["ok.example"])
        #expect(model.alerts.unreadCount == 1)
    }

    @Test func explainsHostsInNotificationsWithoutWaitingLong() async {
        Localizer.shared.preference = .english
        let (engine, model) = makeEngine()
        let alert = AlertItem(id: 1, deviceID: UUID(), appID: UUID(), kind: .domain, scope: .site, value: "beacon.qq.com", site: "qq.com",
                              host: "beacon.qq.com", ip: nil, geo: nil, processName: "WeChat", isDirect: false, requestRowID: nil,
                              createdAt: .now, readAt: nil)
        #expect(engine.explanation(for: alert, appName: "WeChat") == nil, "off by default")

        model.preferences.notifyExplainHosts = true
        let insights = CaptureFakeInsights()
        let insight = HostInsight(host: "beacon.qq.com", category: .analytics, operatorName: "Tencent", summary: "Reports usage statistics.",
                                  concern: nil, language: "en", model: nil, createdAt: .now)
        insights.cached = insight
        model.insights = insights
        #expect(await engine.explanation(for: alert, appName: "WeChat")?() == "Tencent — Reports usage statistics.")

        // Not cached: the model may answer, but never later than the timeout.
        insights.cached = nil
        insights.generated = insight
        insights.delay = .seconds(5)
        let clock = ContinuousClock()
        let started = clock.now
        #expect(await engine.explanation(for: alert, appName: "WeChat")?() == nil)
        #expect(started.duration(to: clock.now) < .seconds(3))

        insights.delay = .zero
        #expect(await engine.explanation(for: alert, appName: "WeChat")?() == "Tencent — Reports usage statistics.")
        insights.available = false
        #expect(await engine.explanation(for: alert, appName: "WeChat")?() == nil)

        var direct = alert
        direct.kind = .ip
        direct.scope = .ip
        direct.host = nil
        #expect(engine.explanation(for: direct, appName: "WeChat") == nil, "an IP without a hostname has no host to explain")
    }

    @Test func describesWriteFailuresInTheUILanguage() {
        Localizer.shared.preference = .english
        let (engine, model) = makeEngine()
        var update = CaptureUIUpdate()
        update.databaseFailure = "PostgreSQL refused every write: disk full"
        update.databaseError = CaptureServerRejection(message: "disk full")
        engine.apply(update)
        #expect(model.live.database == .failed(message: "PostgreSQL refused every write: disk full"))
        #expect(CaptureEngine.message(for: CaptureTimeoutError(seconds: 20)) == "PostgreSQL did not answer in time")
    }

    @Test func describesDatabaseAndSurgeFailuresInTheUILanguage() {
        Localizer.shared.preference = .english
        #expect(CaptureEngine.message(for: DatabaseError.unreachable("connection refused")) == "PostgreSQL is unreachable: connection refused")
        #expect(CaptureEngine.message(for: SurgeError.commandFailed(command: "status", message: "denied")) == "surge-cli status failed: denied")
        #expect(CaptureEngine.message(for: CaptureDisplayError(DatabaseError.notConfigured)) == "No PostgreSQL connection is configured.")

        Localizer.shared.preference = .chinese
        defer { Localizer.shared.preference = .english }
        guard Localizer.shared.bundle != nil else { return }
        #expect(CaptureEngine.message(for: DatabaseError.unreachable("connection refused")) == "连不上 PostgreSQL：connection refused")
        #expect(CaptureEngine.message(for: DatabaseError.query("syntax error")) == "PostgreSQL 错误：syntax error")
        #expect(CaptureEngine.message(for: DatabaseError.invalidURL("postgresql://x")) == "PostgreSQL 连接地址无效：postgresql://x")
        #expect(CaptureEngine.message(for: DatabaseError.notConfigured) == "还没有设置 PostgreSQL 连接。")
        #expect(CaptureEngine.message(for: SurgeError.cliNotFound(path: "/opt/surge-cli")) == "在 /opt/surge-cli 找不到 surge-cli。")
        #expect(CaptureEngine.message(for: SurgeError.commandFailed(command: "status", message: "denied")) == "surge-cli status 失败：denied")
        #expect(CaptureEngine.message(for: SurgeError.decoding(command: "dump active", message: "bad JSON")) == "无法读取 surge-cli dump active 的输出：bad JSON")
        #expect(CaptureEngine.message(for: SurgeError.timedOut(command: "status")) == "surge-cli status 超时。")
    }

    @Test func aFailedConnectionTestIsDescribedInTheUILanguage() async {
        Localizer.shared.preference = .english
        let failing = CaptureFakeDatabase()
        await failing.setFailing(true)
        let (engine, _) = makeEngine(database: failing)
        guard case .failure(let error) = await engine.testDatabaseConnection() else {
            Issue.record("an unreachable database must fail")
            return
        }
        #expect(error.localizedDescription == "PostgreSQL is unreachable: test")
    }

    // MARK: Apps

    @Test func anAppAddedOnAnotherMacWaitsForItsInventory() async throws {
        let database = CaptureFakeDatabase()
        let earlier = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app", createdAt: .now)
        await database.setApps([earlier])
        let (engine, model) = makeEngine(database: database)
        #expect(await engine.connectDatabase())
        #expect(await engine.pipeline.awaitingInventory.isEmpty, "apps loaded at launch come with their inventory")

        let cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app", createdAt: .now)
        await database.setApps([earlier, cursor])
        await engine.refreshSharedState()
        #expect(model.catalog.apps.map(\.id) == [earlier.id, cursor.id])
        let loadAfter = try #require(await engine.pipeline.inventoryLoadAfter[cursor.id])
        #expect(loadAfter > .now.addingTimeInterval(60), "the other Mac's backfill gets time to rebuild the inventory")
        // An earlier load (another app, a reconnect) does not end the wait.
        try await engine.pipeline.loadKnownHosts()
        #expect(await engine.pipeline.awaitingInventory[cursor.id] != nil)

        // An app added long ago (seen after this Mac was offline) only needs a load.
        let docker = CaptureFixtures.app("Docker", path: "/Applications/Docker.app", createdAt: .now.addingTimeInterval(-86_400))
        await database.setApps([earlier, cursor, docker])
        await engine.refreshSharedState()
        #expect(await eventually { await engine.pipeline.awaitingInventory[docker.id] == nil })
        #expect(await engine.pipeline.awaitingInventory[cursor.id] != nil)
    }

    @Test func aStaleAppListDoesNotUndoALocalChange() async throws {
        let database = CaptureFakeDatabase()
        let (engine, model) = makeEngine(database: database)
        #expect(await engine.connectDatabase())
        await database.setAppsDelay(.milliseconds(400))
        let refresh = Task { await engine.refreshSharedState() }
        // The refresh has read the (still empty) list when the app is added here.
        try await Task.sleep(for: .milliseconds(100))
        await database.setAppsDelay(.zero)
        let app = try await engine.monitorApp(path: "/Applications/Imaginary Tool.app", includeChildren: true, alertOnDomain: true,
                                              alertOnIP: true, backfill: false)
        await refresh.value
        #expect(model.catalog.apps.map(\.id) == [app.id])
        #expect(await engine.pipeline.isMonitoring(app.id))
    }

    @Test func aFailedDeleteKeepsTheApp() async throws {
        let database = CaptureFakeDatabase()
        let (engine, model) = makeEngine(database: database)
        let app = try await engine.monitorApp(path: "/Applications/Imaginary Tool.app", includeChildren: true, alertOnDomain: true,
                                              alertOnIP: true, backfill: false)
        await database.setFailing(true)
        await #expect(throws: DatabaseError.self) { try await engine.deleteApp(app.id) }
        #expect(model.catalog.apps.map(\.id) == [app.id])
        #expect(await engine.pipeline.isMonitoring(app.id), "attribution and first contact go on")
    }

    @Test func keepsTheRecordingMacsActivityFresh() {
        let (engine, model) = makeEngine()
        let me = model.preferences.thisDeviceID
        let then = Date(timeIntervalSince1970: 1_792_000_000)
        model.devices.devices = [Device(id: me, name: "Mac", model: nil, shortName: "Mac", hue: 240, isRemoteSurge: false, rowCount: 10,
                                        lastWriteAt: then, createdAt: then)]
        var update = CaptureUIUpdate()
        update.rowsWritten = 3
        update.lastWriteAt = then.addingTimeInterval(60)
        engine.apply(update, now: then.addingTimeInterval(60))
        #expect(model.devices.thisDevice?.rowCount == 13)
        #expect(model.devices.thisDevice?.activity(now: then.addingTimeInterval(61)) == .writingNow)
    }
}

/// A mutable value shared with a closure (main actor only).
final class CaptureBox<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

/// Databases handed to `retireDatabase`.
actor CaptureRetiredDatabases {
    private(set) var count = 0
    func add(_ database: any TidemarkDatabase) { count += 1 }
}

/// Scriptable on-device insights.
@MainActor
final class CaptureFakeInsights: HostInsightProviding {
    var cached: HostInsight?
    var generated: HostInsight?
    var delay: Duration = .zero
    var available = true

    var isAvailable: Bool { available }
    var unavailableReason: String? { available ? nil : "Off" }
    func insight(for context: HostContext) async throws -> HostInsight {
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let generated else { throw DatabaseError.notConfigured }
        return generated
    }
    func cachedInsight(for host: String) async -> HostInsight? { cached }
    func prewarm() {}
}
