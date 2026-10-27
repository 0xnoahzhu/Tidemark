import Foundation
import NIOCore
import Testing
@testable import Tidemark

/// Database logic that needs no server: URL parsing, statement splitting, SQL helpers, error paths.
struct DatabaseUnitTests {
    @Test func parsesConnectionURLs() throws {
        let full = try PostgresConnectionURL("postgresql://tide:p%40ss%2Fw@[::1]:5433/tidemark?sslmode=verify-full")
        #expect(full.host == "::1")
        #expect(full.port == 5433)
        #expect(full.username == "tide")
        #expect(full.password == "p@ss/w")
        #expect(full.database == "tidemark")
        #expect(full.tls == .verifyFull)
        #expect(full.redacted == "[::1]:5433/tidemark")

        let minimal = try PostgresConnectionURL("postgres://db.local")
        #expect(minimal.host == "db.local")
        #expect(minimal.port == 5432)
        #expect(minimal.password == nil)
        #expect(minimal.database == nil)
        #expect(minimal.rootCertificatePath == nil)
        #expect(!minimal.username.isEmpty)

        let socket = try PostgresConnectionURL("postgres://me@/tidemark?host=/tmp")
        #expect(socket.socketPath == "/tmp/.s.PGSQL.5432")
        #expect(socket.tls == .disable)

        #expect(try PostgresConnectionURL("postgres://h/d?sslmode=require").tls == .require)
        #expect(try PostgresConnectionURL("postgres://h/d?sslmode=prefer").tls == .prefer)
        #expect(try PostgresConnectionURL("postgres://h/d?sslmode=allow").tls == .disable)
        #expect(try PostgresConnectionURL("postgres://h/d?sslmode=disable").tls == .disable)
    }

    @Test func defaultsToTLSWhenTrafficLeavesTheMac() throws {
        // libpq's `prefer`: TLS whenever the server offers it…
        for url in ["postgres://db.local", "postgres://10.1.2.52:5455/tidemark", "postgres://[2001:db8::5]/t", "postgres://db.example.com/t"] {
            #expect(try PostgresConnectionURL(url).tls == .prefer, "\(url)")
        }
        // …except on this Mac, where nothing crosses the network.
        for url in ["postgres://localhost/t", "postgres://127.0.0.1:15455/t", "postgres://[::1]/t", "postgres://u@/t?host=/tmp", "postgres:///t"] {
            #expect(try PostgresConnectionURL(url).tls == .disable, "\(url)")
        }
    }

    @Test func honoursLibpqQueryParameters() throws {
        let url = try PostgresConnectionURL("postgresql://db.local?user=tide&password=p%40ss&dbname=tidemark&port=5433&application_name=x")
        #expect(url.username == "tide")
        #expect(url.password == "p@ss")
        #expect(url.database == "tidemark")
        #expect(url.port == 5433)
        // The URL's own parts win over query parameters.
        let both = try PostgresConnectionURL("postgresql://me:mine@db.local:6000/main?user=tide&password=other&dbname=x&port=1")
        #expect(both.username == "me" && both.password == "mine" && both.database == "main" && both.port == 6000)
        #expect(throws: DatabaseError.self) { try PostgresConnectionURL("postgres://h/d?port=abc") }

        // A private CA: `require` with a root certificate verifies the chain, as in libpq.
        let privateCA = try PostgresConnectionURL("postgres://db.local/t?sslmode=require&sslrootcert=/etc/ssl/tidemark-ca.pem")
        #expect(privateCA.tls == .verifyCA)
        #expect(privateCA.rootCertificatePath == "/etc/ssl/tidemark-ca.pem")
        #expect(try PostgresConnectionURL("postgres://db.local/t?sslmode=verify-full&sslrootcert=/ca.pem").tls == .verifyFull)
        let system = try PostgresConnectionURL("postgres://db.example.com/t?sslrootcert=system")
        #expect(system.tls == .verifyFull && system.rootCertificatePath == nil)
    }

