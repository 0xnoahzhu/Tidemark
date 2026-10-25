import Foundation
import Testing
@testable import Tidemark

struct EgressPlannerTests {
    static func option(_ name: String, group: Bool = false) -> SurgePolicyOption {
        SurgePolicyOption(name: name, typeDescription: group ? "Select" : "Snell", lineHash: group ? nil : "POLICY::\(name.lowercased())",
                          enabled: true, isGroup: group)
    }

    /// Proxy → Auto → SG-02, AI → US-West, Streaming → Proxy (duplicate leaf).
    static let groups = [
        SurgePolicyGroup(name: "Proxy", options: [option("HK-01"), option("JP-Tokyo"), option("Auto", group: true)], selected: "HK-01"),
        SurgePolicyGroup(name: "Auto", options: [option("HK-01"), option("SG-02")], selected: "SG-02"),
        SurgePolicyGroup(name: "AI", options: [option("US-West")], selected: "US-West"),
        SurgePolicyGroup(name: "Streaming", options: [option("Proxy", group: true), option("DIRECT")], selected: "Proxy"),
    ]

    func environment(mode: Int?, global: String? = nil, selections: [String: String] = ["Proxy": "Auto"]) -> SurgeEnvironment {
        SurgeEnvironment(proxyMode: mode, globalPolicy: global, groupSelections: selections)
    }

