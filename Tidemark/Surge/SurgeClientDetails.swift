import Foundation

/// Surge facts beyond `SurgeClient` that `SurgeCLIClient` can read. Callers check for this protocol with
/// `as? any SurgeClientDetails` and fall back to the plain `SurgeClient` calls when a client (a test double,
/// a placeholder) does not provide it.
protocol SurgeClientDetails: SurgeClient {
    /// Interface and port of Surge's HTTP proxy listener (`dump event`). Throws `SurgeHTTPProxyOff` when
    /// Surge reports no HTTP listener.
    func httpProxyListener() async throws -> SurgeHTTPListener
    /// The policy the profile's `FINAL` rule names (`dump rule`), often a policy group; nil when the
    /// profile has no FINAL rule.
    func finalRulePolicy() async throws -> String?
}

/// Where Surge's HTTP proxy listens, from `HTTP proxy listen on interface: 0.0.0.0, port: 6152`.
struct SurgeHTTPListener: Hashable, Sendable {
    /// Address the listener is bound to as Surge reports it: `0.0.0.0`, `127.0.0.1`, `192.168.1.20`, `::`.
    var interface: String
    var port: Int

    /// Address a client on this Mac connects to: loopback for wildcard and loopback listeners, the bound
    /// address otherwise (a listener bound to a LAN address does not accept loopback connections).
    var connectHost: String {
        let host = interface.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        switch host {
        case "", "*", "0.0.0.0", "localhost", "127.0.0.1": return "127.0.0.1"
        case "::", "::1": return "::1"
        default: return host
        }
    }
}

/// Surge has no HTTP proxy listener: its HTTP proxy is turned off (no `http-listen`).
struct SurgeHTTPProxyOff: Error, Hashable, Sendable, LocalizedError {
    var errorDescription: String? { "Surge's HTTP proxy is not listening." }
}
