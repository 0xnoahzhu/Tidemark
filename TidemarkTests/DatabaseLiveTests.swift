import Foundation
import PostgresNIO
import Testing
@testable import Tidemark

/// Live tests against the PostgreSQL server in `TIDEMARK_TEST_DATABASE_URL` (skipped when unset).
///
/// Every test migrates a fresh `tm_test_<8 hex>` schema and drops it afterwards, also on failure.
/// Nothing outside that schema is written, except that the first migration on a database installs
/// the `pg_trgm` extension into `public` when it is missing (production needs it there too).
@Suite(.serialized, .enabled(if: liveDatabaseURL != nil, "Set TIDEMARK_TEST_DATABASE_URL to run"))
struct DatabaseLiveTests {
    static var databaseURL: String? { liveDatabaseURL }

    // MARK: - Schema & connection

    @Test func migrateIsIdempotent() async throws {
        try await withTestDatabase { db in
            #expect(try await db.schemaVersion() == Schema.latestVersion)
            #expect(try await db.migrate() == Schema.latestVersion)
            #expect(try await db.migrate() == Schema.latestVersion)
            let applied = try await db.rows("SELECT count(*) AS n FROM schema_migrations").first.map { try PostgresRowReader($0)("n", as: Int.self) }
            #expect(applied == Schema.migrations.count)

            let tables = try await db.tableNames()
            for table in ["devices", "apps", "app_installs", "processes", "requests", "app_hosts", "host_sources", "ip_info",
                          "alerts", "mutes", "probe_sessions", "probe_hosts", "host_insights", "egress_checks", "egress_changes"] {
                #expect(tables.contains(table), "missing table \(table)")
            }
            #expect(!tables.contains("schema_migrations"))
            #expect(try await db.mutes() == ["*.apple.com", "*.icloud.com", "*.mzstatic.com"])
        }
    }

    @Test func pingReportsServerVersion() async throws {
        try await withTestDatabase { db in
            let ping = try await db.ping()
            print("DatabaseLiveTests: \(ping.serverVersion), round trip \(ping.roundTrip)")
            #expect(ping.serverVersion.first?.isNumber == true)
            #expect(!ping.serverVersion.contains(" "))
            #expect(ping.roundTrip < .seconds(2))
        }
    }