    @Test func plansDirectAndEachGroupsLeafOnce() {
        let plan = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 2), ruleMatch: SurgeRuleMatch(policy: "Proxy", rule: "FINAL"))
        #expect(plan.candidates.map(\.policyPath) == [["DIRECT"], ["Proxy", "Auto", "SG-02"], ["AI", "US-West"]])
        #expect(plan.candidates.map(\.target) == ["DIRECT", "POLICY::sg-02", "POLICY::us-west"])
        #expect(plan.currentPath == ["Proxy", "Auto", "SG-02"], "rule mode follows the FINAL route")
        #expect(plan.currentRule == "FINAL")
    }

    @Test func findsTheCurrentRoutePerOutboundMode() {
        let direct = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 0), ruleMatch: nil)
        #expect(direct.currentPath == ["DIRECT"])
        #expect(direct.currentRule == nil)
        let global = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 1, global: "AI"), ruleMatch: nil)
        #expect(global.currentPath == ["AI", "US-West"])
        #expect(global.currentRule == "Global · AI")
        let byLeaf = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 2), ruleMatch: SurgeRuleMatch(policy: "US-West", rule: "DOMAIN-SUFFIX,openai.com"))
        #expect(byLeaf.currentPath == ["AI", "US-West"])
        #expect(byLeaf.currentRule == "DOMAIN-SUFFIX,openai.com")
        #expect(EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 2), ruleMatch: nil).currentPath == nil)
    }

    @Test func followsTheFinalRuleThroughItsGroups() {
        // `rule match` reports only the leaf, which several groups may select; the FINAL rule names the group.
        let hints = EgressPlanner.RouteHints(finalPolicy: "Streaming", ruleMatch: SurgeRuleMatch(policy: "SG-02", rule: "FINAL"))
        let plan = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 2), hints: hints)
        #expect(plan.currentPath == ["Streaming", "Proxy", "Auto", "SG-02"])
        #expect(plan.currentRule == "FINAL")

        let builtIn = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 2), hints: .init(finalPolicy: "DIRECT"))
        #expect(builtIn.currentPath == ["DIRECT"])
        #expect(builtIn.candidates.filter { $0.leaf == "DIRECT" }.count == 1)
    }

    @Test func fallsBackToTheStatusGlobalPolicy() {
        let plan = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 1), hints: .init(statusGlobalPolicy: "AI"))
        #expect(plan.currentPath == ["AI", "US-West"], "not DIRECT when environment lacks the global policy")
        #expect(plan.currentRule == "Global · AI")
        #expect(EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 1), hints: .init()).currentPath == ["DIRECT"])
    }

    @Test func ignoresTheInternalRuleName() {
        let plan = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 2), ruleMatch: SurgeRuleMatch(policy: "AI", rule: "(internal)"))
        #expect(plan.currentPath == ["AI", "US-West"])
        #expect(plan.currentRule == nil)
    }

    @Test func addsTheCurrentPolicyWhenNoGroupSelectsIt() {
        let plan = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 1, global: "JP-Tokyo"), ruleMatch: nil)
        #expect(plan.currentPath == ["JP-Tokyo"])
        #expect(plan.candidates.last == EgressCandidate(policyPath: ["JP-Tokyo"], target: "POLICY::jp-tokyo"))
    }

    @Test func environmentSelectionsWinOverGroupDefaults() {
        let plan = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 2, selections: [:]), ruleMatch: SurgeRuleMatch(policy: "Proxy", rule: "FINAL"))
        #expect(plan.currentPath == ["Proxy", "HK-01"])
    }

    @Test func automaticGroupsUseTheirLivePick() {
        var groups = Self.groups
        groups[1].type = "URL Test Group"
        let selections = ["Proxy": "Auto", "Auto": "HK-01"]   // a stale pick in the environment
        let plan = EgressPlanner.plan(groups: groups, environment: environment(mode: 2, selections: selections), hints: .init(finalPolicy: "Proxy"))
        #expect(plan.currentPath == ["Proxy", "Auto", "SG-02"])
        #expect(EgressPlanner.isAutomatic(groupType: "URL Test Group"))
        #expect(EgressPlanner.isAutomatic(groupType: "Fallback Group"))
        #expect(EgressPlanner.isAutomatic(groupType: "Load Balance Group"))
        #expect(EgressPlanner.isAutomatic(groupType: "Smart Group"))
        #expect(!EgressPlanner.isAutomatic(groupType: "Manual Selection Group"))
        #expect(!EgressPlanner.isAutomatic(groupType: nil))
    }

    @Test func arrangesTheCurrentSampleFirst() {
        let now = Date.now
        let samples = [["DIRECT"], ["Proxy", "Auto", "SG-02"], ["AI", "US-West"]].map {
            EgressSample(policyPath: $0, ip: "1.1.1.1", location: nil, network: nil, latencyMs: nil, isCurrent: false, checkedAt: now, error: nil)
        }
        let arranged = EgressPlanner.arrange(samples, currentPath: ["Streaming", "Proxy", "Auto", "SG-02"])
        #expect(arranged.map(\.policyDisplay) == ["Streaming › Proxy › Auto › SG-02", "DIRECT", "AI › US-West"])
        #expect(arranged.map(\.isCurrent) == [true, false, false])
    }

    @Test func formatsLocationsAndNetworks() {
        #expect(EgressPlanner.countryName("HK") == "Hong Kong")
        #expect(EgressPlanner.countryName("jp") == "Japan")
        #expect(EgressPlanner.countryName(nil) == nil)
        #expect(EgressPlanner.network(asn: 9009, organization: "M247 Europe SRL") == "AS9009 M247 Europe SRL")
        #expect(EgressPlanner.network(asn: nil, organization: nil) == nil)
        #expect(EgressSignal.policyChanged.reason == "Policy group switched by hand")
        #expect(EgressSignal.profileReloaded.reason == "Profile reloaded")
        #expect(EgressSignal.networkChanged("Wi-Fi “Office-5G”").reason == "Network changed to Wi-Fi “Office-5G”")
        #expect(EgressSignal.wake.reason == nil)
    }

    @Test func storesCountriesAsISOCodes() {
        #expect(EgressPlanner.countryCode("sg") == "SG")
        #expect(EgressPlanner.countryCode(" HK ") == "HK")
        #expect(EgressPlanner.countryCode("Hong Kong") == "HK", "names stored by older versions map back to their code")
        #expect(EgressPlanner.countryCode("United States") == "US")
        #expect(EgressPlanner.countryCode("Japan") == "JP")
        #expect(EgressPlanner.countryCode("Los Angeles, US") == nil, "free text is not a country")
        #expect(EgressPlanner.countryCode("") == nil)
        #expect(EgressPlanner.countryCode(nil) == nil)
    }

    @Test @MainActor func namesStoredLocationsInTheAppLanguage() {
        guard Localizer.shared.languageCode == "en" else { return }
        #expect(EgressPlanner.localizedLocation("HK") == "Hong Kong")
        #expect(EgressPlanner.localizedLocation("Japan") == "Japan")
        #expect(EgressPlanner.localizedLocation("Los Angeles, US") == "Los Angeles, US")
        #expect(EgressPlanner.localizedLocation(nil) == nil)
    }

    // MARK: Change causes

    static func routing(_ path: [String], selections: [String: String], automatic: Set<String> = [], mode: Int = 2, global: String? = nil) -> EgressPlanner.RoutingState {
        EgressPlanner.RoutingState(proxyMode: mode, globalPolicy: global, currentPath: path, selections: selections, automaticGroups: automatic)
    }

    @Test func tellsAutomaticPicksFromManualSwitches() {
        let before = Self.routing(["Proxy", "Auto", "SG-02"], selections: ["Proxy": "Auto", "Auto": "SG-02"], automatic: ["Auto"])
        let autoPick = Self.routing(["Proxy", "Auto", "HK-01"], selections: ["Proxy": "Auto", "Auto": "HK-01"], automatic: ["Auto"])
        let manual = Self.routing(["Proxy", "JP-Tokyo"], selections: ["Proxy": "JP-Tokyo", "Auto": "SG-02"], automatic: ["Auto"])
        let elsewhere = Self.routing(["Proxy", "Auto", "SG-02"], selections: ["Proxy": "Auto", "Auto": "SG-02", "AI": "US-East"], automatic: ["Auto"])
        #expect(EgressPlanner.routeChange(from: before, to: autoPick) == .automatic)
        #expect(EgressPlanner.routeChange(from: before, to: manual) == .manual)
        #expect(EgressPlanner.routeChange(from: before, to: elsewhere) == .none, "a group off the route does not explain it")
        #expect(EgressPlanner.routeChange(from: nil, to: autoPick) == .none)
        let global = Self.routing(["AI", "US-West"], selections: [:], mode: 1, global: "AI")
        #expect(EgressPlanner.routeChange(from: global, to: Self.routing(["X", "US-West"], selections: [:], mode: 1, global: "X")) == .manual)
        #expect(EgressPlanner.routeChange(from: global, to: before) == .manual, "the outbound mode changed")
    }

    @Test func picksTheReasonToStore() {
        #expect(EgressPlanner.changeReason(noted: nil, route: .automatic) == "Auto test picked a faster node")
        #expect(EgressPlanner.changeReason(noted: nil, route: .manual) == "Policy group switched by hand")
        #expect(EgressPlanner.changeReason(noted: nil, route: .none) == "Egress changed")
        #expect(EgressPlanner.changeReason(noted: EgressReason.manualSwitch, route: .automatic) == "Auto test picked a faster node")
        #expect(EgressPlanner.changeReason(noted: EgressReason.manualSwitch, route: .manual) == "Policy group switched by hand")
        #expect(EgressPlanner.changeReason(noted: "Surge restarted", route: .automatic) == "Surge restarted")
        #expect(EgressPlanner.changeReason(noted: "Network changed to Ethernet", route: .none) == "Network changed to Ethernet")
    }

    // MARK: Measuring and IP info

    @Test func measuresEachPolicyThroughSurge() async {
        let surge = CaptureFakeSurge()
        surge.update { s in
            s.externalIPs = ["DIRECT": "123.118.32.17", "POLICY::sg-02": "139.180.141.22", "POLICY::v6": "2001:19f0::1"]
            s.latencies = ["DIRECT": 8, "POLICY::sg-02": 75]
            s.geo["139.180.141.22"] = SurgeGeoIP(address: nil, country: "SG", asn: 20473, organization: "The Constant Company")
        }
        let candidates = [EgressCandidate(policyPath: ["DIRECT"], target: "DIRECT"),
                          EgressCandidate(policyPath: ["Proxy", "SG-02"], target: "POLICY::sg-02"),
                          EgressCandidate(policyPath: ["AI", "US-West"], target: "POLICY::us-west"),
                          EgressCandidate(policyPath: ["V6"], target: "POLICY::v6")]
        let samples = await EgressMonitor.measure(candidates, surge: surge, timeout: .seconds(2), now: .now)
        #expect(samples.map(\.ip) == ["123.118.32.17", "139.180.141.22", nil, "2001:19f0::1"])
        #expect(samples[1].location == "SG", "the ISO code; the UI names the country in the app language")
        #expect(samples[1].network == "AS20473 The Constant Company")
        #expect(samples[1].latencyMs == 75)
        #expect(samples[1].hasIPv6 == nil, "unknown until tested")
        #expect(samples[2].error != nil)
        #expect(samples[3].hasIPv6 == true)
    }

    @Test func parsesTheIPInfoService() throws {
        let json = #"{"status":"ok","1.1.1.1":{"asn":"AS13335","hostname":"one.one.one.one","organisation":"Cloudflare, Inc.","isocode":"AU","proxy":"no","type":"Business"}}"#
        let info = try #require(EgressIPInfo.parseService(Data(json.utf8), ip: "1.1.1.1"))
        #expect(info.networkType == "Business")
        #expect(info.kind == "business")
        #expect(info.asn == 13335)
        #expect(info.hostname == "one.one.one.one")
        #expect(info.countryCode == "AU")
        let hosting = #"{"status":"ok","45.76.218.90":{"type":"Hosting","proxy":"yes"}}"#
        let parsed = EgressIPInfo.parseService(Data(hosting.utf8), ip: "45.76.218.90")
        #expect(parsed?.networkType == "Hosting · proxy")
        #expect(parsed?.kind == "hosting")
        #expect(EgressIPInfo.serviceURL(for: "1.1.1.1")?.absoluteString == "https://proxycheck.io/v2/1.1.1.1?vpn=1&asn=1")
    }

    @Test func normalizesNetworkTypes() {
        #expect(EgressIPInfo.networkKind("Hosting") == "hosting")
        #expect(EgressIPInfo.networkKind("Data Center") == "hosting")
        #expect(EgressIPInfo.networkKind("Residential") == "residential")
        #expect(EgressIPInfo.networkKind("Wireless") == "mobile")
        #expect(EgressIPInfo.networkKind("Business") == "business")
        #expect(EgressIPInfo.networkKind("VPN") == "vpn")
        #expect(EgressIPInfo.networkKind("  ") == nil)
    }

    @Test func keepsNonPublicAddressesLocal() {
        for ip in ["10.0.0.1", "172.16.5.4", "172.31.255.255", "192.168.31.24", "127.0.0.1", "169.254.1.1", "100.64.0.1", "100.127.255.254",
                   "198.18.0.1", "198.19.255.1", "192.0.2.1", "198.51.100.7", "203.0.113.7", "0.0.0.0", "224.0.0.251", "255.255.255.255",
                   "::1", "::", "fe80::1", "fd7a:115c:a1e0::1", "ff02::1", "2001:db8::42", "::ffff:192.168.1.1", "not an ip"] {
            #expect(!EgressIPInfo.isPublic(ip), "\(ip)")
        }
        for ip in ["1.1.1.1", "104.16.27.34", "100.128.0.1", "172.32.0.1", "198.20.0.1", "2606:4700:4700::1111", "::ffff:8.8.8.8", "[2001:4860::8888]"] {
            #expect(EgressIPInfo.isPublic(ip), "\(ip)")
        }
    }

    @Test func rejectsInvalidAddressesForReverseDNS() {
        #expect(EgressIPInfo.lookupName("not an ip") == nil)
        #expect(EgressIPInfo.lookupName("999.1.1.1") == nil)
    }

    @Test func reverseDNSGivesUpAfterTheTimeout() async {
        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = await EgressIPInfo.reverseDNS("192.0.2.1", timeout: .milliseconds(200))
        }
        #expect(elapsed < .seconds(2), "the blocking lookup is left behind instead of awaited")
    }
}

