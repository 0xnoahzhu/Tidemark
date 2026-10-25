import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO
import Synchronization

/// `TidemarkDatabase` on PostgreSQL, through PostgresNIO's pooled `PostgresClient`.
///
/// Lifecycle: create it with a connection URL, call `connect()` (starts the pools and waits until the
/// server answers), then `migrate()`. Call `shutdown()` when the app quits; a database that was shut
/// down cannot be connected again — create a new instance instead (e.g. after the URL changes).
///
/// Two pools: the capture write path (requests, processes, inventory, alerts) and `ping()` use a small
/// `writer` pool the UI can never exhaust; UI reads and maintenance use the `main` pool. Every connection
/// carries statement, lock and idle-in-transaction timeouts (`SessionLimits`), so a stuck query, a lock
/// held by another Mac or a Mac that went to sleep mid-transaction cannot hang a pool for long. Reads that
/// legitimately scan a long history run with a longer statement timeout (`longReadTimeout`), maintenance
/// with `maintenanceTimeout`. On top of that, a call that holds its connection far beyond its statement
/// timeout gets the connection closed (`CallLimit`), so a server that vanished without closing the TCP
/// connection cannot keep a pool slot forever; a writer call whose task is cancelled (capture gave up on
/// it) closes its connection at once, which also keeps its transaction from committing later.
///
/// Every pooled connection runs with `search_path = <schema>, public`, so all SQL is written without a
/// schema prefix and the same code serves production (`public`) and throwaway test schemas.
///
/// Errors follow `DatabaseError`: anything that may succeed later (connection problems, the server running
/// out of resources, shutting down or being read-only, lock and serialization conflicts) is `.unreachable`,
/// a statement cancelled at its statement timeout or a call past its `CallLimit` is `.timedOut`; only a
/// statement or its data being rejected is `.query`. Cancelling the calling task
/// throws `CancellationError`. All methods are safe to call concurrently; each one leases its own
/// connection from a pool.
final class PostgresDatabase: TidemarkDatabase {
    /// Schema holding Tidemark's tables (`public` in production).
    let schema: String
    /// The parsed connection target, nil when the URL or the schema name is invalid (every call then
    /// throws `invalidURL`).
    let endpoint: PostgresConnectionURL?
    /// Classifies hosts into sites when `backfill` rebuilds an app's inventory.
    let siteClassifier: any SiteClassifying
    /// How long a call waits for a pooled connection before failing with `.unreachable`.
    let leaseTimeout: Duration

    private let setup: Result<Setup, DatabaseError>
    private let lifecycle = Mutex<Lifecycle>(.idle)
    /// The background task applying index steps of migrations (`migrate()`), nil when none runs.
    let indexMaintenance = Mutex<Task<Void, Never>?>(nil)

    /// The connection pool a call runs on.
    enum Pool: Sendable {
        /// UI reads, settings and maintenance.
        case main
        /// The capture write path and `ping()`: connections reserved for writes, so a burst of slow
        /// History queries can never make a flush wait for a connection.
        case writer

        var limits: SessionLimits {
            switch self {
            case .main: .main
            case .writer: .writer
            }
        }
    }

    /// Per-connection limits, sent as startup parameters.
    struct SessionLimits: Sendable, Equatable {
        /// Longest a single statement may run (`statement_timeout`).
        var statement: Duration
        /// Longest a statement waits for a lock held by another session (`lock_timeout`).
        var lock: Duration
        /// Longest a session may sit idle inside an open transaction
        /// (`idle_in_transaction_session_timeout`); the server then ends the session and releases its
        /// locks, e.g. when a MacBook sleeps in the middle of a flush.
        var idleInTransaction: Duration

        static let main = SessionLimits(statement: .seconds(30), lock: .seconds(10), idleInTransaction: .seconds(60))
        /// Below capture's 20 s bound per write (`CapturePipeline.writeTimeout`): the server cancels a
        /// statement capture already gave up on instead of running it on one of the two writer connections.
        static let writer = SessionLimits(statement: .seconds(15), lock: .seconds(5), idleInTransaction: .seconds(15))

        var parameters: [(String, String)] {
            [
                ("statement_timeout", PostgresDatabase.setting(statement)),
                ("lock_timeout", PostgresDatabase.setting(lock)),
                ("idle_in_transaction_session_timeout", PostgresDatabase.setting(idleInTransaction)),
            ]
        }
    }

    /// Statement timeout of reads that scan a long stretch of the request log: History over long ranges,
    /// its histogram and totals, the policy list, an app's counters and process tree, the backfill preview.
    static let longReadTimeout: Duration = .seconds(300)
    /// Statement timeout of maintenance on large tables (retention, backfill, deleting an app).
    static let maintenanceTimeout: Duration = .seconds(600)

