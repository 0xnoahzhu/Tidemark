import Foundation
import Testing
@testable import Tidemark

/// An earlier ID of this Mac: work kept on disk under it is written under the current ID, and its rows are merged
/// into the current ID as maintenance, as are the rows of IDs found by the history they share with this Mac.
@Suite(.timeLimit(.minutes(1)))
struct CaptureDeviceMergeTests {
    /// The ID an earlier version stored, and the hardware-derived ID this Mac has now.
    let earlier = UUID()
    let current = UUID()
    let nodePath = "/Users/me/Library/Application Support/com.raycast.macos/node/bin/node"
    let boot = Date(timeIntervalSince1970: 1_792_000_000)
    /// Later than any internal timer start, so intervals have always elapsed.
    let base = Date.now.addingTimeInterval(5)

    var processes: CaptureFakeProcesses {
        CaptureFakeProcesses([
            LiveProcess(pid: 540, parentPID: 1, name: "Raycast", path: "/Applications/Raycast.app/Contents/MacOS/Raycast", startTime: boot),
            LiveProcess(pid: 1388, parentPID: 540, name: "node", path: nodePath, startTime: boot.addingTimeInterval(5)),
        ])
    }

    func makePipeline(_ database: CaptureFakeDatabase, device: DeviceID, directory: URL) -> CapturePipeline {
        CapturePipeline(
            settings: CaptureSettings(deviceID: device, batchRows: 200, batchInterval: 1, ownExecutablePath: nil),
            database: database, surge: CaptureFakeSurge(), processes: processes, classifier: CaptureFakeClassifier(), probes: ProbeRegistry(),
            spool: CaptureSpool(directory: directory, limit: 10_000), contactGrace: 0
        )
    }