@MainActor
struct EgressMonitorTests {
    let scratch = TestDefaults()

    func makeModel(surge: any SurgeClient, database: CaptureFakeDatabase = CaptureFakeDatabase()) -> AppModel {
        let model = AppModel(preferences: Preferences(defaults: scratch.make()))
        model.surge = surge
        model.database = database
        return model
    }

    func makeMonitor(_ model: AppModel, service: EgressServiceSpy = EgressServiceSpy()) -> EgressMonitor {
        let monitor = EgressMonitor(model: model, checkTimeout: .seconds(2))
        monitor.serviceLookup = service.lookup
        monitor.reverseLookup = { _ in nil }
        return monitor
    }

    @Test func logsChangesOfTheCurrentEgressWithTheirCause() async {
        let surge = CaptureFakeSurge()
        surge.update { s in
            s.groups = EgressPlannerTests.groups
            s.environment = SurgeEnvironment(proxyMode: 1, globalPolicy: "Proxy", groupSelections: ["Proxy": "HK-01"])
            s.externalIPs = ["DIRECT": "123.118.32.17", "POLICY::hk-01": "103.152.220.41", "POLICY::sg-02": "139.180.141.22", "POLICY::us-west": "154.21.88.6"]
        }
        let database = CaptureFakeDatabase()
        let model = makeModel(surge: surge, database: database)
        let monitor = makeMonitor(model)

        await monitor.checkAll()
        #expect(model.egress.current?.policyPath == ["Proxy", "HK-01"])
        #expect(model.egress.current?.ip == "103.152.220.41")
        #expect(model.egress.proxyMode == 1)
        #expect(model.egress.currentRule == "Global · Proxy")
        #expect(model.egress.samples.count == 4)
        #expect(model.egress.lastChecked != nil)
        #expect(await database.egressSamples.count == 4)
        #expect(model.egress.changes.isEmpty, "the first check has nothing to compare with")

        // The user picks JP-Tokyo by hand; Surge emits an environment event.
        surge.update { s in
            s.environment.groupSelections["Proxy"] = "JP-Tokyo"
            s.externalIPs["POLICY::jp-tokyo"] = "45.76.218.90"
        }
        monitor.note(.policyChanged)
        await monitor.checkAll()
        #expect(model.egress.current?.ip == "45.76.218.90")
        #expect(model.egress.changes.first?.reason == "Policy group switched by hand")
        #expect(model.egress.changes.first?.policyPath == ["Proxy", "JP-Tokyo"])

        // No cause observed: a generic reason.
        surge.update { $0.externalIPs["POLICY::jp-tokyo"] = "45.76.218.91" }
        await monitor.checkAll()
        #expect(model.egress.changes.first?.reason == "Egress changed")
        #expect(model.egress.changes.count == 2)
    }

