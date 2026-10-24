import Foundation

/// Something that may have changed the egress IP; the next check logs it as the cause of a change.
enum EgressSignal: Hashable, Sendable {
    /// An `environment` event: a policy group selection or the outbound mode changed.
    case policyChanged
    case profileReloaded
    /// Surge's `start-time` changed between connections.
    case surgeRestarted
    /// The primary interface changed, e.g. `Wi-Fi “Office-5G”`.
    case networkChanged(String)
    /// The Mac woke from sleep (re-check only).
    case wake

    /// Stored reason for an `EgressChange` (English; the UI translates known reasons).
    var reason: String? {
        switch self {
        case .policyChanged: "Policy group switched by hand"
        case .profileReloaded: "Profile reloaded"
        case .surgeRestarted: "Surge restarted"
        case .networkChanged(let description): "Network changed to \(description)"
        case .wake: nil
        }
    }
}

/// A policy whose egress IP is checked.
struct EgressCandidate: Hashable, Sendable {
    /// `["Proxy", "HK-01"]`, `["DIRECT"]`.
    var policyPath: [String]
    /// What `test-policy-external-ip` / `test-policy` get: the leaf's line hash, else its name.
    var target: String

    var leaf: String { policyPath.last ?? target }
}

/// Which policies to check and which one is current, from Surge's policy groups and environment.
enum EgressPlanner {
    struct Plan: Hashable, Sendable {
        var candidates: [EgressCandidate]
        /// Path of the policy the outbound mode / FINAL rule uses, when known.
        var currentPath: [String]?
    }

    static let builtIn: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "REJECT-NO-DROP"]

    /// DIRECT, then each group's current selection followed down to a leaf policy, deduplicated by leaf;
    /// the current route is always included.
    static func plan(groups: [SurgePolicyGroup], environment: SurgeEnvironment, ruleMatch: SurgeRuleMatch?) -> Plan {
        let byName = Dictionary(groups.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        var hashes: [String: String] = [:]
        for group in groups {
            for option in group.options where option.isGroup != true {
                if let hash = option.lineHash, hashes[option.name] == nil { hashes[option.name] = hash }
            }
        }
        func candidate(_ path: [String]) -> EgressCandidate? {
            guard let leaf = path.last, !leaf.uppercased().hasPrefix("REJECT"), byName[leaf] == nil else { return nil }
            return EgressCandidate(policyPath: path, target: builtIn.contains(leaf.uppercased()) ? leaf.uppercased() : (hashes[leaf] ?? leaf))
        }

        var candidates = [EgressCandidate(policyPath: ["DIRECT"], target: "DIRECT")]
        var leaves: Set<String> = ["direct"]
        for group in groups {
            let path = resolve(group.name, groups: byName, selections: environment.groupSelections)
            guard let c = candidate(path), leaves.insert(c.leaf.lowercased()).inserted else { continue }
            candidates.append(c)
        }

        let current = currentPath(environment: environment, ruleMatch: ruleMatch, groups: byName, candidates: candidates)
        if let current, let c = candidate(current), leaves.insert(c.leaf.lowercased()).inserted {
            candidates.append(c)
        }
        return Plan(candidates: candidates, currentPath: current)
    }

    /// Follows group selections from `name` down to a leaf policy: `["AI", "US", "AT&T-RackNerd-Hysteria2"]`.
    static func resolve(_ name: String, groups: [String: SurgePolicyGroup], selections: [String: String]) -> [String] {
        var path = [name]
        var current = name
        while path.count < 8, let group = groups[current] {
            guard let next = selections[current] ?? group.selected ?? group.options.first?.name, !path.contains(next) else { break }
            path.append(next)
            current = next
        }
        return path
    }

    /// Direct mode → DIRECT; global proxy → the global policy's path; rule mode → the policy the FINAL
    /// route (a rule match on a neutral host) uses.
    static func currentPath(environment: SurgeEnvironment, ruleMatch: SurgeRuleMatch?, groups: [String: SurgePolicyGroup], candidates: [EgressCandidate]) -> [String]? {
        switch environment.proxyMode {
        case 0:
            return ["DIRECT"]
        case 1:
            return resolve(environment.globalPolicy ?? "DIRECT", groups: groups, selections: environment.groupSelections)
        default:
            guard let policy = ruleMatch?.policy, !policy.isEmpty else { return nil }
            if groups[policy] != nil { return resolve(policy, groups: groups, selections: environment.groupSelections) }
            if let known = candidates.first(where: { $0.leaf.caseInsensitiveCompare(policy) == .orderedSame }) { return known.policyPath }
            return [policy]
        }
    }

    /// `Hong Kong`, `Japan` from an ISO region code (English, like every value stored in the database).
    static func countryName(_ code: String?) -> String? {
        guard let code = code?.trimmingCharacters(in: .whitespaces).uppercased(), !code.isEmpty else { return nil }
        let short = ["HK": "Hong Kong", "MO": "Macao", "TW": "Taiwan", "US": "United States", "GB": "United Kingdom", "KR": "South Korea", "RU": "Russia"]
        if let name = short[code] { return name }
        return Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
    }

    /// `AS9009 M247 Europe SRL`
    static func network(asn: Int?, organization: String?) -> String? {
        let parts = [asn.map { "AS\($0)" }, organization?.trimmingCharacters(in: .whitespaces)].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    /// Current sample first (with the current route's path), the rest in candidate order.
    static func arrange(_ samples: [EgressSample], currentPath: [String]?) -> [EgressSample] {
        var samples = samples
        guard let currentPath, let leaf = currentPath.last,
              let index = samples.firstIndex(where: { $0.policyPath.last?.caseInsensitiveCompare(leaf) == .orderedSame }) else {
            return samples
        }
        var current = samples.remove(at: index)
        current.isCurrent = true
        current.policyPath = currentPath
        return [current] + samples
    }
}
