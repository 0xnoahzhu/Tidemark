import Foundation
import PostgresNIO

extension PostgresDatabase {
    /// Session-level advisory lock that serializes migrations across Macs (`"Tidemark"` in ASCII).
    static let migrationLockKey: Int64 = 0x5469_6465_6D61_726B
    /// How long `migrate()` waits for another Mac's migration before failing with `.unreachable` (the
    /// caller retries on its next connection attempt).
    static let migrationLockWait: Duration = .seconds(30)
    /// Lock wait of each DDL statement: short, so a migration waiting for a lock never queues every Mac's
    /// reads and writes of that table behind it. A timed-out migration is retried.
    static let migrationLockTimeout = "3s"
    /// Lock wait of a concurrent index build, which waits for older transactions without blocking anyone.
    static let concurrentIndexLockTimeout = "2min"
    /// Attempts per migration when it loses a lock wait, a deadlock or a serialization conflict.
    static let migrationAttempts = 5

    /// Creates the schema when needed, then applies every pending migration while holding an advisory
    /// lock, so several Macs starting at once migrate exactly once.
    ///
    /// Throws `.unreachable` when another Mac holds the migration lock for longer than
    /// `migrationLockWait`, or when a newer Tidemark applied a migration this build cannot write after
    /// (`Schema.Migration.requiresVersion`): writing resumes once this Mac runs a newer Tidemark.
    @discardableResult
    func migrate() async throws -> Int {
        try await migrate(upTo: nil)
    }

    /// `migrate()`, stopping after migration `target` (all pending ones when nil). Tests use it to build an
    /// older schema and upgrade it.
    @discardableResult
    func migrate(upTo target: Int?) async throws -> Int {
        let schema = schema
        let quotedSchema = quotedSchema
        return try await withConnection { connection in
            try await Self.acquireMigrationLock(on: connection)
            do {
                // Index builds on a large table can outlast the pool's statement timeout.
                try await connection.query("SET statement_timeout = 0", logger: Self.logger)
                let version = try await Self.applyMigrations(on: connection, schema: schema, quotedSchema: quotedSchema, upTo: target)
                // The lock and settings belong to this pooled session: restore them even if the caller was cancelled.
                try await withTaskCancellationShield {
                    try await Self.endMigrationSession(connection)
                }
                return version
            } catch {
                await withTaskCancellationShield {
                    do { try await Self.endMigrationSession(connection) } catch { try? await connection.close() }
                }
                throw error
            }
        }
    }

