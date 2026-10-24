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
    }

    @Test func findsTheCurrentRoutePerOutboundMode() {
        #expect(EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 0), ruleMatch: nil).currentPath == ["DIRECT"])
        #expect(EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 1, global: "AI"), ruleMatch: nil).currentPath == ["AI", "US-West"])
        let byLeaf = EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 2), ruleMatch: SurgeRuleMatch(policy: "US-West", rule: "DOMAIN-SUFFIX,openai.com"))
        #expect(byLeaf.currentPath == ["AI", "US-West"])
        #expect(EgressPlanner.plan(groups: Self.groups, environment: environment(mode: 2), ruleMatch: nil).currentPath == nil)
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
        #expect(EgressSignal.networkChanged("Wi-Fi “Office-5G”").reason == "Network changed to Wi-Fi “Office-5G”")
        #expect(EgressSignal.wake.reason == nil)
    }

    @Test func measuresEachPolicyThroughSurge() async {
        let surge = CaptureFakeSurge()
        surge.update { s in
            s.externalIPs = ["DIRECT": "123.118.32.17", "POLICY::sg-02": "139.180.141.22"]
            s.latencies = ["DIRECT": 8, "POLICY::sg-02": 75]
            s.geo["139.180.141.22"] = SurgeGeoIP(address: nil, country: "SG", asn: 20473, organization: "The Constant Company")
        }
        let candidates = [EgressCandidate(policyPath: ["DIRECT"], target: "DIRECT"),
                          EgressCandidate(policyPath: ["Proxy", "SG-02"], target: "POLICY::sg-02"),
                          EgressCandidate(policyPath: ["AI", "US-West"], target: "POLICY::us-west")]
        let samples = await EgressMonitor.measure(candidates, surge: surge, timeout: .seconds(2), now: .now)
        #expect(samples.map(\.ip) == ["123.118.32.17", "139.180.141.22", nil])
        #expect(samples[1].location == "Singapore")
        #expect(samples[1].network == "AS20473 The Constant Company")
        #expect(samples[1].latencyMs == 75)
        #expect(samples[2].error != nil)
    }

    @Test func parsesTheIPInfoService() throws {
        let json = #"{"status":"ok","1.1.1.1":{"asn":"AS13335","hostname":"one.one.one.one","organisation":"Cloudflare, Inc.","isocode":"AU","proxy":"no","type":"Business"}}"#
        let info = try #require(EgressIPInfo.parseService(Data(json.utf8), ip: "1.1.1.1"))
        #expect(info.networkType == "Business")
        #expect(info.asn == 13335)
        #expect(info.hostname == "one.one.one.one")
        #expect(info.countryCode == "AU")
        let hosting = #"{"status":"ok","45.76.218.90":{"type":"Hosting","proxy":"yes"}}"#
        #expect(EgressIPInfo.parseService(Data(hosting.utf8), ip: "45.76.218.90")?.networkType == "Hosting · proxy")
        #expect(EgressIPInfo.serviceURL(for: "1.1.1.1")?.absoluteString == "https://proxycheck.io/v2/1.1.1.1?vpn=1&asn=1")
    }

    @Test func rejectsInvalidAddressesForReverseDNS() {
        #expect(EgressIPInfo.lookupName("not an ip") == nil)
        #expect(EgressIPInfo.lookupName("999.1.1.1") == nil)
    }
}

@MainActor
struct EgressMonitorTests {
    func makeModel(surge: CaptureFakeSurge, database: CaptureFakeDatabase) -> AppModel {
        let defaults = UserDefaults(suiteName: "tidemark-tests-\(UUID().uuidString)")!
        let model = AppModel(preferences: Preferences(defaults: defaults))
        model.surge = surge
        model.database = database
        return model
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
        let monitor = EgressMonitor(model: model, checkTimeout: .seconds(2))

        await monitor.checkAll()
        #expect(model.egress.current?.policyPath == ["Proxy", "HK-01"])
        #expect(model.egress.current?.ip == "103.152.220.41")
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
}
