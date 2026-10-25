import Foundation
import Testing
@testable import Tidemark

/// Write failures, deleted apps, Tidemark's own requests, global inventory sources and the files kept
/// beside the spool.
@Suite(.timeLimit(.minutes(1)))
struct CaptureResilienceTests {
    let device = UUID()
    let ownExecutable = "/Applications/Tidemark.app/Contents/MacOS/Tidemark"
    let nodePath = "/Users/me/Library/Application Support/com.raycast.macos/node/bin/node"
    let boot = Date(timeIntervalSince1970: 1_792_000_000)
    /// Later than any internal timer start, so intervals have always elapsed.
    let base = Date.now.addingTimeInterval(5)

    /// Raycast (540) → node (1388); Claude (700) → zsh (701) → Tidemark (702).
    var processes: CaptureFakeProcesses {
        CaptureFakeProcesses([
            LiveProcess(pid: 540, parentPID: 1, name: "Raycast", path: "/Applications/Raycast.app/Contents/MacOS/Raycast", startTime: boot),
            LiveProcess(pid: 1388, parentPID: 540, name: "node", path: nodePath, startTime: boot.addingTimeInterval(5)),
            LiveProcess(pid: 700, parentPID: 1, name: "Claude", path: "/Applications/Claude.app/Contents/MacOS/Claude", startTime: boot),
            LiveProcess(pid: 701, parentPID: 700, name: "zsh", path: "/bin/zsh", startTime: boot.addingTimeInterval(1)),
            LiveProcess(pid: 702, parentPID: 701, name: "Tidemark", path: ownExecutable, startTime: boot.addingTimeInterval(2)),
        ])
    }

    func makePipeline(database: CaptureFakeDatabase, surge: CaptureFakeSurge = CaptureFakeSurge(), directory: URL,
                      probes: ProbeRegistry = ProbeRegistry(), contactGrace: TimeInterval = 0,
                      writeTimeout: Duration = .seconds(20)) -> CapturePipeline {
        CapturePipeline(
            settings: CaptureSettings(deviceID: device, isRemote: false, batchRows: 200, batchInterval: 1, ownExecutablePath: ownExecutable),
            database: database, surge: surge, processes: processes, classifier: CaptureFakeClassifier(), probes: probes,
            spool: CaptureSpool(directory: directory, limit: 10_000), contactGrace: contactGrace, writeTimeout: writeTimeout
        )
    }

    func nodeRequest(id: Int64, host: String, remoteAddress: String? = "104.18.32.12", completed: Bool = true) -> SurgeRequest {
        CaptureFixtures.request(id: id, host: host, processPath: nodePath, pid: 1388, remoteAddress: remoteAddress, policy: "DIRECT",
                                completed: completed)
    }