    /// Rule mode with Proxy → Auto (a URL test group) → SG-02 as the FINAL route.
    func autoTestSurge() -> EgressFakeSurge {
        var groups = EgressPlannerTests.groups
        groups[1].type = "URL Test Group"
        let surge = EgressFakeSurge()
        surge.update { s in
            s.groups = groups
            s.environment = SurgeEnvironment(proxyMode: 2, globalPolicy: nil, groupSelections: ["Proxy": "Auto"])
            s.finalPolicy = "Proxy"
            s.externalIPs = ["DIRECT": "123.118.32.17", "POLICY::hk-01": "103.152.220.41", "POLICY::sg-02": "139.180.141.22",
                             "POLICY::us-west": "154.21.88.6", "POLICY::jp-tokyo": "45.76.218.90"]
        }
        return surge
    }

    @Test func reportsAutoTestPicks() async {
        let surge = autoTestSurge()
        let model = makeModel(surge: surge)
        let monitor = makeMonitor(model)

        await monitor.checkAll()
        #expect(model.egress.current?.policyPath == ["Proxy", "Auto", "SG-02"])
        #expect(model.egress.currentRule == "FINAL")
        #expect(model.egress.proxyMode == 2)
        #expect(surge.snapshot.ruleMatches == 0, "the FINAL rule is read instead of matching a made-up host")

        // The URL test switches to HK-01 without an environment event.
        surge.update { $0.groups[1].selected = "HK-01" }
        await monitor.checkAll()
        #expect(model.egress.current?.policyPath == ["Proxy", "Auto", "HK-01"])
        #expect(model.egress.changes.first?.reason == "Auto test picked a faster node")

        // An environment event whose only effect on the route was the automatic pick.
        surge.update { $0.groups[1].selected = "SG-02" }
        monitor.note(.policyChanged)
        await monitor.checkAll()
        #expect(model.egress.changes.first?.reason == "Auto test picked a faster node")

        // A manual switch whose environment event was missed.
        surge.update { $0.environment.groupSelections["Proxy"] = "JP-Tokyo" }
        await monitor.checkAll()
        #expect(model.egress.changes.first?.reason == "Policy group switched by hand")
        #expect(model.egress.changes.count == 3)
    }

