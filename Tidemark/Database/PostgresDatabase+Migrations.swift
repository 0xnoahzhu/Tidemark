import Foundation
import os
import PostgresNIO
import Synchronization

/// Schema migrations on a database several Macs use at once.
///
/// `migrate()` runs on every connect, so it first reads `schema_migrations` without any lock: a Mac with
/// nothing to apply never waits for another Mac. Only when this build has migrations to apply does it take
/// the migration advisory lock, read again, and run each migration's transaction, which also records it.
///
/// Index steps (`Schema.ConcurrentStep`) run afterwards, outside the migration lock, under a per-schema
/// index lock instead, so one Mac builds while every other Mac keeps connecting and writing. Whether a step
/// is still missing is read from the catalog, so an interrupted build is simply resumed. Small tables are
/// indexed right away; large ones in the background (`startIndexMaintenance`), retrying with a backoff until
/// every step is in effect. A build that fails drops the invalid index it left behind before trying again.
extension PostgresDatabase {
    /// Session-level advisory lock that serializes migrations across Macs (`"Tidemark"` in ASCII). Every
    /// Tidemark build takes it, so it must never change.
    static let migrationLockKey: Int64 = 0x5469_6465_6D61_726B
    /// How long `migrate()` waits for another Mac's migration before failing with `.unreachable` (the
    /// caller retries on its next connection attempt). Only a Mac with migrations to apply waits.
    static let migrationLockWait: Duration = .seconds(30)
    /// Lock wait of each DDL statement: short, so a migration waiting for a lock never queues every Mac's
    /// reads and writes of that table behind it. A timed-out migration is retried.
    static let migrationLockTimeout = "3s"
    /// Statement timeout of migration transactions (they never rewrite a large table).
    static let migrationStatementTimeout: Duration = .seconds(300)
    /// Client-side limit of the migration session: the lock wait plus the transactions.
    static let migrationCallLimit: Duration = .seconds(900)
    /// Attempts per migration when it loses a lock wait, a deadlock or a serialization conflict.
    static let migrationAttempts = 5

    /// First key of the per-schema index lock (`pg_advisory_lock(int4, int4)`, the second key being
    /// `hashtext(<schema>)`), held while applying index steps: one Mac at a time per schema, and only the
    /// holder may drop an invalid index (another Mac's build in progress is invalid too).
    static let indexLockClass: Int32 = 0x544D_4958
    /// Index steps on tables up to this size run inside `migrate()` (seconds at most); larger ones run in
    /// the background, so a long build never delays connecting.
    static let inlineIndexBuildBytes: Int64 = 16 << 20
    /// Lock wait of an index build inside `migrate()`: a build that would wait for a long transaction is left
    /// to the background instead.
    static let inlineIndexLockTimeout = "10s"
    /// `maintenance_work_mem` for index builds (raised to this, never lowered): GIN builds on a large table
    /// are much faster with more than the 64 MB default.
    static let indexBuildMemory = "256MB"
    /// Client-side limit of one pass over the index steps: far beyond any build, it only frees a connection
    /// left half-open (e.g. the Mac slept during a build). A build still running on the server keeps
    /// holding the index lock, so the next pass waits for it instead of dropping it.
    static let indexPassLimit: Duration = .seconds(6 * 3_600)

    private static let maintenanceLog = os.Logger(subsystem: "io.tidemark.Tidemark", category: "database")

    /// Where `migrate(upTo:indexBuilds:)` applies missing index steps.
    enum IndexBuilds: Sendable {
        /// In the call, waiting for another Mac's build and for older transactions.
        case inline
        /// In the background.
        case background
        /// In the call when the tables are small (`inlineIndexBuildBytes`) and nothing makes the build wait,
        /// otherwise in the background.
        case automatic
    }

    /// Creates the schema when needed, applies every pending migration and makes sure their index steps
    /// are applied (in the background on large tables). Returns the schema version.
    ///
    /// Throws `.unreachable` when another Mac holds the migration lock for longer than
    /// `migrationLockWait` while this build has a migration to apply, or when a newer Tidemark applied a
    /// migration this build cannot write after (`Schema.Migration.requiresVersion`): writing resumes once
    /// this Mac runs a newer Tidemark. Index steps never make it fail.
    @discardableResult
    func migrate() async throws -> Int {
        try await migrate(upTo: nil, indexBuilds: .automatic)
    }

