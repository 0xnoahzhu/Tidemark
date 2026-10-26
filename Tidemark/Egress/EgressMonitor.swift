import Foundation
import Network
import os

/// Checks the external IP Tidemark's traffic leaves through, per policy, and logs changes of the current
/// egress with their likely cause. Fills `model.egress`; implements `EgressActions`.
///
/// Checks run every 10 minutes, 5 s after a relevant event (policy switch, profile reload, Surge restart,
/// network change, wake) and on demand; a check asked for while one runs is run again right after it.
/// Surge and the database are read from `model` on every use, so a client rebuilt by the capture engine is
/// picked up automatically.
///
/// Network changes are judged by Surge's own view of the network (`summary`: primary interface, address,
/// router), read a few seconds after `NWPathMonitor` reports a path update. The path itself cannot tell:
/// with Surge's enhanced mode on, its first interface is Surge's `utun`, and Wi-Fi networks are not
/// readable without Location access.
@MainActor
final class EgressMonitor: EgressActions {
    let model: AppModel
    /// Destination given to `rule match` to find the route in rule mode when the FINAL rule can't be read.
    let neutralHost = "egress-check.tidemark.invalid"
    /// Fetched through the current policy (HTTP HEAD to an IPv6 literal) to learn whether it reaches IPv6.
    static let ipv6ProbeURL = "http://[2606:4700:4700::1111]/"
    let checkTimeout: Duration
    let checkInterval: Duration
    let debounceDelay: Duration
    /// Wait after a network path update before reading Surge's view of the network.
    let networkSettleDelay: Duration

    /// The IP info service lookup (network type); replaced in tests.
    var serviceLookup: @Sendable (String) async -> EgressIPInfo.ServiceInfo? = { await EgressIPInfo.service($0) }
    /// Reverse DNS lookup; replaced in tests.
    var reverseLookup: @Sendable (String) async -> String? = { await EgressIPInfo.reverseDNS($0, timeout: .seconds(5)) }