    @Test func forgetsACauseThatChangedNothing() async {
        let surge = autoTestSurge()
        let model = makeModel(surge: surge)
        let monitor = makeMonitor(model)
        await monitor.checkAll()

        monitor.note(.profileReloaded)
        await monitor.checkAll()
        #expect(model.egress.changes.isEmpty)

        surge.update { $0.externalIPs["POLICY::sg-02"] = "139.180.141.23" }
        await monitor.checkAll()
        #expect(model.egress.changes.first?.reason == "Egress changed", "the reload was checked and did not move the egress")
    }

    @Test func checksAgainWhenAskedDuringACheck() async throws {
        let surge = autoTestSurge()
        surge.update { $0.externalIPDelay = .milliseconds(300) }
        let model = makeModel(surge: surge)
        let monitor = makeMonitor(model)
        let first = Task { await monitor.checkAll() }
        while !model.egress.isChecking { await Task.yield() }
        let callsPerCheck = 3   // DIRECT, Proxy › Auto › SG-02, AI › US-West
        await monitor.checkAll()   // returns at once: a check is running
        await first.value
        for _ in 0..<100 where surge.snapshot.externalIPCalls.count < 2 * callsPerCheck {
            try await Task.sleep(for: .milliseconds(50))
        }
        while model.egress.isChecking { try await Task.sleep(for: .milliseconds(20)) }
        #expect(surge.snapshot.externalIPCalls.count == 2 * callsPerCheck, "the request is not dropped")
    }

