import Foundation
import Testing
@testable import Tidemark

@Suite("Surge command output")
struct SurgeOutputParserTests {
    // MARK: - Commands

    @Test func decodesStatus() throws {
        let status = try SurgeOutputParser.decode(SurgeStatus.self, from: SurgeFixtures.data("surge-status.json"), command: "status")
        #expect(status.version == "6.10.0")
        #expect(status.build == "12500")
        #expect(status.mode == "proxy")
        #expect(status.globalPolicy == "AI")
        #expect(status.controllerProtocol == 25)
        #expect(status.startTime == 1792780717.6306829)
        #expect(status.features?["enhanced-mode"] == true)
        #expect(status.features?["mitm"] == false)
    }

    @Test func decodesEnvironmentWithMixedValueTypes() throws {
        let environment = try SurgeOutputParser.environment(from: SurgeFixtures.data("surge-environment.json"), command: "environment")
        #expect(environment.proxyMode == 1)
        #expect(environment.globalPolicy == "AI")
        #expect(environment.groupSelections == ["AI": "AT&T-RackNerd-Hysteria2", "Mail": "AT&T-RackNerd-Hysteria2", "Select": "AT&T-RackNerd-Hysteria2"])

        let stringly = try SurgeOutputParser.environment(from: Data(#"{"environment":{"ProxyMode":"2","AllProxyModePolicyNameKey":""}}"#.utf8), command: "environment")
        #expect(stringly.proxyMode == 2)
        #expect(stringly.globalPolicy == nil)
        #expect(stringly.groupSelections.isEmpty)
    }

    @Test func decodesRecentRequestsSkippingBrokenRecords() throws {
        let requests = try SurgeOutputParser.requests(from: SurgeFixtures.data("surge-dump-recent.json"), command: "dump recent")
        #expect(requests.map(\.id) == [58433, 58419, 58440])
        let listing = try SurgeOutputParser.requestListing(from: SurgeFixtures.data("surge-dump-recent.json"), command: "dump recent")
        #expect(listing.requests == requests)
        #expect(listing.undecodable == 1, "the record with a text ID is counted, not guessed")
        #expect(try SurgeOutputParser.requestListing(from: Data(#"{"requests":[]}"#.utf8), command: "dump active").undecodable == 0)

        let completed = requests[0]
        #expect(completed.url == "api.anthropic.com:443")
        #expect(completed.method == "HTTPS")
        #expect(completed.completed == true)
        #expect(completed.completedDate == 1792871220.675943)
        #expect(completed.outBytes == 1_045_333)
        #expect(completed.notes?.contains("12:46:59.908692 [Rule] Policy decision path: AI -> AT&T-RackNerd-Hysteria2") == true)

        let active = requests[1]
        #expect(active.method == "UDP")
        #expect(active.completedDate == nil)
        #expect(active.setupCompletedDate == 1792871199.2218661)

        let fromAnotherDevice = requests[2]
        #expect(fromAnotherDevice.pid == nil, "PID 0 means no local process")
        #expect(fromAnotherDevice.processPath == nil)
        #expect(fromAnotherDevice.deviceName == "iPad")
    }

    @Test func readsDNSCacheAndLocalMappings() throws {
        let cache = try SurgeOutputParser.dnsCache(from: SurgeFixtures.data("surge-dump-dns.json"), command: "dump dns")
        #expect(cache["example.com"] == ["172.66.147.243", "104.20.23.154"])
        #expect(cache["mtalk.google.com"] == ["142.250.141.188"])
        #expect(cache["proxy.example.net"] == ["203.0.113.40"])
        #expect(cache["localhost"] == ["::1"])

        let mapped = try SurgeOutputParser.dnsCache(from: Data(#"{"local":[{"domain":"Router.LAN.","data":"server:system"},{"domain":"a.test","data":"10.0.0.1"}],"dnsCache":[{"domain":"a.test","data":["10.0.0.1","10.0.0.2"]}]}"#.utf8), command: "dump dns")
        #expect(mapped["router.lan"] == nil, "mappings to other names are not addresses")
        #expect(mapped["a.test"] == ["10.0.0.1", "10.0.0.2"], "duplicates are merged")
    }

    @Test func decodesPolicyGroupsWithLineHashes() throws {
        let groups = try SurgeOutputParser.policyGroups(
            from: SurgeFixtures.data("surge-policy-groups.json"),
            selections: ["Select": "AI", "AI": "ignored because the list has a selection"],
            command: "policy-group list"
        )
        #expect(groups.map(\.name) == ["AI", "NG", "Select"])
        #expect(groups[0].selected == "AT&T-RackNerd-Hysteria2")
        #expect(groups[0].options.map(\.name) == ["AT&T-RackNerd-SNELL", "AT&T-RackNerd-Hysteria2"])
        #expect(groups[0].options[1].lineHash == "POLICY::22222222222222222222222222222222")
        #expect(groups[0].options[1].typeDescription == "Hysteria 2")
        #expect(groups[2].selected == "AI", "taken from the environment when the list has none")
        #expect(groups[2].options[1].isGroup == true)
        #expect(groups[2].options[1].lineHash == nil)
        #expect(groups.map(\.type) == ["Manual Selection Group", "Manual Selection Group", "Manual Selection Group"])

        let untyped = try SurgeOutputParser.policyGroups(from: Data(#"{"groups":[{"name":"Auto","type":" ","options":[]}]}"#.utf8), command: "policy-group list")
        #expect(untyped.first?.type == nil)
    }

    @Test func findsTheFinalRulePolicy() throws {
        #expect(try SurgeOutputParser.finalRulePolicy(fromRules: SurgeFixtures.data("surge-dump-rule.json"), command: "dump rule") == "Select")
        let plain = Data(#"{"rules":["final, Proxy"]}"#.utf8)
        #expect(try SurgeOutputParser.finalRulePolicy(fromRules: plain, command: "dump rule") == "Proxy")
        let none = Data(#"{"rules":["DOMAIN,final.example.com,DIRECT"]}"#.utf8)
        #expect(try SurgeOutputParser.finalRulePolicy(fromRules: none, command: "dump rule") == nil)
        #expect(try SurgeOutputParser.finalRulePolicy(fromRules: Data("{}".utf8), command: "dump rule") == nil)
    }

    @Test func readsExternalIP() throws {
        #expect(try SurgeOutputParser.externalIP(from: Data(#"{"address":"203.0.113.7"}"#.utf8), command: "test external-ip") == "203.0.113.7")
        #expect(throws: SurgeError.decoding(command: "test external-ip", message: "no address in the reply")) {
            try SurgeOutputParser.externalIP(from: Data(#"{"address":""}"#.utf8), command: "test external-ip")
        }
    }

    @Test func readsPolicyLatencyFromTheReceiveTime() throws {
        #expect(try SurgeOutputParser.latency(from: SurgeFixtures.data("surge-test-policy.json"), command: "test-policy") == 156)
        let pooled = Data(#"{"AT&T-RackNerd-Hysteria2":{"receive":168,"available":0,"round-one-total":179}}"#.utf8)
        #expect(try SurgeOutputParser.latency(from: pooled, command: "test-policy") == 168)
        let direct = Data(#"{"DIRECT":{"tfo":false,"tcp":61,"receive":67,"available":64,"round-one-total":132}}"#.utf8)
        #expect(try SurgeOutputParser.latency(from: direct, command: "test-policy") == 67)
        let totalOnly = Data(#"{"X":{"round-one-total":240}}"#.utf8)
        #expect(try SurgeOutputParser.latency(from: totalOnly, command: "test-policy") == 240)
        #expect(try SurgeOutputParser.latency(from: Data("{}".utf8), command: "test-policy") == nil, "unknown policy or failed test")
    }

    @Test func describesThisMacNetwork() throws {
        let status = try SurgeOutputParser.decode(SurgeStatus.self, from: SurgeFixtures.data("surge-status.json"), command: "status")
        let network = try SurgeOutputParser.network(summary: SurgeFixtures.data("surge-summary.json"), status: status, command: "summary")
        #expect(network.interface == "en0")
        #expect(network.interfaceDetail == "Wired")
        #expect(network.localIP == "192.168.1.20")
        #expect(network.router == "192.168.1.1")
        #expect(network.dnsServers == ["223.5.5.5", "119.29.29.29"])
        #expect(network.surgeMode == "Enhanced mode · global proxy")

        let wifi = Data(#"{"sections":[{"lines":[{"content":"Wi-Fi","title":"Primary interface type"},{"content":"Office-5G","title":"Wi-Fi SSID"}]}]}"#.utf8)
        #expect(try SurgeOutputParser.network(summary: wifi, status: nil, command: "summary").interfaceDetail == "Wi-Fi “Office-5G”")
    }

    @Test func describesTheSurgeMode() {
        func mode(_ mode: String, enhanced: Bool, systemProxy: Bool) -> String? {
            SurgeOutputParser.surgeMode(for: SurgeStatus(mode: mode, features: ["enhanced-mode": enhanced, "system-proxy": systemProxy]))
        }
        #expect(mode("rule", enhanced: true, systemProxy: true) == "Enhanced mode · rule-based")
        #expect(mode("proxy", enhanced: true, systemProxy: false) == "Enhanced mode · global proxy")
        #expect(mode("direct", enhanced: true, systemProxy: false) == "Enhanced mode · direct")
        #expect(mode("rule", enhanced: false, systemProxy: true) == "System proxy · rule-based")
        #expect(mode("rule", enhanced: false, systemProxy: false) == "Rule-based")
        #expect(SurgeOutputParser.surgeMode(for: nil) == nil)
    }

    @Test func findsTheHTTPProxyPort() throws {
        #expect(try SurgeOutputParser.httpProxyPort(fromEvents: SurgeFixtures.data("surge-dump-event.json"), command: "dump event") == 6152)
        let custom = Data(#"{"events":[{"content":"HTTP proxy listen on interface: 127.0.0.1, port: 7890"}]}"#.utf8)
        #expect(try SurgeOutputParser.httpProxyPort(fromEvents: custom, command: "dump event") == 7890)
        #expect(try SurgeOutputParser.httpProxyPort(fromEvents: Data(#"{"events":[]}"#.utf8), command: "dump event") == nil)
    }

    @Test func findsTheHTTPProxyListenerInterface() throws {
        let wildcard = try #require(try SurgeOutputParser.httpProxyListener(fromEvents: SurgeFixtures.data("surge-dump-event.json"), command: "dump event"))
        #expect(wildcard == SurgeHTTPListener(interface: "0.0.0.0", port: 6152))
        #expect(wildcard.connectHost == "127.0.0.1")

        let lan = Data(#"{"events":[{"content":"HTTP proxy listen on interface: 192.168.1.20, port: 8888"}]}"#.utf8)
        let bound = try #require(try SurgeOutputParser.httpProxyListener(fromEvents: lan, command: "dump event"))
        #expect(bound.interface == "192.168.1.20" && bound.port == 8888)
        #expect(bound.connectHost == "192.168.1.20", "a listener bound to a LAN address does not accept loopback connections")

        #expect(SurgeHTTPListener(interface: "127.0.0.1", port: 1).connectHost == "127.0.0.1")
        #expect(SurgeHTTPListener(interface: "::", port: 1).connectHost == "::1")
        #expect(SurgeHTTPListener(interface: "[::1]", port: 1).connectHost == "::1")
        let socksOnly = Data(#"{"events":[{"content":"SOCKS5 proxy listen on interface: 0.0.0.0, port: 6153"}]}"#.utf8)
        #expect(try SurgeOutputParser.httpProxyListener(fromEvents: socksOnly, command: "dump event") == nil)
    }

    @Test func decodesLookups() throws {
        let lookup = try SurgeOutputParser.decode(SurgeDNSLookup.self, from: SurgeFixtures.data("surge-dns-lookup.json"), command: "dns lookup")
        #expect(lookup.addresses == ["172.66.147.243", "104.20.23.154"])
        #expect(lookup.server == "https://cloudflare-dns.com/dns-query")
        #expect(lookup.durationMs == 950.88)

        let geo = try SurgeOutputParser.decode(SurgeGeoIP.self, from: SurgeFixtures.data("surge-geoip.json"), command: "geoip")
        #expect(geo.country == "CN")
        #expect(geo.asn == 4134)
        #expect(geo.organization == "Chinanet")

        let probe = try SurgeOutputParser.decode(SurgeHTTPProbe.self, from: SurgeFixtures.data("surge-http-probe.json"), command: "http probe")
        #expect(probe.status == 200)
        #expect(probe.method == "HEAD")
        #expect(probe.policy == "AT&T-RackNerd-Hysteria2")
        #expect(probe.rule == nil)
        #expect(probe.headers?.first?.name == "date")

        let match = try SurgeOutputParser.decode(SurgeRuleMatch.self, from: Data(#"{"policy":"AT&T-RackNerd-Hysteria2","rule":"(internal)"}"#.utf8), command: "rule match")
        #expect(match.rule == "(internal)")
    }

    // MARK: - Errors

    @Test func mapsStandardErrorToCommandFailed() {
        let output = SurgeCommandOutput(exitStatus: 1, stdout: Data(), stderr: Data("Error: Policy doesn't exist\n".utf8))
        #expect(throws: SurgeError.commandFailed(command: "test-policy-external-ip X", message: "Policy doesn't exist")) {
            try SurgeOutputParser.payload(of: output, command: "test-policy-external-ip X")
        }
    }

    @Test func mapsPlainTextErrorOnStandardOutput() {
        let output = SurgeCommandOutput(exitStatus: 0, stdout: Data("Error: Unknown dump type.\n".utf8), stderr: Data())
        #expect(throws: SurgeError.commandFailed(command: "dump nosuch", message: "Unknown dump type.")) {
            try SurgeOutputParser.payload(of: output, command: "dump nosuch")
        }
    }

    @Test func mapsJSONErrorObjects() {
        let output = SurgeCommandOutput(exitStatus: 0, stdout: Data(#"{"error":"Policy group does not exist."}"#.utf8), stderr: Data())
        #expect(throws: SurgeError.commandFailed(command: "policy-group get X", message: "Policy group does not exist.")) {
            try SurgeOutputParser.payload(of: output, command: "policy-group get X")
        }
        let nested = SurgeCommandOutput(exitStatus: 0, stdout: Data(#"{"error":{"message":"Denied"}}"#.utf8), stderr: Data())
        #expect(throws: SurgeError.commandFailed(command: "status", message: "Denied")) {
            try SurgeOutputParser.payload(of: nested, command: "status")
        }
    }

    @Test func reportsExitStatusWithoutMessage() {
        let output = SurgeCommandOutput(exitStatus: 9, stdout: Data(), stderr: Data())
        #expect(throws: SurgeError.commandFailed(command: "status", message: "exit status 9")) {
            try SurgeOutputParser.payload(of: output, command: "status")
        }
    }

    @Test func passesThroughPayloadsWithNullErrorKeys() throws {
        let json = Data(#"{"error":null,"address":"203.0.113.7"}"#.utf8)
        let output = SurgeCommandOutput(exitStatus: 0, stdout: json, stderr: Data("warning on stderr".utf8))
        #expect(try SurgeOutputParser.payload(of: output, command: "test external-ip") == json)
    }

    @Test func mapsMalformedJSONToDecodingErrors() {
        #expect(throws: SurgeError.self) {
            try SurgeOutputParser.decode(SurgeStatus.self, from: Data("not json".utf8), command: "status")
        }
        do {
            _ = try SurgeOutputParser.decode(SurgeGeoIP.self, from: Data(#"{"asn":"AS13335"}"#.utf8), command: "geoip 1.1.1.1")
            Issue.record("expected a decoding error")
        } catch {
            guard case .decoding(let command, let message) = error else { Issue.record("unexpected \(error)"); return }
            #expect(command == "geoip 1.1.1.1")
            #expect(message.contains("asn"))
        }
        #expect(throws: SurgeError.decoding(command: "status", message: "surge-cli printed nothing.")) {
            try SurgeOutputParser.payload(of: SurgeCommandOutput(exitStatus: 0, stdout: Data("\n".utf8), stderr: Data()), command: "status")
        }
    }
}