    @Test func rejectsInvalidURLsWithoutLeakingPasswords() {
        for url in ["mysql://u:secret@h/d", "postgres://u:secret@h/d?sslmode=bogus", "postgres://u:secret@h:99999/d", "not a url",
                    "postgres://h/d?password=secret&sslmode=bogus", "postgres://h/d?sslmode=bogus&SSLPassword=secret"] {
            #expect(throws: DatabaseError.self) { try PostgresConnectionURL(url) }
            do {
                _ = try PostgresConnectionURL(url)
            } catch {
                #expect(!error.localizedDescription.contains("secret"))
            }
        }
        #expect(!PostgresConnectionURL.redact("postgres://h/d?password=secret").contains("secret"))
        // Text that is not a PostgreSQL URL may hold a password anywhere before its last "@", or after a keyword.
        for text in ["tide:secret@db/tidemark", "mysql://u:se@secret@h/d", "postgres://u:a/b@secret@h/d", "postgres://u:a/b@h/d?PASSWORD=secret",
                     "host=db password=secret", "postgres://u:%zz@h/d?Password=secret"] {
            #expect(!PostgresConnectionURL.redact(text).contains("secret"), "\(text)")
        }
        #expect(PostgresConnectionURL.redact("mysql://u:se@secret@h/d") == "mysql://…@h/d")
        #expect(PostgresConnectionURL.redact("tide:secret@db/tidemark") == "…@db/tidemark")
        #expect(PostgresConnectionURL.redact("postgres://tide:secret@h/d?sslmode=bogus") == "postgres://tide:•••@h/d?sslmode=bogus")
        #expect(PostgresConnectionURL.redact("postgres://h/d?password=secret&sslmode=bogus") == "postgres://h/d?password=•••&sslmode=bogus")
        #expect(PostgresConnectionURL.redact("postgres://h/d?sslmode=bad&sslpassword=secret") == "postgres://h/d?sslmode=bad&sslpassword=•••")
    }

    @Test func classifiesServerErrorsByWhetherARetryCanSucceed() {
        // May succeed later: keep the data and retry.
        for state in ["08006", "08P01", "28P01", "3D000", "3F000", "53100", "53200", "53300", "57014", "57P01", "57P03", "58030",
                      "40001", "40P01", "25006", "25P03", "55P03", "55006", "42501", "XX000", "F0000", "72000"] {
            #expect(PostgresDatabase.isTransient(sqlState: state), "\(state)")
        }
        // The statement or its data is wrong: retrying the same rows fails again.
        for state in ["22001", "22P02", "23503", "23505", "23514", "42601", "42703", "42P01", "54000", "40002", "25001", "0A000", "55000", ""] {
            #expect(!PostgresDatabase.isTransient(sqlState: state), "\(state)")
        }
    }

    /// A 57014 is the statement timeout when an English server says so, or, when the server translates its
    /// messages, when the call ran at least as long as its statement timeout.
    @Test func tellsAStatementTimeoutFromAnotherCancel() {
        let timeout = Duration.seconds(30)
        #expect(PostgresDatabase.isStatementTimeout(message: "canceling statement due to statement timeout", statementTimeout: nil, ranFor: nil))
        #expect(PostgresDatabase.isStatementTimeout(message: "canceling statement due to statement timeout", statementTimeout: timeout, ranFor: .seconds(1)))
        for message in ["canceling statement due to user request", "canceling statement due to conflict with recovery"] {
            #expect(!PostgresDatabase.isStatementTimeout(message: message, statementTimeout: timeout, ranFor: .seconds(40)), "\(message)")
        }

        // A server whose lc_messages is, say, de_DE or zh_CN.
        let translated = "<the server's message in its own language>"
        #expect(PostgresDatabase.isStatementTimeout(message: translated, statementTimeout: timeout, ranFor: .seconds(30)))
        #expect(PostgresDatabase.isStatementTimeout(message: translated, statementTimeout: timeout, ranFor: .seconds(31)))
        #expect(!PostgresDatabase.isStatementTimeout(message: translated, statementTimeout: timeout, ranFor: .seconds(12)))
        #expect(!PostgresDatabase.isStatementTimeout(message: translated, statementTimeout: nil, ranFor: .seconds(600)))
        #expect(!PostgresDatabase.isStatementTimeout(message: translated, statementTimeout: timeout, ranFor: nil))
        #expect(!PostgresDatabase.isStatementTimeout(message: nil, statementTimeout: timeout, ranFor: .seconds(1)))
    }

