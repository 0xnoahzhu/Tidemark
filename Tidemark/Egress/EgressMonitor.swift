import CoreWLAN
import Foundation
import Network
import os

/// Checks the external IP Tidemark's traffic leaves through, per policy, and logs changes of the current
/// egress with their likely cause. Fills `model.egress`; implements `EgressActions`.
///
/// Checks run every 10 minutes, 5 s after a relevant event (policy switch, profile reload, Surge restart,
/// network change, wake) and on demand. Surge and the database are read from `model` on every use, so a
/// client rebuilt by the capture engine is picked up automatically.
@MainActor
final class EgressMonitor: EgressActions {
    let model: AppModel
    /// Host used with `rule match` to find the FINAL route in rule mode.
    let neutralHost = "egress-check.tidemark.invalid"
    let checkTimeout: Duration
    let checkInterval: Duration
    let debounceDelay: Duration

    private static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "egress")

    private var started = false
    private var jobs: [String: Task<Void, Never>] = [:]
    private var pathTask: Task<Void, Never>?
    private var cause: (reason: String, at: Date)?
    private var previousIP: String?
    private var historyLoaded = false

    init(model: AppModel, checkTimeout: Duration = .seconds(20), checkInterval: Duration = .seconds(600), debounceDelay: Duration = .seconds(5)) {
        self.model = model
        self.checkTimeout = checkTimeout
        self.checkInterval = checkInterval
        self.debounceDelay = debounceDelay
    }

    /// Device the samples are stored under (the remote Surge's row when one is configured).
    var deviceID: DeviceID { CaptureDeviceInfo.recordingDeviceID(model.preferences) }

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
        guard !model.egress.isChecking else { return }
        model.egress.isChecking = true
        defer { model.egress.isChecking = false }
        await loadHistoryIfNeeded()

        let surge = model.surge
        let plan: EgressPlanner.Plan
        do {
            async let environment = surge.environment()
            async let groups = surge.policyGroups()
            let (env, policyGroups) = try await (environment, groups)
            var match: SurgeRuleMatch?
            if env.proxyMode != 0, env.proxyMode != 1 {
                match = try? await surge.ruleMatch(host: neutralHost, processPath: nil)
            }
            plan = EgressPlanner.plan(groups: policyGroups, environment: env, ruleMatch: match)
        } catch {
            Self.log.error("Egress check skipped: \(error.localizedDescription, privacy: .public)")
            return
        }

        let now = Date.now
        let measured = await Self.measure(plan.candidates, surge: surge, timeout: checkTimeout, now: now)
        let samples = EgressPlanner.arrange(measured, currentPath: plan.currentPath)
        model.egress.samples = samples
        model.egress.lastChecked = now

        let database = model.database
        let device = deviceID
        do {
            try await database.saveEgressSamples(samples, deviceID: device)
        } catch {
            Self.log.error("Saving egress samples failed: \(error.localizedDescription, privacy: .public)")
        }
        await recordChange(current: samples.first(where: \.isCurrent), now: now)
    }

    func lookup(ip: String) async -> IPLookupResult {
        let ip = ip.trimmingCharacters(in: .whitespacesAndNewlines)
        var result = IPLookupResult(ip: ip)
        guard HostName.isIPAddress(ip) else { return result }
        let surge = model.surge
        async let geo = try? CaptureTimeout.run(.seconds(5)) { try await surge.geoIP(ip) }
        async let reverse = try? CaptureTimeout.run(.seconds(5)) { await EgressIPInfo.reverseDNS(ip) }
        async let service = EgressIPInfo.service(ip)
        let (surgeGeo, ptr, info) = await (geo, reverse, service)
        result.country = EgressPlanner.countryName(surgeGeo?.country ?? info?.countryCode)
        result.asn = surgeGeo?.asn ?? info?.asn
        result.organization = surgeGeo?.organization ?? info?.organization
        result.networkType = info?.networkType
        result.reverseDNS = (ptr ?? nil) ?? info?.hostname
        return result
    }

    // MARK: Checks

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

    /// External IP, latency and GeoIP through one policy.
    nonisolated static func measure(_ candidate: EgressCandidate, surge: any SurgeClient, timeout: Duration, now: Date) async -> EgressSample {
        let target = candidate.target
        async let latency = try? CaptureTimeout.run(timeout) { try await surge.policyLatency(policy: target) }
        do {
            let ip = try await CaptureTimeout.run(timeout) { try await surge.externalIP(policy: target) }
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let geo = try? await CaptureTimeout.run(timeout) { try await surge.geoIP(ip) }
            return EgressSample(
                policyPath: candidate.policyPath, ip: ip, location: EgressPlanner.countryName(geo?.country),
                network: EgressPlanner.network(asn: geo?.asn, organization: geo?.organization),
                latencyMs: (await latency) ?? nil, isCurrent: false, checkedAt: now, error: nil
            )
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return EgressSample(policyPath: candidate.policyPath, ip: nil, location: nil, network: nil, latencyMs: nil,
                                isCurrent: false, checkedAt: now, error: message)
        }
    }

    /// Logs a change of the current egress IP with the last observed cause.
    private func recordChange(current: EgressSample?, now: Date) async {
        guard let current, let ip = current.ip else { return }
        defer {
            previousIP = ip
            cause = nil
        }
        guard let previous = previousIP, previous != ip else { return }
        let reason = cause.flatMap { now.timeIntervalSince($0.at) < 1800 ? $0.reason : nil } ?? "Egress changed"
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

    func refreshNetwork() async {
        let surge = model.surge
        if let network = try? await CaptureTimeout.run(.seconds(10), { try await surge.network() }) {
            if model.egress.network != network { model.egress.network = network }
        }
    }

    // MARK: Network path

    /// Watches the primary interface (NWPathMonitor as an AsyncSequence) and reports changes.
    private func watchPath() {
        pathTask?.cancel()
        pathTask = Task { [weak self] in
            var last: String?
            for await path in NWPathMonitor() {
                guard let self, !Task.isCancelled else { return }
                guard path.status == .satisfied else { continue }
                let description = Self.describe(path)
                if let last, last != description {
                    self.note(.networkChanged(description))
                    self.jobs["network-refresh"]?.cancel()
                    self.jobs["network-refresh"] = Task { [weak self] in
                        try? await Task.sleep(for: .seconds(3))
                        await self?.refreshNetwork()
                    }
                }
                last = description
            }
        }
    }

    /// `Wi-Fi “Office-5G”`, `Ethernet`, `Wi-Fi`.
    static func describe(_ path: NWPath) -> String {
        guard let interface = path.availableInterfaces.first else { return "offline" }
        switch interface.type {
        case .wifi:
            if let ssid = CWWiFiClient.shared().interface(withName: interface.name)?.ssid(), !ssid.isEmpty {
                return "Wi-Fi “\(ssid)”"
            }
            return "Wi-Fi"
        case .wiredEthernet: return "Ethernet"
        case .cellular: return "Cellular"
        case .loopback: return "Loopback"
        case .other: return interface.name
        @unknown default: return interface.name
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
