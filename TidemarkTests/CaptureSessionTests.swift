import Foundation
import Testing
@testable import Tidemark

/// Surge sessions (engine restarts), stream gaps, recycled request IDs and late updates.
struct CaptureSessionTests {
    let device = UUID()
    let nodePath = "/Users/me/Library/Application Support/com.raycast.macos/node/bin/node"
    let boot = Date(timeIntervalSince1970: 1_792_000_000)
    /// Later than any internal timer start, so intervals have always elapsed.
    let base = Date.now.addingTimeInterval(5)
    /// Start of the requests (seconds): two hours before `base`, so they are not "just started".
    var requestStart: Double { (base.timeIntervalSince1970 - 7_200).rounded() }

    var processes: CaptureFakeProcesses {
        CaptureFakeProcesses([
            LiveProcess(pid: 540, parentPID: 1, name: "Raycast", path: "/Applications/Raycast.app/Contents/MacOS/Raycast", startTime: boot),
            LiveProcess(pid: 1388, parentPID: 540, name: "node", path: nodePath, startTime: boot.addingTimeInterval(5)),
        ])
    }

    func makePipeline(database: CaptureFakeDatabase, directory: URL, contactGrace: TimeInterval = 0) -> CapturePipeline {
        CapturePipeline(
            settings: CaptureSettings(deviceID: device, isRemote: false, batchRows: 200, batchInterval: 1, ownExecutablePath: nil),
            database: database, surge: CaptureFakeSurge(), processes: processes, classifier: CaptureFakeClassifier(), probes: ProbeRegistry(),
            spool: CaptureSpool(directory: directory, limit: 10_000), contactGrace: contactGrace
        )
    }

    func curl(_ id: Int64, start: Double, completed: Bool = false) -> SurgeRequest {
        CaptureFixtures.request(id: id, host: "h\(id).example", processPath: "/usr/bin/curl", remoteAddress: "10.0.0.\(id % 250)",
                                completed: completed, start: start)
    }