    /// How long a call may hold its leased connection before Tidemark stops waiting for the server, closes
    /// the connection (the pool replaces it) and fails with `.timedOut`. The statement timeouts make the
    /// server give up first; this only catches a server that can no longer answer, e.g. a TCP connection
    /// left half-open while the Mac slept, which would otherwise keep its pool slot forever.
    enum CallLimit: Sendable, Equatable {
        /// Derived from the pool's statement timeout.
        case pool
        /// Derived from a statement timeout set for this call (`withTransaction(statementTimeout:)`).
        case statement(Duration)
        /// Exactly this long (migrations and index builds, which set their own statement timeouts).
        case client(Duration)

        /// The client-side limit on `pool`. Derived limits are generous (twice the statement timeout plus a
        /// margin), because one call may run several statements.
        func duration(on pool: Pool) -> Duration {
            switch self {
            case .pool: Self.margin(pool.limits.statement)
            case .statement(let timeout): Self.margin(timeout)
            case .client(let limit): limit
            }
        }

        /// The statement timeout the call runs with, for error messages.
        func statementTimeout(on pool: Pool) -> Duration? {
            switch self {
            case .pool: pool.limits.statement
            case .statement(let timeout): timeout
            case .client: nil
            }
        }

        private static func margin(_ statement: Duration) -> Duration { statement * 2 + .seconds(5) }
    }

    /// A duration as a PostgreSQL setting: whole seconds as `30s`, anything else in milliseconds.
    static func setting(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        if attoseconds == 0 { return "\(seconds)s" }
        return "\(seconds * 1_000 + attoseconds / 1_000_000_000_000_000)ms"
    }

    /// Connections per pool; together they stay at the 8 connections per Mac Tidemark always used.
    static let mainPoolSize = 6
    static let writerPoolSize = 2

    private struct Setup: Sendable {
        var main: PostgresClient
        var writer: PostgresClient
        var url: PostgresConnectionURL
        /// Startup parameters of the main pool, reused by the standalone probe connection.
        var startupParameters: [(String, String)]
    }

    private enum Lifecycle: Sendable {
        case idle
        case running(Task<Void, Never>)
        case shutDown
    }

    /// Creates the database client. Nothing connects until `connect()`.
    ///
    /// - Parameters:
    ///   - url: `postgres://` or `postgresql://` URL (see `PostgresConnectionURL` for `sslmode`).
    ///     An invalid URL does not crash: `connect()` and every other call throw `DatabaseError.invalidURL`.
    ///   - schema: Schema for Tidemark's tables; created by `migrate()` when missing.
    ///   - siteClassifier: Registrable-domain classifier used when backfilling inventories.
    ///   - leaseTimeout: Maximum wait for a pooled connection.
    init(
        url: String,
        schema: String = "public",
        siteClassifier: any SiteClassifying = NaiveSiteClassifier(),
        leaseTimeout: Duration = .seconds(10)
    ) {
        self.schema = schema
        self.siteClassifier = siteClassifier
        self.leaseTimeout = leaseTimeout
        do throws(DatabaseError) {
            let parsed = try PostgresConnectionURL(url)
            guard Self.isValidSchemaName(schema) else { throw .invalidURL("schema \"\(schema)\"") }
            self.endpoint = parsed
            self.setup = .success(Self.makeSetup(url: parsed, schema: schema))
        } catch {
            self.endpoint = nil
            self.setup = .failure(error)
        }
    }

    deinit {
        if case .running(let task) = lifecycle.withLock({ $0 }) { task.cancel() }
    }

    // MARK: - Connection

    /// Starts the connection pools (once) and waits up to ~5 s for the server to answer.
    ///
    /// Authentication failures and unknown databases fail immediately; network errors are retried
    /// until the deadline. Throws `DatabaseError.unreachable` with the server's or the network's reason.
    func connect() async throws {
        let setup = try setup.get()
        try startPools(setup)
        try await probeServer(setup, within: .seconds(5))
        do {
            async let main: Void = selectOne(on: .main)
            async let writer: Void = selectOne(on: .writer)
            _ = try await (main, writer)
        } catch DatabaseError.query(let message) {
            // `SELECT 1` refused: the server, not the data, is the problem.
            throw DatabaseError.unreachable(.message(message))
        }
    }

    private func selectOne(on pool: Pool) async throws {
        _ = try await withConnection(on: pool) { connection in
            try await connection.query("SELECT 1", logger: Self.logger).collect()
        }
    }

    /// Closes every pooled connection and waits for the pools to stop, even when the calling task is
    /// being cancelled (e.g. during app termination after the final flush).
    func shutdown() async {
        let task: Task<Void, Never>? = lifecycle.withLock { state in
            defer { state = .shutDown }
            if case .running(let task) = state { return task }
            return nil
        }
        indexMaintenance.withLock { $0 }?.cancel()
        guard let task else { return }
        task.cancel()
        await withTaskCancellationShield {
            await task.value
        }
    }

