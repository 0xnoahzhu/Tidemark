import Foundation
import PostgresNIO
import Testing
@testable import Tidemark

/// The capture pipeline against the PostgreSQL server in `TIDEMARK_TEST_DATABASE_URL` (skipped when unset):
/// how real constraint violations are handled. Every test uses a fresh `tm_test_<8 hex>` schema and drops it.
@Suite(.serialized, .enabled(if: captureLiveDatabaseURL != nil, "Set TIDEMARK_TEST_DATABASE_URL to run"))
struct CaptureLiveTests {
    let nodePath = "/Users/me/Library/Application Support/com.raycast.macos/node/bin/node"
    let boot = Date(timeIntervalSince1970: 1_792_000_000)
    let base = Date.now.addingTimeInterval(5)

    var processes: CaptureFakeProcesses {
        CaptureFakeProcesses([
            LiveProcess(pid: 540, parentPID: 1, name: "Raycast", path: "/Applications/Raycast.app/Contents/MacOS/Raycast", startTime: boot),
            LiveProcess(pid: 1388, parentPID: 540, name: "node", path: nodePath, startTime: boot.addingTimeInterval(5)),
        ])
    }

    func makePipeline(_ db: CaptureLivePostgres, device: DeviceID, directory: URL) -> CapturePipeline {
        CapturePipeline(
            settings: CaptureSettings(deviceID: device, isRemote: false, batchRows: 200, batchInterval: 1, ownExecutablePath: nil),
            database: db, surge: CaptureFakeSurge(), processes: processes, classifier: CaptureFakeClassifier(), probes: ProbeRegistry(),
            spool: CaptureSpool(directory: directory, limit: 10_000), contactGrace: 0
        )
    }

    func device() -> Device {
        Device(id: UUID(), name: "Capture Test Mac", model: nil, shortName: "CTM", hue: 240, isRemoteSurge: false, rowCount: 0,
               lastWriteAt: nil, createdAt: .now)
    }

    @Test func anAppDeletedOnAnotherMacDoesNotBlockWrites() async throws {
        try await withTestDatabase { db in
            let temp = CaptureTempDirectory()
            let mac = device()
            try await db.upsertDevice(mac)
            let raycast = CaptureFixtures.app("Raycast", path: "/Applications/Raycast.app")
            try await db.insertApp(raycast)
            let pipeline = makePipeline(db, device: mac.id, directory: temp.url)
            await pipeline.setApps([raycast], paused: [])
            try await pipeline.loadKnownHosts()
            await pipeline.setDatabaseOnline(true)
            await pipeline.beginSession(1_000)

            // Another Mac deletes the app while this Mac still attributes requests to it.
            await pipeline.ingest(CaptureFixtures.request(id: 1, host: "api.linear.app", processPath: nodePath, pid: 1388,
                                                          remoteAddress: "104.18.32.12", policy: "DIRECT", completed: true), now: base)
            try await db.deleteApp(raycast.id)
            await pipeline.tick(now: base.addingTimeInterval(2))

            #expect(await pipeline.isOnline, "foreign-key violations are about the rows, not the server")
            #expect(await pipeline.drainUpdate().databaseFailure == nil)
            let rows = try await db.rows("SELECT app_id, host FROM requests")
            #expect(rows.count == 1)
            let appID = try rows.first.map { try PostgresRowReader($0)("app_id", as: UUID?.self) }
            #expect(appID == .some(nil), "written without the deleted app")
            let processes = try await db.rows("SELECT count(*) AS n FROM processes").first.map { try PostgresRowReader($0)("n", as: Int.self) }
            #expect(processes == 2)
            let sources = try await db.rows("SELECT count(*) AS n FROM host_sources").first.map { try PostgresRowReader($0)("n", as: Int.self) }
            #expect(sources == 2)
            #expect(try await db.knownHosts().isEmpty)

            // Later writes go through normally.
            await pipeline.setApps([], paused: [])
            await pipeline.ingest(CaptureFixtures.request(id: 2, host: "example.org", processPath: "/usr/bin/curl", remoteAddress: "93.184.215.14",
                                                          completed: true), now: base.addingTimeInterval(3))
            await pipeline.tick(now: base.addingTimeInterval(5))
            let total = try await db.rows("SELECT count(*) AS n FROM requests").first.map { try PostgresRowReader($0)("n", as: Int.self) }
            #expect(total == 2)
        }
    }