    private static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "egress")
    /// A noted cause explains a change for this long.
    private static let causeLifetime: TimeInterval = 1800

    private var started = false
    private var jobs: [String: Task<Void, Never>] = [:]
    private var pathTask: Task<Void, Never>?
    private var cause: (reason: String, at: Date)?
    private var previousIP: String?
    private var historyLoaded = false
    /// A check was asked for while one was running.
    private var recheckPending = false
    /// Routing at the last check that measured the current egress.
    private var lastRouting: EgressPlanner.RoutingState?
    /// Surge's view of the network at the last refresh.
    private var networkFingerprint: EgressNetworkFingerprint?
    /// Physical interfaces of the last path update, and the description of a change not yet confirmed.
    private var pathSignature: String?
    private var pendingPathChange: String?
    /// Network type of an egress IP from the IP info service, and when it was asked.
    private var networkTypes: [String: (kind: String?, at: Date)] = [:]
    /// IPv6 reachability through a policy (`target|ip`), and when it was tested.
    private var ipv6Results: [String: (reachable: Bool, at: Date)] = [:]

    init(model: AppModel, checkTimeout: Duration = .seconds(20), checkInterval: Duration = .seconds(600), debounceDelay: Duration = .seconds(5),
         networkSettleDelay: Duration = .seconds(3)) {
        self.model = model
        self.checkTimeout = checkTimeout
        self.checkInterval = checkInterval
        self.debounceDelay = debounceDelay
        self.networkSettleDelay = networkSettleDelay
    }

    /// Device the samples are stored under: this Mac's row.
    var deviceID: DeviceID { model.preferences.thisDeviceID }

    // MARK: Lifecycle

    func start() {
        guard !started else { return }
        started = true
        every("check", checkInterval, delay: .seconds(4)) { await $0.checkAll() }
        every("network", .seconds(300), delay: .seconds(1)) { await $0.refreshNetwork() }
        watchPath()
    }

    func stop() {
        started = false
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        pathTask?.cancel()
        pathTask = nil
    }

    /// Remembers why the egress may have changed and schedules a check.
    func note(_ signal: EgressSignal) {
        if let reason = signal.reason { cause = (reason, .now) }
        guard started else { return }
        jobs["debounced-check"]?.cancel()
        jobs["debounced-check"] = Task { [weak self, debounceDelay] in
            try? await Task.sleep(for: debounceDelay)
            guard !Task.isCancelled, let self else { return }
            await self.checkAll()
        }
    }

    // MARK: EgressActions

    func checkAll() async {
        guard !model.egress.isChecking else {
            // The running check may have measured the old route: check again when it ends.
            recheckPending = true
            return
        }
        model.egress.isChecking = true
        await runCheck(startedAt: .now)
        model.egress.isChecking = false
        if recheckPending {
            recheckPending = false
            jobs["recheck"] = Task { [weak self] in await self?.checkAll() }
        }
    }

    func lookup(ip: String) async -> IPLookupResult {
        let ip = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = IPLookupResult(ip: ip)
        guard HostName.isIPAddress(ip) else { return result }
        let surge = model.surge
        // The IP info service only sees public addresses the user looked up.
        let useService = EgressIPInfo.isPublic(ip)
        let serviceLookup = self.serviceLookup
        let reverseLookup = self.reverseLookup
        async let geo = try? CaptureTimeout.run(.seconds(5)) { try await surge.geoIP(ip) }
        async let reverse = reverseLookup(ip)
        async let service: EgressIPInfo.ServiceInfo? = useService ? await serviceLookup(ip) : nil
        let (surgeGeo, ptr, info) = await (geo, reverse, service)
        result.country = EgressPlanner.countryCode(surgeGeo?.country ?? info?.countryCode)
        result.asn = surgeGeo?.asn ?? info?.asn
        result.organization = surgeGeo?.organization ?? info?.organization
        result.networkType = info?.networkType
        result.reverseDNS = ptr ?? info?.hostname
        return result
    }

    // MARK: Checks

    private func runCheck(startedAt: Date) async {
        await loadHistoryIfNeeded()

        let surge = model.surge
        let environment: SurgeEnvironment
        let groups: [SurgePolicyGroup]
        do {
            async let env = surge.environment()
            async let list = surge.policyGroups()
            (environment, groups) = try await (env, list)
        } catch {
            Self.log.error("Egress check skipped: \(error.localizedDescription, privacy: .public)")
            return
        }
        let hints = await routeHints(surge: surge, environment: environment)
        let plan = EgressPlanner.plan(groups: groups, environment: environment, hints: hints)
        model.egress.proxyMode = environment.proxyMode
        model.egress.currentRule = plan.currentRule
        let routing = EgressPlanner.routingState(groups: groups, environment: environment, plan: plan)

        let now = Date.now
        let measured = await Self.measure(plan.candidates, surge: surge, timeout: checkTimeout, now: now)
        var samples = annotateFromCache(EgressPlanner.arrange(measured, currentPath: plan.currentPath), plan: plan, now: now)
        model.egress.samples = samples
        model.egress.lastChecked = now
        let annotated = await annotate(samples, plan: plan, surge: surge, now: now)
        if annotated != samples {
            samples = annotated
            model.egress.samples = samples
        }

        let database = model.database
        let device = deviceID
        do {
            try await database.saveEgressSamples(samples, deviceID: device)
        } catch {
            Self.log.error("Saving egress samples failed: \(error.localizedDescription, privacy: .public)")
        }
        await recordChange(current: samples.first(where: \.isCurrent), routing: routing, checkStartedAt: startedAt, now: now)
    }

    /// The FINAL rule's policy in rule mode (else a rule match on a neutral host), the status's global
    /// policy in global mode when `environment` lacks it.
    private func routeHints(surge: any SurgeClient, environment: SurgeEnvironment) async -> EgressPlanner.RouteHints {
        var hints = EgressPlanner.RouteHints()
        let timeout = checkTimeout
        switch environment.proxyMode {
        case 0:
            break
        case 1:
            if environment.globalPolicy == nil {
                hints.statusGlobalPolicy = (try? await CaptureTimeout.run(timeout) { try await surge.status() })?.globalPolicy
            }
        default:
            if let detailed = surge as? any SurgeClientDetails {
                hints.finalPolicy = try? await CaptureTimeout.run(timeout) { try await detailed.finalRulePolicy() }
            }
            if hints.finalPolicy == nil {
                let host = neutralHost
                hints.ruleMatch = try? await CaptureTimeout.run(timeout) { try await surge.ruleMatch(host: host, processPath: nil) }
            }
        }
        return hints
    }

    /// Measures candidates, at most four at a time, keeping their order.
    nonisolated static func measure(_ candidates: [EgressCandidate], surge: any SurgeClient, timeout: Duration, now: Date) async -> [EgressSample] {
        var results = [EgressSample?](repeating: nil, count: candidates.count)
        await withTaskGroup(of: (Int, EgressSample).self) { group in
            var next = 0
            func enqueue() {
                guard next < candidates.count else { return }
                let index = next
                let candidate = candidates[index]
                group.addTask { (index, await measure(candidate, surge: surge, timeout: timeout, now: now)) }
                next += 1
            }
            for _ in 0..<4 { enqueue() }
            for await (index, sample) in group {
                results[index] = sample
                enqueue()
            }
        }
        return results.compactMap { $0 }
    }

    /// External IP, latency and GeoIP through one policy. The location is the ISO country code (`HK`); the
    /// UI names it in the app language.
    nonisolated static func measure(_ candidate: EgressCandidate, surge: any SurgeClient, timeout: Duration, now: Date) async -> EgressSample {
        let target = candidate.target
        async let latency = try? CaptureTimeout.run(timeout) { try await surge.policyLatency(policy: target) }
        do {
            let ip = try await CaptureTimeout.run(timeout) { try await surge.externalIP(policy: target) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let geo = try? await CaptureTimeout.run(timeout) { try await surge.geoIP(ip) }
            return EgressSample(
                policyPath: candidate.policyPath, ip: ip, location: EgressPlanner.countryCode(geo?.country),
                network: EgressPlanner.network(asn: geo?.asn, organization: geo?.organization),
                latencyMs: (await latency) ?? nil, isCurrent: false, checkedAt: now, error: nil,
                hasIPv6: ip.contains(":") ? true : nil
            )
        } catch {
            return EgressSample(policyPath: candidate.policyPath, ip: nil, location: nil, network: nil, latencyMs: nil,
                                isCurrent: false, checkedAt: now, error: storedError(error))
        }
    }

    /// A failed check as `egress_checks.error` keeps it: the error's English description (`Timed out after 20 s.`,
    /// `surge-cli test-policy-external-ip … failed: Policy does not exist.`), never the UI language, because other
    /// Macs and later versions read it back (`EgressFormat.error` shows it short and translated).
    nonisolated static func storedError(_ error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    // MARK: Network type and IPv6

    /// Fills `networkType` and the current egress's `hasIPv6` from earlier answers that are still fresh.
    private func annotateFromCache(_ samples: [EgressSample], plan: EgressPlanner.Plan, now: Date) -> [EgressSample] {
        samples.map { sample in
            var sample = sample
            guard let ip = sample.ip else { return sample }
            if let cached = networkTypes[ip], Self.isFresh(cached.at, found: cached.kind != nil, now: now) {
                sample.networkType = cached.kind
            }
            if sample.isCurrent, sample.hasIPv6 == nil, let key = ipv6Key(sample, plan: plan),
               let cached = ipv6Results[key], now.timeIntervalSince(cached.at) < 3600 {
                sample.hasIPv6 = cached.reachable
            }
            return sample
        }
    }

    /// Asks the IP info service for the network type of egress IPs it has no fresh answer for (only public
    /// addresses) and tests whether the current egress reaches IPv6.
    private func annotate(_ samples: [EgressSample], plan: EgressPlanner.Plan, surge: any SurgeClient, now: Date) async -> [EgressSample] {
        var samples = samples
        // Surge takes about 15 s to give up on a policy without IPv6, so the test runs alongside the lookups.
        let ipv6Test: (index: Int, key: String, target: String)? = samples.firstIndex(where: \.isCurrent).flatMap { index in
            guard samples[index].ip != nil, samples[index].hasIPv6 == nil, let key = ipv6Key(samples[index], plan: plan),
                  let target = target(of: samples[index], plan: plan) else { return nil }
            return (index, key, target)
        }
        let ipv6Target = ipv6Test?.target
        async let ipv6 = Self.reachesIPv6(through: ipv6Target, surge: surge)

        let missing = Set(samples.compactMap(\.ip).filter { ip in
            guard EgressIPInfo.isPublic(ip) else { return false }
            guard let cached = networkTypes[ip] else { return true }
            return !Self.isFresh(cached.at, found: cached.kind != nil, now: now)
        })
        let lookup = serviceLookup
        let answers = await withTaskGroup(of: (String, String?).self) { group in
            for ip in missing { group.addTask { (ip, await lookup(ip)?.kind) } }
            var answers: [String: String?] = [:]
            for await (ip, kind) in group { answers.updateValue(kind, forKey: ip) }
            return answers
        }
        for (ip, kind) in answers { networkTypes[ip] = (kind, now) }
        for index in samples.indices {
            if let ip = samples[index].ip, let cached = networkTypes[ip] { samples[index].networkType = cached.kind }
        }
        // Only a definite answer is kept (an hour, either way); an unknown one is asked again next check.
        if let ipv6Test, let reachable = await ipv6 {
            ipv6Results[ipv6Test.key] = (reachable, now)
            samples[ipv6Test.index].hasIPv6 = reachable
        }
        return samples
    }

    /// Longer than Surge's own deadline for an `http probe` (about 15 s), whose "HTTP request timeout" is the
    /// answer for a proxy that can't reach IPv6.
    nonisolated static let ipv6ProbeTimeout: Duration = .seconds(25)

    /// Whether a HEAD request to an IPv6 literal gets through `target` (a policy name or `POLICY::` line hash;
    /// surge-cli's `http probe` takes both). nil when it is unknown: no target, Surge could not be asked, the
    /// probe outlived `timeout`, or Surge failed for another reason (an unknown policy, say).
    nonisolated static func reachesIPv6(through target: String?, surge: any SurgeClient,
                                        timeout: Duration = ipv6ProbeTimeout) async -> Bool? {
        guard let target else { return nil }
        do {
            _ = try await CaptureTimeout.run(timeout) { try await surge.httpProbe(url: ipv6ProbeURL, policy: target) }
            return true
        } catch SurgeError.commandFailed(_, let message) {
            return meansNoIPv6(message) ? false : nil
        } catch {
            return nil
        }
    }

    /// Surge's failures for an IPv6 destination the policy has no route to: `No outgoing interface` (DIRECT
    /// on an IPv4-only network), `HTTP request timeout` (a proxy that drops IPv6; its IPv4 egress was just
    /// measured), an unreachable network or host.
    nonisolated static func meansNoIPv6(_ message: String) -> Bool {
        let text = message.lowercased()
        return ["no outgoing interface", "http request timeout", "network is unreachable", "no route to host",
                "host is unreachable", "address family not supported"].contains { text.contains($0) }
    }

    /// Answers stay fresh for a day, failures for an hour.
    private static func isFresh(_ at: Date, found: Bool, now: Date) -> Bool {
        now.timeIntervalSince(at) < (found ? 86_400 : 3600)
    }

    private func target(of sample: EgressSample, plan: EgressPlanner.Plan) -> String? {
        guard let leaf = sample.policyPath.last else { return nil }
        return plan.candidates.first { $0.leaf.caseInsensitiveCompare(leaf) == .orderedSame }?.target
    }

    private func ipv6Key(_ sample: EgressSample, plan: EgressPlanner.Plan) -> String? {
        guard let ip = sample.ip, let target = target(of: sample, plan: plan) else { return nil }
        return "\(target)|\(ip)"
    }

    // MARK: Changes

    /// Logs a change of the current egress IP with its likely cause.
    private func recordChange(current: EgressSample?, routing: EgressPlanner.RoutingState, checkStartedAt: Date, now: Date) async {
        guard let current, let ip = current.ip else { return }
        let previous = previousIP
        let previousRouting = lastRouting
        previousIP = ip
        lastRouting = routing
        if let noted = cause, now.timeIntervalSince(noted.at) >= Self.causeLifetime { cause = nil }
        guard let previous, previous != ip else {
            // A check that started after the cause was noted saw no change: the cause did not move the egress.
            // (One that started earlier may have measured the old route; its re-check decides.)
            if let noted = cause, noted.at <= checkStartedAt { cause = nil }
            return
        }
        let reason = EgressPlanner.changeReason(noted: cause?.reason, route: EgressPlanner.routeChange(from: previousRouting, to: routing))
        cause = nil
        let change = EgressChange(id: 0, changedAt: now, ip: ip, policyPath: current.policyPath, reason: reason)
        let database = model.database
        let device = deviceID
        do {
            try await database.insertEgressChange(change, deviceID: device)
            model.egress.changes = try await database.egressChanges(deviceID: device, limit: 50)
        } catch {
            var local = change
            local.id = -Int64(now.timeIntervalSince1970 * 1000)
            model.egress.changes.insert(local, at: 0)
        }
    }

    private func loadHistoryIfNeeded() async {
        guard !historyLoaded, model.live.database.isHealthy else { return }
        let database = model.database
        let device = deviceID
        guard let latest = try? await database.latestEgress(deviceID: device) else { return }
        historyLoaded = true
        if model.egress.samples.isEmpty, !latest.isEmpty {
            model.egress.samples = latest.sorted { $0.isCurrent && !$1.isCurrent }
            model.egress.lastChecked = latest.map(\.checkedAt).max()
        }
        if previousIP == nil { previousIP = latest.first(where: \.isCurrent)?.ip }
        if let changes = try? await database.egressChanges(deviceID: device, limit: 50) { model.egress.changes = changes }
    }

    // MARK: Network

    /// Reads Surge's view of the network, publishes it, and notes a network change when the primary
    /// interface, address or router differ from the last reading.
    func refreshNetwork() async {
        let surge = model.surge
        let network = try? await CaptureTimeout.run(.seconds(10)) { try await surge.network() }
        let pathChange = pendingPathChange
        pendingPathChange = nil
        guard let network else {
            // Surge can't be asked; the physical interfaces changing is still worth a re-check.
            if let pathChange { note(.networkChanged(pathChange)) }
            return
        }
        if model.egress.network != network { model.egress.network = network }
        let fingerprint = EgressNetworkFingerprint(network)
        guard !fingerprint.isEmpty else { return }
        let previous = networkFingerprint
        networkFingerprint = fingerprint
        guard let previous, previous != fingerprint else { return }
        note(.networkChanged(Self.describe(network) ?? pathChange ?? fingerprint.interface ?? "?"))
    }

    /// `Wi-Fi “Office-5G”`, `Ethernet`, `Wi-Fi` from Surge's primary interface type (and SSID when Surge
    /// reports one), else the interface name.
    nonisolated static func describe(_ network: ThisMacNetwork) -> String? {
        if let detail = network.interfaceDetail?.trimmingCharacters(in: .whitespaces), !detail.isEmpty {
            return detail.hasPrefix("Wired") ? "Ethernet" + detail.dropFirst("Wired".count) : detail
        }
        if let interface = network.interface, !interface.isEmpty { return interface }
        return nil
    }

    /// Watches path updates (NWPathMonitor as an AsyncSequence). Every satisfied update schedules a reading
    /// of Surge's network a moment later; the reading decides whether the network changed.
    private func watchPath() {
        pathTask?.cancel()
        pathTask = Task { [weak self] in
            for await path in NWPathMonitor() {
                guard let self, !Task.isCancelled else { return }
                guard path.status == .satisfied else { continue }
                self.pathUpdated(signature: Self.physicalSignature(path), description: Self.describe(path))
            }
        }
    }

    private func pathUpdated(signature: String, description: String) {
        if let previous = pathSignature, previous != signature { pendingPathChange = description }
        pathSignature = signature
        jobs["network-refresh"]?.cancel()
        jobs["network-refresh"] = Task { [weak self, networkSettleDelay] in
            try? await Task.sleep(for: networkSettleDelay)
            guard !Task.isCancelled, let self else { return }
            await self.refreshNetwork()
        }
    }

    /// Interfaces that carry traffic out of the Mac: not Surge's or a VPN's tunnels, not loopback.
    nonisolated static func physicalInterfaces(_ path: NWPath) -> [NWInterface] {
        let virtualPrefixes = ["utun", "ipsec", "ppp", "gif", "stf", "awdl", "llw", "bridge", "anpi", "ap"]
        return path.availableInterfaces.filter { interface in
            interface.type != .other && interface.type != .loopback && !virtualPrefixes.contains { interface.name.hasPrefix($0) }
        }
    }

    nonisolated static func physicalSignature(_ path: NWPath) -> String {
        physicalInterfaces(path).map(\.name).sorted().joined(separator: ",")
    }

    /// `Ethernet`, `Wi-Fi`, `Cellular` for the first physical interface of a path.
    nonisolated static func describe(_ path: NWPath) -> String {
        guard let interface = physicalInterfaces(path).first else { return "offline" }
        switch interface.type {
        case .wifi: return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        case .cellular: return "Cellular"
        default: return interface.name
        }
    }

    private func every(_ name: String, _ interval: Duration, delay: Duration, _ body: @escaping @MainActor (EgressMonitor) async -> Void) {
        jobs[name]?.cancel()
        jobs[name] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            while !Task.isCancelled {
                guard let self else { return }
                await body(self)
                try? await Task.sleep(for: interval)
            }
        }
    }
}

/// What identifies the network Surge sends traffic out on.
struct EgressNetworkFingerprint: Hashable, Sendable {
    var interface: String?
    var localIP: String?
    var router: String?
    var interfaceDetail: String?

    init(_ network: ThisMacNetwork) {
        interface = network.interface
        localIP = network.localIP
        router = network.router
        interfaceDetail = network.interfaceDetail
    }

    /// Surge reports no interface and no address (offline, or Surge has not seen the network yet).
    var isEmpty: Bool { interface == nil && localIP == nil }
}