    @Test func mapsClientSideErrors() {
        #expect(PostgresDatabase.map(CancellationError()) is CancellationError)
        #expect(PostgresDatabase.map(DatabaseError.query("x")) as? DatabaseError == .query("x"))
        #expect(PostgresDatabase.map(IOError(errnoCode: ECONNRESET, reason: "read")) as? DatabaseError == .unreachable("Connection reset by peer"))
        let encoding = EncodingError.invalidValue(Double.nan, .init(codingPath: [], debugDescription: "NaN"))
        guard case .query = PostgresDatabase.map(encoding) as? DatabaseError else {
            Issue.record("An encoding failure is the data's fault")
            return
        }
        struct Unknown: Error {}
        guard case .unreachable = PostgresDatabase.map(Unknown()) as? DatabaseError else {
            Issue.record("Unknown failures keep the data")
            return
        }
    }

    /// Causes Tidemark recognizes are typed so the UI can translate them; the log keeps the English wording.
    @Test func describesConnectionFailuresWithTypedReasons() throws {
        let lan = try PostgresConnectionURL("postgres://tide@192.168.1.20:5432/tidemark")
        let blocked = IOError(errnoCode: EHOSTUNREACH, reason: "connect")
        #expect(PostgresDatabase.describe(blocked, endpoint: lan) == .localNetworkBlocked)
        #expect(PostgresDatabase.describe(blocked, endpoint: nil) == .message("No route to host"), "only a LAN address hints at Local Network privacy")
        #expect(PostgresDatabase.map(ChannelError.connectTimeout(.seconds(5)), endpoint: lan) as? DatabaseError
                == .unreachable(.connectTimedOut(target: "192.168.1.20:5432/tidemark")))
        #expect(PostgresDatabase.describe(ChannelError.connectTimeout(.seconds(5)), endpoint: nil) == .connectTimedOut(target: nil))
        // A reason that is already typed passes through.
        #expect(PostgresDatabase.describe(DatabaseError.unreachable(.migrationInProgress), endpoint: lan) == .migrationInProgress)