    /// `migrate()`, stopping after migration `target` (all pending ones when nil). Tests use it to build an
    /// older schema and upgrade it; by default its index steps are applied before it returns.
    @discardableResult
    func migrate(upTo target: Int?, indexBuilds: IndexBuilds = .inline) async throws -> Int {
        let (version, work) = try await applyMigrations(upTo: target)
        guard !work.steps.isEmpty else { return version }
        switch indexBuilds {
        case .inline:
            try await buildIndexes(upTo: target, waitingForLock: Self.migrationLockWait)
        case .background:
            startIndexMaintenance(upTo: target)
        case .automatic:
            if work.tableBytes <= Self.inlineIndexBuildBytes,
               (try? await indexPass(upTo: target, lockTimeout: Self.inlineIndexLockTimeout)) == .done {
                break
            }
            startIndexMaintenance(upTo: target)
        }
        return version
    }

    // MARK: Migrations

    /// What `schema_migrations` holds: applied version → its `requires_version`.
    struct MigrationState: Sendable {
        var applied: [Int: Int?] = [:]

        var latest: Int { applied.keys.max() ?? 0 }

        func pending(upTo target: Int?) -> [Schema.Migration] {
            Schema.migrations.filter { !applied.keys.contains($0.version) && $0.version <= (target ?? .max) }
        }

        /// Throws when a newer Tidemark applied a migration this build cannot write after.
        func checkWritable() throws {
            let blocking = applied.filter { $0.key > Schema.latestVersion }.compactMap(\.value).max()
            if let blocking, blocking > Schema.latestVersion {
                throw DatabaseError.unreachable(
                    "The database was upgraded by a newer version of Tidemark (schema \(latest)); this version (schema \(Schema.latestVersion)) cannot write to it. Update Tidemark on this Mac."
                )
            }
        }
    }

    /// Missing index steps of the applied migrations, and the size of the tables they work on.
    struct IndexWork: Sendable {
        var steps: [Schema.ConcurrentStep] = []
        var tableBytes: Int64 = 0
    }