    @Test func aNewSessionClosesThePreviousOnesActiveRequests() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)
        await pipeline.ingest(curl(7, start: requestStart), now: base)
        await pipeline.tick(now: base)
        let oldKey = RequestKey(deviceID: device, session: 1_000, surgeID: 7)
        #expect(await database.rows[oldKey]?.state == .active)

        // Surge's engine restarted a minute later; request IDs start over.
        let restart = requestStart + 60
        let newSession = Int64(restart * 1000)
        let epoch = await pipeline.beginSession(newSession, now: base.addingTimeInterval(1))
        #expect(await pipeline.currentEpoch == epoch)
        await pipeline.tick(now: base.addingTimeInterval(2))

        let closed = await database.rows[oldKey]
        #expect(closed?.state == .completed)
        #expect(closed?.completedAt == Date(timeIntervalSince1970: restart), "closed when the old engine stopped")
        let sessions = await database.closedSessions
        #expect(sessions.map(\.before) == [1_000, newSession], "older sessions' leftovers are closed in PostgreSQL too")
        #expect(sessions.allSatisfy { $0.deviceID == device })
        #expect(sessions.last?.at == Date(timeIntervalSince1970: restart))
    }

    func activeRow(_ id: Int64, session: Int64 = 1_000) -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device, session: session, surgeID: id), rowID: nil, startedAt: Date(timeIntervalSince1970: requestStart),
            setupCompletedAt: nil, completedAt: nil, method: "HTTPS", host: "h\(id).example", port: 443, url: nil, remoteIP: nil,
            remoteAddress: nil, geo: nil, policyPath: ["DIRECT"], rule: nil, state: .active, inBytes: 0, outBytes: 0, pid: nil,
            processPath: "/usr/bin/curl", bundlePath: nil, chain: [], appID: nil, localAddress: nil, interface: nil, notes: [],
            isNew: false, writtenAt: nil, probeSessionID: nil
        )
    }

    @Test func quittingLeavesOpenConnectionsActive() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)
        await pipeline.ingest(curl(1, start: requestStart), now: base)
        await pipeline.ingest(curl(2, start: requestStart, completed: true), now: base)
        await pipeline.flushAll(now: base.addingTimeInterval(1), final: true)

        let open = await database.rows[RequestKey(deviceID: device, session: 1_000, surgeID: 1)]
        #expect(open?.state == .active && open?.completedAt == nil,
                "a connection that outlives Tidemark stays active (a completed row could never become active again)")
        #expect(await database.rows[RequestKey(deviceID: device, session: 1_000, surgeID: 2)]?.state == .completed)
    }

    @Test func closingEndedSessionsNeverTakesCaptureOffline() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        await database.setFailingMaintenance(true)
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)
        await pipeline.ingest(curl(1, start: requestStart, completed: true), now: base)
        await pipeline.tick(now: base.addingTimeInterval(1))
        #expect(await pipeline.isOnline, "a slow or failed maintenance statement is not an outage")
        #expect(await database.closedSessions.count == 1)
        #expect(await database.writes.count == 1, "rows keep flowing")

        // Not retried on every round…
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(await database.closedSessions.count == 1)
        // …but after the next reconnect.
        await database.setFailingMaintenance(false)
        await pipeline.setDatabaseOnline(false)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(3))
        #expect(await database.closedSessions.count == 2)
        await pipeline.tick(now: base.addingTimeInterval(4))
        #expect(await database.closedSessions.count == 2, "done once it succeeded")
    }

    @Test func requestsThatEndedWhileTidemarkWasNotRunningAreClosedOnceOnline() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        // An earlier run left 5, 6 and 7 active: 5 ended meanwhile, 6 is still open, and 7 is open and already
        // reported again by the stream although the listing missed it.
        for id in [5, 6, 7] as [Int64] { await database.preinsertRow(activeRow(id)) }
        let pipeline = makePipeline(database: database, directory: temp.url)
        let epoch = await pipeline.beginSession(1_000)
        await pipeline.ingest(curl(7, start: requestStart), now: base)
        // PostgreSQL is not reachable yet when the stream's backfill lists the active requests.
        await pipeline.closeVanished([6], fetchedAt: base, epoch: epoch)
        await pipeline.tick(now: base.addingTimeInterval(1))
        #expect(await database.vanishedCloses.isEmpty)

        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(2))
        let close = try #require(await database.vanishedCloses.first)
        #expect(close.keeping == [6, 7], "requests this run still holds as active are kept too")
        #expect(await database.rows[activeRow(5).key]?.state == .completed)
        #expect(await database.rows[activeRow(6).key]?.state == .active)
        #expect(await database.rows[activeRow(7).key]?.state == .active)

        await pipeline.tick(now: base.addingTimeInterval(3))
        #expect(await database.vanishedCloses.count == 1, "closed once")
    }

    @Test func pendingFirstContactsAreEvaluatedBeforeASessionEnds() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        let pipeline = makePipeline(database: database, directory: temp.url, contactGrace: 30)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)
        // Waiting for GeoIP data (30 s grace) when Surge restarts.
        await pipeline.ingest(CaptureFixtures.request(id: 1, host: "api.linear.app", processPath: nodePath, pid: 1388,
                                                      remoteAddress: "104.18.32.12", policy: "DIRECT"), now: base)
        await pipeline.beginSession(2_000, now: base.addingTimeInterval(1))
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(await database.appHosts.count == 2)
        #expect(await database.alertsInserted.count == 1)
    }

    @Test func recycledRequestIDsAreHeldUntilTheSessionIsChecked() async {
        let temp = CaptureTempDirectory()
        let pipeline = makePipeline(database: CaptureFakeDatabase(), directory: temp.url)
        await pipeline.beginSession(1_000)
        await pipeline.ingest(curl(5_000, start: requestStart), now: base)
        await pipeline.ingest(curl(5_001, start: requestStart + 1), now: base)
        _ = await pipeline.drainUpdate()

        // A lower ID that started later cannot belong to this engine session.
        await pipeline.ingest(curl(3, start: requestStart + 40), now: base)
        var update = await pipeline.drainUpdate()
        #expect(update.records.isEmpty)
        #expect(update.signals.contains(.sessionCheck))

        // Same session after all: the held event is recorded.
        await pipeline.confirmSession(1_000)
        update = await pipeline.drainUpdate()
        #expect(update.records.map(\.key.surgeID) == [3])
    }

    @Test func aKnownIDWithAnotherStartTimeIsANewEnginesRequest() async {
        let temp = CaptureTempDirectory()
        let pipeline = makePipeline(database: CaptureFakeDatabase(), directory: temp.url)
        await pipeline.beginSession(1_000)
        await pipeline.ingest(curl(42, start: requestStart), now: base)
        _ = await pipeline.drainUpdate()
        await pipeline.ingest(curl(42, start: requestStart + 300), now: base)
        let update = await pipeline.drainUpdate()
        #expect(update.records.isEmpty, "never merged into the old request")
        #expect(update.signals.contains(.sessionCheck))

        // The engine found a new session: held events are dropped with the old session's state.
        await pipeline.beginSession(2_000)
        _ = await pipeline.drainUpdate()
        await pipeline.ingest(curl(42, start: requestStart + 300), now: base)
        #expect(await pipeline.drainUpdate().records.map(\.key.session) == [2_000])
    }

    @Test func longLivedConnectionsAreNotMistakenForANewSession() async {
        let temp = CaptureTempDirectory()
        let pipeline = makePipeline(database: CaptureFakeDatabase(), directory: temp.url)
        await pipeline.beginSession(1_000)
        await pipeline.ingest(curl(90_000, start: base.timeIntervalSince1970 - 10), now: base)
        // A WebSocket opened two hours earlier reports in after a reconnect.
        await pipeline.ingest(curl(12, start: requestStart), now: base)
        let update = await pipeline.drainUpdate()
        #expect(Set(update.records.map(\.key.surgeID)) == [90_000, 12])
        #expect(!update.signals.contains(.sessionCheck))
    }

    @Test func requestsThatEndedWhileTheStreamWasAwayAreClosed() async {
        let temp = CaptureTempDirectory()
        let pipeline = makePipeline(database: CaptureFakeDatabase(), directory: temp.url)
        let epoch = await pipeline.beginSession(1_000)
        await pipeline.ingest(curl(1, start: requestStart), now: base)
        await pipeline.ingest(curl(2, start: requestStart), now: base)
        _ = await pipeline.drainUpdate()

        await pipeline.reconcileActive([2], fetchedAt: base.addingTimeInterval(30), epoch: epoch, now: base.addingTimeInterval(31))
        let records = await pipeline.drainUpdate().records
        let ended = records.first { $0.key.surgeID == 1 }
        #expect(ended?.state == .completed)
        #expect(ended?.completedAt == base, "closed when last seen")
        #expect(records.allSatisfy { $0.key.surgeID != 2 }, "still active in Surge")

        // A reconcile from an earlier stream is ignored.
        await pipeline.ingest(curl(3, start: requestStart), now: base.addingTimeInterval(40))
        _ = await pipeline.drainUpdate()
        await pipeline.reconcileActive([], fetchedAt: base.addingTimeInterval(60), epoch: epoch - 1)
        #expect(await pipeline.drainUpdate().records.isEmpty)
    }

    @Test func aLateDumpRecentDoesNotReopenAFinishedRequest() async {
        let temp = CaptureTempDirectory()
        let pipeline = makePipeline(database: CaptureFakeDatabase(), directory: temp.url)
        await pipeline.beginSession(1_000)
        var finished = curl(9, start: requestStart, completed: true)
        finished.notes = ["a", "b", "c"]
        await pipeline.ingest(finished, now: base)
        _ = await pipeline.drainUpdate()

        var stale = curl(9, start: requestStart, completed: false)
        stale.notes = ["a"]
        await pipeline.ingestBackfill([stale], now: base.addingTimeInterval(1))
        let record = await pipeline.drainUpdate().records.first
        #expect(record == nil || (record?.state == .completed && record?.notes.count == 3))
    }

    @Test func aLateIPDoesNotAddASecondAlert() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)

        // Proxied: no IP yet; first contact is evaluated with the domain alone.
        var request = CaptureFixtures.request(id: 1, host: "api.notion.com", processPath: nodePath, pid: 1388, remoteAddress: "23.254.139.175 (Proxy)")
        await pipeline.ingest(request, now: base)
        // The IP arrives later.
        request.remoteAddress = "104.18.22.110"
        await pipeline.ingest(request, now: base.addingTimeInterval(5))
        await pipeline.tick(now: base.addingTimeInterval(7))

        #expect(Set(await database.appHosts.values.map(\.value)) == ["api.notion.com", "104.18.22.110"])
        #expect(await database.alertsInserted.map(\.value) == ["api.notion.com"], "one alert per request")
    }
}