        #expect(DatabaseError.unreachable(.passwordRequired(target: "db.local:5432/t")).errorDescription
                == "PostgreSQL is unreachable: db.local:5432/t requires a password.")
        #expect(DatabaseError.unreachable(.cannotConnect(target: nil, reason: "Connection refused")).errorDescription
                == "PostgreSQL is unreachable: Could not connect to the server: Connection refused")
        #expect(DatabaseError.unreachable(.noConnection(target: "db.local:5432/t", within: .seconds(10))).errorDescription
                == "PostgreSQL is unreachable: No connection to db.local:5432/t within 10 s.")
        #expect(DatabaseError.unreachable(.schemaTooNew(schema: 5, supported: 3)).errorDescription?.hasSuffix("Update Tidemark on this Mac.") == true)
    }

    @Test func requestQueryTimeWindow() {
        let now = Date(timeIntervalSince1970: 1_761_300_000)
        #expect(PostgresDatabase.TimeWindow(RequestQuery(range: .last24Hours), now: now).lower == now.addingTimeInterval(-86_400))
        #expect(PostgresDatabase.TimeWindow(RequestQuery(range: .all), now: now) == .init(lower: nil))
    }

    /// An IP filter compares the stored address (`requests_remote_ip_started_idx`); a value that is no IP finds nothing
    /// rather than failing the cast.
    @Test func filtersOnTheAddressARequestReached() {
        func filters(_ query: RequestQuery) -> String {
            var sql = PostgresDatabase.SQL("SELECT 1 FROM requests r")
            PostgresDatabase.appendFilters(query, window: .init(lower: nil), to: &sql)
            return sql.text
        }
        #expect(filters(RequestQuery(range: .all, remoteIP: "[2001:DB8::1]")) == "SELECT 1 FROM requests r WHERE r.remote_ip = $1::inet")
        #expect(filters(RequestQuery(range: .all, remoteIP: "api2.cursor.sh")) == "SELECT 1 FROM requests r WHERE false")
    }

    @Test func poolsCarrySessionLimits() {
        let main = Dictionary(uniqueKeysWithValues: PostgresDatabase.SessionLimits.main.parameters)
        let writer = Dictionary(uniqueKeysWithValues: PostgresDatabase.SessionLimits.writer.parameters)
        for limits in [main, writer] {
            #expect(Set(limits.keys) == ["statement_timeout", "lock_timeout", "idle_in_transaction_session_timeout"])
        }
        #expect(main == ["statement_timeout": "30s", "lock_timeout": "10s", "idle_in_transaction_session_timeout": "60s"])
        #expect(writer == ["statement_timeout": "15s", "lock_timeout": "5s", "idle_in_transaction_session_timeout": "15s"])
        // The server cancels a write before capture gives up on it (20 s per write).
        #expect(PostgresDatabase.SessionLimits.writer.statement < .seconds(20))
        #expect(PostgresDatabase.sessionCloseTimeout < .seconds(20))
        #expect(PostgresDatabase.mainPoolSize + PostgresDatabase.writerPoolSize == 8)
    }

    @Test func formatsDurationsForTheServerAndForMessages() {
        #expect(PostgresDatabase.setting(.seconds(600)) == "600s")
        #expect(PostgresDatabase.setting(.milliseconds(50)) == "50ms")
        #expect(PostgresDatabase.setting(.milliseconds(1_500)) == "1500ms")
        #expect(DatabaseError.spoken(.milliseconds(50)) == "50 ms")
        #expect(DatabaseError.spoken(.seconds(30)) == "30 s")
        #expect(DatabaseError.spoken(.seconds(300)) == "5 min")
        #expect(DatabaseError.timedOut(.statement(.seconds(300))).errorDescription
                == "PostgreSQL query timed out: The server cancelled it after 5 min (statement timeout).")
        #expect(DatabaseError.timedOut(.statement(nil)).errorDescription == "PostgreSQL query timed out: The server cancelled it at its statement timeout.")
        #expect(DatabaseError.timedOut(.noReply(target: "db.local:5432/t", within: .seconds(35))).errorDescription
                == "PostgreSQL query timed out: No reply from db.local:5432/t within 35 s; the connection was closed.")
    }

    @Test func callLimitsLeaveTheServerTimeToAnswerFirst() {
        typealias Limit = PostgresDatabase.CallLimit
        #expect(Limit.pool.duration(on: .writer) == .seconds(35))
        #expect(Limit.pool.duration(on: .main) == .seconds(65))
        #expect(Limit.statement(.seconds(300)).duration(on: .main) == .seconds(605))
        #expect(Limit.client(.seconds(2)).duration(on: .writer) == .seconds(2))
        #expect(Limit.pool.statementTimeout(on: .writer) == .seconds(15))
        #expect(Limit.statement(.seconds(300)).statementTimeout(on: .main) == .seconds(300))
        #expect(Limit.client(.seconds(2)).statementTimeout(on: .main) == nil)
        // Index builds may take hours; their limit only frees a connection the server can no longer answer on.
        #expect(PostgresDatabase.indexPassLimit >= .seconds(3 * 3_600))
    }

    @Test func invalidURLSurfacesOnConnect() async {
        let database = PostgresDatabase(url: "http://example.com")
        await #expect(throws: DatabaseError.self) { try await database.connect() }
        let badSchema = PostgresDatabase(url: "postgres://localhost/db", schema: "Bad-Name")
        await #expect(throws: DatabaseError.invalidURL("schema \"Bad-Name\"")) { try await badSchema.connect() }
    }

    @Test func callsBeforeConnectFailAsUnreachable() async {
        let database = PostgresDatabase(url: "postgres://localhost/db")
        await #expect(throws: DatabaseError.unreachable(.notConnected)) { _ = try await database.devices() }
    }

    @Test func unreachableServerFailsWithinDeadline() async throws {
        // Port 9 (discard) is closed on macOS: every attempt is refused until the ~5 s deadline.
        let database = PostgresDatabase(url: "postgres://tidemark@127.0.0.1:9/tidemark")
        let clock = ContinuousClock()
        let start = clock.now
        do {
            try await database.connect()
            Issue.record("connect() unexpectedly succeeded")
        } catch let error as DatabaseError {
            guard case .unreachable(let reason) = error else {
                Issue.record("Expected .unreachable, got \(error)")
                return
            }
            #expect(reason.description.lowercased().contains("refused"))
        }
        #expect(start.duration(to: clock.now) < .seconds(9))
        await database.shutdown()
    }

    @Test func splitsMigrationScripts() {
        let script = """
            -- comment; with a semicolon
            CREATE TABLE a (x text DEFAULT 'semi;colon', "odd;name" int);
            /* block; /* nested; */ still comment; */
            INSERT INTO a (x) VALUES ('it''s; fine'), (E'back\\'slash;');
            CREATE FUNCTION f() RETURNS int AS $body$ SELECT 1; $body$ LANGUAGE sql;
            DO $$ BEGIN PERFORM 1; END $$;
            SELECT $1::int;
            -- trailing comment only
            """
        let statements = Schema.statements(in: script)
        #expect(statements.count == 5)
        #expect(statements[0].hasPrefix("-- comment; with a semicolon\nCREATE TABLE a"))
        #expect(statements[1].contains("'it''s; fine'"))
        #expect(statements[1].contains("(E'back\\'slash;')"))
        #expect(statements[2].hasSuffix("LANGUAGE sql"))
        #expect(statements[3] == "DO $$ BEGIN PERFORM 1; END $$")
        #expect(statements[4] == "SELECT $1::int")
    }

    @Test func schemaMigrationsSplitIntoSingleStatements() throws {
        #expect(Schema.migrations.map(\.version) == Array(1...Schema.latestVersion))
        for migration in Schema.migrations {
            #expect(Schema.statements(in: migration.sql).allSatisfy { !$0.isEmpty })
        }
        let v1 = Schema.statements(in: Schema.migrations[0].sql)
        #expect(v1.count > 10)
        #expect(v1.first == "CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public")
        #expect(Schema.statements(in: Schema.bootstrap).count == 1)

        // From v2 on a migration may run again after an interruption: every statement is idempotent,
        // and indexes on the request log are built concurrently.
        let v2 = try #require(Schema.migrations.first { $0.version == 2 })
        let statements = Schema.statements(in: v2.sql)
        #expect(statements.count == 4)
        for statement in statements {
            #expect(statement.contains("IF NOT EXISTS") || statement.contains("SET (fillfactor"), "\(statement)")
            #expect(!statement.uppercased().contains("CREATE INDEX") && !statement.uppercased().contains("DROP INDEX"), "\(statement)")
        }
        #expect(v2.requiresVersion == 1)
        #expect(v2.concurrentSteps.contains(.dropIndex(name: "requests_updated_idx")))
        #expect(v2.concurrentSteps.contains { step in
            if case .createIndex(let name, "requests", let definition) = step { return name == "requests_search_trgm_idx" && definition.contains(Schema.requestSearchText) }
            return false
        })

        // v3 only adds index changes: every older build keeps writing.
        let v3 = try #require(Schema.migrations.first { $0.version == 3 })
        #expect(Schema.statements(in: v3.sql).isEmpty)
        #expect(v3.requiresVersion == 1)
        #expect(v3.concurrentSteps == [
            .createIndex(name: "requests_active_idx", table: "requests", definition: "(device_id, surge_session) WHERE state = 'active'"),
            .enableAutosummarize(index: "requests_updated_brin_idx"),
        ])

        // v4 only adds: nullable columns without a default (no table rewrite, no GENERATED column), new tables, and
        // indexes built concurrently. Every older build keeps writing.
        let v4 = try #require(Schema.migrations.first { $0.version == 4 })
        let v4Statements = Schema.statements(in: v4.sql)
        #expect(v4Statements.count == 3)
        #expect(v4Statements[0].hasPrefix("ALTER TABLE requests"), "the requests lock comes before the new tables lock devices")
        for statement in v4Statements {
            let upper = statement.uppercased()
            #expect(upper.contains("IF NOT EXISTS"), "\(statement)")
            #expect(!upper.contains("CREATE INDEX") && !upper.contains("DROP ") && !upper.contains("GENERATED") && !upper.contains("ALTER COLUMN"), "\(statement)")
        }
        let added = v4Statements[0].components(separatedBy: "ADD COLUMN IF NOT EXISTS").dropFirst()
        #expect(added.count == 7 && added.allSatisfy { !$0.uppercased().contains("DEFAULT") && !$0.uppercased().contains("NOT NULL") })
        #expect(v4.requiresVersion == 1)
        #expect(v4.concurrentSteps.map(\.indexName) == ["requests_host_started_idx", "requests_remote_ip_started_idx", "dns_answers_domain_idx",
                                                         "proxy_errors_target_idx", "requests_ended_error_idx"])
        // The partial index serves `RequestQuery.endedWithError` only while its predicate is the query's condition.
        guard case .createIndex(_, "requests", let errorIndex)? = v4.concurrentSteps.last else { Issue.record("no index of errors"); return }
        let condition = PostgresDatabase.endedWithErrorCondition.dropFirst().dropLast().replacingOccurrences(of: "r.", with: "")
        #expect(errorIndex == "(started_at DESC) WHERE " + condition)
        // v5 creates one table, which older builds never write, and copies into it in batches outside its transaction
        // (the new table's foreign keys lock `devices` and `apps` until it commits).
        let v5 = try #require(Schema.migrations.first { $0.version == 5 })
        let v5Statements = Schema.statements(in: v5.sql)
        #expect(v5Statements.count == 1 && v5Statements[0].hasPrefix("CREATE TABLE IF NOT EXISTS app_host_sources"))
        #expect(v5Statements[0].contains("PRIMARY KEY (app_id, kind, value, device_id, source_path)"))
        #expect(v5Statements[0].contains("REFERENCES apps(id) ON DELETE CASCADE") && v5Statements[0].contains("REFERENCES devices(id) ON DELETE CASCADE"))
        #expect(v5.requiresVersion == 1 && v5.concurrentSteps.isEmpty)
        let backfill = try #require(v5.backfill)
        #expect(backfill.key == ["kind", "value", "device_id", "source_path"] && backfill.start.count == backfill.key.count)
        #expect(backfill.batch.contains("ON CONFLICT (app_id, kind, value, device_id, source_path) DO NOTHING"))
        #expect(backfill.batch.contains("(s.kind, s.value, s.device_id, s.source_path) > ($1::text, $2::text, $3::uuid, $4::text)"))
        #expect(backfill.batch.contains("LIMIT $5") && backfill.batchSize == 10_000)
        #expect(Schema.statements(in: backfill.batch).count == 1 && Schema.statements(in: backfill.resume).count == 1)
        #expect(Schema.migrations.allSatisfy { $0.version == 5 || $0.backfill == nil })
        // Shipped migrations never change.
        #expect(Schema.migrations.map(\.name) == ["initial", "write path and egress details", "active requests and brin autosummarize",
                                                  "request details, dns answers and proxy errors", "host sources per app"])
    }

    @Test func indexStepsFollowTheCatalog() {
        let valid = Schema.IndexState(valid: true, options: [])
        // Migrations v1 to v3 (v4's steps are checked below).
        let all = Array(Schema.migrations.prefix(3))
        let v1Indexes = ["requests_updated_idx", "requests_host_idx", "requests_host_trgm_idx", "requests_remote_ip_idx",
                         "host_sources_last_seen_idx", "requests_started_idx"]
        let v1Catalog = Dictionary(uniqueKeysWithValues: v1Indexes.map { ($0, valid) })

        // A v1 schema gets every step of v2 and v3, in order.
        #expect(Schema.pendingSteps(of: all, catalog: v1Catalog) == all[1].concurrentSteps + all[2].concurrentSteps)

        // A finished v2 schema only gets v3's.
        var v2Catalog: [String: Schema.IndexState] = [
            "requests_started_idx": valid, "requests_search_trgm_idx": valid,
            "requests_updated_brin_idx": Schema.IndexState(valid: true, options: ["pages_per_range=16"]),
        ]
        #expect(Schema.pendingSteps(of: all, catalog: v2Catalog) == all[2].concurrentSteps)
        #expect(Schema.pendingSteps(of: Array(all.prefix(2)), catalog: v2Catalog).isEmpty)

        // Everything in effect: nothing to do.
        v2Catalog["requests_active_idx"] = valid
        v2Catalog["requests_updated_brin_idx"]?.options.append("autosummarize=on")
        #expect(Schema.pendingSteps(of: all, catalog: v2Catalog).isEmpty)

        // An invalid leftover is built again; a BRIN index rebuilt here gets autosummarize again.
        var broken = v2Catalog
        broken["requests_active_idx"] = Schema.IndexState(valid: false, options: [])
        #expect(Schema.pendingSteps(of: all, catalog: broken) == [all[2].concurrentSteps[0]])
        broken["requests_updated_brin_idx"] = nil
        #expect(Schema.pendingSteps(of: all, catalog: broken) == [
            .createIndex(name: "requests_updated_brin_idx", table: "requests", definition: "USING brin (updated_at) WITH (pages_per_range = 16)"),
            all[2].concurrentSteps[0],
            .enableAutosummarize(index: "requests_updated_brin_idx"),
        ])

        // An index a later migration drops again is never built, and only dropped while it exists.
        let later = Schema.Migration(version: 99, name: "test", sql: "", concurrentSteps: [.dropIndex(name: "requests_active_idx")])
        let withoutActive = v2Catalog.filter { $0.key != "requests_active_idx" }
        #expect(!Schema.pendingSteps(of: all + [later], catalog: withoutActive).contains { $0.indexName == "requests_active_idx" })
        #expect(Schema.pendingSteps(of: all + [later], catalog: v2Catalog) == [.dropIndex(name: "requests_active_idx")])

        // v4 on a finished v3 schema: its indexes, until they are in effect.
        let v4 = Schema.migrations[3]
        #expect(Schema.pendingSteps(of: all + [v4], catalog: v2Catalog) == v4.concurrentSteps)
        var v4Catalog = v2Catalog
        for step in v4.concurrentSteps { v4Catalog[step.indexName] = valid }
        #expect(Schema.pendingSteps(of: Schema.migrations, catalog: v4Catalog).isEmpty)
    }

    @Test func indexRetriesBackOff() {
        #expect(PostgresDatabase.indexRetryPause(after: 1) == .seconds(30))
        #expect(PostgresDatabase.indexRetryPause(after: 4) == .seconds(300))
        #expect(PostgresDatabase.indexRetryPause(after: 40) == .seconds(900))
    }

    @Test func escapesLikePatternsAndBundlePaths() {
        #expect(PostgresDatabase.containsPattern("50%_off\\") == "%50\\%\\_off\\\\%")
        let match = PostgresDatabase.bundleMatch("/Applications/My_App 100%.app//")
        #expect(match.paths == ["/Applications/My_App 100%.app", "/Applications/My_App 100%.app/"])
        #expect(match.pattern == "/Applications/My\\_App 100\\%.app/%")
    }

    @Test func normalizesInetValues() {
        #expect(PostgresDatabase.inetText("[2001:db8::1]") == "2001:db8::1")
        #expect(PostgresDatabase.inetText("fe80::1%en0") == "fe80::1")
        #expect(PostgresDatabase.inetText(" 10.0.0.1 ") == "10.0.0.1")
        #expect(PostgresDatabase.inetText("23.254.139.175 (Proxy)") == nil)
        #expect(PostgresDatabase.inetText(nil) == nil)
    }

    @Test func chunksStayUnderTheBindLimit() {
        let items = Array(0..<5_000)
        let chunks = PostgresDatabase.chunks(items, bindsPerItem: 33)
        #expect(chunks.allSatisfy { $0.count * 33 <= PostgresDatabase.maxBinds })
        #expect(chunks.reduce(0) { $0 + $1.count } == 5_000)
        #expect(PostgresDatabase.chunks(items, bindsPerItem: 40_000).allSatisfy { $0.count == 1 })
    }

    @Test func readsPlannerEstimates() {
        let json = #"[{"Plan": {"Node Type": "Seq Scan", "Plan Rows": 123456, "Plan Width": 0}}]"#
        #expect(PostgresDatabase.plannedRows(fromExplainJSON: json) == 123_456)
        #expect(PostgresDatabase.plannedRows(fromExplainJSON: "nonsense") == nil)
    }

    @Test func recognizesLocalNetworkHosts() {
        for host in ["10.1.2.52", "192.168.1.20", "172.20.0.5", "169.254.1.1", "nas.local", "fd12::1", "fe80::1"] {
            #expect(PostgresDatabase.isLocalNetworkHost(host), "\(host)")
        }
        for host in ["8.8.8.8", "172.32.0.1", "db.example.com", "fdic.gov", "2001:db8::1", "127.0.0.1"] {
            #expect(!PostgresDatabase.isLocalNetworkHost(host), "\(host)")
        }
    }

    @Test func validatesSchemaNames() {
        #expect(PostgresDatabase.isValidSchemaName("public"))
        #expect(PostgresDatabase.isValidSchemaName("tm_test_0a1b2c3d"))
        #expect(!PostgresDatabase.isValidSchemaName("Public"))
        #expect(!PostgresDatabase.isValidSchemaName("1abc"))
        #expect(!PostgresDatabase.isValidSchemaName("a;drop"))
        #expect(!PostgresDatabase.isValidSchemaName(""))
    }
}
