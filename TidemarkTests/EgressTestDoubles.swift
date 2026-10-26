import Foundation
import Synchronization
@testable import Tidemark

/// Scriptable Surge client with the `SurgeClientDetails` extras (FINAL rule, HTTP listener), for the
/// egress monitor and the probe controller.
final class EgressFakeSurge: SurgeClientDetails {
    struct State {
        var geo: [String: SurgeGeoIP] = [:]
        var externalIPs: [String: String] = [:]
        var latencies: [String: Int] = [:]
        var groups: [SurgePolicyGroup] = []
        var environment = SurgeEnvironment(proxyMode: 2, globalPolicy: nil, groupSelections: [:])
        var status = SurgeStatus()
        var finalPolicy: String? = "Proxy"
        var ruleMatch = SurgeRuleMatch(policy: "HK-01", rule: "FINAL")
        /// nil: `network()` fails.
        var network: ThisMacNetwork? = ThisMacNetwork(interface: "en0", interfaceDetail: "Wired", localIP: "192.168.1.20",
                                                      router: "192.168.1.1", dnsServers: ["223.5.5.5"], surgeMode: nil)
        /// nil: Surge's HTTP proxy is off.
        var listener: SurgeHTTPListener? = SurgeHTTPListener(interface: "0.0.0.0", port: 6152)
        /// How reading the listener fails (before `listener` is looked at).
        var listenerFailure: SurgeError?
        /// Policies (targets) through which the IPv6 probe succeeds.
        var ipv6Targets: Set<String> = []
        /// How the IPv6 probe fails through the other policies.
        var ipv6Failure = SurgeError.commandFailed(command: "http probe", message: "No outgoing interface")
        /// How long `http probe` takes.
        var httpProbeDelay: Duration = .zero
        /// How long `test-policy-external-ip` takes.
        var externalIPDelay: Duration = .zero
        var externalIPCalls: [String] = []
        var httpProbes: [String] = []
        var ruleMatches = 0
    }

    let endpoint: SurgeEndpoint
    let state = Mutex(State())

    init() {
        endpoint = SurgeEndpoint(cliPath: "/usr/bin/false")
    }

    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var snapshot: State { state.withLock { $0 } }

    func events() -> AsyncThrowingStream<SurgeEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func status() async throws -> SurgeStatus { snapshot.status }
    func environment() async throws -> SurgeEnvironment { snapshot.environment }
    func recentRequests() async throws -> [SurgeRequest] { [] }
    func activeRequests() async throws -> [SurgeRequest] { [] }
    func dnsLookup(_ domain: String) async throws -> SurgeDNSLookup { throw SurgeError.commandFailed(command: "dns lookup", message: "NXDOMAIN") }
    func dnsCache() async throws -> [String: [String]] { [:] }
    func geoIP(_ ip: String) async throws -> SurgeGeoIP {
        guard let geo = snapshot.geo[ip] else { throw SurgeError.commandFailed(command: "geoip", message: "unknown") }
        return geo
    }
    func ruleMatch(host: String, processPath: String?) async throws -> SurgeRuleMatch {
        state.withLock { s in
            s.ruleMatches += 1
            return s.ruleMatch
        }
    }
    func httpProbe(url: String, policy: String?) async throws -> SurgeHTTPProbe {
        let (reachable, failure, delay) = state.withLock { s in
            s.httpProbes.append(policy ?? "")
            return (s.ipv6Targets.contains(policy ?? ""), s.ipv6Failure, s.httpProbeDelay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        guard reachable else { throw failure }
        return SurgeHTTPProbe(method: "HEAD", status: 301, durationMs: 120, policy: policy, rule: nil, url: url, headers: [])
    }
    func policyGroups() async throws -> [SurgePolicyGroup] { snapshot.groups }
    func externalIP(policy: String?) async throws -> String {
        let key = policy ?? "DIRECT"
        let (ip, delay) = state.withLock { s in
            s.externalIPCalls.append(key)
            return (s.externalIPs[key], s.externalIPDelay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        guard let ip else { throw SurgeError.commandFailed(command: "test-policy-external-ip", message: "failed") }
        return ip
    }
    func policyLatency(policy: String) async throws -> Int? { snapshot.latencies[policy] }
    func network() async throws -> ThisMacNetwork {
        guard let network = snapshot.network else { throw SurgeError.timedOut(command: "summary") }
        return network
    }
    func httpProxyPort() async throws -> Int { try await httpProxyListener().port }
    func httpProxyListener() async throws -> SurgeHTTPListener {
        let state = snapshot
        if let failure = state.listenerFailure { throw failure }
        guard let listener = state.listener else { throw SurgeHTTPProxyOff() }
        return listener
    }
    func finalRulePolicy() async throws -> String? { snapshot.finalPolicy }
}

/// Records which IPs were sent to the IP info service.
final class EgressServiceSpy: Sendable {
    private let asked = Mutex<[String]>([])
    let answer: EgressIPInfo.ServiceInfo?

    init(answer: EgressIPInfo.ServiceInfo? = EgressIPInfo.ServiceInfo(networkType: "Hosting", kind: "hosting", countryCode: "US")) {
        self.answer = answer
    }

    var ips: [String] { asked.withLock { $0 } }

    var lookup: @Sendable (String) async -> EgressIPInfo.ServiceInfo? {
        { [self] ip in
            asked.withLock { $0.append(ip) }
            return answer
        }
    }
}
