import Foundation

/// Reasons stored with an `EgressChange`. They are English, like every value in the database; the UI
/// translates them (`Network changed to %@` with the network description as the argument).
enum EgressReason {
    static let manualSwitch = "Policy group switched by hand"
    static let autoTest = "Auto test picked a faster node"
    static let profileReloaded = "Profile reloaded"
    static let surgeRestarted = "Surge restarted"
    /// No cause was observed.
    static let unknown = "Egress changed"
    static let networkChangedPrefix = "Network changed to "

    /// `Network changed to Wi-Fi “Office-5G”`, `Network changed to Ethernet`.
    static func networkChanged(_ description: String) -> String { networkChangedPrefix + description }
}

/// Something that may have changed the egress IP; the next check logs it as the cause of a change.
enum EgressSignal: Hashable, Sendable {
    /// An `environment` event: a policy group selection or the outbound mode changed.
    case policyChanged
    case profileReloaded
    /// Surge's `start-time` changed between connections.
    case surgeRestarted
    /// The network changed, e.g. `Wi-Fi “Office-5G”`, `Ethernet`.
    case networkChanged(String)
    /// The Mac woke from sleep (re-check only).
    case wake

    /// Stored reason for an `EgressChange` (English; the UI translates known reasons).
    var reason: String? {
        switch self {
        case .policyChanged: EgressReason.manualSwitch
        case .profileReloaded: EgressReason.profileReloaded
        case .surgeRestarted: EgressReason.surgeRestarted
        case .networkChanged(let description): EgressReason.networkChanged(description)
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
        /// What routes traffic through `currentPath`: `FINAL` (or the rule a neutral destination matched)
        /// in rule mode, `Global · AI` in global proxy mode, nil in direct mode or when unknown.
        var currentRule: String?
    }

    /// Facts beyond `environment` that pin down the current route.
    struct RouteHints: Hashable, Sendable {
        /// The policy the profile's FINAL rule names (`dump rule`), used in rule mode.
        var finalPolicy: String?
        /// `rule match` on a neutral destination, used in rule mode when the FINAL rule is unknown.
        var ruleMatch: SurgeRuleMatch?
        /// `status` → `global-policy`, used in global proxy mode when `environment` has no global policy.
        var statusGlobalPolicy: String?
    }

    static let builtIn: Set<String> = ["DIRECT", "REJECT", "REJECT-DROP", "REJECT-TINYGIF", "REJECT-NO-DROP"]

    /// DIRECT, then each group's current selection followed down to a leaf policy, deduplicated by leaf;
    /// the current route is always included.
    static func plan(groups: [SurgePolicyGroup], environment: SurgeEnvironment, hints: RouteHints) -> Plan {
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

        let route = currentRoute(environment: environment, hints: hints, groups: byName, candidates: candidates)
        if let current = route.path, let c = candidate(current), leaves.insert(c.leaf.lowercased()).inserted {
            candidates.append(c)
        }
        return Plan(candidates: candidates, currentPath: route.path, currentRule: route.rule)
    }

    /// `plan(groups:environment:hints:)` with only a rule match on a neutral destination.
    static func plan(groups: [SurgePolicyGroup], environment: SurgeEnvironment, ruleMatch: SurgeRuleMatch?) -> Plan {
        plan(groups: groups, environment: environment, hints: RouteHints(ruleMatch: ruleMatch))
    }

    /// Follows group selections from `name` down to a leaf policy: `["AI", "US", "AT&T-RackNerd-Hysteria2"]`.
    static func resolve(_ name: String, groups: [String: SurgePolicyGroup], selections: [String: String]) -> [String] {
        var path = [name]
        var current = name
        while path.count < 8, let group = groups[current] {
            guard let next = selection(of: group, selections: selections) ?? group.options.first?.name, !path.contains(next) else { break }
            path.append(next)
            current = next
        }
        return path
    }

    /// The option a group currently uses. Surge picks for automatic groups itself, so their live pick from
    /// `policy-group list` wins; for the others the `environment` selection wins.
    static func selection(of group: SurgePolicyGroup, selections: [String: String]) -> String? {
        isAutomatic(groupType: group.type) ? (group.selected ?? selections[group.name]) : (selections[group.name] ?? group.selected)
    }

    /// Whether Surge picks the group's selection itself: URL test, fallback, load balance and smart groups.
    static func isAutomatic(groupType: String?) -> Bool {
        guard let type = groupType?.lowercased(), !type.contains("manual") else { return false }
        return ["url test", "url-test", "urltest", "auto", "fallback", "load balance", "load-balance", "loadbalance", "smart"]
            .contains { type.contains($0) }
    }

    /// Direct mode → DIRECT; global proxy → the global policy's path; rule mode → the policy the FINAL rule
    /// names, followed through its groups (else the policy a neutral destination matched).
    static func currentRoute(environment: SurgeEnvironment, hints: RouteHints, groups: [String: SurgePolicyGroup],
                             candidates: [EgressCandidate]) -> (path: [String]?, rule: String?) {
        switch environment.proxyMode {
        case 0:
            return (["DIRECT"], nil)
        case 1:
            let global = environment.globalPolicy ?? nonEmpty(hints.statusGlobalPolicy) ?? "DIRECT"
            return (resolve(global, groups: groups, selections: environment.groupSelections), "Global · \(global)")
        default:
            if let final = nonEmpty(hints.finalPolicy) {
                let path = groups[final] != nil ? resolve(final, groups: groups, selections: environment.groupSelections) : [final]
                return (path, "FINAL")
            }
            guard let policy = nonEmpty(hints.ruleMatch?.policy) else { return (nil, nil) }
            let rule = nonEmpty(hints.ruleMatch?.rule).flatMap { $0 == "(internal)" ? nil : $0 }
            if groups[policy] != nil { return (resolve(policy, groups: groups, selections: environment.groupSelections), rule) }
            // `rule match` reports the leaf; several groups may select it, so this path is a best guess.
            if let known = candidates.first(where: { $0.leaf.caseInsensitiveCompare(policy) == .orderedSame }) { return (known.policyPath, rule) }
            return ([policy], rule)
        }
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
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

    // MARK: - Change causes

    /// Routing at one check, compared between checks to explain a change of the current egress.
    struct RoutingState: Hashable, Sendable {
        var proxyMode: Int?
        var globalPolicy: String?
        var currentPath: [String]?
        /// The option each group uses.
        var selections: [String: String]
        /// Groups whose selection Surge makes itself.
        var automaticGroups: Set<String>
    }

    /// How the route to the current egress changed between two checks.
    enum RouteChange: Hashable, Sendable {
        case none
        /// The outbound mode, the global policy or a manual group's selection on the route changed.
        case manual
        /// Only automatic groups on the route (URL test, fallback, smart…) picked another option.
        case automatic
    }

    static func routingState(groups: [SurgePolicyGroup], environment: SurgeEnvironment, plan: Plan) -> RoutingState {
        var selections: [String: String] = [:]
        var automatic: Set<String> = []
        for group in groups {
            if let selected = selection(of: group, selections: environment.groupSelections) { selections[group.name] = selected }
            if isAutomatic(groupType: group.type) { automatic.insert(group.name) }
        }
        let global = plan.currentRule.flatMap { $0.hasPrefix("Global · ") ? String($0.dropFirst("Global · ".count)) : nil }
        return RoutingState(proxyMode: environment.proxyMode, globalPolicy: environment.globalPolicy ?? global,
                            currentPath: plan.currentPath, selections: selections, automaticGroups: automatic)
    }

    static func routeChange(from old: RoutingState?, to new: RoutingState) -> RouteChange {
        guard let old else { return .none }
        if old.proxyMode != new.proxyMode { return .manual }
        if new.proxyMode == 1, old.globalPolicy != new.globalPolicy { return .manual }
        var names: [String] = []
        for path in [old.currentPath, new.currentPath] {
            for name in path ?? [] where !names.contains(name) { names.append(name) }
        }
        var automatic = false
        for name in names {
            guard let before = old.selections[name], let after = new.selections[name], before != after else { continue }
            if old.automaticGroups.contains(name) || new.automaticGroups.contains(name) {
                automatic = true
            } else {
                return .manual
            }
        }
        return automatic ? .automatic : .none
    }

    /// The reason to store for a change of the current egress IP. A noted cause wins, except that an
    /// environment event whose only effect on the route was an automatic pick is an auto-test pick; without
    /// a noted cause the route comparison decides.
    static func changeReason(noted: String?, route: RouteChange) -> String {
        switch (noted, route) {
        case (EgressReason.manualSwitch?, .automatic): EgressReason.autoTest
        case (let noted?, _): noted
        case (nil, .automatic): EgressReason.autoTest
        case (nil, .manual): EgressReason.manualSwitch
        case (nil, .none): EgressReason.unknown
        }
    }

    // MARK: - Countries

    /// English short names used instead of the system's long ones (`Hong Kong SAR China`); the
    /// `EgressEngine` string table translates them.
    static let shortCountryNames: [String: String] = [
        "HK": "Hong Kong", "MO": "Macao", "TW": "Taiwan", "US": "United States", "GB": "United Kingdom", "KR": "South Korea", "RU": "Russia",
    ]

    /// Lowercased English country name → ISO code, for rows stored by versions that saved names.
    private static let codesByEnglishName: [String: String] = {
        let english = Locale(identifier: "en_US")
        var result: [String: String] = [:]
        for region in Locale.Region.isoRegions {
            let code = region.identifier
            guard code.count == 2, code.allSatisfy(\.isLetter), let name = english.localizedString(forRegionCode: code) else { continue }
            result[name.lowercased()] = code
        }
        for (code, name) in shortCountryNames { result[name.lowercased()] = code }
        return result
    }()

    /// The ISO region code stored for a country (`HK`), from a code in any case or an English country name;
    /// nil for empty values and free text that is not a country.
    static func countryCode(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        if value.count == 2, value.allSatisfy({ $0.isASCII && $0.isLetter }) { return value.uppercased() }
        return codesByEnglishName[value.lowercased()]
    }

    /// `Hong Kong`, `Japan`: the English name of an ISO region code.
    static func countryName(_ code: String?) -> String? {
        guard let code = countryCode(code) else { return nil }
        return shortCountryNames[code] ?? Locale(identifier: "en_US").localizedString(forRegionCode: code) ?? code
    }

    /// A stored location (`HK`, or `Hong Kong` in older rows) in the app language: `Hong Kong`, or its
    /// translation; free text that is not a country is returned unchanged.
    @MainActor
    static func localizedLocation(_ stored: String?) -> String? {
        guard let stored = stored?.trimmingCharacters(in: .whitespaces), !stored.isEmpty else { return nil }
        guard let code = countryCode(stored) else { return stored }
        if let short = shortCountryNames[code] { return tr(short, "EgressEngine") }
        return Localizer.shared.locale.localizedString(forRegionCode: code) ?? countryName(code) ?? code
    }
}