    @Test func aRowTheServerRefusesIsSetAside() async throws {
        try await withTestDatabase { db in
            let temp = CaptureTempDirectory()
            let mac = device()
            try await db.upsertDevice(mac)
            let pipeline = makePipeline(db, device: mac.id, directory: temp.url)
            await pipeline.setDatabaseOnline(true)
            await pipeline.beginSession(1_000)
            // PostgreSQL text cannot hold NUL characters.
            for (id, host) in [(Int64(1), "good.example"), (2, "bad\u{0}.example"), (3, "fine.example")] {
                await pipeline.ingest(CaptureFixtures.request(id: id, host: host, processPath: "/usr/bin/curl", remoteAddress: "10.0.0.\(id)",
                                                              completed: true), now: base)
            }
            await pipeline.tick(now: base.addingTimeInterval(2))

            #expect(await pipeline.isOnline)
            let hosts = try await db.rows("SELECT host FROM requests ORDER BY surge_id").map { try PostgresRowReader($0)("host", as: String.self) }
            #expect(hosts == ["good.example", "fine.example"])
            let rejected = try String(contentsOf: temp.url.appending(path: "rejected.jsonl"), encoding: .utf8)
            #expect(rejected.split(separator: "\n").count == 1)
        }
    }

    @Test func connectionsOpenAtQuitStayActiveUntilTheNextLaunchClosesTheOnesThatEnded() async throws {
        try await withTestDatabase { db in
            let temp = CaptureTempDirectory()
            let mac = device()
            try await db.upsertDevice(mac)
            let session: Int64 = 1_792_000_000_000
            func open(_ id: Int64) -> SurgeRequest {
                CaptureFixtures.request(id: id, host: "h\(id).example", processPath: "/usr/bin/curl", remoteAddress: "93.184.215.\(id)",
                                        start: base.timeIntervalSince1970 - 600)
            }
            func states() async throws -> [Int64: (state: String, completed: Bool)] {
                var result: [Int64: (state: String, completed: Bool)] = [:]
                for row in try await db.rows("SELECT surge_id, state, completed_at FROM requests") {
                    let read = PostgresRowReader(row)
                    result[try read("surge_id", as: Int64.self)] = (try read("state", as: String.self), try read("completed_at", as: Date?.self) != nil)
                }
                return result
            }

            do {
                let pipeline = makePipeline(db, device: mac.id, directory: temp.url)
                await pipeline.setDatabaseOnline(true)
                await pipeline.beginSession(session)
                await pipeline.ingest(open(1), now: base)
                await pipeline.ingest(open(2), now: base)
                await pipeline.flushAll(now: base.addingTimeInterval(1), final: true)
            }
            var rows = try await states()
            #expect(rows[1]?.state == "active" && rows[1]?.completed == false, "quitting does not end a connection")
            #expect(rows[2]?.state == "active" && rows[2]?.completed == false)

            // Relaunched within the same Surge session: 1 is still open, 2 ended while Tidemark was not running.
            let relaunched = makePipeline(db, device: mac.id, directory: temp.url)
            await relaunched.setDatabaseOnline(true)
            let epoch = await relaunched.beginSession(session)
            await relaunched.ingestBackfill([open(1)], epoch: epoch, now: base.addingTimeInterval(60))
            await relaunched.closeVanished([open(1)], fetchedAt: base.addingTimeInterval(60), epoch: epoch)
            await relaunched.tick(now: base.addingTimeInterval(62))
            rows = try await states()
            #expect(rows[1]?.state == "active" && rows[1]?.completed == false, "still open: still active")
            #expect(rows[2]?.state == "completed" && rows[2]?.completed == true, "ended meanwhile: closed")
        }
    }

