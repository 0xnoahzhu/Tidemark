import Foundation
import Testing
@preconcurrency import UserNotifications
@testable import Tidemark

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct CaptureEngineTests {
    let temp = CaptureTempDirectory()
    let scratch = TestDefaults()
    /// Notifications the engines posted; none reaches Notification Center.
    let notifications = CaptureBox<[UNNotificationRequest]>([])

    func makeEngine(database: CaptureFakeDatabase = CaptureFakeDatabase(), surge: CaptureFakeSurge = CaptureFakeSurge()) -> (CaptureEngine, AppModel) {
        let model = AppModel(preferences: Preferences(defaults: scratch.make()))
        model.database = database
        let engine = CaptureEngine(model: model, surge: surge, database: database, processes: CaptureFakeProcesses(),
                                   classifier: CaptureFakeClassifier(), spool: CaptureSpool(directory: temp.url, limit: 1000))
        // Never connect to the environment's TIDEMARK_DATABASE_URL from tests.
        engine.settingsDatabaseURL = { "postgresql://tide@db-a.invalid/tidemark" }
        let notifications = self.notifications
        engine.notifier.deliver = { notifications.value.append($0) }
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

    @Test func listsNewAlertsFromEveryMac() {
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
        var shown = alert
        shown.id = 42
        other.alerts = [shown]
        engine.apply(other)
        #expect(model.alerts.items.map(\.id) == [42, 41], "another Mac's scope still lists this Mac's alerts")
        #expect(model.alerts.unreadCount == 2)
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

    @Test func registersThisMacBeforeWritesResume() async {
        // Every request row references this Mac's row: a flush that reached the server first would be refused
        // whole and spooled.
        let database = CaptureFakeDatabase()
        let (engine, _) = makeEngine(database: database)
        let pipeline = engine.pipeline
        await database.setOnUpsertDevice { await pipeline.isOnline }
        #expect(await engine.connectDatabase())
        #expect(await database.deviceUpserts == [engine.thisDeviceID])
        #expect(await database.onlineWhenRegistered == [false])
        #expect(await pipeline.isOnline)
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

        // A new password in the URL rebuilds the client.
        engine.settingsDatabaseURL = { "postgresql://tide:new@db-a.invalid/tidemark" }
        engine.reconnect()
        #expect(await eventually { (model.database as? CaptureFakeDatabase) === replacement })
        #expect(built.value == ["postgresql://tide:new@db-a.invalid/tidemark"])
        #expect(await eventually { (await engine.pipeline.database as? CaptureFakeDatabase) === replacement })
        #expect(await eventually { model.live.database.isHealthy })
        #expect(await CaptureWait.finishes { await engine.stopStream() })
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
        #expect(await CaptureWait.finishes { await engine.stopStream() })
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
        #expect(await CaptureWait.finishes { await engine.stopStream() })
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
        #expect(await CaptureWait.finishes { await engine.stopStream() })
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

    /// Every alert becomes a system notification on every Mac: this Mac's and the ones other Macs found, which
    /// name their Mac, also for an app whose monitoring is paused here (that only stops this Mac's alerts).
    @Test func notifiesAlertsFromEveryMac() async {
        Localizer.shared.preference = .english
        let database = CaptureFakeDatabase()
        let (engine, model) = makeEngine(database: database)
        let cursor = CaptureFixtures.app("Cursor", path: "/Applications/Cursor.app")
        let docker = CaptureFixtures.app("Docker", path: "/Applications/Docker.app")
        await database.setApps([cursor, docker])
        #expect(await engine.connectDatabase())
        let me = model.preferences.thisDeviceID
        let mini = Device(id: UUID(), name: "Mac mini (Office)", model: "Mac mini · M4", shortName: "mini", hue: 150, isRemoteSurge: false,
                          rowCount: 0, lastWriteAt: nil, createdAt: .now)
        model.devices.devices = [mini]
        func alert(_ id: Int64, _ device: DeviceID, _ app: MonitoredApp, _ kind: HostKind, _ value: String) -> AlertItem {
            AlertItem(id: id, deviceID: device, appID: app.id, kind: kind, scope: kind == .ip ? .ip : .host, value: value, site: nil,
                      host: kind == .ip ? nil : value, ip: nil, geo: nil, processName: "com.docker.backend", isDirect: false,
                      requestRowID: nil, createdAt: .now, readAt: nil)
        }

        var update = CaptureUIUpdate()
        update.alerts = [alert(1, me, cursor, .domain, "api2.cursor.sh")]
        engine.apply(update)
        model.catalog.paused.insert(docker.id)
        await database.setOtherMacAlerts([alert(2, mini.id, docker, .ip, "104.16.98.215")])
        await engine.pollOtherMacAlerts()

        let posted = notifications.value.map(\.content)
        #expect(posted.map(\.title) == ["Tidemark", "Tidemark"])
        #expect(posted.map(\.subtitle) == ["Cursor contacted a new host", "Docker connected to a new IP"])
        #expect(posted.map(\.body) == ["api2.cursor.sh · via com.docker.backend", "Mac mini (Office) · 104.16.98.215 · via com.docker.backend"])
        #expect(model.alerts.items.map(\.id) == [2, 1])
    }

    @Test func describesWriteFailuresInTheUILanguage() {
        Localizer.shared.preference = .english
        let (engine, model) = makeEngine()
        var update = CaptureUIUpdate()
        update.databaseFailure = "PostgreSQL refused every write: disk full"
        update.databaseError = CaptureServerRejection(message: "disk full")
        engine.apply(update)
        #expect(model.live.database == .failed(CaptureServerRejection(message: "disk full")))
        #expect(SidebarStatusText.help(model.live.database) == "PostgreSQL refused every write: disk full")
        #expect(CaptureEngine.message(for: CaptureTimeoutError(seconds: 20)) == "PostgreSQL did not answer in time")

        // The status keeps the error, so it reads in a language chosen after the failure.
        Localizer.shared.preference = .chinese
        defer { Localizer.shared.preference = .english }
        guard Localizer.shared.bundle != nil else { return }
        #expect(SidebarStatusText.help(model.live.database) == "PostgreSQL 拒绝了所有写入：disk full")
        #expect(CaptureEngine.message(for: CaptureSurgeFailure.stoppedStreaming) == "Surge 已停止推送")
    }

    @Test func describesDatabaseAndSurgeFailuresInTheUILanguage() {
        Localizer.shared.preference = .english
        #expect(CaptureEngine.message(for: DatabaseError.unreachable("connection refused")) == "PostgreSQL is unreachable: connection refused")
        #expect(CaptureEngine.message(for: SurgeError.commandFailed(command: "status", message: "denied")) == "surge-cli status failed: denied")
        #expect(CaptureEngine.message(for: SurgeError.commandFailed(command: "status", message: "exit status 9"))
                == "surge-cli status failed with exit status 9.")
        #expect(CaptureEngine.message(for: CaptureDisplayError(DatabaseError.notConfigured)) == "No PostgreSQL connection is configured.")
        // Typed reasons read in English exactly as the log has them.
        let typed: [DatabaseError] = [
            .unreachable(.passwordRequired(target: "db.local:5432/tidemark")), .unreachable(.localNetworkBlocked),
            .unreachable(.cannotConnect(target: "db.local:5432/tidemark", reason: .connectTimedOut(target: "db.local:5432/tidemark"))),
            .unreachable(.noConnection(target: nil, within: .seconds(10))), .unreachable(.schemaTooNew(schema: 5, supported: 3)),
            .unreachable(.tlsNotAccepted(target: "db.local:5432/tidemark")), .unreachable(.serverClosedConnection(target: "db.local:5432/tidemark")),
            .timedOut(.statement(.seconds(300))), .timedOut(.statement(nil)), .timedOut(.noReply(target: "db.local:5432/tidemark", within: .seconds(35))),
        ]
        for error in typed {
            #expect(CaptureEngine.message(for: error) == error.errorDescription)
        }

        Localizer.shared.preference = .chinese
        defer { Localizer.shared.preference = .english }
        guard Localizer.shared.bundle != nil else { return }
        #expect(CaptureEngine.message(for: DatabaseError.unreachable("connection refused")) == "连不上 PostgreSQL：connection refused")
        #expect(CaptureEngine.message(for: DatabaseError.unreachable(.passwordRequired(target: "db.local:5432/tidemark")))
                == "连不上 PostgreSQL：db.local:5432/tidemark 需要密码。")
        #expect(CaptureEngine.message(for: DatabaseError.unreachable(.cannotConnect(target: "db.local:5432/tidemark", reason: .connectTimedOut(target: "db.local:5432/tidemark"))))
                == "连不上 PostgreSQL：无法连接到 db.local:5432/tidemark：连接 db.local:5432/tidemark 超时。")
        #expect(CaptureEngine.message(for: DatabaseError.unreachable(.noConnection(target: "db.local:5432/tidemark", within: .seconds(10))))
                == "连不上 PostgreSQL：10 秒内没有可用的 db.local:5432/tidemark 连接。")
        #expect(CaptureEngine.message(for: DatabaseError.unreachable(.localNetworkBlocked)).hasSuffix("本地网络中允许 Tidemark。"))
        #expect(CaptureEngine.message(for: DatabaseError.timedOut(.statement(.seconds(300))))
                == "PostgreSQL 查询超时：服务器在 5 分钟后取消了查询（statement timeout）。")
        #expect(CaptureEngine.message(for: DatabaseError.timedOut(.noReply(target: "db.local:5432/tidemark", within: .seconds(35))))
                == "PostgreSQL 查询超时：db.local:5432/tidemark 在 35 秒内没有回应，连接已关闭。")
        for error in typed {
            let english = error.errorDescription ?? ""
            let reason = english[(english.range(of: ": ")?.upperBound ?? english.startIndex)...]
            #expect(!CaptureEngine.message(for: error).contains(reason), "\(error) is translated")
        }
        #expect(CaptureEngine.message(for: DatabaseError.query("syntax error")) == "PostgreSQL 错误：syntax error")
        #expect(CaptureEngine.message(for: DatabaseError.invalidURL("postgresql://x")) == "PostgreSQL 连接地址无效：postgresql://x")
        #expect(CaptureEngine.message(for: DatabaseError.notConfigured) == "还没有设置 PostgreSQL 连接。")
        #expect(CaptureEngine.message(for: SurgeError.cliNotFound(path: "/opt/surge-cli")) == "在 /opt/surge-cli 找不到 surge-cli。")
        #expect(CaptureEngine.message(for: SurgeError.commandFailed(command: "status", message: "denied")) == "surge-cli status 失败：denied")
        #expect(CaptureEngine.message(for: SurgeError.commandFailed(command: "status", message: "exit status 9")) == "surge-cli status 失败，退出状态 9。")
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
        #expect(await CaptureWait.finishes { await refresh.value })
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