    @Test func testsIPv6ThroughTheCurrentPolicy() async {
        let surge = autoTestSurge()
        let model = makeModel(surge: surge)
        let monitor = makeMonitor(model)
        await monitor.checkAll()
        #expect(model.egress.current?.hasIPv6 == false)
        #expect(surge.snapshot.httpProbes == ["POLICY::sg-02"], "only the current egress is tested")
        #expect(model.egress.samples.dropFirst().allSatisfy { $0.hasIPv6 == nil })

        await monitor.checkAll()
        #expect(surge.snapshot.httpProbes.count == 1, "the answer is reused for the same policy and IP")

        surge.update { s in
            s.groups[1].selected = "HK-01"
            s.ipv6Targets = ["POLICY::hk-01"]
        }
        await monitor.checkAll()
        #expect(model.egress.current?.hasIPv6 == true)
    }

    /// Only Surge saying the IPv6 address can't be reached means "No IPv6"; anything else stays unknown and
    /// is not kept, so the next check asks again.
    @Test func keepsIPv6UnknownWhenTheProbeFailsForAnotherReason() async {
        let surge = autoTestSurge()
        surge.update { $0.ipv6Failure = .timedOut(command: "http probe") }
        let model = makeModel(surge: surge)
        let monitor = makeMonitor(model)
        await monitor.checkAll()
        #expect(model.egress.current?.ip != nil)
        #expect(model.egress.current?.hasIPv6 == nil)

        surge.update { $0.ipv6Failure = .commandFailed(command: "http probe", message: "Policy does not exist.") }
        await monitor.checkAll()
        #expect(surge.snapshot.httpProbes.count == 2, "an unknown answer is not cached")
        #expect(model.egress.current?.hasIPv6 == nil)

        surge.update { $0.ipv6Failure = .commandFailed(command: "http probe", message: "HTTP request timeout") }
        await monitor.checkAll()
        #expect(model.egress.current?.hasIPv6 == false, "Surge gave up on the IPv6 address through the policy")
        await monitor.checkAll()
        #expect(surge.snapshot.httpProbes.count == 3, "a definite answer is cached")
    }