    func row(_ id: Int64, device: DeviceID, session: Int64 = 1_000) -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device, session: session, surgeID: id), rowID: nil, startedAt: boot, setupCompletedAt: nil,
            completedAt: boot, method: "HTTPS", host: "h\(id).example", port: 443, url: nil, remoteIP: "203.0.113.\(id % 250)", remoteAddress: nil,
            geo: nil, policyPath: ["DIRECT"], rule: nil, state: .completed, inBytes: 1, outBytes: 1, pid: nil, processPath: "/usr/bin/curl",
            bundlePath: nil, chain: [], appID: nil, localAddress: nil, interface: nil, notes: [], isNew: false, writtenAt: nil, probeSessionID: nil
        )
    }

    // MARK: Spool and saved work

    @Test func aSpoolWrittenUnderAnEarlierIDReplaysUnderTheCurrentOne() async throws {
        let temp = CaptureTempDirectory()
        do {
            var spool = CaptureSpool(directory: temp.url, limit: 10_000)
            try spool.append([row(1, device: earlier), row(2, device: earlier), row(3, device: current)])
        }
        // The earlier ID's row is gone (merged away): a row under it would be refused on the foreign key.
        let database = CaptureFakeDatabase()
        await database.setEnforcesDeviceKeys(true)
        await database.register(current)
        var stored = row(2, device: current)
        stored.inBytes = 99
        await database.preinsertRow(stored)
        let pipeline = makePipeline(database, device: current, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base)

        #expect(await pipeline.isOnline)
        #expect(await pipeline.drainUpdate().databaseFailure == nil)
        #expect(await pipeline.bufferedRows == 0, "the spool drained")
        let writes = await database.writes
        #expect(writes.count == 3 && writes.allSatisfy { $0.key.deviceID == current })
        #expect(Set(await database.rows.keys) == Set([1, 2, 3].map { RequestKey(deviceID: current, session: 1_000, surgeID: $0) }),
                "the row stored under the current ID took the spooled copy as an update")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appending(path: "rejected.jsonl").path(percentEncoded: false)), "nothing was set aside")
        #expect(await pipeline.deviceMerges == [earlier: current], "the spool named an earlier ID of this Mac: it is merged")
    }

    @Test func workSavedOfflineUnderAnEarlierIDIsWrittenAsThisMacsNow() async throws {
        let temp = CaptureTempDirectory()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        do {
            // The earlier version quits while PostgreSQL is unreachable: the row is spooled and its first contact,
            // process chain and host sources are kept in auxiliary.json, all under the earlier ID.
            let database = CaptureFakeDatabase()
            await database.setKnown([raycast.id: ["backend.raycast.com"]])
            let pipeline = makePipeline(database, device: earlier, directory: temp.url)
            await pipeline.setApps([raycast], paused: [])
            try await pipeline.loadKnownHosts()
            await pipeline.beginSession(1_000)
            await pipeline.ingest(CaptureFixtures.request(id: 1, host: "api.notion.com", processPath: nodePath, pid: 1388,
                                                          remoteAddress: "104.18.32.12", policy: "DIRECT", completed: true), now: base)
            await pipeline.flushAll(now: base.addingTimeInterval(1), final: true)
        }
        // Only auxiliary.json names the earlier ID.
        for segment in try FileManager.default.contentsOfDirectory(at: temp.url, includingPropertiesForKeys: nil) where segment.pathExtension == "jsonl" {
            try FileManager.default.removeItem(at: segment)
        }

        let database = CaptureFakeDatabase()
        await database.setApps([raycast])
        await database.setEnforcesDeviceKeys(true)
        await database.register(current)
        let pipeline = makePipeline(database, device: current, directory: temp.url)
        _ = await pipeline.restoreSnapshot()
        await pipeline.setApps([raycast], paused: [])
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(2))
        await pipeline.tick(now: base.addingTimeInterval(4))

        #expect(await pipeline.isOnline)
        #expect(await database.chains.map(\.deviceID) == [current])
        let sources = await database.sources
        #expect(!sources.isEmpty && sources.allSatisfy { $0.deviceID == current })
        #expect(await database.appHosts.values.allSatisfy { $0.firstDeviceID == current })
        let alerts = await database.alertsInserted
        #expect(alerts.map(\.value) == ["api.notion.com"] && alerts.allSatisfy { $0.deviceID == current })
        #expect(await pipeline.deviceMerges == [earlier: current], "auxiliary.json named an earlier ID of this Mac: it is merged")
    }

    // MARK: Merging earlier IDs

    @Test func anEarlierIDIsMergedOnceTheSpoolIsReplayedAndTheDelayPassed() async throws {
        let temp = CaptureTempDirectory()
        do {
            var spool = CaptureSpool(directory: temp.url, limit: 10_000)
            try spool.append([row(1, device: current), row(2, device: current)])
        }
        let database = CaptureFakeDatabase()
        await database.register(earlier)
        await database.register(current)
        await database.preinsertRow(row(7, device: earlier))
        let pipeline = makePipeline(database, device: current, directory: temp.url)
        await pipeline.scheduleDeviceMerge(from: earlier, into: current)

        // Not while PostgreSQL is unreachable, nor before something still writing under the earlier ID had time to
        // show itself.
        await pipeline.tick(now: base)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(1))
        await pipeline.tick(now: base.addingTimeInterval(100))
        #expect(await database.deviceMerges.isEmpty)
        #expect(await database.writes.count == 2, "the spool was replayed")

        await pipeline.tick(now: base.addingTimeInterval(201))
        let merges = await database.deviceMerges
        #expect(merges.map(\.from) == [earlier] && merges.map(\.into) == [current])
        #expect(merges.first?.idleFor == .seconds(200), "nothing may have written under it since this launch first reached PostgreSQL")
        #expect(merges.first?.writesBefore == 2, "after the spool was replayed")
        #expect(await pipeline.drainUpdate().mergedDevices == [earlier])
        #expect(await database.rows.keys.allSatisfy { $0.deviceID == current })
        #expect(await database.registeredDevices == [current])

        await pipeline.tick(now: base.addingTimeInterval(202))
        #expect(await database.deviceMerges.count == 1, "done once it succeeded")
        #expect(await pipeline.drainUpdate().mergedDevices.isEmpty)
        await pipeline.scheduleDeviceMerge(from: earlier, into: current)
        await pipeline.tick(now: base.addingTimeInterval(203))
        #expect(await database.deviceMerges.count == 1, "not scheduled again in this launch")
    }

    @Test func earlierIDsAreFoundByTheHistoryTheyShare() async {
        let temp = CaptureTempDirectory()
        let second = UUID()
        let database = CaptureFakeDatabase()
        // The earlier ID recorded this Mac's current Surge session; a second one shares the earlier ID's sessions.
        await database.setHistorySharers([earlier])
        await database.preinsertRow(row(7, device: earlier))
        let pipeline = makePipeline(database, device: current, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)
        await pipeline.tick(now: base)
        #expect(await database.historyLookups.isEmpty, "not before the delay")

        await pipeline.tick(now: base.addingTimeInterval(130))
        #expect(await database.historyLookups.map(\.device) == [current])
        #expect(await database.historyLookups.first?.sessions == [1_000])
        #expect(await database.deviceMerges.map(\.from) == [earlier])
        #expect(await pipeline.drainUpdate().mergedDevices == [earlier])

        // The merge moved rows: their history may lead further, so the next round looks again.
        await database.setHistorySharers([second])
        await pipeline.tick(now: base.addingTimeInterval(131))
        #expect(await database.historyLookups.count == 2)
        #expect(await database.deviceMerges.map(\.from) == [earlier, second])
        #expect(await pipeline.drainUpdate().mergedDevices == [second])

        // Nothing moved this time: the next look is an hour later.
        await pipeline.tick(now: base.addingTimeInterval(132))
        await pipeline.tick(now: base.addingTimeInterval(1_000))
        #expect(await database.historyLookups.count == 2)
        await pipeline.tick(now: base.addingTimeInterval(131 + 3_600))
        #expect(await database.historyLookups.count == 3)
    }

    @Test func anIDSomethingStillWritesUnderIsLeftAloneUntilTheNextLaunch() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        await database.setMergeRefusal(.stillWriting, for: earlier)
        await database.setHistorySharers([earlier])
        let pipeline = makePipeline(database, device: current, directory: temp.url)
        await pipeline.scheduleDeviceMerge(from: earlier, into: current)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base)
        await pipeline.tick(now: base.addingTimeInterval(130))
        #expect(await database.deviceMerges.map(\.from) == [earlier])
        #expect(await pipeline.drainUpdate().mergedDevices.isEmpty, "the earlier ID is not forgotten: the next launch tries again")

        // Found again by its history, or scheduled again: left alone.
        await pipeline.scheduleDeviceMerge(from: earlier, into: current)
        await pipeline.tick(now: base.addingTimeInterval(131))
        await pipeline.tick(now: base.addingTimeInterval(130 + 3_600))
        #expect(await database.historyLookups.count == 2)
        #expect(await database.deviceMerges.count == 1)
        #expect(await pipeline.isOnline)
    }

    @Test func aFailedMergeIsRetriedLaterWithoutHoldingUpTheClosesOrTakingCaptureOffline() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        await database.setFailingMerges(true)
        let pipeline = makePipeline(database, device: current, directory: temp.url)
        await pipeline.scheduleDeviceMerge(from: earlier, into: current)
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)
        await pipeline.tick(now: base)
        await pipeline.ingest(CaptureFixtures.request(id: 1, host: "example.org", processPath: "/usr/bin/curl", completed: true), now: base)
        await pipeline.tick(now: base.addingTimeInterval(130))
        #expect(await pipeline.isOnline, "a failed merge is not an outage")
        #expect(await database.deviceMerges.count == 1)
        #expect(await database.writes.count == 1, "rows keep flowing")
        #expect(await pipeline.drainUpdate().mergedDevices.isEmpty)

        // Closes go on meanwhile.
        await pipeline.beginSession(2_000)
        await pipeline.tick(now: base.addingTimeInterval(140))
        #expect(await database.closedSessions.count == 2)
        #expect(await database.deviceMerges.count == 1, "the merge waits for its own retry time")

        // Ten minutes after the first failure, twenty after the second; a reconnect does not hurry it.
        await pipeline.tick(now: base.addingTimeInterval(130 + 600))
        #expect(await database.deviceMerges.count == 2)
        await pipeline.setDatabaseOnline(false)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(130 + 600 + 1_000))
        #expect(await database.deviceMerges.count == 2)
        await database.setFailingMerges(false)
        await pipeline.tick(now: base.addingTimeInterval(130 + 600 + 1_200))
        #expect(await database.deviceMerges.count == 3)
        #expect(await pipeline.drainUpdate().mergedDevices == [earlier])
    }

    @Test func aMergeTheServerKeepsRefusingIsGivenUpUntilTheNextLaunch() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        await database.setMergeFailure(.query("refused by the test"))
        let pipeline = makePipeline(database, device: current, directory: temp.url)
        await pipeline.scheduleDeviceMerge(from: earlier, into: current)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base)
        var now = base.addingTimeInterval(130)
        for pause in [600.0, 1_200, 2_400, 4_800] {
            await pipeline.tick(now: now)
            now = now.addingTimeInterval(pause)
        }
        #expect(await database.deviceMerges.count == 3)
        #expect(await pipeline.isOnline)
        await pipeline.tick(now: now.addingTimeInterval(86_400))
        #expect(await database.deviceMerges.count == 3)
    }

    @Test func requestsTheMergeMovedAreClosedLikeThisMacsOwn() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        // The earlier run left a request of an earlier Surge session active.
        var open = row(5, device: earlier, session: 500)
        open.state = .active
        open.completedAt = nil
        await database.preinsertRow(open)
        let pipeline = makePipeline(database, device: current, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)
        await pipeline.tick(now: base)
        #expect(await database.closedSessions.count == 1, "this Mac's earlier sessions were closed before the merge ran")

        await pipeline.scheduleDeviceMerge(from: earlier, into: current)
        await pipeline.tick(now: base.addingTimeInterval(130))
        await pipeline.tick(now: base.addingTimeInterval(131))
        let moved = RequestKey(deviceID: current, session: 500, surgeID: 5)
        #expect(await database.rows[moved]?.state == .completed)
        #expect(await database.closedSessions.count == 2)
    }

    // MARK: Engine

    @MainActor
    @Test func theEngineMergesAndForgetsTheEarlierIDAndKeepsItsName() async throws {
        let temp = CaptureTempDirectory()
        let scratch = TestDefaults()
        let defaults = scratch.make()
        defaults.set(earlier.uuidString, forKey: DeviceIdentity.defaultsKey)
        let preferences = Preferences(defaults: defaults, hardwareUUID: "12345678-9ABC-DEF0-1234-56789ABCDEF0")
        let me = preferences.thisDeviceID
        #expect(preferences.legacyDeviceID == earlier)

        let database = CaptureFakeDatabase()
        let created = Date(timeIntervalSince1970: 1_750_000_000)
        await database.setDevices([Device(id: earlier, name: "Office Mac", model: nil, shortName: "Office", hue: 65,
                                          rowCount: 7, lastWriteAt: nil, createdAt: created)])
        let model = AppModel(preferences: preferences)
        model.database = database
        let engine = CaptureEngine(model: model, surge: CaptureFakeSurge(), database: database, processes: CaptureFakeProcesses(),
                                   classifier: CaptureFakeClassifier(), spool: CaptureSpool(directory: temp.url, limit: 1000))
        engine.settingsDatabaseURL = { "postgresql://tide@db-a.invalid/tidemark" }
        // Notifications never reach Notification Center from tests.
        engine.notifier.deliver = { _ in }
        model.devices.scope = .device(earlier)

        await engine.scheduleLegacyDeviceMerge()
        #expect(await engine.connectDatabase())
        // The derived ID is registered with the name, color and age the Mac had.
        let registered = try #require(await database.upsertedDevices.first { $0.id == me })
        #expect(registered.name == "Office Mac" && registered.hue == 65 && registered.createdAt == created)

        await engine.pipeline.tick(now: base)
        await engine.pipeline.tick(now: base.addingTimeInterval(130))
        #expect(await database.deviceMerges.map(\.from) == [earlier])
        engine.apply(await engine.pipeline.drainUpdate(), now: base)
        #expect(preferences.legacyDeviceID == nil)
        #expect(defaults.string(forKey: DeviceIdentity.defaultsKey) == nil, "the merge never runs again")
        #expect(model.devices.scope == .device(me), "a page scoped to the earlier ID shows this Mac")
        #expect(Preferences(defaults: defaults, hardwareUUID: "12345678-9ABC-DEF0-1234-56789ABCDEF0").legacyDeviceID == nil)
    }
}