    /// Round trip of `SELECT 1` on a writer connection (so it reports whether captured requests can be
    /// written, whatever the UI is reading), plus the bare server version (`18.3`).
    func ping() async throws -> (roundTrip: Duration, serverVersion: String) {
        try await withConnection(on: .writer) { connection in
            let clock = ContinuousClock()
            let start = clock.now
            _ = try await connection.query("SELECT 1", logger: Self.logger).collect()
            let roundTrip = start.duration(to: clock.now)
            let rows = try await connection.query("SHOW server_version", logger: Self.logger).collect()
            let raw = try rows.first.map { try $0.makeRandomAccess()[0].decode(String.self) } ?? ""
            // "18.3 (Debian 18.3-1.pgdg13+1)" → "18.3"
            let version = raw.split(separator: " ").first.map(String.init) ?? raw
            return (roundTrip, version)
        }
    }

    // MARK: - Pool plumbing

    private func startPools(_ setup: Setup) throws {
        let main = setup.main
        let writer = setup.writer
        try lifecycle.withLock { state in
            switch state {
            case .idle:
                state = .running(Task.detached(name: "Tidemark PostgreSQL pools") {
                    await withDiscardingTaskGroup { group in
                        group.addTask { await main.run() }
                        group.addTask { await writer.run() }
                    }
                })
            case .running:
                break
            case .shutDown:
                throw DatabaseError.unreachable(.shutDown)
            }
        }
    }

    /// Whether `connect()` started the pools and `shutdown()` has not stopped them.
    var isRunning: Bool {
        lifecycle.withLock { state in
            if case .running = state { return true }
            return false
        }
    }

    /// The pool's client, once `connect()` started the pools.
    private func runningClient(_ pool: Pool) throws -> PostgresClient {
        let setup = try setup.get()
        guard isRunning else { throw DatabaseError.unreachable(.notConnected) }
        switch pool {
        case .main: return setup.main
        case .writer: return setup.writer
        }
    }