    @Test func concurrentCallsShareThePoolAndShutdownStopsIt() async throws {
        try await withTestDatabase { db in
            let device = Fixture.device("MacBook Pro")
            try await db.upsertDevice(device)
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<40 {
                    group.addTask {
                        if index.isMultiple(of: 2) {
                            try await db.upsertRequests([Fixture.request(device: device.id, id: Int64(index))])
                        } else {
                            _ = try await db.queryRequests(RequestQuery(range: .all, search: "github"))
                        }
                    }
                }
                try await group.waitForAll()
            }
            #expect(try await db.devices().first?.rowCount == 20)

            // A second client on the same schema: after shutdown every call fails fast.
            let url = try #require(Self.databaseURL)
            let other = PostgresDatabase(url: url, schema: db.schema)
            try await other.connect()
            #expect(try await other.schemaVersion() == Schema.latestVersion)
            await other.shutdown()
            await #expect(throws: DatabaseError.self) { _ = try await other.devices() }
            await #expect(throws: DatabaseError.self) { try await other.connect() }
        }
    }

    @Test func wrongPasswordIsReportedAsUnreachable() async throws {
        let url = try #require(Self.databaseURL)
        var components = try #require(URLComponents(string: url))
        components.password = "definitely-not-the-password"
        let db = PostgresDatabase(url: try #require(components.string), schema: "tm_test_00000000")
        await #expect(throws: DatabaseError.self) { try await db.connect() }
        await db.shutdown()
    }

    // MARK: - Devices & apps

    @Test func devicesKeepRowCountAcrossUpserts() async throws {
        try await withTestDatabase { db in
            var device = Fixture.device("MacBook Pro")
            try await db.upsertDevice(device)
            try await db.upsertRequests([Fixture.request(device: device.id, id: 1), Fixture.request(device: device.id, id: 2)])

            device.model = "MacBook Pro · M5"
            device.hue = 120.5
            try await db.upsertDevice(device)
            let stored = try #require(try await db.devices().first)
            #expect(stored.rowCount == 2)
            #expect(stored.model == "MacBook Pro · M5")
            #expect(abs(stored.hue - 120.5) < 0.001)
            #expect(stored.lastWriteAt != nil)

            try await db.renameDevice(device.id, name: "Mac mini (Office)")
            let renamed = try #require(try await db.devices().first)
            #expect(renamed.name == "Mac mini (Office)")
            #expect(renamed.shortName == "mini")
        }
    }

    @Test func appsCRUDAndInstalls() async throws {
        try await withTestDatabase { db in
            let mac = Fixture.device("MacBook Pro")
            let mini = Fixture.device("Mac mini")
            try await db.upsertDevice(mac)
            try await db.upsertDevice(mini)

            var app = Fixture.app("Cursor", path: "/Applications/Cursor.app")
            try await db.insertApp(app)
            await #expect(throws: DatabaseError.self) { try await db.insertApp(Fixture.app("Dup", path: app.path)) }

            app.alertRule = .site
            app.includeChildren = false
            app.archivedAt = Fixture.now
            app.name = "Cursor ✨"
            try await db.updateApp(app)
            let stored = try #require(try await db.apps().first)
            #expect(stored.name == "Cursor ✨")
            #expect(stored.alertRule == .site)
            #expect(!stored.includeChildren)
            #expect(stored.isArchived)
            #expect(abs(stored.tileHue - app.tileHue) < 0.01)
            #expect(abs(stored.createdAt.timeIntervalSince(app.createdAt)) < 0.001)

            try await db.setInstalled(appID: app.id, deviceID: mac.id, installed: true)
            try await db.setInstalled(appID: app.id, deviceID: mini.id, installed: false)
            try await db.setInstalled(appID: app.id, deviceID: mini.id, installed: true)
            #expect(try await db.installs() == [app.id: [mac.id: true, mini.id: true]])

            var request = Fixture.request(device: mac.id, id: 1)
            request.appID = app.id
            try await db.upsertRequests([request])
            _ = try await db.insertAppHosts([Fixture.host(app: app.id, "api2.cursor.sh")])
            _ = try await db.insertAlerts([Fixture.alert(device: mac.id, app: app.id, value: "api2.cursor.sh")])

            try await db.deleteApp(app.id)
            #expect(try await db.apps().isEmpty)
            #expect(try await db.installs().isEmpty)
            #expect(try await db.knownHosts().isEmpty)
            #expect(try await db.alerts(filter: .all, appID: nil, scope: .all, limit: 10).isEmpty)
            let kept = try await db.queryRequests(RequestQuery(range: .all))
            #expect(kept.rows.count == 1)
            #expect(kept.rows.first?.appID == nil)
        }
    }

    // MARK: - Requests

    @Test func upsertRoundTripsEveryField() async throws {
        try await withTestDatabase { db in
            let device = Fixture.device("MacBook Pro")
            try await db.upsertDevice(device)
            let app = Fixture.app("微信 WeChat", path: "/Applications/WeChat.app")
            try await db.insertApp(app)
            let probe = UUID()

            var full = Fixture.request(device: device.id, id: 42, host: "例子.测试")
            full.setupCompletedAt = full.startedAt.addingTimeInterval(0.25)
            full.completedAt = full.startedAt.addingTimeInterval(1.5)
            full.method = "HTTPS"
            full.port = 443
            full.url = "https://例子.测试/路径?q=🙂"
            full.remoteIP = "2001:db8::1"
            full.remoteAddress = "23.254.139.175 (Proxy)"
            full.geo = GeoInfo(countryCode: "HK", asn: 9009, organization: "M247 Europe SRL")
            full.policyPath = ["AI", "AT&T-RackNerd-Hysteria2"]
            full.rule = "DOMAIN-SUFFIX,测试"
            full.state = .completed
            full.inBytes = 15_770
            full.outBytes = 1_140
            full.pid = 4242
            full.processPath = "/Applications/WeChat.app/Contents/MacOS/WeChat"
            full.bundlePath = "/Applications/WeChat.app"
            full.chain = [
                ProcessLink(name: "WeChat", pid: 4000, path: "/Applications/WeChat.app/Contents/MacOS/WeChat", startTime: Fixture.now.addingTimeInterval(-60)),
                ProcessLink(name: "helper \"quoted\"", pid: 4242, path: nil, startTime: nil),
            ]
            full.appID = app.id
            full.localAddress = "192.168.1.20:51234"
            full.interface = "en0"
            full.notes = ["12:07:22.102428 [TLS] TLS Client Hello SNI: 例子.测试", "{\"json\": [1, 2]}", ""]
            full.isNew = true
            full.probeSessionID = probe

            let empty = Fixture.request(device: device.id, id: 43, host: "149.154.175.60")
            let ids = try await db.upsertRequests([full, empty])
            #expect(ids.count == 2)
            #expect(Set(ids.values).count == 2)

            let page = try await db.queryRequests(RequestQuery(range: .all))
            let stored = try #require(page.rows.first { $0.key == full.key })
            #expect(stored.rowID == ids[full.key])
            #expect(stored.host == full.host)
            #expect(stored.url == full.url)
            #expect(stored.port == 443)
            #expect(stored.remoteIP == "2001:db8::1")
            #expect(stored.remoteAddress == full.remoteAddress)
            #expect(stored.geo == full.geo)
            #expect(stored.policyPath == full.policyPath)
            #expect(stored.finalPolicy == "AT&T-RackNerd-Hysteria2")
            #expect(stored.rule == full.rule)
            #expect(stored.state == .completed)
            #expect(stored.inBytes == 15_770 && stored.outBytes == 1_140)
            #expect(stored.pid == 4242)
            #expect(stored.processPath == full.processPath)
            #expect(stored.bundlePath == full.bundlePath)
            #expect(stored.chain.count == 2)
            #expect(stored.chain[1].name == "helper \"quoted\"")
            #expect(stored.chain[1].startTime == nil)
            let storedStart = try #require(stored.chain[0].startTime)
            let fullStart = try #require(full.chain[0].startTime)
            #expect(abs(storedStart.timeIntervalSince(fullStart)) < 0.000_01)
            #expect(stored.appID == app.id)
            #expect(stored.localAddress == full.localAddress)
            #expect(stored.interface == "en0")
            #expect(stored.notes == full.notes)
            #expect(stored.isNew)
            #expect(stored.probeSessionID == probe)
            #expect(Fixture.close(stored.startedAt, full.startedAt))
            let completed = (try #require(stored.completedAt), try #require(full.completedAt))
            let setup = (try #require(stored.setupCompletedAt), try #require(full.setupCompletedAt))
            #expect(Fixture.close(completed.0, completed.1))
            #expect(Fixture.close(setup.0, setup.1))
            #expect(stored.writtenAt != nil)

            let bare = try #require(page.rows.first { $0.key == empty.key })
            #expect(bare.isIPLiteral)
            #expect(bare.remoteIP == nil && bare.geo == nil && bare.url == nil && bare.port == nil && bare.pid == nil)
            #expect(bare.policyPath.isEmpty && bare.notes.isEmpty && bare.chain.isEmpty)
            #expect(bare.appID == nil && bare.probeSessionID == nil && bare.setupCompletedAt == nil && bare.completedAt == nil)
        }
    }

    @Test func upsertMergesUpdatesWithoutRegressing() async throws {
        try await withTestDatabase { db in
            let device = Fixture.device("MacBook Pro")
            try await db.upsertDevice(device)
            let app = Fixture.app("Cursor", path: "/Applications/Cursor.app")
            try await db.insertApp(app)

            var first = Fixture.request(device: device.id, id: 7)
            first.isNew = true
            first.appID = app.id
            first.remoteIP = "104.18.19.125"
            first.geo = GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare, Inc.")
            first.inBytes = 500
            let ids = try await db.upsertRequests([first])
            let before = try #require(try await db.queryRequests(RequestQuery(range: .all)).rows.first)

            try await Task.sleep(for: .milliseconds(20))
            var update = Fixture.request(device: device.id, id: 7)
            update.state = .completed
            update.completedAt = first.startedAt.addingTimeInterval(3)
            update.inBytes = 9_000
            update.outBytes = 300
            update.policyPath = ["DIRECT"]
            update.notes = ["a", "b"]
            #expect(try await db.upsertRequests([update]) == ids)

            // A stale snapshot replayed from the spool must not undo the update.
            var stale = Fixture.request(device: device.id, id: 7)
            stale.state = .active
            stale.inBytes = 100
            try await db.upsertRequests([stale])

            let after = try #require(try await db.queryRequests(RequestQuery(range: .all)).rows.first)
            #expect(after.rowID == before.rowID)
            #expect(after.isNew)
            #expect(after.appID == app.id)
            #expect(after.remoteIP == "104.18.19.125")
            #expect(after.geo == first.geo)
            #expect(after.state == .completed)
            #expect(after.completedAt != nil)
            #expect(after.inBytes == 9_000 && after.outBytes == 300)
            #expect(after.policyPath == ["DIRECT"])
            #expect(after.notes == ["a", "b"])
            let writtenAfter = try #require(after.writtenAt)
            let writtenBefore = try #require(before.writtenAt)
            #expect(writtenAfter > writtenBefore)

            let row = try await db.rows("SELECT written_at, updated_at FROM requests").first.map { row in
                let read = PostgresRowReader(row)
                return (try read("written_at", as: Date.self), try read("updated_at", as: Date.self))
            }
            let (writtenAt, updatedAt) = try #require(row)
            #expect(writtenAt < updatedAt)
            #expect(try await db.devices().first?.rowCount == 1)

            // Duplicate keys inside one batch are merged instead of failing.
            var a = Fixture.request(device: device.id, id: 8)
            a.isNew = true
            var b = Fixture.request(device: device.id, id: 8)
            b.state = .failed
            let merged = try await db.upsertRequests([a, b])
            #expect(merged.count == 1)
            let failed = try await db.queryRequests(RequestQuery(range: .all, status: .failed))
            #expect(failed.rows.map(\.key.surgeID) == [8])
            #expect(failed.rows.first?.isNew == true)
            #expect(try await db.devices().first?.rowCount == 2)
        }
    }

    @Test func bulkUpsertOf2000Rows() async throws {
        try await withTestDatabase { db in
            let device = Fixture.device("MacBook Pro")
            try await db.upsertDevice(device)
            let rows = (1...2_000).map { index in
                var row = Fixture.request(device: device.id, id: Int64(index), host: "host\(index % 97).example.com")
                row.startedAt = Fixture.now.addingTimeInterval(-Double(index))
                row.policyPath = ["Proxy", "Node \(index % 5)"]
                row.notes = ["note \(index)"]
                row.remoteIP = "10.0.\(index / 256).\(index % 256)"
                row.chain = [ProcessLink(name: "proc", pid: Int32(index), path: "/usr/bin/proc", startTime: Fixture.now)]
                return row
            }
            let clock = ContinuousClock()
            let insertTime = try await clock.measure {
                let ids = try await db.upsertRequests(rows)
                #expect(ids.count == 2_000)
            }
            let updateTime = try await clock.measure {
                try await db.upsertRequests(rows.map { var r = $0; r.state = .completed; r.inBytes = 1; return r })
            }
            print("DatabaseLiveTests: upsert of 2,000 new rows took \(insertTime), re-upsert of the same rows took \(updateTime)")
            #expect(try await db.devices().first?.rowCount == 2_000)
            #expect(try await db.countRequests(since: .distantPast, scope: .all) == 2_000)
            #expect(try await db.estimatedRequestCount() == 2_000)
            #expect(insertTime < .seconds(20))
        }
    }

    @Test func queriesFilterCountAndPage() async throws {
        try await withTestDatabase { db in
            let mac = Fixture.device("MacBook Pro")
            let mini = Fixture.device("Mac mini")
            try await db.upsertDevice(mac)
            try await db.upsertDevice(mini)
            let app = Fixture.app("Raycast", path: "/Applications/Raycast.app")
            try await db.insertApp(app)

            var rows: [RequestRecord] = []
            for index in 0..<30 {
                var row = Fixture.request(device: index.isMultiple(of: 3) ? mini.id : mac.id, id: Int64(index), host: "svc\(index).linear.app")
                row.startedAt = Fixture.now.addingTimeInterval(-Double(index) * 1_800)
                row.policyPath = index.isMultiple(of: 2) ? ["DIRECT"] : ["Proxy", "HK"]
                row.state = [.completed, .active, .failed, .rejected][index % 4]
                row.chain = [ProcessLink(name: index < 5 ? "node" : "Raycast", pid: 1, path: nil, startTime: nil)]
                row.remoteIP = "172.16.0.\(index)"
                if index >= 25 { row.appID = app.id }
                rows.append(row)
            }
            var old = Fixture.request(device: mac.id, id: 999, host: "old.example.com")
            old.startedAt = Fixture.now.addingTimeInterval(-40 * 24 * 3600)
            rows.append(old)
            try await db.upsertRequests(rows)

            let day = try await db.queryRequests(RequestQuery(range: .last24Hours, limit: 10))
            #expect(day.rows.count == 10)
            #expect(day.totalCount == 30)
            #expect(day.rows.map(\.startedAt) == day.rows.map(\.startedAt).sorted(by: >))
            #expect(day.elapsed > .zero)

            let second = try await db.queryRequests(RequestQuery(range: .last24Hours, limit: 10, offset: 10))
            #expect(Set(second.rows.map(\.key)).isDisjoint(with: day.rows.map(\.key)))

            #expect(try await db.queryRequests(RequestQuery(scope: .device(mini.id), range: .last24Hours)).totalCount == 10)
            #expect(try await db.queryRequests(RequestQuery(range: .last24Hours, appID: app.id)).totalCount == 5)
            #expect(try await db.queryRequests(RequestQuery(range: .last24Hours, policy: "HK")).totalCount == 15)
            #expect(try await db.queryRequests(RequestQuery(range: .last24Hours, status: .failed)).totalCount == 14)
            #expect(try await db.queryRequests(RequestQuery(range: .last24Hours, status: .active)).totalCount == 8)
            #expect(try await db.queryRequests(RequestQuery(range: .lastHour)).totalCount == 2)
            #expect(try await db.queryRequests(RequestQuery(range: .all)).totalCount == 31)
            #expect(try await db.queryRequests(RequestQuery(scope: .device(mac.id), range: .all)).totalCount == 21)

            // Search: host, process name, remote IP and app name; LIKE wildcards are literal.
            #expect(try await db.queryRequests(RequestQuery(range: .all, search: "SVC12.")).rows.map(\.key.surgeID) == [12])
            #expect(try await db.queryRequests(RequestQuery(range: .all, search: "node")).totalCount == 5)
            #expect(try await db.queryRequests(RequestQuery(range: .all, search: "172.16.0.29")).rows.map(\.key.surgeID) == [29])
            #expect(try await db.queryRequests(RequestQuery(range: .all, search: "raycast")).totalCount >= 25)
            #expect(try await db.queryRequests(RequestQuery(range: .all, search: "%")).totalCount == 0)

            #expect(try await db.distinctPolicies(since: nil) == ["DIRECT", "HK"])
            #expect(try await db.countRequests(since: Fixture.now.addingTimeInterval(-3_000), scope: .all) == 2)
            #expect(try await db.countRequests(since: .distantPast, scope: .device(mini.id)) == 10)

            let histogram = try await db.histogram(RequestQuery(range: .last24Hours), buckets: 24)
            #expect(histogram.counts.count == 24)
            #expect(histogram.counts.reduce(0, +) == 30)
            #expect(histogram.counts.last == 2)
            let all = try await db.histogram(RequestQuery(range: .all), buckets: 10)
            #expect(all.counts.reduce(0, +) == 31)
            #expect(all.counts.first == 1)
            #expect(Fixture.close(all.start, old.startedAt))
            let none = try await db.histogram(RequestQuery(range: .all, search: "nothing-matches"), buckets: 5)
            #expect(none.counts == [0, 0, 0, 0, 0])

            #expect(try await db.deleteRequests(olderThan: Fixture.now.addingTimeInterval(-30 * 24 * 3600), deviceID: nil) == 1)
            #expect(try await db.devices().first { $0.id == mac.id }?.rowCount == 20)
        }
    }

    @Test func requestsWrittenByOtherMacs() async throws {
        try await withTestDatabase { db in
            let mac = Fixture.device("MacBook Pro")
            let mini = Fixture.device("Mac mini")
            try await db.upsertDevice(mac)
            try await db.upsertDevice(mini)
            try await db.upsertRequests([Fixture.request(device: mac.id, id: 1), Fixture.request(device: mini.id, id: 1)])
            let initial = try await db.requestsWritten(after: .distantPast, excluding: nil, limit: 10)
            #expect(initial.count == 2)
            let cursor = try #require(initial.compactMap(\.writtenAt).max())

            #expect(try await db.requestsWritten(after: cursor, excluding: mac.id, limit: 10).isEmpty)
            try await Task.sleep(for: .milliseconds(20))
            var update = Fixture.request(device: mini.id, id: 1)
            update.state = .completed
            try await db.upsertRequests([update, Fixture.request(device: mini.id, id: 2), Fixture.request(device: mac.id, id: 2)])

            let fresh = try await db.requestsWritten(after: cursor, excluding: mac.id, limit: 10)
            #expect(Set(fresh.map(\.key.surgeID)) == [1, 2])
            #expect(fresh.allSatisfy { $0.deviceID == mini.id })
            #expect(fresh.first { $0.key.surgeID == 1 }?.state == .completed)
            #expect(try await db.requestsWritten(after: cursor, excluding: mac.id, limit: 1).count == 1)
            #expect(try await db.requestsWritten(after: cursor, excluding: nil, limit: 10).count == 3)
        }
    }

    // MARK: - Processes

    @Test func processChainsAndTree() async throws {
        try await withTestDatabase { db in
            let device = Fixture.device("MacBook Pro")
            try await db.upsertDevice(device)
            let app = Fixture.app("Cursor", path: "/Applications/Cursor.app")
            try await db.insertApp(app)

            let t = Fixture.now.addingTimeInterval(-600)
            let cursor = ProcessLink(name: "Cursor", pid: 812, path: "/Applications/Cursor.app/Contents/MacOS/Cursor", startTime: t)
            let plugin = ProcessLink(name: "Cursor Helper (Plugin)", pid: 851, path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)", startTime: t.addingTimeInterval(1))
            let renderer = ProcessLink(name: "Cursor Helper (Renderer)", pid: 845, path: "/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Renderer).app/Contents/MacOS/Cursor Helper (Renderer)", startTime: t.addingTimeInterval(2))
            let node = ProcessLink(name: "node", pid: 1201, path: "/usr/local/bin/node", startTime: t.addingTimeInterval(3))
            let git = ProcessLink(name: "git", pid: 1288, path: "/usr/bin/git", startTime: t.addingTimeInterval(4))
            let gitAgain = ProcessLink(name: "git", pid: 1390, path: "/usr/bin/git", startTime: t.addingTimeInterval(50))
            let remote = ProcessLink(name: "git-remote-https", pid: 1290, path: "/Library/Developer/CommandLineTools/usr/libexec/git-core/git-remote-https", startTime: t.addingTimeInterval(5))
            let noStart = ProcessLink(name: "ghost", pid: 7, path: nil, startTime: nil)

            let nodeID = try #require(try await db.upsertProcessChain(deviceID: device.id, chain: [cursor, plugin, noStart, node], appID: app.id))
            #expect(try await db.upsertProcessChain(deviceID: device.id, chain: [cursor, plugin, noStart, node], appID: nil) == nodeID)
            let remoteID = try #require(try await db.upsertProcessChain(deviceID: device.id, chain: [cursor, plugin, git, remote], appID: app.id))
            _ = try await db.upsertProcessChain(deviceID: device.id, chain: [cursor, plugin, gitAgain], appID: app.id)
            _ = try await db.upsertProcessChain(deviceID: device.id, chain: [cursor, renderer], appID: app.id)
            #expect(try await db.upsertProcessChain(deviceID: device.id, chain: [noStart], appID: app.id) == nil)

            let parents = try await db.rows("SELECT p.name, q.name AS parent FROM processes p LEFT JOIN processes q ON q.id = p.parent_id")
                .reduce(into: [String: String]()) { result, row in
                    let read = PostgresRowReader(row)
                    result[try read("name", as: String.self) + ":" + "\(result.count)"] = try read("parent", as: String?.self) ?? "-"
                }
            #expect(parents.values.filter { $0 == "Cursor Helper (Plugin)" }.count == 3)
            #expect(parents.values.filter { $0 == "-" }.count == 1)

            // Requests resolve process_id through the chain's leaf.
            var fromNode = Fixture.request(device: device.id, id: 1, host: "registry.npmjs.org")
            fromNode.appID = app.id
            fromNode.chain = [cursor, plugin, node]
            var fromNode2 = Fixture.request(device: device.id, id: 2, host: "registry.npmjs.org")
            fromNode2.appID = app.id
            fromNode2.chain = [cursor, plugin, node]
            var fromRemote = Fixture.request(device: device.id, id: 3, host: "github.com")
            fromRemote.appID = app.id
            fromRemote.chain = [cursor, plugin, git, remote]
            var direct = Fixture.request(device: device.id, id: 4, host: "140.82.112.3")
            direct.appID = app.id
            direct.chain = [cursor, plugin, git, remote]
            try await db.upsertRequests([fromNode, fromNode2, fromRemote, direct])
            let linked = try await db.rows("SELECT surge_id, process_id FROM requests ORDER BY surge_id").map { row in
                try PostgresRowReader(row)("process_id", as: Int64?.self)
            }
            #expect(linked == [nodeID, nodeID, remoteID, remoteID])

            let tree = try await db.processTree(appID: app.id, scope: .all)
            #expect(tree.map(\.name) == ["Cursor", "Cursor Helper (Plugin)", "node", "git", "git-remote-https", "Cursor Helper (Renderer)"])
            #expect(tree.map(\.depth) == [0, 1, 2, 2, 3, 1])
            let gitNode = try #require(tree.first { $0.name == "git" })
            #expect(gitNode.pid == 1390)
            #expect(gitNode.isRunning)
            let nodeNode = try #require(tree.first { $0.name == "node" })
            #expect(nodeNode.requestCount == 2 && nodeNode.domainCount == 1)
            let remoteNode = try #require(tree.first { $0.name == "git-remote-https" })
            #expect(remoteNode.requestCount == 2 && remoteNode.domainCount == 1)
            #expect(Set(tree.map(\.id)).count == tree.count)

            #expect(try await db.processTree(appID: app.id, scope: .device(UUID())).isEmpty)
            let stats = try await db.appStats(app.id, scope: .device(device.id))
            #expect(stats.processes == 6)
            #expect(stats.requests == 4)
        }
    }

    // MARK: - Inventory

    @Test func appHostsFirstContactAndTouch() async throws {
        try await withTestDatabase { db in
            let mac = Fixture.device("MacBook Pro")
            let mini = Fixture.device("Mac mini")
            try await db.upsertDevice(mac)
            try await db.upsertDevice(mini)
            let app = Fixture.app("Docker", path: "/Applications/Docker.app")
            try await db.insertApp(app)

            var ip = Fixture.host(app: app.id, "104.16.98.215", kind: .ip)
            ip.isDirect = false
            ip.hosts = ["registry-1.docker.io"]
            ip.geo = GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare, Inc.")
            let domain = Fixture.host(app: app.id, "registry-1.docker.io")
            let created = try await db.insertAppHosts([domain, ip, domain])
            #expect(created.map(\.value) == ["registry-1.docker.io", "104.16.98.215"])
            #expect(try await db.insertAppHosts([domain]).isEmpty)

            // Two Macs racing on the same first contact: exactly one wins.
            let racer = Fixture.host(app: app.id, "auth.docker.io")
            async let first = db.insertAppHosts([racer])
            async let second = db.insertAppHosts([racer])
            let winners = try await first.count + second.count
            #expect(winners == 1)

            #expect(try await db.knownHosts() == [app.id: ["registry-1.docker.io", "104.16.98.215", "auth.docker.io"]])

            var touch = ip
            touch.requestCount = 5
            touch.lastSeen = Fixture.now.addingTimeInterval(120)
            touch.hosts = ["hub.docker.com", "registry-1.docker.io"]
            touch.policy = "Proxy › HK"
            touch.geo = nil
            var touchAgain = touch
            touchAgain.requestCount = 2
            touchAgain.lastSeen = Fixture.now.addingTimeInterval(60)
            touchAgain.isDirect = true
            try await db.touchAppHosts([touch, touchAgain, Fixture.host(app: app.id, "unknown.example.com")])

            let hosts = try await db.appHosts(app.id, scope: .all)
            #expect(hosts.count == 3)
            let storedIP = try #require(hosts.first { $0.kind == .ip })
            #expect(storedIP.requestCount == 1 + 7)
            #expect(Fixture.close(storedIP.lastSeen, touch.lastSeen))
            #expect(storedIP.hosts == ["hub.docker.com", "registry-1.docker.io"])
            #expect(storedIP.policy == "Proxy › HK")
            #expect(storedIP.geo == ip.geo)
            #expect(storedIP.isDirect)

            // Device scope: only entries that Mac reported in host_sources.
            try await db.touchHostSources([
                Fixture.source(.domain, "registry-1.docker.io", device: mini.id, app: app.id),
                Fixture.source(.ip, "104.16.98.215", device: mac.id, app: app.id),
            ])
            #expect(try await db.appHosts(app.id, scope: .device(mini.id)).map(\.value) == ["registry-1.docker.io"])
            #expect(try await db.appHosts(app.id, scope: .device(mac.id)).map(\.value) == ["104.16.98.215"])

            let stats = try await db.appStats(app.id, scope: .all)
            #expect(stats.domains == 2 && stats.ips == 1 && stats.sites == 1 && stats.directIPs == 1)
            #expect(stats.newIn24h == 3 && stats.newDomainsIn24h == 2)
            let miniStats = try await db.appStats(app.id, scope: .device(mini.id))
            #expect(miniStats.domains == 1 && miniStats.ips == 0)
        }
    }

    @Test func globalInventoryGroupsSources() async throws {
        try await withTestDatabase { db in
            let mac = Fixture.device("MacBook Pro")
            let mini = Fixture.device("Mac mini")
            try await db.upsertDevice(mac)
            try await db.upsertDevice(mini)
            let app = Fixture.app("Cursor", path: "/Applications/Cursor.app")
            try await db.insertApp(app)
            let probe = ProbeSession(id: UUID(), deviceID: mac.id, url: "https://github.com", host: "github.com", mode: .desktop,
                                     startedAt: Fixture.now, endedAt: nil, steps: [], hosts: [])
            try await db.saveProbeSession(probe)

            var github = Fixture.source(.domain, "github.com", device: mac.id, app: app.id, path: "/Applications/Cursor.app/Contents/MacOS/Cursor", title: "Cursor")
            github.geo = GeoInfo(countryCode: "US", asn: 36459, organization: "GitHub, Inc.")
            var githubLater = github
            githubLater.seenAt = Fixture.now.addingTimeInterval(30)
            githubLater.requestDelta = 4
            githubLater.geo = nil
            try await db.touchHostSources([
                github, githubLater,
                Fixture.source(.domain, "github.com", device: mini.id, app: nil, path: "/usr/bin/git", title: "git"),
                Fixture.source(.domain, "github.com", device: mac.id, app: nil, path: "probe:\(probe.id.uuidString)", title: "Probe · github.com"),
                Fixture.source(.ip, "140.82.112.3", device: mac.id, app: nil, path: "/usr/bin/git", title: "git"),
            ])
            try await db.touchHostSources([githubLater])

            let all = try await db.inventory(kind: nil, search: "", scope: .all)
            #expect(all.count == 2)
            let entry = try #require(all.first { $0.value == "github.com" })
            #expect(entry.requestCount == 1 + 4 + 4 + 1 + 1)
            #expect(entry.sources.count == 3)
            #expect(entry.geo == github.geo)
            #expect(Fixture.close(entry.lastSeen, githubLater.seenAt))
            let probeSource = try #require(entry.sources.first { $0.probeSessionID != nil })
            #expect(probeSource.probeSessionID == probe.id)
            #expect(probeSource.path == "Site probe · github.com")
            #expect(entry.sources.contains { $0.appID == app.id && $0.title == "Cursor" })

            #expect(try await db.inventory(kind: .ip, search: "", scope: .all).map(\.value) == ["140.82.112.3"])
            #expect(try await db.inventory(kind: nil, search: "GIT", scope: .all).count == 2)
            #expect(try await db.inventory(kind: nil, search: "140.82", scope: .all).map(\.value) == ["140.82.112.3"])
            let miniOnly = try await db.inventory(kind: nil, search: "", scope: .device(mini.id))
            #expect(miniOnly.map(\.value) == ["github.com"])
            #expect(miniOnly.first?.sources.map(\.title) == ["git"])

            try await db.deleteProbeSession(probe.id)
            #expect(try await db.inventory(kind: .domain, search: "", scope: .all).first?.sources.count == 2)
        }
    }

    @Test func ipInfoRoundTrip() async throws {
        try await withTestDatabase { db in
            #expect(try await db.ipInfo("8.8.8.8") == nil)
            let geo = GeoInfo(countryCode: "US", asn: 15169, organization: "Google LLC")
            try await db.saveIPInfo("8.8.8.8", geo: geo)
            try await db.saveIPInfo("[2001:4860:4860::8888]", geo: GeoInfo(countryCode: nil, asn: nil, organization: nil))
            try await db.saveIPInfo("not-an-ip", geo: geo)
            #expect(try await db.ipInfo("8.8.8.8") == geo)
            #expect(try await db.ipInfo("2001:4860:4860::8888") == GeoInfo(countryCode: nil, asn: nil, organization: nil))
            #expect(try await db.ipInfo("not-an-ip") == nil)
            let updated = GeoInfo(countryCode: "US", asn: 15169, organization: "Google")
            try await db.saveIPInfo("8.8.8.8", geo: updated)
            #expect(try await db.ipInfo("8.8.8.8") == updated)
        }
    }

    @Test func backfillAttributesPastRequests() async throws {
        try await withTestDatabase { db in
            let device = Fixture.device("MacBook Pro")
            try await db.upsertDevice(device)
            let path = "/Applications/Grok_Bot 100%.app"
            var rows: [RequestRecord] = []

            var main = Fixture.request(device: device.id, id: 1, host: "api.x.ai")
            main.processPath = path + "/Contents/MacOS/Grok"
            main.policyPath = ["AI", "US"]
            main.remoteIP = "104.18.1.1"
            rows.append(main)
            var helperLater = Fixture.request(device: device.id, id: 2, host: "api.x.ai")
            helperLater.startedAt = main.startedAt.addingTimeInterval(10)
            helperLater.bundlePath = path + "/"
            helperLater.policyPath = ["AI", "JP"]
            helperLater.remoteIP = "104.18.1.1"
            rows.append(helperLater)
            var direct = Fixture.request(device: device.id, id: 3, host: "149.154.175.60")
            direct.bundlePath = path
            rows.append(direct)
            var unrelated = Fixture.request(device: device.id, id: 4, host: "example.com")
            unrelated.processPath = "/Applications/Grok_Bot 100%.application/x"
            rows.append(unrelated)
            var lookalike = Fixture.request(device: device.id, id: 5, host: "example.org")
            lookalike.processPath = "/Applications/GrokXBot 100%.app/Contents/MacOS/x"
            rows.append(lookalike)
            try await db.upsertRequests(rows)

            #expect(try await db.countRequests(inBundle: path) == 3)
            #expect(try await db.countRequests(inBundle: path + "/") == 3)

            let app = Fixture.app("Grok Bot", path: path)
            try await db.insertApp(app)
            _ = try await db.insertAppHosts([Fixture.host(app: app.id, "api.x.ai", firstSeen: Fixture.now.addingTimeInterval(-86_400 * 3))])
            #expect(try await db.backfill(appID: app.id, bundlePath: path) == 3)
            #expect(try await db.backfill(appID: app.id, bundlePath: path) == 0)

            let hosts = try await db.appHosts(app.id, scope: .all)
            let domain = try #require(hosts.first { $0.kind == .domain && $0.value == "api.x.ai" })
            #expect(domain.site == "x.ai")
            #expect(domain.requestCount == 2)
            #expect(domain.policy == "AI › JP")
            #expect(domain.firstSeen < Fixture.now.addingTimeInterval(-86_400 * 2))
            let shared = try #require(hosts.first { $0.kind == .ip && $0.value == "104.18.1.1" })
            #expect(shared.hosts == ["api.x.ai"])
            #expect(!shared.isDirect)
            let literal = try #require(hosts.first { $0.kind == .ip && $0.value == "149.154.175.60" })
            #expect(literal.isDirect)
            #expect(hosts.count == 3)
            #expect(try await db.queryRequests(RequestQuery(range: .all, appID: app.id)).totalCount == 3)
        }
    }

    // MARK: - Alerts & mutes

    @Test func alertsLifecycle() async throws {
        try await withTestDatabase { db in
            let mac = Fixture.device("MacBook Pro")
            let mini = Fixture.device("Mac mini")
            try await db.upsertDevice(mac)
            try await db.upsertDevice(mini)
            let cursor = Fixture.app("Cursor", path: "/Applications/Cursor.app")
            let docker = Fixture.app("Docker", path: "/Applications/Docker.app")
            try await db.insertApp(cursor)
            try await db.insertApp(docker)
            let requestID = try #require(try await db.upsertRequests([Fixture.request(device: mac.id, id: 1)]).values.first)

            var ipAlert = Fixture.alert(device: mini.id, app: docker.id, value: "104.16.98.215")
            ipAlert.kind = .ip
            ipAlert.scope = .ip
            ipAlert.ip = "104.16.98.215"
            ipAlert.host = ""
            ipAlert.isDirect = true
            ipAlert.geo = GeoInfo(countryCode: "US", asn: 13335, organization: "Cloudflare")
            var siteAlert = Fixture.alert(device: mac.id, app: cursor.id, value: "raw.githubusercontent.com")
            siteAlert.requestRowID = requestID
            siteAlert.createdAt = Fixture.now.addingTimeInterval(5)
            let inserted = try await db.insertAlerts([ipAlert, siteAlert])
            #expect(inserted.count == 2)
            #expect(inserted[0].value == "104.16.98.215" && inserted[1].value == "raw.githubusercontent.com")
            #expect(inserted[0].id < inserted[1].id)

            let all = try await db.alerts(filter: .all, appID: nil, scope: .all, limit: 10)
            #expect(all.map(\.id) == [inserted[1].id, inserted[0].id])
            let storedIP = try #require(all.last)
            #expect(storedIP.geo == ipAlert.geo && storedIP.isDirect && storedIP.host == "" && storedIP.kind == .ip && storedIP.scope == .ip)
            #expect(all.first?.requestRowID == requestID)
            #expect(try await db.alerts(filter: .ip, appID: nil, scope: .all, limit: 10).map(\.id) == [inserted[0].id])
            #expect(try await db.alerts(filter: .domain, appID: nil, scope: .all, limit: 10).map(\.id) == [inserted[1].id])
            #expect(try await db.alerts(filter: .all, appID: docker.id, scope: .all, limit: 10).count == 1)
            #expect(try await db.alerts(filter: .all, appID: nil, scope: .device(mac.id), limit: 10).count == 1)
            #expect(try await db.alerts(filter: .all, appID: nil, scope: .all, limit: 1).count == 1)
            #expect(try await db.alerts(after: 0, excluding: mac.id).map(\.id) == [inserted[0].id])
            #expect(try await db.alerts(after: inserted[0].id, excluding: nil).map(\.id) == [inserted[1].id])

            #expect(try await db.unreadAlertCount(scope: .all) == 2)
            try await db.markAlertsRead([inserted[0].id])
            #expect(try await db.unreadAlertCount(scope: .all) == 1)
            #expect(try await db.unreadAlertCount(scope: .device(mini.id)) == 0)
            #expect(try await db.alerts(filter: .unread, appID: nil, scope: .all, limit: 10).map(\.id) == [inserted[1].id])
            try await db.markAllAlertsRead(appID: docker.id, scope: .all)
            #expect(try await db.unreadAlertCount(scope: .all) == 1)
            try await db.markAllAlertsRead(appID: nil, scope: .all)
            #expect(try await db.unreadAlertCount(scope: .all) == 0)

            // Retention keeps alerts and clears their request link.
            #expect(try await db.deleteRequests(olderThan: Fixture.now.addingTimeInterval(3600), deviceID: nil) == 1)
            #expect(try await db.alerts(filter: .domain, appID: nil, scope: .all, limit: 10).first?.requestRowID == nil)

            try await db.deleteAlert(inserted[0].id)
            #expect(try await db.alerts(filter: .all, appID: nil, scope: .all, limit: 10).count == 1)
        }
    }

    @Test func mutesCRUD() async throws {
        try await withTestDatabase { db in
            try await db.addMute("  API.Notion.com ")
            try await db.addMute("api.notion.com")
            try await db.addMute("104.16.98.215")
            #expect(try await db.mutes() == ["*.apple.com", "*.icloud.com", "*.mzstatic.com", "api.notion.com", "104.16.98.215"])
            try await db.removeMute("API.NOTION.COM")
            try await db.removeMute("*.apple.com")
            #expect(try await db.mutes() == ["*.icloud.com", "*.mzstatic.com", "104.16.98.215"])
        }
    }

    // MARK: - Probes, insights, egress

    @Test func probeSessionsRoundTrip() async throws {
        try await withTestDatabase { db in
            let device = Fixture.device("MacBook Pro")
            try await db.upsertDevice(device)
            var session = ProbeSession(
                id: UUID(), deviceID: device.id, url: "https://github.com/explore", host: "github.com", mode: .iphone,
                startedAt: Fixture.now, endedAt: nil,
                steps: [ProbeStep(at: 0, label: "Page load", url: "https://github.com/explore"), ProbeStep(at: 4.25, label: "点击 · Open a repo", url: nil)],
                hosts: [
                    ProbeHost(host: "github.com", firstAt: 0.012, lastAt: 6.5, requestCount: 12, ips: ["140.82.112.3"], step: 0),
                    ProbeHost(host: "avatars.githubusercontent.com", firstAt: 0.4, lastAt: 5, requestCount: 3, ips: [], step: 1),
                ]
            )
            try await db.saveProbeSession(session)
            var older = session
            older.id = UUID()
            older.startedAt = Fixture.now.addingTimeInterval(-3600)
            older.hosts = []
            try await db.saveProbeSession(older)

            session.endedAt = Fixture.now.addingTimeInterval(8)
            session.hosts = [ProbeHost(host: "github.com", firstAt: 0.012, lastAt: 7.75, requestCount: 14, ips: ["140.82.112.3", "140.82.112.4"], step: 0)]
            try await db.saveProbeSession(session)

            let sessions = try await db.probeSessions(limit: 10)
            #expect(sessions.map(\.id) == [session.id, older.id])
            let stored = sessions[0]
            #expect(stored.mode == .iphone)
            #expect(stored.steps == session.steps)
            #expect(stored.hosts == session.hosts)
            let ended = (try #require(stored.endedAt), try #require(session.endedAt))
            #expect(Fixture.close(ended.0, ended.1))
            #expect(try await db.probeSessions(limit: 1).count == 1)

            try await db.deleteProbeSession(session.id)
            #expect(try await db.probeSessions(limit: 10).map(\.id) == [older.id])
        }
    }

    @Test func hostInsightsRoundTrip() async throws {
        try await withTestDatabase { db in
            #expect(try await db.hostInsight("api2.cursor.sh", language: "en") == nil)
            let insight = HostInsight(host: "API2.cursor.sh", category: .aiInference, operatorName: "Anysphere",
                                      summary: "Cursor's model gateway.", concern: nil, language: "en", model: "AFM 3 Core", createdAt: Fixture.now)
            try await db.saveHostInsight(insight)
            var chinese = insight
            chinese.language = "zh-Hans"
            chinese.summary = "Cursor 的模型网关。"
            chinese.concern = "会发送代码片段"
            try await db.saveHostInsight(chinese)

            let english = try #require(try await db.hostInsight("api2.CURSOR.sh", language: "en"))
            #expect(english.host == "api2.cursor.sh")
            #expect(english.category == .aiInference && english.operatorName == "Anysphere" && english.concern == nil)
            #expect(try await db.hostInsight("api2.cursor.sh", language: "zh-Hans")?.summary == "Cursor 的模型网关。")

            chinese.category = .telemetry
            try await db.saveHostInsight(chinese)
            #expect(try await db.hostInsight("api2.cursor.sh", language: "zh-Hans")?.category == .telemetry)
        }
    }

    @Test func egressSamplesAndChanges() async throws {
        try await withTestDatabase { db in
            let mac = Fixture.device("MacBook Pro")
            let mini = Fixture.device("Mac mini")
            try await db.upsertDevice(mac)
            try await db.upsertDevice(mini)

            let earlier = Fixture.now.addingTimeInterval(-300)
            try await db.saveEgressSamples([
                EgressSample(policyPath: ["DIRECT"], ip: "203.0.113.7", location: "Hong Kong", network: "AS4760 HKT", latencyMs: 12, isCurrent: true, checkedAt: earlier, error: nil),
                EgressSample(policyPath: ["AI", "US-West"], ip: nil, location: nil, network: nil, latencyMs: nil, isCurrent: false, checkedAt: earlier, error: "Timed out"),
                EgressSample(policyPath: ["Removed"], ip: "198.51.100.1", location: nil, network: nil, latencyMs: 80, isCurrent: false, checkedAt: earlier.addingTimeInterval(-7200), error: nil),
            ], deviceID: mac.id)
            try await db.saveEgressSamples([
                EgressSample(policyPath: ["DIRECT"], ip: "203.0.113.7", location: "Hong Kong", network: "AS4760 HKT", latencyMs: 9, isCurrent: false, checkedAt: Fixture.now, error: nil),
                EgressSample(policyPath: ["AI", "US-West"], ip: "2001:db8::42", location: "Los Angeles, US", network: "AS9009 M247", latencyMs: 160, isCurrent: true, checkedAt: Fixture.now, error: nil),
            ], deviceID: mac.id)
            try await db.saveEgressSamples([
                EgressSample(policyPath: ["DIRECT"], ip: "192.0.2.1", location: nil, network: nil, latencyMs: 3, isCurrent: true, checkedAt: Fixture.now, error: nil),
            ], deviceID: mini.id)

            let latest = try await db.latestEgress(deviceID: mac.id)
            #expect(latest.map(\.policyPath) == [["AI", "US-West"], ["DIRECT"]])
            #expect(latest.map(\.isCurrent) == [true, false])
            #expect(latest[0].ip == "2001:db8::42" && latest[0].latencyMs == 160 && latest[0].error == nil)
            #expect(latest[1].latencyMs == 9)
            #expect(try await db.latestEgress(deviceID: UUID()).isEmpty)

            try await db.insertEgressChange(EgressChange(id: 0, changedAt: earlier, ip: "203.0.113.7", policyPath: ["DIRECT"], reason: "Surge restarted"), deviceID: mac.id)
            try await db.insertEgressChange(EgressChange(id: 0, changedAt: Fixture.now, ip: "2001:db8::42", policyPath: ["AI", "US-West"], reason: "策略组手动切换"), deviceID: mac.id)
            await #expect(throws: DatabaseError.self) {
                try await db.insertEgressChange(EgressChange(id: 0, changedAt: .now, ip: "nope", policyPath: [], reason: ""), deviceID: mac.id)
            }
            let changes = try await db.egressChanges(deviceID: mac.id, limit: 10)
            #expect(changes.map(\.reason) == ["策略组手动切换", "Surge restarted"])
            #expect(changes[0].ip == "2001:db8::42" && changes[0].policyPath == ["AI", "US-West"] && changes[0].id > 0)
            #expect(try await db.egressChanges(deviceID: mac.id, limit: 1).count == 1)
            #expect(try await db.egressChanges(deviceID: mini.id, limit: 10).isEmpty)
        }
    }

    // MARK: - Harness

    /// Runs `body` against a freshly migrated `tm_test_<8 hex>` schema and always drops it afterwards.
    private func withTestDatabase(_ body: (PostgresDatabase) async throws -> Void) async throws {
        let url = try #require(Self.databaseURL)
        let schema = "tm_test_" + String(format: "%08x", UInt32.random(in: .min ... .max))
        let db = PostgresDatabase(url: url, schema: schema)
        try await db.connect()

        var failure: (any Error)?
        do {
            try await db.migrate()
            try await body(db)
        } catch {
            failure = error
        }

        var dropError: (any Error)?
        for _ in 0..<3 {
            do {
                try await Self.dropTestSchema(db)
                dropError = nil
                break
            } catch {
                dropError = error
            }
        }
        let leftover = try await db.rows("SELECT count(*) AS n FROM pg_namespace WHERE nspname = \(schema)")
            .first.map { try PostgresRowReader($0)("n", as: Int.self) }
        #expect(leftover == 0, "schema \(schema) was not dropped")
        await db.shutdown()

        if let failure { throw failure }
        if let dropError { throw dropError }
    }

    private static func dropTestSchema(_ db: PostgresDatabase) async throws {
        // Never drop anything but a throwaway test schema.
        precondition(db.schema.hasPrefix("tm_test_") && PostgresDatabase.isValidSchemaName(db.schema))
        try await db.execute(PostgresQuery(unsafeSQL: "DROP SCHEMA IF EXISTS \(db.quotedSchema) CASCADE"))
    }
}

/// `TIDEMARK_TEST_DATABASE_URL`, or nil when unset (the suite is then skipped).
private let liveDatabaseURL: String? = {
    let value = ProcessInfo.processInfo.environment["TIDEMARK_TEST_DATABASE_URL"]?.trimmingCharacters(in: .whitespaces)
    return value?.isEmpty == false ? value : nil
}()

/// PostgresNIO declares a `PostgresDatabase` protocol too; this file imports both modules.
private typealias PostgresDatabase = Tidemark.PostgresDatabase

/// Test data builders. Times are whole milliseconds so they survive PostgreSQL's microsecond precision.
private enum Fixture {
    static let now = Date(timeIntervalSince1970: (Date.now.timeIntervalSince1970 * 1_000).rounded() / 1_000)
    static let session: Int64 = 1_761_300_000_000

    static func close(_ a: Date, _ b: Date) -> Bool { abs(a.timeIntervalSince(b)) < 0.001 }

    static func device(_ name: String) -> Device {
        Device(id: UUID(), name: name, model: nil, shortName: Device.shortName(for: name), hue: 240, isRemoteSurge: false,
               rowCount: 0, lastWriteAt: nil, createdAt: now)
    }

    static func app(_ name: String, path: String) -> MonitoredApp {
        MonitoredApp(id: UUID(), name: name, path: path, bundleID: nil, tileLetter: String(name.prefix(1)), tileHue: 210.5,
                     includeChildren: true, alertRule: .anyHost, alertNewIP: true, archivedAt: nil, createdAt: now)
    }

    static func request(device: DeviceID, id: Int64, host: String = "api.github.com") -> RequestRecord {
        RequestRecord(
            key: RequestKey(deviceID: device, session: session, surgeID: id), rowID: nil, startedAt: now.addingTimeInterval(-1),
            setupCompletedAt: nil, completedAt: nil, method: "HTTPS", host: host, port: nil, url: nil, remoteIP: nil, remoteAddress: nil,
            geo: nil, policyPath: [], rule: nil, state: .active, inBytes: 0, outBytes: 0, pid: nil, processPath: nil, bundlePath: nil,
            chain: [], appID: nil, localAddress: nil, interface: nil, notes: [], isNew: false, writtenAt: nil, probeSessionID: nil
        )
    }

    static func host(app: AppID, _ value: String, kind: HostKind = .domain, firstSeen: Date = now) -> AppHost {
        AppHost(appID: app, kind: kind, value: value, site: kind == .domain ? NaiveSiteClassifier().site(for: value) : nil,
                firstSeen: firstSeen, lastSeen: firstSeen, requestCount: 1, processName: "proc", policy: nil, geo: nil,
                isDirect: false, hosts: [])
    }

    static func source(_ kind: HostKind, _ value: String, device: DeviceID, app: AppID?, path: String = "/usr/bin/curl", title: String = "curl") -> HostSourceTouch {
        HostSourceTouch(kind: kind, value: value, deviceID: device, sourcePath: path, sourceTitle: title, appID: app,
                        bundlePath: nil, seenAt: now, requestDelta: 1, geo: nil)
    }

    static func alert(device: DeviceID, app: AppID, value: String) -> AlertItem {
        AlertItem(id: 0, deviceID: device, appID: app, kind: .domain, scope: .site, value: value, site: NaiveSiteClassifier().site(for: value),
                  host: value, ip: nil, geo: nil, processName: "node", isDirect: false, requestRowID: nil, createdAt: now, readAt: nil)
    }
}
