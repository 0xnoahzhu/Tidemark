import Foundation
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
        #expect(minimal.tls == .disable)
        #expect(!minimal.username.isEmpty)

        let socket = try PostgresConnectionURL("postgres://me@/tidemark?host=/tmp")
        #expect(socket.socketPath == "/tmp/.s.PGSQL.5432")

        #expect(try PostgresConnectionURL("postgres://h/d?sslmode=require").tls == .require)
        #expect(try PostgresConnectionURL("postgres://h/d?sslmode=prefer").tls == .prefer)
        #expect(try PostgresConnectionURL("postgres://h/d?sslmode=allow").tls == .disable)
    }

    @Test func rejectsInvalidURLsWithoutLeakingPasswords() {
        for url in ["mysql://u:secret@h/d", "postgres://u:secret@h/d?sslmode=bogus", "postgres://u:secret@h:99999/d", "not a url"] {
            #expect(throws: DatabaseError.self) { try PostgresConnectionURL(url) }
            do {
                _ = try PostgresConnectionURL(url)
            } catch {
                #expect(!error.localizedDescription.contains("secret"))
            }
        }
    }

    @Test func invalidURLSurfacesOnConnect() async {
        let database = PostgresDatabase(url: "http://example.com")
        await #expect(throws: DatabaseError.self) { try await database.connect() }
        let badSchema = PostgresDatabase(url: "postgres://localhost/db", schema: "Bad-Name")
        await #expect(throws: DatabaseError.invalidURL("schema \"Bad-Name\"")) { try await badSchema.connect() }
    }

    @Test func callsBeforeConnectFailAsUnreachable() async {
        let database = PostgresDatabase(url: "postgres://localhost/db")
        await #expect(throws: DatabaseError.unreachable("Not connected.")) { _ = try await database.devices() }
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
            guard case .unreachable(let message) = error else {
                Issue.record("Expected .unreachable, got \(error)")
                return
            }
            #expect(message.lowercased().contains("refused"))
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

    @Test func schemaMigrationsSplitIntoSingleStatements() {
        for migration in Schema.migrations {
            let statements = Schema.statements(in: migration.sql)
            #expect(statements.count > 10)
            #expect(statements.allSatisfy { !$0.isEmpty })
            #expect(statements.first == "CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public")
        }
        #expect(Schema.statements(in: Schema.bootstrap).count == 1)
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