    /// Opens standalone connections until one succeeds, to report precise reasons (wrong password,
    /// unknown database, refused connection) that the pool would only retry silently.
    ///
    /// The probe runs on a temporary one-thread POSIX event loop: Network.framework connections (the
    /// pool's default transport) wait out the whole connect timeout on a refused port instead of failing.
    private func probeServer(_ setup: Setup, within limit: Duration) async throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { group.shutdownGracefully { _ in } }
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: limit)
        var lastError: any Error = DatabaseError.unreachable(.connectTimedOut(target: setup.url.redacted))
        var attempt = 0
        while true {
            try Task.checkCancellation()
            attempt += 1
            let remaining = clock.now.duration(to: deadline)
            do {
                let configuration = try Self.directConfiguration(setup, timeout: max(remaining, .seconds(1)))
                let connection = try await PostgresConnection.connect(on: group.next(), configuration: configuration, id: attempt, logger: Self.logger)
                try? await connection.close()
                return
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                lastError = error
                if Self.isPermanentConnectFailure(error) { break }
            }
            let pause = Duration.milliseconds(min(1_000, 150 * attempt))
            guard clock.now.advanced(by: pause) < deadline else { break }
            try await Task.sleep(for: pause)
        }
        throw DatabaseError.unreachable(Self.describe(lastError, endpoint: setup.url))
    }

    /// Leases a connection from `pool` for `body`. Fails with `.unreachable` when no connection becomes
    /// available within `leaseTimeout`. A connection handed over after the timeout fired goes back unused:
    /// the caller was told the work failed, so it must not be applied behind its back (a retry would apply
    /// it twice).
    ///
    /// Once leased, `body` runs until it finishes, or until `limit` passes: the connection is then closed
    /// (the pool replaces it) and the call fails with `.timedOut`. On the writer pool, cancelling the
    /// calling task closes the connection right away and throws `CancellationError`: the transaction rolls
    /// back instead of committing after the caller gave up (capture keeps or spools that work and writes
    /// it again). Either way the call ends once the connection is closed, even if `body` is stuck on it
    /// (`LeasedCall`). On the main pool a cancelled call's statement runs to completion first.
    func withConnection<Result: Sendable>(
        on pool: Pool = .main,
        limit: CallLimit = .pool,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        let client = try runningClient(pool)
        let lease = LeaseState()
        let timeout = leaseTimeout
        let endpoint = self.endpoint
        let clientLimit = limit.duration(on: pool)
        let statementTimeout = limit.statementTimeout(on: pool)
        let closesOnCancel = pool == .writer
        do {
            return try await withThrowingTaskGroup(of: LeaseOutcome<Result>.self) { group in
                group.addTask(name: "PostgreSQL lease") {
                    try await client.withConnection { connection in
                        guard lease.claim() else { return LeaseOutcome.abandoned }
                        let value = try await Self.run(body, on: connection, limit: clientLimit, statementTimeout: statementTimeout,
                                                       closesOnCancel: closesOnCancel, endpoint: endpoint)
                        return LeaseOutcome.finished(value)
                    }
                }
                group.addTask(name: "PostgreSQL lease timeout") {
                    try await Task.sleep(for: timeout)
                    guard lease.expire() else { return .leased }
                    throw DatabaseError.unreachable(.noConnection(target: endpoint?.redacted, within: timeout))
                }
                while let outcome = try await group.next() {
                    if case .finished(let value) = outcome {
                        group.cancelAll()
                        return value
                    }
                }
                throw CancellationError()
            }
        } catch {
            throw Self.map(error, endpoint: endpoint, statementTimeout: statementTimeout)
        }
    }

    /// Runs `body` on a leased connection (`LeasedCall`), closing the connection when `limit` passes first or,
    /// with `closesOnCancel`, when the task is cancelled; the call then ends as soon as the connection is
    /// closed, whether `body` noticed or not. The errors of `body` are mapped here, where it is known how
    /// long the call held its connection (`isStatementTimeout`).
    private static func run<Result: Sendable>(
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Result,
        on connection: PostgresConnection,
        limit: Duration,
        statementTimeout: Duration?,
        closesOnCancel: Bool,
        endpoint: PostgresConnectionURL?
    ) async throws -> Result {
        let call = LeasedCall<Result>(connection)
        let started = ContinuousClock.now
        let outcome = await withTaskCancellationHandler {
            await call.run(body, limit: limit)
        } onCancel: {
            call.cancel(closingConnection: closesOnCancel)
        }
        switch outcome {
        case .finished(.success(let value), _):
            return value
        case .finished(.failure(let error), closedBy: nil):
            throw map(error, endpoint: endpoint, statementTimeout: statementTimeout, ranFor: started.duration(to: .now))
        case .finished(.failure, closedBy: let reason?), .abandoned(let reason):
            switch reason {
            case .expired: throw DatabaseError.timedOut(.noReply(target: endpoint?.redacted, within: limit))
            case .cancelled: throw CancellationError()
            }
        }
    }

    /// Runs `body` inside `BEGIN … COMMIT` on one connection leased from `pool`; rolls back when it throws.
    /// A transaction chosen as a deadlock victim (or failing serialization) is retried up to two more
    /// times, so `body` must be safe to run again (all of ours rebuild their state inside the closure).
    /// `statementTimeout` replaces the pool's limit for this transaction only, for long reads and
    /// maintenance on large tables (`longReadTimeout`, `maintenanceTimeout`).
    func withTransaction<Result: Sendable>(
        on pool: Pool = .main,
        statementTimeout: Duration? = nil,
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        let setTimeout = statementTimeout.map { PostgresQuery(unsafeSQL: "SET LOCAL statement_timeout = '\(Self.setting($0))'") }
        let limit: CallLimit = statementTimeout.map { .statement($0) } ?? .pool
        return try await withConnection(on: pool, limit: limit) { connection in
            var attempt = 1
            while true {
                try await connection.query("BEGIN", logger: Self.logger)
                do {
                    if let setTimeout { try await connection.query(setTimeout, logger: Self.logger) }
                    let value = try await body(connection)
                    try await connection.query("COMMIT", logger: Self.logger)
                    return value
                } catch {
                    await Self.rollback(connection)
                    guard attempt < 3, Self.isTransientConflict(error) else { throw error }
                    attempt += 1
                    try await Task.sleep(for: .milliseconds(20 * attempt))
                }
            }
        }
    }

    /// Deadlock (`40P01`) or serialization failure (`40001`) reported by the server.
    static func isTransientConflict(_ error: any Error) -> Bool {
        let state = sqlState(of: error)
        return state == "40P01" || state == "40001"
    }

    /// The SQLSTATE of an error reported by the server, nil for anything else.
    static func sqlState(of error: any Error) -> String? {
        guard let error = error as? PSQLError, error.code == .server else { return nil }
        return error.serverInfo?[.sqlState]
    }

    /// Rolls back even when the task is cancelled; a connection that cannot roll back is closed so it
    /// never returns to the pool inside an open transaction. A closed connection is left alone: its
    /// transaction ended with it, and PostgresNIO never answers a statement sent after a connection finished
    /// closing (`LeasedCall`).
    static func rollback(_ connection: PostgresConnection) async {
        guard !connection.isClosed else { return }
        await withTaskCancellationShield {
            do {
                try await connection.query("ROLLBACK", logger: logger)
            } catch {
                try? await connection.close()
            }
        }
    }

    /// Runs a statement and returns its rows. With `statementTimeout` it runs in a transaction of its own
    /// with that limit instead of the pool's (`longReadTimeout` for reads over a long history).
    func rows(_ query: PostgresQuery, on pool: Pool = .main, statementTimeout: Duration? = nil) async throws -> [PostgresRow] {
        guard let statementTimeout else {
            return try await withConnection(on: pool) { connection in
                try await connection.query(query, logger: Self.logger).collect()
            }
        }
        return try await withTransaction(on: pool, statementTimeout: statementTimeout) { connection in
            try await connection.query(query, logger: Self.logger).collect()
        }
    }

    /// Runs a statement and discards its result.
    func execute(_ query: PostgresQuery, on pool: Pool = .main, statementTimeout: Duration? = nil) async throws {
        _ = try await rows(query, on: pool, statementTimeout: statementTimeout)
    }

    // MARK: - Configuration

    /// PostgresNIO logs nothing; failures surface as `DatabaseError`.
    static let logger = Logger(label: "io.tidemark.postgres", factory: { _ in SwiftLogNoOpLogHandler() })

    /// `"schema"` quoted as an SQL identifier.
    var quotedSchema: String { Self.quoteIdentifier(schema) }

    static func quoteIdentifier(_ name: String) -> String {
        "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// Lowercase letters, digits and `_`, starting with a letter or `_`, at most 63 bytes.
    static func isValidSchemaName(_ name: String) -> Bool {
        guard let first = name.unicodeScalars.first, name.utf8.count <= 63 else { return false }
        let lower = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyz_")
        let rest = lower.union(CharacterSet(charactersIn: "0123456789"))
        return lower.contains(first) && name.unicodeScalars.allSatisfy { rest.contains($0) }
    }

    private static func makeSetup(url: PostgresConnectionURL, schema: String) -> Setup {
        let root = url.rootCertificatePath
        let tls: PostgresClient.Configuration.TLS = switch url.tls {
        case .disable: .disable
        case .prefer: .prefer(tlsConfiguration(.none))
        case .require: .require(tlsConfiguration(.none))
        case .verifyCA: .require(tlsConfiguration(.noHostnameVerification, rootCertificate: root))
        case .verifyFull: .require(tlsConfiguration(.fullVerification, rootCertificate: root))
        }

        let searchPath = schema == "public" ? "public" : "\(quoteIdentifier(schema)), public"
        func parameters(_ application: String, _ limits: SessionLimits) -> [(String, String)] {
            [("search_path", searchPath), ("application_name", application)] + limits.parameters
        }
        func client(_ application: String, _ limits: SessionLimits, size: Int) -> PostgresClient {
            var configuration: PostgresClient.Configuration
            if let socket = url.socketPath {
                configuration = .init(unixSocketPath: socket, username: url.username, password: url.password, database: url.database)
            } else {
                configuration = .init(host: url.host, port: url.port, username: url.username, password: url.password, database: url.database, tls: tls)
            }
            configuration.options.connectTimeout = .seconds(5)
            configuration.options.minimumConnections = 1
            configuration.options.maximumConnections = size
            configuration.options.connectionIdleTimeout = .seconds(120)
            configuration.options.additionalStartupParameters = parameters(application, limits)
            return PostgresClient(configuration: configuration)
        }

        return Setup(
            main: client("Tidemark", .main, size: mainPoolSize),
            writer: client("Tidemark writer", .writer, size: writerPoolSize),
            url: url,
            startupParameters: parameters("Tidemark", .main)
        )
    }

    private static func tlsConfiguration(_ verification: CertificateVerification, rootCertificate: String? = nil) -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = verification
        if let rootCertificate { configuration.trustRoots = .file(rootCertificate) }
        return configuration
    }

    /// A standalone-connection configuration equivalent to the pool's, for `probeServer`.
    private static func directConfiguration(_ setup: Setup, timeout: Duration) throws -> PostgresConnection.Configuration {
        let url = setup.url
        let root = url.rootCertificatePath
        var configuration: PostgresConnection.Configuration
        if let socket = url.socketPath {
            configuration = .init(unixSocketPath: socket, username: url.username, password: url.password, database: url.database)
        } else {
            let tls: PostgresConnection.Configuration.TLS = switch url.tls {
            case .disable: .disable
            case .prefer: .prefer(try NIOSSLContext(configuration: tlsConfiguration(.none)))
            case .require: .require(try NIOSSLContext(configuration: tlsConfiguration(.none)))
            case .verifyCA: .require(try NIOSSLContext(configuration: tlsConfiguration(.noHostnameVerification, rootCertificate: root)))
            case .verifyFull: .require(try NIOSSLContext(configuration: tlsConfiguration(.fullVerification, rootCertificate: root)))
            }
            configuration = .init(host: url.host, port: url.port, username: url.username, password: url.password, database: url.database, tls: tls)
        }
        let milliseconds = timeout.components.seconds * 1_000 + timeout.components.attoseconds / 1_000_000_000_000_000
        configuration.options.connectTimeout = .milliseconds(max(500, milliseconds))
        configuration.options.additionalStartupParameters = setup.startupParameters
        return configuration
    }

    // MARK: - Errors

    /// Maps PostgresNIO / NIO errors to `DatabaseError`; `CancellationError` passes through.
    ///
    /// `.query` is reserved for errors that retrying the same statement cannot fix (the server rejected
    /// the statement or its data, or a reply could not be decoded); everything else — including errors
    /// of unknown origin — is `.unreachable`, so callers keep the data and retry later. A statement the
    /// server cancelled at its `statementTimeout` (SQLSTATE 57014) is `.timedOut`: the server answered, the
    /// query was just too slow. `ranFor` is how long the call held its connection (`isStatementTimeout`).
    static func map(_ error: any Error, endpoint: PostgresConnectionURL? = nil, statementTimeout: Duration? = nil,
                    ranFor: Duration? = nil) -> any Error {
        switch error {
        case let error as DatabaseError:
            return error
        case is CancellationError:
            return error
        case let error as PSQLError:
            switch error.code {
            case .server:
                let state = error.serverInfo?[.sqlState] ?? ""
                // 57014 is also an administrator's `pg_cancel_backend`, which stays `.unreachable` below.
                if state == "57014",
                   isStatementTimeout(message: error.serverInfo?[.message], statementTimeout: statementTimeout, ranFor: ranFor) {
                    return DatabaseError.timedOut(.statement(statementTimeout))
                }
                let reason = describe(error, endpoint: endpoint)
                return isTransient(sqlState: state) ? DatabaseError.unreachable(reason) : DatabaseError.query(reason.description)
            case .queryCancelled:
                return CancellationError()
            case .tooManyParameters:
                return DatabaseError.query(describe(error, endpoint: endpoint).description)
            default:
                return DatabaseError.unreachable(describe(error, endpoint: endpoint))
            }
        case let error as PostgresDecodingError:
            return DatabaseError.query("Could not read column \(error.columnName) (\(error.code)).")
        case is EncodingError:
            return DatabaseError.query(String(describing: error))
        case is IOError, is ChannelError, is NIOConnectionError, is NIOSSLError:
            return DatabaseError.unreachable(describe(error, endpoint: endpoint))
        default:
            // _ConnectionPoolModule.ConnectionPoolError (pool shut down, request cancelled) is internal.
            let typeName = String(describing: type(of: error))
            if typeName.contains("ConnectionPoolError") {
                return Task.isCancelled ? CancellationError() : DatabaseError.unreachable(.poolClosed)
            }
            return DatabaseError.unreachable(.message(String(describing: error)))
        }
    }

    /// Whether a server error says nothing about the statement or its data, so the same work can succeed
    /// later: connection problems (08), authentication and unknown database or schema (28, 3D, 3F),
    /// insufficient resources such as a full disk (53), operator intervention such as a statement
    /// timeout or shutdown (57), system and internal errors (58, XX), serialization failures and
    /// deadlocks (40, except 40002), a read-only or timed-out transaction (25006, 25P02, 25P03, 25P04), a
    /// lock that could not be taken (55P03, 55006), a missing privilege (42501), snapshot too old (72),
    /// configuration file errors (F0).
    ///
    /// Everything else — data exceptions (22), constraint and foreign-key violations (23), syntax errors
    /// and undefined objects (42), program limits (54)… — rejects the statement itself.
    static func isTransient(sqlState state: String) -> Bool {
        switch state.prefix(2) {
        case "08", "28", "3D", "3F", "53", "57", "58", "72", "F0", "XX":
            return true
        case "40":
            return state != "40002"
        case "25":
            return ["25006", "25P02", "25P03", "25P04"].contains(state)
        case "55":
            return state == "55P03" || state == "55006"
        case "42":
            return state == "42501"
        default:
            return false
        }
    }

    /// Whether a `query_canceled` (SQLSTATE 57014) is the server's statement timeout rather than an
    /// administrator's `pg_cancel_backend` or a conflict with recovery on a standby. A server that writes its
    /// messages in English names the cause. One whose `lc_messages` translates them (a superuser-only
    /// setting, so Tidemark cannot ask for English) is judged by time instead: the call held its connection
    /// at least as long as its statement timeout, which a timeout guarantees and a cancel from elsewhere
    /// rarely does.
    static func isStatementTimeout(message: String?, statementTimeout: Duration?, ranFor: Duration?) -> Bool {
        let message = message ?? ""
        if message.contains("statement timeout") { return true }
        if message.hasPrefix("canceling statement due to") { return false }
        guard let statementTimeout, let ranFor else { return false }
        return ranFor >= statementTimeout
    }

    /// Why a connection or a call failed, without credentials. The causes Tidemark recognizes are typed, so
    /// the UI can describe them in its own language; the server's own message and anything unknown stay as
    /// reported.
    static func describe(_ error: any Error, endpoint: PostgresConnectionURL?) -> DatabaseError.UnreachableReason {
        let target = endpoint?.redacted
        switch error {
        case let error as DatabaseError:
            switch error {
            case .unreachable(let reason): return reason
            case .timedOut(let reason): return .message(reason.description)
            case .query(let message): return .message(message)
            case .notConfigured, .invalidURL: return .message(error.errorDescription ?? "\(error)")
            }
        case let error as PSQLError:
            if let message = error.serverInfo?[.message] {
                if let detail = error.serverInfo?[.detail], !detail.isEmpty { return .message("\(message) (\(detail))") }
                return .message(message)
            }
            switch error.code {
            case .sslUnsupported: return .tlsNotAccepted(target: target)
            case .failedToAddSSLHandler: return .tlsUnavailable(target: target)
            case .unsupportedAuthMechanism: return .unsupportedAuthentication(target: target)
            case .authMechanismRequiresPassword: return .passwordRequired(target: target)
            case .saslError: return .authenticationFailed(target: target)
            case .serverClosedConnection, .uncleanShutdown: return .serverClosedConnection(target: target)
            case .clientClosedConnection, .poolClosed: return .connectionClosed(target: target)
            default:
                if let underlying = error.underlying { return describe(underlying, endpoint: endpoint) }
                return .message("PostgreSQL error (\(error.code)).")
            }
        case let error as NIOConnectionError:
            if let dns = error.dnsAError ?? error.dnsAAAAError { return .cannotResolve(host: error.host, detail: "\(dns)") }
            return .cannotConnect(target: target, reason: error.connectionErrors.first.map { describe($0.error, endpoint: endpoint) })
        case let error as IOError:
            // macOS answers EHOSTUNREACH when Local Network privacy blocks the app from a LAN address.
            if error.errnoCode == EHOSTUNREACH, let host = endpoint?.host, isLocalNetworkHost(host) { return .localNetworkBlocked }
            return .message(String(cString: strerror(error.errnoCode)))
        case let error as ChannelError:
            if case .connectTimeout = error { return .connectTimedOut(target: target) }
            return .connectionFailed(target: target, detail: "\(error)")
        case let error as NIOSSLError:
            return .tlsFailed(target: target, detail: "\(error)")
        default:
            return .message(String(describing: error))
        }
    }

    /// Private, link-local or `.local` addresses, which macOS gates behind Local Network privacy.
    static func isLocalNetworkHost(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower.hasSuffix(".local") { return true }
        if HostName.isIPv4(lower) {
            let octets = lower.split(separator: ".").compactMap { Int($0) }
            switch (octets[0], octets[1]) {
            case (10, _), (192, 168), (169, 254): return true
            case (172, 16...31): return true
            default: return false
            }
        }
        guard lower.contains(":") else { return false }
        return lower.hasPrefix("fe80:") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
    }

    /// Errors that retrying cannot fix: wrong credentials, unknown database, TLS mismatch.
    private static func isPermanentConnectFailure(_ error: any Error) -> Bool {
        guard let error = error as? PSQLError else { return error is NIOSSLError }
        switch error.code {
        case .server:
            let state = error.serverInfo?[.sqlState] ?? ""
            return state.hasPrefix("28") || state == "3D000"
        case .sslUnsupported, .unsupportedAuthMechanism, .authMechanismRequiresPassword, .saslError, .failedToAddSSLHandler:
            return true
        default:
            return false
        }
    }
}

