import Foundation

/// Why the Surge link is down when no call failed. `errorDescription` is English, for the log.
enum CaptureSurgeFailure: Error, Equatable, LocalizedError {
    /// The watch ended without an error.
    case stoppedStreaming
    /// Surge announced that it is quitting.
    case shuttingDown

    var errorDescription: String? {
        switch self {
        case .stoppedStreaming: "Surge stopped streaming"
        case .shuttingDown: "Surge is shutting down"
        }
    }
}

/// The reasons inside `CaptureEngine.message(for:)`'s failures, in the UI language. Text the server, the
/// network or surge-cli reported stays as it was reported.
extension CaptureEngine {
    /// Why PostgreSQL is unreachable (the part after "PostgreSQL is unreachable:").
    static func message(for reason: DatabaseError.UnreachableReason) -> String {
        switch reason {
        case .message(let text): text
        case .notConnected: tr("Not connected.", "Capture")
        case .shutDown: tr("The database connection was shut down.", "Capture")
        case .poolClosed: tr("The connection pool is closed.", "Capture")
        case .noConnection(let target, let wait): trf("No connection to %1$@ within %2$@.", "Capture", serverName(target), spoken(wait))
        case .cannotResolve(let host, let detail): trf("Could not resolve %1$@: %2$@", "Capture", host, detail)
        case .cannotConnect(let target, let reason?): trf("Could not connect to %1$@: %2$@", "Capture", serverName(target), message(for: reason))
        case .cannotConnect(let target, nil): trf("Could not connect to %@.", "Capture", serverName(target))
        case .connectTimedOut(let target): trf("Timed out connecting to %@.", "Capture", serverName(target))
        case .connectionFailed(let target, let detail): trf("Connection to %1$@ failed (%2$@).", "Capture", serverName(target), detail)
        case .localNetworkBlocked:
            tr("No route to host. If the server is on your local network, allow Tidemark in System Settings › Privacy & Security › Local Network.", "Capture")
        case .serverClosedConnection(let target): trf("%@ closed the connection.", "Capture", serverName(target))
        case .connectionClosed(let target): trf("The connection to %@ was closed.", "Capture", serverName(target))
        case .passwordRequired(let target): trf("%@ requires a password.", "Capture", serverName(target))
        case .unsupportedAuthentication(let target):
            trf("%@ asked for an authentication method Tidemark does not support.", "Capture", serverName(target))
        case .authenticationFailed(let target): trf("SCRAM authentication with %@ failed.", "Capture", serverName(target))
        case .tlsNotAccepted(let target): trf("%@ does not accept TLS connections; use sslmode=disable or prefer.", "Capture", serverName(target))
        case .tlsUnavailable(let target): trf("Could not start TLS with %@.", "Capture", serverName(target))
        case .tlsFailed(let target, let detail): trf("TLS error with %1$@: %2$@", "Capture", serverName(target), detail)
        case .migrationInProgress: tr("Another Mac is upgrading the database; Tidemark will try again shortly.", "Capture")
        case .indexBuildInProgress: tr("Another Mac is building the database's indexes; Tidemark will try again shortly.", "Capture")
        case .schemaTooNew(let schema, let supported):
            trf("The database was upgraded by a newer version of Tidemark (schema %1$lld); this version (schema %2$lld) cannot write to it. Update Tidemark on this Mac.",
                "Capture", schema, supported)
        }
    }

    /// What took too long (the part after "PostgreSQL query timed out:").
    static func message(for reason: DatabaseError.TimeoutReason) -> String {
        switch reason {
        case .statement(let timeout?): trf("The server cancelled it after %@ (statement timeout).", "Capture", spoken(timeout))
        case .statement(nil): tr("The server cancelled it at its statement timeout.", "Capture")
        case .noReply(let target, let limit):
            trf("No reply from %1$@ within %2$@; the connection was closed.", "Capture", serverName(target), spoken(limit))
        }
    }

    /// A duration in the UI language: `50 ms`, `30 s`, `5 min`.
    static func spoken(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        if seconds == 0 { return trf("%lld ms", "Capture", attoseconds / 1_000_000_000_000_000) }
        if seconds >= 120, seconds.isMultiple(of: 60) { return trf("%lld min", "Capture", seconds / 60) }
        return trf("%lld s", "Capture", seconds)
    }

    /// The server as `host:port/database`, or "the server" when it is not known.
    private static func serverName(_ target: String?) -> String {
        target ?? tr("the server", "Capture")
    }
}
