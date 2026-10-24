import Foundation

/// Egress IP observed through one policy (row in `egress_checks`).
struct EgressSample: Identifiable, Hashable, Codable, Sendable {
    /// e.g. `["AI", "AT&T-RackNerd-Hysteria2"]`, `["DIRECT"]`.
    var policyPath: [String]
    var ip: String?
    /// `Hong Kong`, `Los Angeles, US`
    var location: String?
    /// `AS9009 M247 Europe SRL`
    var network: String?
    var latencyMs: Int?
    /// The policy the current outbound mode / FINAL rule sends traffic through.
    var isCurrent: Bool
    var checkedAt: Date
    var error: String?

    var id: String { policyPath.joined(separator: "›") }
    var policyDisplay: String { policyPath.joined(separator: " › ") }
}

/// A change of the current egress IP (row in `egress_changes`).
struct EgressChange: Identifiable, Hashable, Codable, Sendable {
    var id: Int64
    var changedAt: Date
    var ip: String
    var policyPath: [String]
    /// Human readable cause, e.g. "Policy group switched by hand", "Surge restarted".
    var reason: String
}

/// Result of "Look up an IP".
struct IPLookupResult: Hashable, Sendable {
    var ip: String
    var country: String?
    var asn: Int?
    var organization: String?
    /// `Hosting · anycast`, `Residential`… from the configured IP info service.
    var networkType: String?
    var reverseDNS: String?
}

/// Network facts about this Mac, from `surge-cli summary` / `status`.
struct ThisMacNetwork: Hashable, Sendable {
    var interface: String?
    var interfaceDetail: String?
    var localIP: String?
    var router: String?
    var dnsServers: [String]
    /// e.g. `Enhanced mode · rule-based`
    var surgeMode: String?
}