/// Hand-over of a pooled connection between `withConnection`'s lease and its timeout: whichever of the
/// two moves first wins, so the body never runs once the caller was told the lease timed out.
private final class LeaseState: Sendable {
    private static let waiting: UInt8 = 0
    private static let leased: UInt8 = 1
    private static let expired: UInt8 = 2

    private let value = Atomic<UInt8>(LeaseState.waiting)

    /// The lease got a connection; false when the timeout already fired.
    func claim() -> Bool {
        value.compareExchange(expected: Self.waiting, desired: Self.leased, ordering: .acquiringAndReleasing).exchanged
    }

    /// The timeout fired; false when a connection was already handed to the body.
    func expire() -> Bool {
        value.compareExchange(expected: Self.waiting, desired: Self.expired, ordering: .acquiringAndReleasing).exchanged
    }
}

private enum LeaseOutcome<Value: Sendable>: Sendable {
    case finished(Value)
    case leased
    case abandoned
}

/// Why a call closed its connection.
private enum CallCloseReason: Sendable {
    /// The call limit passed.
    case expired
    /// The caller gave up (writer pool).
    case cancelled
}

/// One call on a leased connection. `body` runs in a task of its own; the call closes the connection when
/// its limit passes or, on the writer pool, when the caller gives up, but never after the call ended: by
/// then the connection may already serve another call.
///
/// A call that closed its connection ends as soon as the connection is closed, even while `body` still
/// waits: PostgresNIO never answers a statement sent after its connection finished closing (NIO drops the
/// write into the torn-down channel pipeline without failing the statement, and the wait cannot be
/// cancelled), so a `body` caught rolling back, cleaning up or between two statements would otherwise hold
/// its caller forever, call limit or not. The abandoned `body` is cancelled and ends, or waits, on its own,
/// on a dead connection.
///
/// A closed connection goes back to the pool only once its close future completed: the pool, which watches
/// the same future, has then dropped it and never leases it again.
private final class LeasedCall<Value: Sendable>: Sendable {
    enum Outcome: Sendable {
        /// `body` finished; `closedBy` tells why the call closed the connection meanwhile, if it did.
        case finished(Result<Value, any Error>, closedBy: CallCloseReason?)
        /// The call closed the connection, which is now closed, and `body` has not finished.
        case abandoned(CallCloseReason)
    }

