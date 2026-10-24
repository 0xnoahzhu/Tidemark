import Foundation
import Logging
import NIOCore
import NIOPosix
import NIOSSL
import PostgresNIO
import Synchronization

/// `TidemarkDatabase` on PostgreSQL, through PostgresNIO's pooled `PostgresClient`.
///
/// Lifecycle: create it with a connection URL, call `connect()` (starts the pool and waits until the
/// server answers), then `migrate()`. Call `shutdown()` when the app quits; a database that was shut
/// down cannot be connected again — create a new instance instead (e.g. after the URL changes).
///
/// Every pooled connection runs with `search_path = <schema>, public`, so all SQL is written without a
/// schema prefix and the same code serves production (`public`) and throwaway test schemas.
///
/// Errors: connection problems surface as `DatabaseError.unreachable`, errors reported by the server as
/// `DatabaseError.query`. Cancelling the calling task throws `CancellationError`. All methods are safe
/// to call concurrently; each one leases its own connection from the pool.
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

    private struct Setup: Sendable {
        var client: PostgresClient
        var url: PostgresConnectionURL
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

    /// Starts the connection pool (once) and waits up to ~5 s for the server to answer.
    ///
    /// Authentication failures and unknown databases fail immediately; network errors are retried
    /// until the deadline. Throws `DatabaseError.unreachable` with the server's or the network's reason.
    func connect() async throws {
        let setup = try setup.get()
        try startPool(setup.client)
        try await probeServer(setup, within: .seconds(5))
        do {
            _ = try await withConnection { connection in
                try await connection.query("SELECT 1", logger: Self.logger).collect()
            }
        } catch let error as DatabaseError {
            throw DatabaseError.unreachable(Self.reason(error))
        }
    }

    /// Closes every pooled connection and waits for the pool to stop, even when the calling task is
    /// being cancelled (e.g. during app termination after the final flush).
    func shutdown() async {
        let task: Task<Void, Never>? = lifecycle.withLock { state in
            defer { state = .shutDown }
            if case .running(let task) = state { return task }
            return nil
        }
        guard let task else { return }
        task.cancel()
        await withTaskCancellationShield {
            await task.value
        }
    }

    /// Round trip of `SELECT 1` on a pooled connection, plus `PostgreSQL <server_version>`.
    func ping() async throws -> (roundTrip: Duration, serverVersion: String) {
        try await withConnection { connection in
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

    private func startPool(_ client: PostgresClient) throws {
        try lifecycle.withLock { state in
            switch state {
            case .idle:
                state = .running(Task.detached(name: "Tidemark PostgreSQL pool") {
                    await client.run()
                })
            case .running:
                break
            case .shutDown:
                throw DatabaseError.unreachable("The database connection was shut down.")
            }
        }
    }

    /// The pool, once `connect()` started it.
    private func runningClient() throws -> PostgresClient {
        let client = try setup.get().client
        let isRunning = lifecycle.withLock { state in
            if case .running = state { return true }
            return false
        }
        guard isRunning else { throw DatabaseError.unreachable("Not connected.") }
        return client
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
        var lastError: any Error = DatabaseError.unreachable("Timed out.")
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

    /// Leases a pooled connection for `body`. Fails with `.unreachable` when no connection becomes
    /// available within `leaseTimeout`; once leased, `body` runs to completion.
    func withConnection<Result: Sendable>(
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        let client = try runningClient()
        let leased = LeaseFlag()
        let timeout = leaseTimeout
        let endpoint = self.endpoint
        do {
            return try await withThrowingTaskGroup(of: LeaseOutcome<Result>.self) { group in
                group.addTask(name: "PostgreSQL lease") {
                    try await client.withConnection { connection in
                        leased.set()
                        return LeaseOutcome.finished(try await body(connection))
                    }
                }
                group.addTask(name: "PostgreSQL lease timeout") {
                    try await Task.sleep(for: timeout)
                    guard leased.isSet else {
                        throw DatabaseError.unreachable("No connection to \(endpoint?.redacted ?? "the server") within \(timeout.components.seconds) s.")
                    }
                    return .leased
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
            throw Self.map(error, endpoint: endpoint)
        }
    }

    /// Runs `body` inside `BEGIN … COMMIT` on one leased connection; rolls back when it throws.
    /// A transaction chosen as a deadlock victim (or failing serialization) is retried up to two more
    /// times, so `body` must be safe to run again (all of ours rebuild their state inside the closure).
    func withTransaction<Result: Sendable>(
        _ body: @escaping @Sendable (PostgresConnection) async throws -> Result
    ) async throws -> Result {
        try await withConnection { connection in
            var attempt = 1
            while true {
                try await connection.query("BEGIN", logger: Self.logger)
                do {
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
        guard let error = error as? PSQLError, error.code == .server else { return false }
        let state = error.serverInfo?[.sqlState]
        return state == "40P01" || state == "40001"
    }

    /// Rolls back even when the task is cancelled; a connection that cannot roll back is closed so it
    /// never returns to the pool inside an open transaction.
    static func rollback(_ connection: PostgresConnection) async {
        await withTaskCancellationShield {
            do {
                try await connection.query("ROLLBACK", logger: logger)
            } catch {
                try? await connection.close()
            }
        }
    }

    /// Runs a statement and returns its rows.
    func rows(_ query: PostgresQuery) async throws -> [PostgresRow] {
        try await withConnection { connection in
            try await connection.query(query, logger: Self.logger).collect()
        }
    }

    /// Runs a statement and discards its result.
    func execute(_ query: PostgresQuery) async throws {
        _ = try await rows(query)
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
        let tls: PostgresClient.Configuration.TLS = switch url.tls {
        case .disable: .disable
        case .prefer: .prefer(tlsConfiguration(.none))
        case .require: .require(tlsConfiguration(.none))
        case .verifyCA: .require(tlsConfiguration(.noHostnameVerification))
        case .verifyFull: .require(tlsConfiguration(.fullVerification))
        }

        let searchPath = schema == "public" ? "public" : "\(quoteIdentifier(schema)), public"
        let parameters = [("search_path", searchPath), ("application_name", "Tidemark")]

        var configuration: PostgresClient.Configuration
        if let socket = url.socketPath {
            configuration = .init(unixSocketPath: socket, username: url.username, password: url.password, database: url.database)
        } else {
            configuration = .init(host: url.host, port: url.port, username: url.username, password: url.password, database: url.database, tls: tls)
        }
        configuration.options.connectTimeout = .seconds(5)
        configuration.options.minimumConnections = 1
        configuration.options.maximumConnections = 8
        configuration.options.connectionIdleTimeout = .seconds(120)
        configuration.options.additionalStartupParameters = parameters

        return Setup(client: PostgresClient(configuration: configuration), url: url, startupParameters: parameters)
    }

    private static func tlsConfiguration(_ verification: CertificateVerification) -> TLSConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        configuration.certificateVerification = verification
        return configuration
    }

    /// A standalone-connection configuration equivalent to the pool's, for `probeServer`.
    private static func directConfiguration(_ setup: Setup, timeout: Duration) throws -> PostgresConnection.Configuration {
        let url = setup.url
        var configuration: PostgresConnection.Configuration
        if let socket = url.socketPath {
            configuration = .init(unixSocketPath: socket, username: url.username, password: url.password, database: url.database)
        } else {
            let tls: PostgresConnection.Configuration.TLS = switch url.tls {
            case .disable: .disable
            case .prefer: .prefer(try NIOSSLContext(configuration: tlsConfiguration(.none)))
            case .require: .require(try NIOSSLContext(configuration: tlsConfiguration(.none)))
            case .verifyCA: .require(try NIOSSLContext(configuration: tlsConfiguration(.noHostnameVerification)))
            case .verifyFull: .require(try NIOSSLContext(configuration: tlsConfiguration(.fullVerification)))
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
    static func map(_ error: any Error, endpoint: PostgresConnectionURL? = nil) -> any Error {
        switch error {
        case let error as DatabaseError:
            return error
        case is CancellationError:
            return error
        case let error as PSQLError:
            switch error.code {
            case .server:
                let state = error.serverInfo?[.sqlState] ?? ""
                let message = describe(error, endpoint: endpoint)
                // 08: connection exception, 28: invalid authorization, 3D000: unknown database,
                // 53300: too many connections, 57P0x: server shutting down / starting up.
                if state.hasPrefix("08") || state.hasPrefix("28") || state == "3D000" || state == "53300" || state.hasPrefix("57P0") {
                    return DatabaseError.unreachable(message)
                }
                return DatabaseError.query(message)
            case .queryCancelled:
                return CancellationError()
            case .tooManyParameters, .messageDecodingFailure, .unexpectedBackendMessage, .invalidCommandTag:
                return DatabaseError.query(describe(error, endpoint: endpoint))
            default:
                return DatabaseError.unreachable(describe(error, endpoint: endpoint))
            }
        case let error as PostgresDecodingError:
            return DatabaseError.query("Could not read column \(error.columnName) (\(error.code)).")
        case is IOError, is ChannelError, is NIOConnectionError, is NIOSSLError:
            return DatabaseError.unreachable(describe(error, endpoint: endpoint))
        default:
            // _ConnectionPoolModule.ConnectionPoolError (pool shut down, request cancelled) is internal.
            let typeName = String(describing: type(of: error))
            if typeName.contains("ConnectionPoolError") {
                return Task.isCancelled ? CancellationError() : DatabaseError.unreachable("The connection pool is closed.")
            }
            return DatabaseError.query(String(describing: error))
        }
    }

    /// A short, human-readable reason for a failure, without credentials.
    static func describe(_ error: any Error, endpoint: PostgresConnectionURL?) -> String {
        let target = endpoint?.redacted ?? "the server"
        switch error {
        case let error as DatabaseError:
            return reason(error)
        case let error as PSQLError:
            if let message = error.serverInfo?[.message] {
                if let detail = error.serverInfo?[.detail], !detail.isEmpty { return "\(message) (\(detail))" }
                return message
            }
            switch error.code {
            case .sslUnsupported: return "\(target) does not accept TLS connections; use sslmode=disable or prefer."
            case .failedToAddSSLHandler: return "Could not start TLS with \(target)."
            case .unsupportedAuthMechanism: return "\(target) asked for an authentication method Tidemark does not support."
            case .authMechanismRequiresPassword: return "\(target) requires a password."
            case .saslError: return "SCRAM authentication with \(target) failed."
            case .serverClosedConnection, .uncleanShutdown: return "\(target) closed the connection."
            case .clientClosedConnection, .poolClosed: return "The connection to \(target) was closed."
            default:
                if let underlying = error.underlying { return describe(underlying, endpoint: endpoint) }
                return "PostgreSQL error (\(error.code))."
            }
        case let error as NIOConnectionError:
            if let dns = error.dnsAError ?? error.dnsAAAAError { return "Could not resolve \(error.host): \(dns)" }
            if let first = error.connectionErrors.first { return "Could not connect to \(target): \(describe(first.error, endpoint: endpoint))" }
            return "Could not connect to \(target)."
        case let error as IOError:
            let reason = String(cString: strerror(error.errnoCode))
            // macOS answers EHOSTUNREACH when Local Network privacy blocks the app from a LAN address.
            if error.errnoCode == EHOSTUNREACH, let host = endpoint?.host, isLocalNetworkHost(host) {
                return "\(reason). If the server is on your local network, allow Tidemark in System Settings › Privacy & Security › Local Network."
            }
            return reason
        case let error as ChannelError:
            if case .connectTimeout = error { return "Timed out connecting to \(target)." }
            return "Connection to \(target) failed (\(error))."
        case let error as NIOSSLError:
            return "TLS error with \(target): \(error)"
        default:
            return String(describing: error)
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

    /// The message of a `DatabaseError` without its "PostgreSQL is unreachable:" style prefix.
    static func reason(_ error: DatabaseError) -> String {
        switch error {
        case .notConfigured, .invalidURL: error.errorDescription ?? "\(error)"
        case .unreachable(let message), .query(let message): message
        }
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

/// Set once a pooled connection has been handed to a `withConnection` body.
private final class LeaseFlag: Sendable {
    private let value = Atomic<Bool>(false)
    func set() { value.store(true, ordering: .releasing) }
    var isSet: Bool { value.load(ordering: .acquiring) }
}

private enum LeaseOutcome<Value: Sendable>: Sendable {
    case finished(Value)
    case leased
}