    /// Applies the pending migrations' transactions (taking the migration lock only when there are any)
    /// and reports the index work they leave.
    private func applyMigrations(upTo target: Int?) async throws -> (version: Int, work: IndexWork) {
        let schema = schema
        let quotedSchema = quotedSchema
        return try await withConnection(limit: .client(Self.migrationCallLimit)) { connection in
            var state = try await Self.readMigrations(on: connection, schema: schema, quotedSchema: quotedSchema)
            try state.checkWritable()
            if !state.pending(upTo: target).isEmpty {
                try await Self.acquireMigrationLock(on: connection)
                do {
                    try await connection.query(PostgresQuery(unsafeSQL: "SET statement_timeout = '\(Self.setting(Self.migrationStatementTimeout))'"), logger: Self.logger)
                    state = try await Self.applyPending(on: connection, schema: schema, quotedSchema: quotedSchema, upTo: target)
                    // The lock and settings belong to this pooled session: restore them even if the caller was cancelled.
                    try await withTaskCancellationShield {
                        try await Self.endMigrationSession(connection)
                    }
                } catch {
                    await withTaskCancellationShield {
                        do { try await Self.endMigrationSession(connection) } catch { try? await connection.close() }
                    }
                    throw error
                }
            }
            let work = try await Self.indexWork(on: connection, schema: schema, applied: Set(state.applied.keys), upTo: target)
            return (state.latest, work)
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

    /// The applied migrations, read without any lock (an empty state before the first migration).
    private static func readMigrations(on connection: PostgresConnection, schema: String, quotedSchema: String) async throws -> MigrationState {
        let bookkeeping: PostgresQuery = "SELECT EXISTS (SELECT 1 FROM pg_tables WHERE schemaname = \(schema) AND tablename = 'schema_migrations') AS present"
        guard try await exists(bookkeeping, on: connection) else { return MigrationState() }
        // `requires_version` exists from v2 on; reading it through to_jsonb works on every version.
        var state = MigrationState()
        let versions = try await connection.query(
            PostgresQuery(unsafeSQL: "SELECT m.version, (to_jsonb(m) ->> 'requires_version')::int4 AS requires FROM \(quotedSchema).schema_migrations m"),
            logger: logger
        ).collect()
        for row in versions {
            let read = PostgresRowReader(row)
            state.applied[try read("version", as: Int.self)] = try read("requires", as: Int?.self)
        }
        return state
    }

    /// Under the migration lock: creates what is missing, reads the state again (another Mac may have just
    /// migrated) and applies what is still pending.
    private static func applyPending(on connection: PostgresConnection, schema: String, quotedSchema: String, upTo target: Int?) async throws -> MigrationState {
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

        var state = try await readMigrations(on: connection, schema: schema, quotedSchema: quotedSchema)
        try state.checkWritable()
        for migration in state.pending(upTo: target) {
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
            state.applied[migration.version] = migration.requiresVersion
        }
        return state
    }

    /// A lost lock wait (`55P03`), deadlock or serialization conflict: the statement can simply run again.
    private static func isRetryableMigrationFailure(_ error: any Error) -> Bool {
        guard let state = sqlState(of: error) else { return false }
        return state == "55P03" || state == "40P01" || state == "40001"
    }

    /// Runs the migration's transaction, which records it. Its index steps are applied separately.
    private static func apply(_ migration: Schema.Migration, on connection: PostgresConnection, schema: String, quotedSchema: String) async throws {
        let searchPath = try await migrationSearchPath(on: connection, schema: schema, quotedSchema: quotedSchema)
        try await connection.query("BEGIN", logger: logger)
        do {
            try await connection.query(PostgresQuery(unsafeSQL: "SET LOCAL search_path TO \(searchPath)"), logger: logger)
            try await connection.query(PostgresQuery(unsafeSQL: "SET LOCAL lock_timeout = '\(migrationLockTimeout)'"), logger: logger)
            for statement in Schema.statements(in: migration.sql) {
                try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
            }
            try await connection.query(recordStatement(migration, quotedSchema: quotedSchema), logger: logger)
            try await connection.query("COMMIT", logger: logger)
        } catch {
            await rollback(connection)
            throw error
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

    // MARK: Index steps

    /// The applied migrations' index steps that the catalog does not show in effect yet, in order.
    private static func pendingIndexSteps(on connection: PostgresConnection, schema: String, applied: Set<Int>, upTo target: Int?) async throws -> [Schema.ConcurrentStep] {
        let migrations = Schema.migrations.filter { applied.contains($0.version) && $0.version <= (target ?? .max) }
        guard migrations.contains(where: { !$0.concurrentSteps.isEmpty }) else { return [] }
        var catalog: [String: Schema.IndexState] = [:]
        for row in try await connection.query("""
            SELECT c.relname AS name, i.indisvalid AS valid, COALESCE(c.reloptions, '{}') AS options
            FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(schema)
            """, logger: logger).collect() {
            let read = PostgresRowReader(row)
            catalog[try read("name", as: String.self)] = Schema.IndexState(valid: try read("valid"), options: try read("options"))
        }
        return Schema.pendingSteps(of: migrations, catalog: catalog)
    }

    /// The missing index steps and the size of the tables they read.
    private static func indexWork(on connection: PostgresConnection, schema: String, applied: Set<Int>, upTo target: Int?) async throws -> IndexWork {
        let steps = try await pendingIndexSteps(on: connection, schema: schema, applied: applied, upTo: target)
        guard !steps.isEmpty else { return IndexWork() }
        var tables: [String] = []
        for case .createIndex(_, let table, _) in steps { tables.append(table) }
        let indexes = steps.map(\.indexName)
        let bytes = try await connection.query("""
            SELECT COALESCE(sum(pg_relation_size(t.oid)), 0)::int8 AS bytes
            FROM pg_class t JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = \(schema) AND t.relkind = 'r' AND (t.relname = ANY(\(tables)) OR t.oid IN (
                SELECT i.indrelid FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid
                WHERE c.relnamespace = n.oid AND c.relname = ANY(\(indexes))
            ))
            """, logger: logger).collect().first.map { try PostgresRowReader($0)("bytes", as: Int64.self) } ?? 0
        return IndexWork(steps: steps, tableBytes: bytes)
    }

    /// Applies the missing index steps in the call, waiting at most `wait` for another Mac's build.
    func buildIndexes(upTo target: Int?, waitingForLock wait: Duration) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: wait)
        while try await indexPass(upTo: target, lockTimeout: "0") == .busy {
            guard clock.now < deadline else {
                throw DatabaseError.unreachable("Another Mac is building the database's indexes; Tidemark will try again shortly.")
            }
            try await Task.sleep(for: .milliseconds(500))
        }
    }

    /// The outcome of one pass over the missing index steps.
    enum IndexPass: Sendable, Equatable {
        /// Every step is in effect.
        case done
        /// Another Mac holds the index lock (it is applying the steps).
        case busy
    }

    /// Takes the index lock (without waiting) and applies every missing index step. Index builds and drops
    /// wait with `lockTimeout` (`"0"`: as long as it takes; they block no reads or writes meanwhile).
    func indexPass(upTo target: Int?, lockTimeout: String) async throws -> IndexPass {
        let schema = schema
        let quotedSchema = quotedSchema
        return try await withConnection(limit: .client(Self.indexPassLimit)) { connection in
            let locked = try await connection.query(
                "SELECT pg_try_advisory_lock(\(Self.indexLockClass), hashtext(\(schema))) AS locked", logger: Self.logger
            ).collect().first.map { try PostgresRowReader($0)("locked", as: Bool.self) }
            guard locked == true else { return .busy }
            do {
                let searchPath = try await Self.migrationSearchPath(on: connection, schema: schema, quotedSchema: quotedSchema)
                for statement in [
                    "SET search_path TO \(searchPath)", "SET statement_timeout = 0", "SET lock_timeout = '\(lockTimeout)'",
                    "SELECT set_config('maintenance_work_mem', '\(Self.indexBuildMemory)', false) "
                        + "WHERE pg_size_bytes(current_setting('maintenance_work_mem')) < pg_size_bytes('\(Self.indexBuildMemory)')",
                ] {
                    try await connection.query(PostgresQuery(unsafeSQL: statement), logger: Self.logger)
                }
                // Read under the lock: another Mac may have finished some steps meanwhile.
                let state = try await Self.readMigrations(on: connection, schema: schema, quotedSchema: quotedSchema)
                let steps = try await Self.pendingIndexSteps(on: connection, schema: schema, applied: Set(state.applied.keys), upTo: target)
                for step in steps {
                    try await Self.run(step, on: connection, schema: schema, quotedSchema: quotedSchema, lockTimeout: lockTimeout)
                }
                try await withTaskCancellationShield {
                    try await Self.endIndexSession(connection, schema: schema)
                }
                return .done
            } catch {
                await withTaskCancellationShield {
                    do { try await Self.endIndexSession(connection, schema: schema) } catch { try? await connection.close() }
                }
                throw error
            }
        }
    }

    /// Puts the session back the way the pool configured it and releases the index lock.
    private static func endIndexSession(_ connection: PostgresConnection, schema: String) async throws {
        for statement in ["RESET statement_timeout", "RESET lock_timeout", "RESET search_path", "RESET maintenance_work_mem"] {
            try await connection.query(PostgresQuery(unsafeSQL: statement), logger: logger)
        }
        try await connection.query("SELECT pg_advisory_unlock(\(indexLockClass), hashtext(\(schema)))", logger: logger)
    }

    /// Runs one index step. Index names are schema-qualified: with `search_path = <test schema>, public` an
    /// unqualified `DROP INDEX IF EXISTS` would fall through to the production schema.
    private static func run(_ step: Schema.ConcurrentStep, on connection: PostgresConnection, schema: String, quotedSchema: String, lockTimeout: String) async throws {
        let qualified = "\(quotedSchema).\(quoteIdentifier(step.indexName))"
        let drop = PostgresQuery(unsafeSQL: "DROP INDEX CONCURRENTLY IF EXISTS \(qualified)")
        switch step {
        case .createIndex(let name, let table, let definition):
            // An invalid index is a leftover of a build that failed or was interrupted (this Mac holds the
            // index lock, so nobody else is building it): it is maintained by every write but never used.
            if try await indexIsInvalid(name, on: connection, schema: schema) {
                try await connection.query(drop, logger: logger)
            }
            do {
                try await connection.query(
                    PostgresQuery(unsafeSQL: "CREATE INDEX CONCURRENTLY IF NOT EXISTS \(quoteIdentifier(name)) ON \(quotedSchema).\(quoteIdentifier(table)) \(definition)"),
                    logger: logger
                )
            } catch {
                // Drop what the failed build left behind now rather than at the next attempt.
                await withTaskCancellationShield {
                    if (try? await indexIsInvalid(name, on: connection, schema: schema)) == true {
                        _ = try? await connection.query(drop, logger: logger)
                    }
                }
                throw error
            }
        case .dropIndex:
            try await connection.query(drop, logger: logger)
        case .enableAutosummarize:
            // Summarize the ranges filled since the last vacuum first (it blocks no writes), then switch
            // autosummarize on; the ALTER locks the index briefly, so it waits for at most a few seconds.
            _ = try await connection.query("SELECT brin_summarize_new_values(to_regclass(\(qualified)))", logger: logger).collect()
            var attempt = 1
            while true {
                do {
                    try await connection.query(PostgresQuery(unsafeSQL: "SET lock_timeout = '\(migrationLockTimeout)'"), logger: logger)
                    try await connection.query(PostgresQuery(unsafeSQL: "ALTER INDEX IF EXISTS \(qualified) SET (autosummarize = on)"), logger: logger)
                    try await connection.query(PostgresQuery(unsafeSQL: "SET lock_timeout = '\(lockTimeout)'"), logger: logger)
                    break
                } catch let error where attempt < migrationAttempts && isRetryableMigrationFailure(error) {
                    try await Task.sleep(for: .seconds(attempt))
                    attempt += 1
                }
            }
        }
    }

    private static func indexIsInvalid(_ name: String, on connection: PostgresConnection, schema: String) async throws -> Bool {
        try await connection.query("""
            SELECT NOT i.indisvalid AS present FROM pg_index i
            JOIN pg_class c ON c.oid = i.indexrelid JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(schema) AND c.relname = \(name)
            """, logger: logger).collect().first.map { try PostgresRowReader($0)("present", as: Bool.self) } ?? false
    }

    // MARK: Background index maintenance

    /// Pause before looking again while another Mac applies the index steps.
    static let indexBusyPause: Duration = .seconds(60)

    /// Pause after the `failures`-th failed pass: 30 s, 1 min, 2 min, 5 min, then every 15 min.
    static func indexRetryPause(after failures: Int) -> Duration {
        let schedule: [Duration] = [.seconds(30), .seconds(60), .seconds(120), .seconds(300)]
        return failures <= schedule.count ? schedule[max(0, failures - 1)] : .seconds(900)
    }

    /// Applies the missing index steps in a background task (one at a time) until all are in effect, the
    /// database shuts down or the task is cancelled. Failures are logged and retried with a backoff.
    func startIndexMaintenance(upTo target: Int?) {
        guard isRunning else { return }
        indexMaintenance.withLock { task in
            guard task == nil else { return }
            task = Task.detached(name: "Tidemark index maintenance", priority: .utility) { [weak self] in
                var failures = 0
                while !Task.isCancelled, let pause = await self?.indexMaintenancePass(upTo: target, failures: &failures) {
                    try? await Task.sleep(for: pause)
                }
                self?.indexMaintenance.withLock { $0 = nil }
            }
        }
    }

    /// One pass of `startIndexMaintenance`: nil when every step is in effect (or the task was cancelled),
    /// otherwise how long to wait before the next pass.
    private func indexMaintenancePass(upTo target: Int?, failures: inout Int) async -> Duration? {
        do {
            if try await indexPass(upTo: target, lockTimeout: "0") == .done { return nil }
            return Self.indexBusyPause
        } catch {
            guard !Task.isCancelled else { return nil }
            failures += 1
            let pause = Self.indexRetryPause(after: failures)
            Self.maintenanceLog.error("Building indexes failed, retrying in \(pause.components.seconds) s: \(error.localizedDescription, privacy: .public)")
            return pause
        }
    }

    /// Waits until the background index maintenance (if any) finished.
    func indexMaintenanceFinished() async {
        await indexMaintenance.withLock { $0 }?.value
    }

    // MARK: Inspection

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
    /// What the catalog says about one index: whether it is valid, and its storage parameters
    /// (`pg_class.reloptions`, e.g. `autosummarize=on`).
    struct IndexState: Sendable, Equatable {
        var valid: Bool
        var options: [String]
    }

    /// The steps of `migrations` whose effect `catalog` (index name → state) does not show yet, in order.
    ///
    /// Whether an index should exist is decided by the last step that builds or drops it, so an index a
    /// later migration drops again is never built. A missing or invalid index that should exist is built;
    /// an existing one that should not is dropped; a BRIN index (re)built here or lacking `autosummarize`
    /// gets it. With everything in effect the result is empty.
    static func pendingSteps(of migrations: [Migration], catalog: [String: IndexState]) -> [ConcurrentStep] {
        let steps = migrations.flatMap(\.concurrentSteps)
        var kept: [String: Bool] = [:]
        for step in steps {
            switch step {
            case .createIndex(let name, _, _): kept[name] = true
            case .dropIndex(let name): kept[name] = false
            case .enableAutosummarize: break
            }
        }
        var built = Set<String>()
        var dropped = Set<String>()
        var summarized = Set<String>()
        var pending: [ConcurrentStep] = []
        for step in steps {
            switch step {
            case .createIndex(let name, _, _):
                guard kept[name] == true, catalog[name]?.valid != true, built.insert(name).inserted else { continue }
            case .dropIndex(let name):
                guard kept[name] == false, catalog[name] != nil, dropped.insert(name).inserted else { continue }
            case .enableAutosummarize(let index):
                guard kept[index] != false else { continue }
                let missing = built.contains(index) || catalog[index].map { !$0.options.contains("autosummarize=on") } == true
                guard missing, summarized.insert(index).inserted else { continue }
            }
            pending.append(step)
        }
        return pending
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
