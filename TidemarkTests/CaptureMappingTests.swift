import Foundation
import Testing
@testable import Tidemark

struct CaptureMappingTests {
    let device = UUID()

    @Test func mapsAProxiedRequestInGlobalMode() throws {
        let request = try CaptureFixtures.decode(CaptureFixtures.cursorProxied)
        let record = CaptureRecordMapper.record(from: request, deviceID: device, session: 1_792_780_717_630, now: .distantPast)

        #expect(record.key == RequestKey(deviceID: device, session: 1_792_780_717_630, surgeID: 58577))
        #expect(record.host == "api3.cursor.sh")
        #expect(record.port == 443)
        #expect(record.method == "HTTPS")
        #expect(record.state == .active)
        #expect(record.policyPath == ["AI", "AT&T-RackNerd-Hysteria2"])
        #expect(record.rule == "Global · AI")
        #expect(record.remoteIP == nil, "proxied connections are resolved later")
        #expect(record.remoteAddress == "23.254.139.175 (Proxy)")
        #expect(record.localAddress == "10.1.2.133:65373")
        #expect(record.interface == "en0")
        #expect(record.bundlePath == "/Applications/Cursor.app")
        #expect(record.completedAt == nil, "Surge reports unset dates as 0")
        #expect(record.setupCompletedAt != nil)
        #expect(record.startedAt == Date(timeIntervalSince1970: 1_792_871_381.33004))
        #expect(record.inBytes == 4037 && record.outBytes == 1236)
        #expect(record.notes.count == 5)
        #expect(record.pid == 851)
        #expect(record.chain.isEmpty && record.appID == nil)
    }

    @Test func mapsADirectIPLiteral() throws {
        let request = try CaptureFixtures.decode(CaptureFixtures.wechatDirectIP)
        let record = CaptureRecordMapper.record(from: request, deviceID: device, session: 1)

        #expect(record.host == "157.148.69.80")
        #expect(record.isIPLiteral)
        #expect(record.remoteIP == "157.148.69.80")
        #expect(record.state == .completed)
        #expect(record.policyPath == ["DIRECT"])
        #expect(record.rule == "IP-CIDR,157.148.0.0/16", "the trailing policy is dropped")
        #expect(record.duration == 1)
        #expect(record.bundlePath == "/Applications/WeChat.app")
    }

    @Test func mapsRuleModeAndPlainHTTP() throws {
        let request = try CaptureFixtures.decode(CaptureFixtures.ruleModeHTTP)
        let record = CaptureRecordMapper.record(from: request, deviceID: device, session: 1)

        #expect(record.method == "GET")
        #expect(record.host == "registry.npmjs.org")
        #expect(record.port == 80)
        #expect(record.url == "http://registry.npmjs.org/@types%2fnode")
        #expect(record.policyPath == ["Proxy", "HK-01"])
        #expect(record.rule == "DOMAIN-SUFFIX,npmjs.org")
        #expect(record.bundlePath == "/usr/local/bin/node")
        #expect(record.processName == "node")
    }

    @Test func mapsFailedAndRejectedStates() throws {
        let failed = CaptureRecordMapper.record(from: try CaptureFixtures.decode(CaptureFixtures.failedRequest), deviceID: device, session: 1)
        #expect(failed.state == .failed)
        #expect(failed.host == "2001:db8::1")
        #expect(failed.port == 8443)
        #expect(failed.remoteIP == "2001:db8::1")
        #expect(failed.policyPath.isEmpty)
        #expect(failed.rule == nil)

        let rejected = CaptureRecordMapper.record(from: try CaptureFixtures.decode(CaptureFixtures.rejected), deviceID: device, session: 1)
        #expect(rejected.state == .rejected)
        #expect(rejected.policyPath == ["REJECT"])
        #expect(rejected.rule == "DOMAIN-SUFFIX,example.com")
    }

    @Test func parsesPolicyPaths() {
        #expect(CaptureRecordMapper.policyPath(notes: ["12:00:00.000001 [Rule] Policy decision path: AI -> US -> LA-01"], policyName: "LA-01") == ["AI", "US", "LA-01"])
        #expect(CaptureRecordMapper.policyPath(notes: ["12:00:00.000001 [Rule] Policy decision path: (Proxy -> HK-01)"], policyName: nil) == ["Proxy", "HK-01"])
        #expect(CaptureRecordMapper.policyPath(notes: ["12:00:00.000001 [TLS] Policy decision path: fake"], policyName: "DIRECT") == ["DIRECT"])
        #expect(CaptureRecordMapper.policyPath(notes: [], policyName: "") == [])
        // The last decision wins (a retried connection can be re-decided).
        let notes = ["12:00:00.000001 [Rule] Policy decision path: A -> B", "12:00:01.000001 [Rule] Policy decision path: A -> C"]
        #expect(CaptureRecordMapper.policyPath(notes: notes, policyName: "C") == ["A", "C"])
    }