    @Test func otherMacsRowsAreReadPageByPageInWriteOrder() async throws {
        try await withTestDatabase { db in
            let mac = device()
            let mini = device()
            try await db.upsertDevice(mac)
            try await db.upsertDevice(mini)
            func row(_ device: DeviceID, _ id: Int64) -> RequestRecord {
                RequestRecord(
                    key: RequestKey(deviceID: device, session: 1_000, surgeID: id), rowID: nil, startedAt: base.addingTimeInterval(-60),
                    setupCompletedAt: nil, completedAt: nil, method: "HTTPS", host: "h\(id).example", port: 443, url: nil, remoteIP: nil,
                    remoteAddress: nil, geo: nil, policyPath: ["DIRECT"], rule: nil, state: .active, inBytes: 0, outBytes: 0, pid: nil,
                    processPath: nil, bundlePath: nil, chain: [], appID: nil, localAddress: nil, interface: nil, notes: [], isNew: false,
                    writtenAt: nil, probeSessionID: nil
                )
            }
            /// The other Mac's rows in the server's write order.
            func written() async throws -> [RequestKey] {
                try await db.rows("SELECT surge_id FROM requests WHERE device_id = \(mini.id) ORDER BY updated_at, id").map {
                    RequestKey(deviceID: mini.id, session: 1_000, surgeID: try PostgresRowReader($0)("surge_id", as: Int64.self))
                }
            }

            // The other Mac writes a burst of more than four pages in three transactions, beside this Mac's own rows.
            for batch in 0..<3 {
                try await db.upsertRequests((0..<35).map { row(mini.id, Int64(batch * 35 + $0)) } + [row(mac.id, Int64(batch))])
            }
            var rows = CaptureOtherMacRows()
            rows.pageSize = 25
            let poll = try await rows.poll(db, excluding: mac.id)
            let burst = try await written()
            #expect(!poll.capped)
            #expect(poll.rows.map(\.key) == burst, "every row once, in write order, none of this Mac's")
            let positions = poll.rows.compactMap(RequestWriteCursor.init)
            #expect(positions.count == 105 && zip(positions, positions.dropFirst()).allSatisfy { $0 < $1 })

            // Rows written again move to the end of the order and are read again; nothing else is.
            try await Task.sleep(for: .milliseconds(20))
            var finished = [row(mini.id, 7), row(mini.id, 70)]
            for index in finished.indices { finished[index].state = .completed }
            try await db.upsertRequests(finished)
            let next = try await rows.poll(db, excluding: mac.id)
            #expect(Set(next.rows.map(\.key)) == Set(finished.map(\.key)))
            #expect(next.rows.allSatisfy { $0.state == .completed })
            #expect(try await rows.poll(db, excluding: mac.id).rows.isEmpty)

            // A poller that reads at most two pages per poll gets there over three polls, in the same order.
            var slow = CaptureOtherMacRows()
            slow.pageSize = 25
            slow.maxPages = 2
            var read: [RequestKey] = []
            var capped: [Bool] = []
            for _ in 0..<3 {
                let poll = try await slow.poll(db, excluding: mac.id)
                read += poll.rows.map(\.key)
                capped.append(poll.capped)
            }
            let order = try await written()
            #expect(capped == [true, true, false])
            #expect(read == order)
        }
    }

    // MARK: Harness

    private func withTestDatabase(_ body: (CaptureLivePostgres) async throws -> Void) async throws {
        let url = try #require(captureLiveDatabaseURL)
        let schema = "tm_test_" + String(format: "%08x", UInt32.random(in: .min ... .max))
        let db = CaptureLivePostgres(url: url, schema: schema)
        try await db.connect()
        var failure: (any Error)?
        do {
            try await db.migrate()
            try await body(db)
        } catch {
            failure = error
        }
        // Never drop anything but a throwaway test schema.
        precondition(db.schema.hasPrefix("tm_test_") && CaptureLivePostgres.isValidSchemaName(db.schema))
        try await db.execute(PostgresQuery(unsafeSQL: "DROP SCHEMA IF EXISTS \(db.quotedSchema) CASCADE"))
        let leftover = try await db.rows("SELECT count(*) AS n FROM pg_namespace WHERE nspname = \(schema)")
            .first.map { try PostgresRowReader($0)("n", as: Int.self) }
        #expect(leftover == 0, "schema \(schema) was not dropped")
        await db.shutdown()
        if let failure { throw failure }
    }
}

/// PostgresNIO declares a `PostgresDatabase` protocol too.
typealias CaptureLivePostgres = Tidemark.PostgresDatabase

/// `TIDEMARK_TEST_DATABASE_URL`, or nil when unset (the suite is then skipped).
private let captureLiveDatabaseURL: String? = {
    let value = ProcessInfo.processInfo.environment["TIDEMARK_TEST_DATABASE_URL"]?.trimmingCharacters(in: .whitespaces)
    return value?.isEmpty == false ? value : nil
}()