    private struct State {
        var continuation: CheckedContinuation<Outcome, Never>?
        /// The outcome when the call ended before `run` installed the continuation (cancelled at once).
        var early: Outcome?
        var result: Result<Value, any Error>?
        var reason: CallCloseReason?
        var cancelled = false
        /// Whether the connection's close future is watched, and whether it completed.
        var watchingClose = false
        var closed = false
        var ended = false
        var work: Task<Void, Never>?
        var timer: Task<Void, Never>?
    }

    /// What to do outside the lock after an event.
    private struct Step {
        var resume: (CheckedContinuation<Outcome, Never>, Outcome)?
        var cancel: [Task<Void, Never>] = []
        var watchClose = false
    }

    private let connection: PostgresConnection
    private let state = Mutex(State())

    init(_ connection: PostgresConnection) { self.connection = connection }

    /// Runs `body`, closing the connection when `limit` passes first, and returns once the call ended.
    func run(_ body: @escaping @Sendable (PostgresConnection) async throws -> Value, limit: Duration) async -> Outcome {
        await withCheckedContinuation { continuation in
            let early = state.withLock { state -> Outcome? in
                if let early = state.early { return early }
                state.continuation = continuation
                return nil
            }
            if let early {
                continuation.resume(returning: early)
                return
            }
            let connection = connection
            let work = Task(name: "PostgreSQL call") {
                let result: Result<Value, any Error>
                do { result = .success(try await body(connection)) } catch { result = .failure(error) }
                self.finished(result)
            }
            let timer = Task(name: "PostgreSQL call limit") {
                do { try await Task.sleep(for: limit) } catch { return }
                self.close(.expired)
            }
            let cancel = state.withLock { state -> [Task<Void, Never>] in
                if state.ended { return [work, timer] }
                state.work = work
                state.timer = timer
                return state.cancelled ? [work] : []
            }
            for task in cancel { task.cancel() }
        }
    }