    @Test func tellsNoRouteFromOtherProbeFailures() async {
        #expect(EgressMonitor.meansNoIPv6("No outgoing interface"))
        #expect(EgressMonitor.meansNoIPv6("HTTP request timeout"))
        #expect(EgressMonitor.meansNoIPv6("connect: Network is unreachable"))
        #expect(!EgressMonitor.meansNoIPv6("Policy does not exist."))
        #expect(!EgressMonitor.meansNoIPv6("exit status 1"))

        let surge = EgressFakeSurge()
        surge.update { s in
            s.ipv6Targets = ["v6"]
            s.httpProbeDelay = .milliseconds(500)
        }
        #expect(await EgressMonitor.reachesIPv6(through: "v6", surge: surge) == true)
        #expect(await EgressMonitor.reachesIPv6(through: "v4-only", surge: surge) == false)
        #expect(await EgressMonitor.reachesIPv6(through: nil, surge: surge) == nil)
        #expect(await EgressMonitor.reachesIPv6(through: "v6", surge: surge, timeout: .milliseconds(50)) == nil,
                "Tidemark's own deadline is not an answer")
    }

    /// The IP info service is always on, and only ever sees public addresses.
    @Test func asksTheIPInfoServiceOnlyForPublicEgressIPs() async {
        let surge = autoTestSurge()
        surge.update { s in
            s.externalIPs["DIRECT"] = "100.80.1.2"   // carrier-grade NAT: never sent
        }
        let model = makeModel(surge: surge)
        let spy = EgressServiceSpy()
        let monitor = makeMonitor(model, service: spy)

        await monitor.checkAll()
        #expect(Set(spy.ips) == ["139.180.141.22", "154.21.88.6"])
        #expect(model.egress.current?.networkType == "hosting")
        #expect(model.egress.samples.first { $0.policyPath == ["DIRECT"] }?.networkType == nil)

        await monitor.checkAll()
        #expect(spy.ips.count == 2, "answers are cached")

        let result = await monitor.lookup(ip: "1.1.1.1")
        #expect(spy.ips.last == "1.1.1.1")
        #expect(result.networkType == "Hosting")
        #expect(result.country == "US", "the ISO code")
        _ = await monitor.lookup(ip: "192.168.1.1")
        #expect(spy.ips.last == "1.1.1.1", "private addresses are not sent")
    }

    @Test func notesNetworkChangesFromSurgesView() async {
        let surge = autoTestSurge()
        let model = makeModel(surge: surge)
        let monitor = makeMonitor(model)

        await monitor.refreshNetwork()
        #expect(model.egress.network?.interface == "en0")
        await monitor.checkAll()

        // Same interfaces, another Wi-Fi network: only Surge's view tells.
        surge.update { s in
            s.network = ThisMacNetwork(interface: "en1", interfaceDetail: "Wi-Fi “Office-5G”", localIP: "10.1.2.133", router: "10.1.2.1",
                                       dnsServers: [], surgeMode: nil)
            s.externalIPs["POLICY::sg-02"] = "139.180.141.99"
        }
        await monitor.refreshNetwork()
        await monitor.checkAll()
        #expect(model.egress.changes.first?.reason == "Network changed to Wi-Fi “Office-5G”")

        // Back to the cable; a reading without an address (offline) is not a network.
        surge.update { s in
            s.network = ThisMacNetwork(interface: nil, interfaceDetail: nil, localIP: nil, router: nil, dnsServers: [], surgeMode: nil)
        }
        await monitor.refreshNetwork()
        surge.update { s in
            s.network = ThisMacNetwork(interface: "en0", interfaceDetail: "Wired", localIP: "192.168.1.20", router: "192.168.1.1",
                                       dnsServers: [], surgeMode: nil)
            s.externalIPs["POLICY::sg-02"] = "139.180.141.22"
        }
        await monitor.refreshNetwork()
        await monitor.checkAll()
        #expect(model.egress.changes.first?.reason == "Network changed to Ethernet")
        #expect(model.egress.changes.count == 2)

        // An unchanged reading notes nothing.
        surge.update { $0.externalIPs["POLICY::sg-02"] = "139.180.141.23" }
        await monitor.refreshNetwork()
        await monitor.checkAll()
        #expect(model.egress.changes.first?.reason == "Egress changed")
    }

    @Test func describesNetworks() {
        func network(_ interface: String?, _ detail: String?) -> ThisMacNetwork {
            ThisMacNetwork(interface: interface, interfaceDetail: detail, localIP: nil, router: nil, dnsServers: [], surgeMode: nil)
        }
        #expect(EgressMonitor.describe(network("en0", "Wired")) == "Ethernet")
        #expect(EgressMonitor.describe(network("en1", "Wi-Fi “Home”")) == "Wi-Fi “Home”")
        #expect(EgressMonitor.describe(network("en5", nil)) == "en5")
        #expect(EgressMonitor.describe(network(nil, nil)) == nil)
    }

    @Test func looksUpIPs() async {
        let surge = EgressFakeSurge()
        surge.update { $0.geo["8.8.8.8"] = SurgeGeoIP(address: "8.8.8.8", country: "us", asn: 15169, organization: "Google LLC") }
        let model = makeModel(surge: surge)
        let spy = EgressServiceSpy(answer: nil)
        let monitor = makeMonitor(model, service: spy)
        monitor.reverseLookup = { $0 == "8.8.8.8" ? "dns.google" : nil }

        let google = await monitor.lookup(ip: " 8.8.8.8 ")
        #expect(google.country == "US")
        #expect(google.asn == 15169)
        #expect(google.reverseDNS == "dns.google")
        #expect(spy.ips == ["8.8.8.8"])

        let invalid = await monitor.lookup(ip: "example.com")
        #expect(invalid.country == nil)
        #expect(spy.ips == ["8.8.8.8"])
    }
}