    @Test func parsesRules() {
        let rule = { (note: String, path: [String]) in CaptureRecordMapper.rule(notes: [note], policyPath: path) }
        #expect(rule("12:00:00.000001 [Rule] Rule matched: DOMAIN-SUFFIX,cursor.sh", ["AI"]) == "DOMAIN-SUFFIX,cursor.sh")
        #expect(rule("12:00:00.000001 [Rule] Rule matched: FINAL,Proxy", ["Proxy", "HK-01"]) == "FINAL")
        #expect(rule("12:00:00.000001 [Rule] Rule matched: GEOIP,CN", ["DIRECT"]) == "GEOIP,CN")
        #expect(rule("12:00:00.000001 [Rule] Global proxy outbound mode: AI", ["AI", "X"]) == "Global · AI")
        #expect(rule("12:00:00.000001 [Rule] All direct outbound mode", ["DIRECT"]) == "Direct")
        #expect(rule("12:00:00.000001 [Rule] Sub-rule matched: DOMAIN,api.github.com", ["Proxy"]) == "DOMAIN,api.github.com")
        #expect(rule("12:00:00.000001 [TLS] TLS Client Hello SNI: example.com", ["DIRECT"]) == nil)
        // A main rule beats a sub-rule, wherever it appears.
        let both = ["12:00:00.000001 [Rule] Sub-rule matched: DOMAIN,a.com", "12:00:00.000002 [Rule] Rule matched: RULE-SET,Apple"]
        #expect(CaptureRecordMapper.rule(notes: both, policyPath: ["DIRECT"]) == "RULE-SET,Apple")
    }

    @Test func resolvesRemoteIPs() {
        #expect(CaptureRecordMapper.remoteIP(remoteAddress: "23.254.139.175 (Proxy)", host: "api.github.com") == nil)
        #expect(CaptureRecordMapper.remoteIP(remoteAddress: "140.82.121.5", host: "api.github.com") == "140.82.121.5")
        #expect(CaptureRecordMapper.remoteIP(remoteAddress: "140.82.121.5:443", host: "api.github.com") == "140.82.121.5")
        #expect(CaptureRecordMapper.remoteIP(remoteAddress: "23.254.139.175 (Proxy)", host: "149.154.175.60") == "149.154.175.60")
        #expect(CaptureRecordMapper.remoteIP(remoteAddress: nil, host: "example.com") == nil)
    }

    @Test func findsTheTopMostBundle() {
        let chain = [
            ProcessLink(name: "Cursor", pid: 812, path: "/Applications/Cursor.app/Contents/MacOS/Cursor", startTime: nil),
            ProcessLink(name: "node", pid: 1201, path: "/usr/local/bin/node", startTime: nil),
        ]
        #expect(CaptureRecordMapper.bundlePath(chain: chain, pathForStatistics: "/usr/local/bin/node") == "/Applications/Cursor.app")
        let helper = [ProcessLink(name: "Helper", pid: 1, path: "/Applications/Slack.app/Contents/Frameworks/Slack Helper.app/Contents/MacOS/Slack Helper", startTime: nil)]
        #expect(CaptureRecordMapper.bundlePath(chain: helper, pathForStatistics: nil) == "/Applications/Slack.app")
        #expect(CaptureRecordMapper.bundlePath(chain: [], pathForStatistics: "/Applications/Grok Bot.app/") == "/Applications/Grok Bot.app")
        // System daemons are reported as `SYSTEM`, which is not a bundle.
        #expect(CaptureRecordMapper.bundlePath(chain: [], pathForStatistics: "SYSTEM") == nil)
        #expect(CaptureRecordMapper.bundlePath(chain: [], pathForStatistics: nil) == nil)
    }

    @Test func splitsHostsFromURLs() {
        #expect(CaptureRecordMapper.hostAndPort(remoteHost: nil, url: "https://Example.com/path") == ("example.com", 443))
        #expect(CaptureRecordMapper.hostAndPort(remoteHost: nil, url: "http://[2001:db8::2]:8080/x") == ("2001:db8::2", 8080))
        #expect(CaptureRecordMapper.hostAndPort(remoteHost: "", url: "api.github.com:443") == ("api.github.com", 443))
        #expect(CaptureRecordMapper.hostAndPort(remoteHost: "API.GitHub.com:443", url: nil) == ("api.github.com", 443))
        // Plain HTTP through Surge's proxy: `remoteHost` has no port.
        #expect(CaptureRecordMapper.hostAndPort(remoteHost: "example.com", url: "http://example.com/") == ("example.com", 80))
    }

    @Test func formatsLocalAddresses() {
        #expect(CaptureRecordMapper.localAddress("10.1.2.133", port: 65374) == "10.1.2.133:65374")
        #expect(CaptureRecordMapper.localAddress("fe80::1", port: 80) == "[fe80::1]:80")
        #expect(CaptureRecordMapper.localAddress("10.1.2.133", port: nil) == "10.1.2.133")
        #expect(CaptureRecordMapper.localAddress(nil, port: 1) == nil)
    }
}