    /// Takes the migration lock, waiting at most `migrationLockWait` for another Mac to finish.
    private static func acquireMigrationLock(on connection: PostgresConnection) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: migrationLockWait)
        while true {
            let rows = try await connection.query("SELECT pg_try_advisory_lock(\(migrationLockKey)) AS locked", logger: logger).collect()
            if try rows.first.map({ try PostgresRowReader($0)("locked", as: Bool.self) }) == true { return }
            guard clock.now < deadline else {
                throw DatabaseError.unreachable("Another Mac is upgrading the database; Tidemark will try again shortly.")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// Puts the session back the way the pool configured it and releases the migration lock.
    private static func endMigrationSession(_ connection: PostgresConnection) async throws {
        for statement in ["RESET statement_timeout", "RESET lock_timeout", "RESET search_path"] {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
        try await connection.query("SELECT pg_advisory_unlock(\(migrationLockKey))", logger: logger)
    }

    private static func applyMigrations(on connection: PostgresConnection, schema: String, quotedSchema: String, upTo target: Int?) async throws -> Int {
        // Only create what is missing: a role without CREATE privilege can still use a migrated schema.
        let schemaExists: PostgresQuery = "SELECT EXISTS (SELECT 1 FROM pg_namespace WHERE nspname = \(schema)) AS present"
        if schema != "public", try await exists(schemaExists, on: connection) == false {
            try await connection.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA IF NOT EXISTS \(quotedSchema)"), logger: logger)
        }
        let bookkeeping: PostgresQuery = "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = \(schema) AND tablename = 'schema_migrations') AS present"
        if try await exists(bookkeeping, on: connection) == false {
            // The session's search_path starts with this schema, so the table is created there.
            for statement in Schema.statements(in: Schema.bootstrap) {
                try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
            }
        }

        // `requires_version` exists from v2 on; reading it through to_jsonb works on every version.
        var applied: [Int: Int?] = [:]
        let versions = try await connection.query(
            PostgresQuery(unsafeSQL: "SELECT m.version, (to_jsonb(m) ->> 'requires_version')::int4 AS requires FROM \(quotedSchema).schema_migrations m"),
            logger: logger
        ).collect()
        for row in versions {
            let read = PostgresRowReader(row)
            applied[try read("version", as: Int.self)] = try read("requires", as: Int?.self)
        }
        if let blocking = applied.filter({ $0.key > Schema.latestVersion }).compactMap({ $0.value }).max(), blocking > Schema.latestVersion {
            let newest = applied.keys.max() ?? blocking
            throw DatabaseError.unreachable(
                "The database was upgraded by a newer version of Tidemark (schema \(newest)); this version (schema \(Schema.latestVersion)) cannot write to it. Update Tidemark on this Mac."
            )
        }

        for migration in Schema.migrations where !applied.keys.contains(migration.version) && migration.version <= (target ?? .max) {
            var attempt = 1
            while true {
                do {
                    try await apply(migration, on: connection, schema: schema, quotedSchema: quotedSchema)
                    break
                } catch let error where attempt < migrationAttempts && isRetryableMigrationFailure(error) {
                    try await Task.sleep(for: .seconds(attempt))
                    attempt += 1
                }
            }
        }

        let latest = try await connection.query(PostgresQuery(unsafeSQL: "SELECT COALESCE(max(version), 0) AS version FROM \(quotedSchema).schema_migrations"), logger: logger).collect()
        return try latest.first.map { try PostgresRowReader($0)("version", as: Int.self) } ?? 0
    }

    /// A lost lock wait (`55P03`), deadlock or serialization conflict: the migration can simply run again.
    private static func isRetryableMigrationFailure(_ error: any Error) -> Bool {
        guard let state = sqlState(of: error) else { return false }
        return state == "55P03" || state == "40P01" || state == "40001"
    }

    /// Runs the migration's transaction, then its concurrent index steps, then records it.
    private static func apply(_ migration: Schema.Migration, on connection: PostgresConnection, schema: String, quotedSchema: String) async throws {
        let searchPath = try await migrationSearchPath(on: connection, schema: schema, quotedSchema: quotedSchema)
        let record = recordStatement(migration, quotedSchema: quotedSchema)

        try await connection.query("BEGIN", logger: logger)
        do {
            try await connection.query(PostgresQuery(unsafeSQL: "SET LOCAL search_path TO \(searchPath)"), logger: logger)
            try await connection.query(PostgresQuery(unsafeSQL: "SET LOCAL lock_timeout = '\(migrationLockTimeout)'"), logger: logger)
            for statement in Schema.statements(in: migration.sql) {
                try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
            }
            if migration.concurrentSteps.isEmpty { try await connection.query(record, logger: logger) }
            try await connection.query("COMMIT", logger: logger)
        } catch {
            await rollback(connection)
            throw error
        }
        guard !migration.concurrentSteps.isEmpty else { return }

        // Session settings, reset by `endMigrationSession`.
        try await connection.query(PostgresQuery(unsafeSQL: "SET search_path TO \(searchPath)"), logger: logger)
        try await connection.query(PostgresQuery(unsafeSQL: "SET lock_timeout = '\(concurrentIndexLockTimeout)'"), logger: logger)
        for step in migration.concurrentSteps {
            try await run(step, on: connection, schema: schema, quotedSchema: quotedSchema)
        }
        try await connection.query(record, logger: logger)
    }

    /// Runs one concurrent step. Index names are schema-qualified: with `search_path = <test schema>, public`
    /// an unqualified `DROP INDEX IF EXISTS` would fall through to the production schema.
    private static func run(_ step: Schema.ConcurrentStep, on connection: PostgresConnection, schema: String, quotedSchema: String) async throws {
        switch step {
        case .createIndex(let name, let table, let definition):
            let valid = try await connection.query("""
                SELECT i.indisvalid AS valid FROM pg_index i
                JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
                WHERE n.nspname = \(schema) AND c.relname = \(name)
                """, logger: logger).collect().first.map { try PostgresRowReader($0)("valid", as: Bool.self) }
            if valid == false {
                try await connection.query(PostgresQuery(unsafeSQL: "DROP INDEX CONCURRENTLY IF EXISTS \(quotedSchema).\(quoteIdentifier(name))"), logger: logger)
            }
            try await connection.query(
                PostgresQuery(unsafeSQL: "CREATE INDEX CONCURRENTLY IF NOT EXISTS \(quoteIdentifier(name)) ON \(quotedSchema).\(quoteIdentifier(table)) \(definition)"),
                logger: logger
            )
        case .dropIndex(let name):
            try await connection.query(PostgresQuery(unsafeSQL: "DROP INDEX CONCURRENTLY IF EXISTS \(quotedSchema).\(quoteIdentifier(name))"), logger: logger)
        }
    }

    /// `<schema>[, <pg_trgm schema>], public`. pg_trgm may already live in another schema (installed by an
    /// administrator); its operator classes must stay resolvable for trigram indexes.
    private static func migrationSearchPath(on connection: PostgresConnection, schema: String, quotedSchema: String) async throws -> String {
        let extensionSchema = try await connection.query(
            "SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_trgm'",
            logger: logger
        ).collect().first.map { try PostgresRowReader($0)("nspname", as: String.self) }
        var path = [quotedSchema]
        if let extensionSchema, extensionSchema != schema, extensionSchema != "public" {
            path.append(quoteIdentifier(extensionSchema))
        }
        path.append("public")
        return path.joined(separator: ", ")
    }

    private static func recordStatement(_ migration: Schema.Migration, quotedSchema: String) -> PostgresQuery {
        let table = "\(quotedSchema).schema_migrations"
        if let requires = migration.requiresVersion {
            return "INSERT INTO \(unescaped: table) (version, name, requires_version) VALUES (\(migration.version), \(migration.name), \(requires)) ON CONFLICT (version) DO NOTHING"
        }
        return "INSERT INTO \(unescaped: table) (version, name) VALUES (\(migration.version), \(migration.name)) ON CONFLICT (version) DO NOTHING"
    }

    private static func exists(_ query: PostgresQuery, on connection: PostgresConnection) async throws -> Bool {
        try await connection.query(query, logger: logger).collect().first.map { try PostgresRowReader($0)("present", as: Bool.self) } ?? false
    }

    /// Highest applied migration in this schema, 0 when the schema was never migrated.
    func schemaVersion() async throws -> Int {
        let schema = schema
        let quotedSchema = quotedSchema
        return try await withConnection { connection in
            let exists = try await connection.query(
                "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = \(schema) AND tablename = 'schema_migrations') AS present",
                logger: Self.logger
            ).collect()
            guard try exists.first.map({ try PostgresRowReader($0)("present", as: Bool.self) }) == true else { return 0 }
            let rows = try await connection.query(
                PostgresQuery(unsafeSQL: "SELECT COALESCE(max(version), 0) AS version FROM \(quotedSchema).schema_migrations"),
                logger: Self.logger
            ).collect()
            return try rows.first.map { try PostgresRowReader($0)("version", as: Int.self) } ?? 0
        }
    }

    /// Tidemark's tables in this schema, largest first (`schema_migrations` is bookkeeping and omitted).
    func tableNames() async throws -> [String] {
        let rows = try await rows("""
            SELECT c.relname AS name
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(schema) AND c.relkind IN ('r', 'p') AND c.relname <> 'schema_migrations'
            ORDER BY pg_total_relation_size(c.oid) DESC, c.relname
            """)
        return try rows.map { try PostgresRowReader($0)("name", as: String.self) }
    }
}

extension Schema {
    /// Splits a migration script into single statements (PostgresNIO speaks the extended query
    /// protocol, which runs one statement per query). Semicolons inside quotes, quoted identifiers,
    /// dollar-quoted bodies and comments do not split; comment-only fragments are dropped.
    static func statements(in script: String) -> [String] {
        enum Mode: Equatable {
            case code
            case quote(escapes: Bool)
            case identifier
            case lineComment
            case blockComment(depth: Int)
            case dollar(tag: String)
        }

        let chars = Array(script.unicodeScalars)
        var statements: [String] = []
        var current = String.UnicodeScalarView()
        var hasCode = false
        var mode = Mode.code
        var i = 0

        func flush() {
            let text = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
            if hasCode, !text.isEmpty { statements.append(text) }
            current = String.UnicodeScalarView()
            hasCode = false
        }

        while i < chars.count {
            let c = chars[i]
            let next: Unicode.Scalar? = i + 1 < chars.count ? chars[i + 1] : nil
            switch mode {
            case .code:
                if c == ";" {
                    flush()
                    i += 1
                    continue
                }
                if c == "-", next == "-" {
                    mode = .lineComment
                } else if c == "/", next == "*" {
                    mode = .blockComment(depth: 1)
                    current.append(c)
                    current.append("*")
                    i += 2
                    continue
                } else if c == "'" {
                    let previous: Unicode.Scalar? = i > 0 ? chars[i - 1] : nil
                    mode = .quote(escapes: previous == "E" || previous == "e")
                    hasCode = true
                } else if c == "\"" {
                    mode = .identifier
                    hasCode = true
                } else if c == "$", let tag = dollarTag(in: chars, at: i) {
                    mode = .dollar(tag: tag)
                    current.append(contentsOf: tag.unicodeScalars)
                    hasCode = true
                    i += tag.unicodeScalars.count
                    continue
                } else if !CharacterSet.whitespacesAndNewlines.contains(c) {
                    hasCode = true
                }
            case .quote(let escapes):
                if escapes, c == "\\", next != nil {
                    current.append(c)
                    current.append(next!)
                    i += 2
                    continue
                }
                if c == "'" {
                    if next == "'" {
                        current.append(c)
                        current.append(c)
                        i += 2
                        continue
                    }
                    mode = .code
                }
            case .identifier:
                if c == "\"" {
                    if next == "\"" {
                        current.append(c)
                        current.append(c)
                        i += 2
                        continue
                    }
                    mode = .code
                }
            case .lineComment:
                if c == "\n" { mode = .code }
            case .blockComment(let depth):
                if c == "*", next == "/" {
                    current.append(c)
                    current.append("/")
                    i += 2
                    mode = depth == 1 ? .code : .blockComment(depth: depth - 1)
                    continue
                }
                if c == "/", next == "*" {
                    current.append(c)
                    current.append("*")
                    i += 2
                    mode = .blockComment(depth: depth + 1)
                    continue
                }
            case .dollar(let tag):
                if c == "$", String(String.UnicodeScalarView(chars[i..<min(chars.count, i + tag.unicodeScalars.count)])) == tag {
                    current.append(contentsOf: tag.unicodeScalars)
                    i += tag.unicodeScalars.count
                    mode = .code
                    continue
                }
            }
            current.append(c)
            i += 1
        }
        flush()
        return statements
    }

    /// `$tag$` (or `$$`) starting at `index`, if the dollar sign opens a dollar-quoted string.
    private static func dollarTag(in chars: [Unicode.Scalar], at index: Int) -> String? {
        if index > 0 {
            // `$1` placeholders and identifiers containing `$` are not dollar quotes.
            let previous = chars[index - 1]
            if CharacterSet.alphanumerics.contains(previous) || previous == "_" || previous == "$" { return nil }
        }
        var end = index + 1
        while end < chars.count, chars[end] != "$" {
            let c = chars[end]
            guard CharacterSet.letters.contains(c) || c == "_" || (end > index + 1 && CharacterSet.decimalDigits.contains(c)) else { return nil }
            end += 1
        }
        guard end < chars.count else { return nil }
        return String(String.UnicodeScalarView(chars[index...end]))
    }
}