    /// The caller gave up: closes the connection first (so a `COMMIT` sent from now on cannot succeed),
    /// then cancels `body`.
    func cancel(closingConnection: Bool) {
        if closingConnection { close(.cancelled) }
        let work = state.withLock { state -> Task<Void, Never>? in
            state.cancelled = true
            return state.work
        }
        work?.cancel()
    }

    /// Closes the connection, unless the call ended, `body` finished or the connection is being closed.
    func close(_ reason: CallCloseReason) {
        let closes = state.withLock { state -> Bool in
            guard !state.ended, state.result == nil, state.reason == nil else { return false }
            state.reason = reason
            state.watchingClose = true
            return true
        }
        guard closes else { return }
        // The future-returning close: this runs synchronously (in a cancellation handler or a timer task). Its
        // future completes at once for a connection that is already closing, so the call watches the channel's
        // close future instead, whose callbacks run after the pool's.
        let _: EventLoopFuture<Void> = connection.close()
        connection.closeFuture.whenComplete { _ in self.connectionClosed() }
    }

    private func finished(_ result: Result<Value, any Error>) {
        let step = state.withLock { state -> Step in
            state.result = result
            return settle(&state)
        }
        perform(step)
    }

    private func connectionClosed() {
        let step = state.withLock { state -> Step in
            state.closed = true
            return settle(&state)
        }
        perform(step)
    }

    /// Ends the call once it can end: `body` finished on a connection that is open (or whose close the pool
    /// saw), or the call closed the connection and it is closed.
    private func settle(_ state: inout State) -> Step {
        var step = Step()
        guard !state.ended else { return step }
        let outcome: Outcome
        if let result = state.result {
            if !state.closed, state.reason != nil || connection.isClosed {
                if !state.watchingClose {
                    state.watchingClose = true
                    step.watchClose = true
                }
                return step
            }
            outcome = .finished(result, closedBy: state.reason)
        } else if let reason = state.reason, state.closed {
            outcome = .abandoned(reason)
        } else {
            return step
        }
        state.ended = true
        step.cancel = [state.timer, state.work].compactMap { $0 }
        if let continuation = state.continuation {
            state.continuation = nil
            step.resume = (continuation, outcome)
        } else {
            state.early = outcome
        }
        return step
    }

    private func perform(_ step: Step) {
        if step.watchClose { connection.closeFuture.whenComplete { _ in self.connectionClosed() } }
        if case let (continuation, outcome)? = step.resume { continuation.resume(returning: outcome) }
        for task in step.cancel { task.cancel() }
    }
}