    func row(_ id: Int64, host: String = "spooled.example", session: Int64 = 1) -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device, session: session, surgeID: id), rowID: nil, startedAt: boot, setupCompletedAt: nil,
            completedAt: boot, method: "HTTPS", host: host, port: 443, url: nil, remoteIP: "203.0.113.\(id % 250)", remoteAddress: nil,
            geo: nil, policyPath: ["DIRECT"], rule: nil, state: .completed, inBytes: 1, outBytes: 1, pid: nil, processPath: "/usr/bin/curl",
            bundlePath: nil, chain: [], appID: nil, localAddress: nil, interface: nil, notes: [], isNew: false, writtenAt: nil, probeSessionID: nil
        )
    }

    func eventually(_ timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return await condition()
    }

    // MARK: Deleted apps and refused writes

    @Test func deletingAnAppUnlinksEverythingQueuedForIt() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        await database.setApps([raycast])
        await database.setEnforcesForeignKeys(true)
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)

        await pipeline.ingest(nodeRequest(id: 1, host: "api.linear.app"), now: base)
        // The app is deleted before the batch goes out: rows, chains and sources still carry its ID.
        await database.setApps([])
        await pipeline.setApps([], paused: [])
        await pipeline.purgeApp(raycast.id)
        await pipeline.tick(now: base.addingTimeInterval(2))

        #expect(await pipeline.isOnline)
        #expect(await pipeline.drainUpdate().databaseFailure == nil)
        let key = RequestKey(deviceID: device, session: 1_000, surgeID: 1)
        #expect(await database.rows[key] != nil)
        #expect(await database.rows[key]?.appID == nil)
        #expect(await database.appHosts.isEmpty)
        #expect(await database.alertsInserted.isEmpty)
        #expect(await database.chains.allSatisfy { $0.appID == nil })
    }

    @Test func writesNamingAnAppDeletedOnAnotherMacAreKeptWithoutIt() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        // Another Mac deleted the app; this Mac's catalog is stale.
        await database.setApps([])
        await database.setEnforcesForeignKeys(true)
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)

        await pipeline.ingest(nodeRequest(id: 1, host: "api.linear.app"), now: base)
        await pipeline.tick(now: base.addingTimeInterval(2))

        #expect(await pipeline.isOnline, "refused statements must not take the pipeline offline")
        let key = RequestKey(deviceID: device, session: 1_000, surgeID: 1)
        #expect(await database.rows[key]?.appID == nil, "the row is written without the deleted app")
        let chains = await database.chains
        #expect(chains.count == 1 && chains.first?.appID == nil)
        let sources = await database.sources
        #expect(!sources.isEmpty && sources.allSatisfy { $0.appID == nil })
        #expect(await database.appHosts.isEmpty)
        #expect(await database.alertsInserted.isEmpty)
        // Nothing poisoned is left behind.
        await pipeline.ingest(nodeRequest(id: 2, host: "example.org"), now: base.addingTimeInterval(3))
        await pipeline.tick(now: base.addingTimeInterval(5))
        #expect(await database.rows[RequestKey(deviceID: device, session: 1_000, surgeID: 2)] != nil)
        #expect(await pipeline.isOnline)
    }

    @Test func refusedRowsAreSetAsideAndTheRestIsWritten() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        await database.setRefusedHosts(["bad.example"])
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.beginSession(1_000)
        for (id, host) in [(Int64(1), "good.example"), (2, "bad.example"), (3, "fine.example")] {
            await pipeline.ingest(CaptureFixtures.request(id: id, host: host, processPath: "/usr/bin/curl", remoteAddress: "10.0.0.\(id)", completed: true), now: base)
        }
        await pipeline.tick(now: base.addingTimeInterval(2))

        #expect(await pipeline.isOnline)
        #expect(Set(await database.rows.keys.map(\.surgeID)) == [1, 3])
        let rejected = try String(contentsOf: temp.url.appending(path: "rejected.jsonl"), encoding: .utf8)
        #expect(rejected.split(separator: "\n").count == 1 && rejected.contains("bad.example"))
        #expect(await pipeline.bufferedRows == 0)
    }

    @Test func aServerRefusingEverythingKeepsTheSpool() async throws {
        let temp = CaptureTempDirectory()
        do {
            var spool = CaptureSpool(directory: temp.url, limit: 10_000)
            try spool.append([row(1), row(2), row(3)])
        }
        let database = CaptureFakeDatabase()
        await database.setRefusingEverything(true)
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base)

        #expect(await pipeline.isOnline == false, "a server that refuses every row is treated as unavailable")
        #expect(await pipeline.bufferedRows == 3, "nothing is dropped")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appending(path: "rejected.jsonl").path(percentEncoded: false)))

        await database.setRefusingEverything(false)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(1))
        #expect(await database.writes.map(\.key.surgeID) == [1, 2, 3])
        #expect(await pipeline.bufferedRows == 0)
    }

    /// A statement the server cancelled at its timeout says nothing about the rows: they wait, never set aside.
    @Test func aTimedOutWriteKeepsItsRows() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        await database.setTimingOutRequests(true)
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        for id in 1...3 {
            await pipeline.ingest(CaptureFixtures.request(id: Int64(id), host: "h\(id).com", processPath: "/usr/bin/curl", completed: true), now: base)
        }
        await pipeline.tick(now: base.addingTimeInterval(2))

        #expect(await pipeline.isOnline == false)
        #expect(await database.requestWriteCalls == 1, "no row-by-row retry: the server, not the data, is the problem")
        #expect(!FileManager.default.fileExists(atPath: temp.url.appending(path: "rejected.jsonl").path(percentEncoded: false)))
        let update = await pipeline.drainUpdate()
        #expect(update.bufferedRows == 3)
        guard case .timedOut? = update.databaseError as? DatabaseError else {
            Issue.record("expected the timeout, got \(String(describing: update.databaseError))")
            return
        }

        await database.setTimingOutRequests(false)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(3))
        #expect(Set(await database.writes.map(\.key.surgeID)) == [1, 2, 3])
        #expect(await pipeline.bufferedRows == 0)
    }

    @Test func aStuckWriteFallsBackToTheSpool() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        await database.setStallingRequests(true)
        let pipeline = makePipeline(database: database, directory: temp.url, writeTimeout: .milliseconds(300))
        await pipeline.setDatabaseOnline(true)
        for id in 1...2 {
            await pipeline.ingest(CaptureFixtures.request(id: Int64(id), host: "h\(id).com", processPath: "/usr/bin/curl", completed: true), now: base)
        }
        let clock = ContinuousClock()
        let started = clock.now
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(started.duration(to: clock.now) < .seconds(3), "the write gives up on time")
        #expect(await pipeline.isOnline == false)
        let update = await pipeline.drainUpdate()
        #expect(update.databaseFailure != nil)
        #expect(update.bufferedRows == 2)
    }

    @Test func quittingDuringAStuckFlushSpoolsItsRows() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        await database.setStallingRequests(true)
        let pipeline = makePipeline(database: database, directory: temp.url, writeTimeout: .seconds(3))
        await pipeline.setDatabaseOnline(true)
        for id in 1...2 {
            await pipeline.ingest(CaptureFixtures.request(id: Int64(id), host: "h\(id).com", processPath: "/usr/bin/curl", completed: true), now: base)
        }
        let stuck = Task { await pipeline.tick(now: base.addingTimeInterval(2)) }
        #expect(await eventually { await pipeline.isFlushing })
        await pipeline.flushAll(now: base.addingTimeInterval(3), final: true)
        var spool = CaptureSpool(directory: temp.url, limit: 10_000)
        #expect(spool.count >= 2, "the stuck batch is on disk before Tidemark quits")
        // Let the abandoned write time out before the directory goes away.
        #expect(await CaptureWait.finishes { await stuck.value }, "the abandoned write gives up at its timeout")
    }

    @Test func quittingDuringAStuckFlushKeepsItsFirstContactWork() async throws {
        let temp = CaptureTempDirectory()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        do {
            let database = CaptureFakeDatabase()
            await database.setKnown([raycast.id: ["backend.raycast.com"]])
            await database.setStallingRequests(true)
            let pipeline = makePipeline(database: database, directory: temp.url, writeTimeout: .seconds(2))
            await pipeline.setApps([raycast], paused: [])
            try await pipeline.loadKnownHosts()
            await pipeline.setDatabaseOnline(true)
            await pipeline.beginSession(1_000)
            await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com"), now: base)
            let stuck = Task { await pipeline.tick(now: base.addingTimeInterval(2)) }
            #expect(await eventually { await pipeline.isFlushing })
            await pipeline.flushAll(now: base.addingTimeInterval(3), final: true)
            // Let the abandoned write time out before the directory goes away.
            #expect(await CaptureWait.finishes { await stuck.value }, "the abandoned write gives up at its timeout")
        }

        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(4))
        await pipeline.tick(now: base.addingTimeInterval(6))
        #expect(await database.writes.map(\.key.surgeID).contains(1), "the stuck batch's row was spooled")
        #expect(Set(await database.appHosts.values.map(\.value)) == ["api.notion.com", "104.18.32.12"], "and its first contact kept")
        #expect(await database.alertsInserted.map(\.value) == ["api.notion.com"])
    }

    @Test func aRefusedRowIsFoundWithoutRewritingEveryRowAlone() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        await database.setRefusedHosts(["h37.example"])
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        for id in 1...64 {
            await pipeline.ingest(CaptureFixtures.request(id: Int64(id), host: "h\(id).example", processPath: "/usr/bin/curl",
                                                          remoteAddress: "10.0.1.\(id)", completed: true), now: base)
        }
        await pipeline.tick(now: base.addingTimeInterval(1))
        #expect(await pipeline.isOnline)
        #expect(await database.rows.count == 63)
        #expect(await database.requestWriteCalls < 20, "the refused batch is split in halves, not written row by row")
        let rejected = (try? String(contentsOf: temp.url.appending(path: "rejected.jsonl"), encoding: .utf8)) ?? ""
        #expect(rejected.split(separator: "\n").count == 1 && rejected.contains("h37.example"))
    }

    @Test func workQueuedBeforeADeviceSwitchKeepsItsDevice() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.beginSession(1_000)
        await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com"), now: base)

        // Switched to a remote Surge before the queue was written.
        let gateway = UUID()
        await pipeline.update(settings: CaptureSettings(deviceID: gateway, isRemote: true, batchRows: 200, batchInterval: 1,
                                                        ownExecutablePath: ownExecutable), now: base.addingTimeInterval(1))
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(await database.chains.map(\.deviceID) == [device])
        #expect(await database.alertsInserted.map(\.deviceID) == [device])
        #expect(await database.writes.allSatisfy { $0.key.deviceID == device })
    }

    @Test func alertsLinkTheirRequestWhileTheSpoolDrains() async throws {
        let temp = CaptureTempDirectory()
        do {
            var spool = CaptureSpool(directory: temp.url, limit: 10_000)
            try spool.append([row(900, session: 1)])
        }
        let database = CaptureFakeDatabase()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.beginSession(1_000)
        await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com"), now: base)
        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(2))

        let alert = try #require(await database.alertsInserted.first)
        let key = RequestKey(deviceID: device, session: 1_000, surgeID: 1)
        #expect(alert.requestRowID != nil)
        #expect(alert.requestRowID == (await database.rowIDs[key]))
        #expect(await pipeline.bufferedRows == 0, "the spooled row was replayed too")
    }

    // MARK: Counters

    @Test func onlyInsertedRowsCountAsWritten() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.beginSession(1_000)
        await pipeline.setDatabaseOnline(true)
        // A previous run already stored request 1.
        await database.preinsertRow(row(1, session: 1_000))
        await pipeline.ingestBackfill([
            CaptureFixtures.request(id: 1, host: "a.example", processPath: "/usr/bin/curl", completed: true),
            CaptureFixtures.request(id: 2, host: "b.example", processPath: "/usr/bin/curl", completed: true),
        ], now: base)
        await pipeline.tick(now: base.addingTimeInterval(2))
        let update = await pipeline.drainUpdate()
        #expect(update.rowsWritten == 1)
        #expect(await database.sources.isEmpty, "backfilled requests add no global inventory counts")
    }

    @Test func bufferedRowsCountOnlyTheOfflineBacklog() async {
        let temp = CaptureTempDirectory()
        let pipeline = makePipeline(database: CaptureFakeDatabase(), directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        for id in 1...2 {
            await pipeline.ingest(CaptureFixtures.request(id: Int64(id), host: "h\(id).com", processPath: "/usr/bin/curl"), now: base)
        }
        #expect(await pipeline.drainUpdate().bufferedRows == 0, "the next batch is not a backlog")
        await pipeline.setDatabaseOnline(false)
        #expect(await pipeline.drainUpdate().bufferedRows == 2)
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(await pipeline.drainUpdate().bufferedRows == 2, "spooled")
    }

    // MARK: Attribution

    @Test func ownRequestsNeverRollUpToAMonitoredApp() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let probes = ProbeRegistry()
        let session = UUID()
        probes.begin(sessionID: session, startedAt: base)
        probes.connectionOpened(host: "github.com", at: base)
        probes.registerUpstream(port: 50_001, host: "github.com")
        let claude = CaptureFixtures.app("Claude", path: "/Applications/Claude.app")
        let pipeline = makePipeline(database: database, directory: temp.url, probes: probes)
        await pipeline.setApps([claude], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)

        // Tidemark runs from a shell inside Claude's process tree.
        let probe = CaptureFixtures.request(id: 1, host: "github.com", processPath: ownExecutable, pid: 702, remoteAddress: "20.205.243.166", sourcePort: 50_001)
        let lookup = CaptureFixtures.request(id: 2, host: "ipinfo.example", processPath: ownExecutable, pid: 702, remoteAddress: "34.117.59.81", completed: true)
        let shell = CaptureFixtures.request(id: 3, host: "api.anthropic.com", processPath: "/bin/zsh", pid: 701, remoteAddress: "160.79.104.10", completed: true)
        for request in [probe, lookup, shell] { await pipeline.ingest(request, now: base) }

        let records = await pipeline.drainUpdate().records
        let own = records.filter { $0.key.surgeID != 3 }
        #expect(own.count == 2)
        #expect(own.allSatisfy { $0.appID == nil && $0.bundlePath == "/Applications/Tidemark.app" })
        #expect(own.first { $0.key.surgeID == 1 }?.probeSessionID == session, "probe rows keep their session")
        #expect(own.first { $0.key.surgeID == 2 }?.chain.map(\.name) == ["Claude", "zsh", "Tidemark"])
        #expect(records.first { $0.key.surgeID == 3 }?.appID == claude.id, "the shell itself still rolls up")

        await pipeline.tick(now: base.addingTimeInterval(2))
        let hosts = await database.appHosts.values.map(\.value)
        #expect(Set(hosts) == ["api.anthropic.com", "160.79.104.10"], "only Claude's own request is a first contact")
        #expect(await database.alertsInserted.map(\.value) == ["api.anthropic.com"])
        #expect(await database.appHosts.values.allSatisfy { $0.firstDeviceID == device })
    }

    @Test func aRestoredAppDetectsFirstContactRightAway() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        var raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        raycast.archivedAt = boot
        await database.setKnown([raycast.id: ["backend.raycast.com"]])
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setApps([raycast], paused: [])
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)

        raycast.archivedAt = nil
        await pipeline.setApps([raycast], paused: [])
        await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com"), now: base)
        await pipeline.tick(now: base.addingTimeInterval(2))
        #expect(await database.appHosts.count == 2)
        #expect(await database.alertsInserted.count == 1)
        #expect(await database.knownHostsCalls == 1, "no reload is needed")
    }

    @Test func aNewAppWaitsForItsInventory() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, directory: temp.url)
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)

        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        // The backfill rebuilds its inventory from history.
        await database.setKnown([raycast.id: ["api.notion.com", "ip:104.18.32.12"]])
        await pipeline.awaitInventory(for: raycast.id, now: base)
        await pipeline.setApps([raycast], paused: [])
        await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com"), now: base)
        await pipeline.tick(now: base.addingTimeInterval(1))
        #expect(await database.touches.isEmpty, "waiting for the inventory")
        #expect(await database.appHosts.isEmpty)

        try await pipeline.loadKnownHosts()
        await pipeline.tick(now: base.addingTimeInterval(3))
        #expect(await database.appHosts.isEmpty, "its history is known, nothing is new")
        #expect(await database.alertsInserted.isEmpty)
        #expect(await database.touches.count == 2)
    }

    @Test func theInventoryWaitEnds() async throws {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, directory: temp.url)
        try await pipeline.loadKnownHosts()
        await pipeline.setDatabaseOnline(true)
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        await pipeline.awaitInventory(for: raycast.id, now: base)
        await pipeline.setApps([raycast], paused: [])
        await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com", completed: false), now: base)
        await pipeline.tick(now: base.addingTimeInterval(1))
        #expect(await database.appHosts.isEmpty)
        await pipeline.tick(now: base.addingTimeInterval(121))
        #expect(await database.appHosts.count == 2, "first contacts are evaluated once the wait expired")
    }

    // MARK: Global inventory sources

    @Test func sourcesWaitForTheProcessPath() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        var request = CaptureFixtures.request(id: 1, host: "apple-relay.example", processPath: nil, remoteAddress: "162.159.196.66")
        await pipeline.ingest(request, now: base)
        await pipeline.tick(now: base.addingTimeInterval(1))
        #expect(await database.sources.isEmpty)

        request.processPath = "/System/Library/PrivateFrameworks/SafariSafeBrowsing.framework/com.apple.Safari.SafeBrowsing.Service"
        await pipeline.ingest(request, now: base.addingTimeInterval(2))
        await pipeline.tick(now: base.addingTimeInterval(4))
        let sources = await database.sources
        #expect(sources.count == 2)
        #expect(sources.allSatisfy { $0.sourcePath == request.processPath && $0.sourceTitle == "com.apple.Safari.SafeBrowsing.Service" })
    }

    @Test func sourcesWithoutAProcessAreRecordedWhenTheRequestEnds() async {
        let temp = CaptureTempDirectory()
        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, directory: temp.url)
        await pipeline.setDatabaseOnline(true)
        var request = CaptureFixtures.request(id: 1, host: "printer.example", processPath: nil, remoteAddress: "192.168.1.20", completed: true)
        request.deviceName = "iPhone"
        await pipeline.ingest(request, now: base)
        await pipeline.tick(now: base.addingTimeInterval(1))
        let sources = await database.sources
        #expect(sources.count == 2)
        #expect(sources.allSatisfy { $0.sourcePath.isEmpty && $0.sourceTitle == "iPhone" }, "no made-up `unknown` process")
    }

    // MARK: Files beside the spool

    @Test func quittingOfflineKeepsFirstContactWorkForTheNextLaunch() async throws {
        let temp = CaptureTempDirectory()
        let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
        do {
            let database = CaptureFakeDatabase()
            await database.setKnown([raycast.id: ["backend.raycast.com"]])
            let pipeline = makePipeline(database: database, directory: temp.url)
            await pipeline.setApps([raycast], paused: [])
            try await pipeline.loadKnownHosts()
            await pipeline.setMutes(["*.muted.example"])
            await pipeline.beginSession(1_000)
            // PostgreSQL went away; Tidemark quits before it comes back.
            await pipeline.ingest(nodeRequest(id: 1, host: "api.notion.com"), now: base)
            await pipeline.flushAll(now: base.addingTimeInterval(1), final: true)
        }

        let database = CaptureFakeDatabase()
        let pipeline = makePipeline(database: database, directory: temp.url)
        let snapshot = try #require(await pipeline.restoreSnapshot(), "the shared state is kept for an offline launch")
        #expect(snapshot.apps.map(\.id) == [raycast.id])
        #expect(snapshot.mutes == ["*.muted.example"])
        #expect(snapshot.known[raycast.id]?.contains("domain:api.notion.com") == true)

        await pipeline.setDatabaseOnline(true)
        await pipeline.tick(now: base.addingTimeInterval(2))
        await pipeline.tick(now: base.addingTimeInterval(4))
        #expect(await database.writes.map(\.key.surgeID) == [1], "the spooled row")
        #expect(await database.appHosts.count == 2, "and its first contact")
        #expect(await database.alertsInserted.map(\.value) == ["api.notion.com"])
    }
}
