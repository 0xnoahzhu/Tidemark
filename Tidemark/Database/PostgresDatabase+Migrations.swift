import Foundation
import PostgresNIO

extension PostgresDatabase {
    /// Session-level advisory lock that serializes migrations across Macs (`"Tidemark"` in ASCII).
    static let migrationLockKey: Int64 = 0x5469_6465_6D61_726B

    /// Creates the schema when needed, then applies every pending migration in its own transaction
    /// while holding an advisory lock, so several Macs starting at once migrate exactly once.
    @discardableResult
    func migrate() async throws -> Int {
        let schema = schema
        let quotedSchema = quotedSchema
        return try await withConnection { connection in
            let lock: PostgresQuery = "SELECT pg_advisory_lock(\(Self.migrationLockKey))"
            let unlock: PostgresQuery = "SELECT pg_advisory_unlock(\(Self.migrationLockKey))"
            try await connection.query(lock, logger: Self.logger)
            do {
                let version = try await Self.applyMigrations(on: connection, schema: schema, quotedSchema: quotedSchema)
                // The lock belongs to this pooled session: release it even if the caller was cancelled.
                try await withTaskCancellationShield {
                    _ = try await connection.query(unlock, logger: Self.logger)
                }
                return version
            } catch {
                await withTaskCancellationShield {
                    do { try await connection.query(unlock, logger: Self.logger) } catch { try? await connection.close() }
                }
                throw error
            }
        }
    }

    private static func applyMigrations(on connection: PostgresConnection, schema: String, quotedSchema: String) async throws -> Int {
        if schema != "public" {
            try await connection.query(PostgresQuery(unsafeSQL: "CREATE SCHEMA IF NOT EXISTS \(quotedSchema)"), logger: logger)
        }
        for statement in Schema.statements(in: Schema.bootstrap) {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }

        var applied = Set<Int>()
        let versions = try await connection.query(PostgresQuery(unsafeSQL: "SELECT version FROM \(quotedSchema).schema_migrations"), logger: logger).collect()
        for row in versions { applied.insert(try PostgresRowReader(row)("version", as: Int.self)) }

        for migration in Schema.migrations where !applied.contains(migration.version) {
            try await connection.query("BEGIN", logger: logger)
            do {
                // pg_trgm may already live in another schema (installed by an administrator); keep its
                // operator classes resolvable for this migration's CREATE INDEX statements.
                let extensionSchema = try await connection.query(
                    "SELECT n.nspname FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace WHERE e.extname = 'pg_trgm'",
                    logger: logger
                ).collect().first.map { try PostgresRowReader($0)("nspname", as: String.self) }
                var path = [quotedSchema]
                if let extensionSchema, extensionSchema != schema, extensionSchema != "public" {
                    path.append(quoteIdentifier(extensionSchema))
                }
                path.append("public")
                try await connection.query(PostgresQuery(unsafeSQL: "SET LOCAL search_path TO \(path.joined(separator: ", "))"), logger: logger)

                for statement in Schema.statements(in: migration.sql) {
                    try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
                }
                try await connection.query(
                    "INSERT INTO schema_migrations (version, name) VALUES (\(migration.version), \(migration.name))",
                    logger: logger
                )
                try await connection.query("COMMIT", logger: logger)
            } catch {
                await rollback(connection)
                throw error
            }
        }

        let latest = try await connection.query(PostgresQuery(unsafeSQL: "SELECT COALESCE(max(version), 0) AS version FROM \(quotedSchema).schema_migrations"), logger: logger).collect()
        return try latest.first.map { try PostgresRowReader($0)("version", as: Int.self) } ?? 0
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
