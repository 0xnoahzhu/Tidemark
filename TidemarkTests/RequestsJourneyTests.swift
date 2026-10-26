import Foundation
import Testing
@testable import Tidemark

/// Requests as Surge 6.10 noted them (from the research samples), at fixed times of one day.
enum RequestsJourneyFixtures {
    static let day = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_761_400_000))
    static let mac = UUID(uuidString: "00000000-0000-0000-0000-0000000000F1")!

    /// The date of `clock` (`02:50:12.910120`) on `day`.
    static func at(_ clock: String) -> Date {
        let parts = clock.split(separator: ":").compactMap { Double($0) }
        return day.addingTimeInterval(parts[0] * 3600 + parts[1] * 60 + parts[2])
    }

    static func record(
        host: String,
        started: String,
        setup: String?,
        completed: String?,
        notes: [String],
        policy: [String] = ["AI", "AT&T-RackNerd-Hysteria2"],
        remoteIP: String? = nil,
        remoteAddress: String? = "23.254.139.175 (Proxy)",
        rule: String? = nil
    ) -> RequestRecord {
        var record = RequestRecord(
            key: RequestKey(deviceID: mac, session: 1, surgeID: 1006), rowID: 1006, startedAt: at(started),
            setupCompletedAt: setup.map(at), completedAt: completed.map(at), method: "HTTPS", host: host, port: 443,
            url: host + ":443", remoteIP: remoteIP, remoteAddress: remoteAddress, geo: nil, policyPath: policy,
            rule: rule ?? CaptureRecordMapper.rule(notes: notes, policyPath: policy), state: completed == nil ? .active : .completed,
            inBytes: 5_120, outBytes: 1_024, pid: nil, processPath: nil, bundlePath: nil, chain: [], appID: nil,
            localAddress: nil, interface: nil, notes: notes, isNew: false, writtenAt: nil, probeSessionID: nil
        )
        record.endReason = CaptureRecordMapper.endReason(notes: notes)
        return record
    }

    /// Rule mode, a DNS lookup on a cache miss (request 1006 of the research).
    static func ruleModeLookup(timed: Bool = true) -> RequestRecord {
        var record = record(
            host: "codex-cloud-backend.chatgpt.com", started: "02:50:12.910120", setup: "02:50:13.230423", completed: "02:50:14.230500",
            notes: [
                "02:50:12.910120 [Connection] Handled by VIF",
                "02:50:12.910948 [TLS] TLS Client Hello SNI: codex-cloud-backend.chatgpt.com",
                "02:50:12.911275 [Rule] Rule evaluating requires DNS lookup for rule: RULE-SET LAN",
                "02:50:13.229792 [DNS] DNS lookup for codex-cloud-backend.chatgpt.com completed in 318.4ms. A record count: 2, AAAA record count: 0",
                "02:50:13.229850 [Rule] DNS completed, IPv4 address for matching: 172.64.155.209, IPv6 address for matching: N/A",
                "02:50:13.229939 [Rule] Sub-rule matched: IP-CIDR 172.64.0.0/13(in claude.list)",
                "02:50:13.230047 [Rule] Rule matched: RULE-SET claude.list",
                "02:50:13.230134 [Rule] Policy decision path: AI -> AT&T-RackNerd-Hysteria2",
                "02:50:13.230404 [Connection-Pool] Use an existing master connector: SGHysteriaMasterConnector-2",
                "02:50:13.230423 [Connector] Master connector is now ready",
                "02:50:14.230500 [Connection] Disconnect: Closed by remote",
            ],
            remoteIP: "172.64.155.209", rule: "RULE-SET claude.list"
        )
        if timed {
            record.timing = [RequestTimingRecord(name: "DNS Lookup", duration: 0.318429), RequestTimingRecord(name: "Rule Evaluating", duration: 0.000407)]
        }
        record.entryMode = 40
        record.remoteIPSource = .ruleDNS
        record.remoteIPResolvedAt = at("02:50:13.229850")
        return record
    }

    /// Rule mode, the answer from Surge's cache.
    static func ruleModeCached() -> RequestRecord {
        record(
            host: "codex-cloud-environments.chatgpt.com", started: "02:50:18.513581", setup: "02:50:18.649059", completed: nil,
            notes: [
                "02:50:18.513581 [Connection] Handled by VIF",
                "02:50:18.647759 [TLS] TLS Client Hello SNI: codex-cloud-environments.chatgpt.com",
                "02:50:18.648329 [Rule] Rule evaluating requires DNS lookup for rule: RULE-SET LAN",
                "02:50:18.648403 [DNS] Use cached DNS result for codex-cloud-environments.chatgpt.com. A record count: 2, AAAA record count: 0",
                "02:50:18.648445 [Rule] DNS completed, IPv4 address for matching: 172.64.155.209, IPv6 address for matching: N/A",
                "02:50:18.648540 [Rule] Rule matched: RULE-SET claude.list",
                "02:50:18.648638 [Rule] Policy decision path: AI -> AT&T-RackNerd-Hysteria2",
                "02:50:18.649005 [Connection-Pool] Use an existing master connector: SGHysteriaMasterConnector-2",
                "02:50:18.649059 [Connector] Master connector is now ready",
            ],
            remoteIP: "172.64.155.209"
        )
    }

    /// Global proxy mode through the HTTP proxy, reset at the end; its IP from Tidemark's lookup three minutes before.
    static func globalModeReset() -> RequestRecord {
        var record = record(
            host: "collect.moomoo.com", started: "02:42:21.285769", setup: "02:42:21.298537", completed: "02:42:21.917266",
            notes: [
                "02:42:21.285769 [Connection] Incoming proxy protocol: HTTP",
                "02:42:21.297502 [TLS] TLS Client Hello SNI: collect.moomoo.com",
                "02:42:21.297989 [Rule] Global proxy outbound mode: AI",
                "02:42:21.298080 [Rule] Policy decision path: AI -> AT&T-RackNerd-Hysteria2",
                "02:42:21.298498 [Connection-Pool] Use an existing master connector: SGHysteriaMasterConnector-2",
                "02:42:21.298537 [Connector] Master connector is now ready",
                "02:42:21.770308 [Connection] Client closed sending stream",
                "02:42:21.917266 [Connection] Disconnect: TCP error: Connection reset.",
            ],
            remoteIP: "43.175.21.9"
        )
        record.entryMode = 1
        record.remoteIPSource = .tidemarkLookup
        record.remoteIPResolvedAt = at("02:39:21.285769")
        return record
    }
}

struct RequestTimingSegmentTests {
    typealias F = RequestsJourneyFixtures

    @Test func placesTheTimedDNSLookupBeforeTheConnect() throws {
        let phases = RequestTiming.phases(for: F.ruleModeLookup())
        #expect(phases.map(\.kind) == [.clientHello, .dns, .connect, .transfer])
        // Surge's own timing, not the 0.1 ms between the DNS note and the next one.
        #expect(abs(phases[1].duration - 0.318429) < 0.000_01)
        // What is left of the setup after the hello and the lookup: about a millisecond, not 319 ms.
        #expect(abs(phases[2].duration - (0.320303 - 0.000828 - 0.318429)) < 0.000_01)
        #expect(abs(phases[0].duration - 0.000828) < 0.000_01)
    }

    @Test func readsTheLookupFromItsNoteWithoutATiming() throws {
        let phases = RequestTiming.phases(for: F.ruleModeLookup(timed: false))
        let dns = try #require(phases.first { $0.kind == .dns })
        #expect(abs(dns.duration - 0.3184) < 0.000_01)
    }

    @Test func aCachedAnswerTakesNoDNSTime() {
        let record = F.ruleModeCached()
        let phases = RequestTiming.phases(for: record, now: record.setupCompletedAt!.addingTimeInterval(2))
        #expect(phases.map(\.kind) == [.clientHello, .connect, .transfer])
        // An active request's transfer runs until now.
        #expect(abs(phases[2].duration - 2) < 0.000_01)
    }

    @Test func labelsGlobalModesSetupAsLocal() {
        let phases = RequestTiming.phases(for: F.globalModeReset())
        #expect(phases.map(\.kind) == [.clientHello, .local, .transfer])
        #expect(RequestTiming.isGlobalProxy(F.globalModeReset()))
        #expect(!RequestTiming.isGlobalProxy(F.ruleModeLookup()))
    }

    @Test func aHelloReadAfterTheRuleIsNoWait() {
        let record = F.record(
            host: "example.com", started: "10:00:00.000000", setup: "10:00:00.010000", completed: "10:00:01.000000",
            notes: [
                "10:00:00.000000 [Connection] Incoming proxy protocol: HTTP",
                "10:00:00.001000 [Rule] Rule matched: FINAL",
                "10:00:00.008000 [TLS] TLS Client Hello SNI: example.com",
            ]
        )
        #expect(RequestTiming.phases(for: record).map(\.kind) == [.connect, .transfer])
    }

    @MainActor
    @Test func namesEveryPhase() {
        let saved = Localizer.shared.override
        defer { Localizer.shared.override = saved }
        Localizer.shared.override = "en"
        #expect(TimingPhase.Kind.allCases.map(TimingBar.label) == ["Client hello", "DNS", "Connect", "Surge (local)", "Transfer"])
        Localizer.shared.override = "zh-Hans"
        guard Localizer.shared.bundle != nil else { return }
        #expect(TimingBar.label(.clientHello) == "Client Hello")
        #expect(TimingBar.label(.local) == "Surge（本机）")
    }
}

struct RequestsJourneyTests {
    typealias F = RequestsJourneyFixtures

    @Test func followsARuleModeRequestThroughItsLookup() throws {
        let record = F.ruleModeLookup()
        let answer = DNSAnswer(
            deviceID: F.mac, domain: record.host, resolvedAt: F.at("02:50:13.229792"), server: "https://cloudflare-dns.com/dns-query",
            interface: nil, addresses: ["172.64.155.209", "104.18.32.47"],
            path: "codex-cloud-backend.chatgpt.com -> codex.chatgpt.com.cdn.cloudflare.net -> 172.64.155.209, 104.18.32.47",
            log: nil, timeCostMs: 318.4, expiresAt: nil
        )
        let check = EgressSample(policyPath: ["AI", "AT&T-RackNerd-Hysteria2"], ip: "38.150.10.4", location: "Los Angeles, US", network: nil,
                                 latencyMs: 210, isCurrent: true, checkedAt: record.startedAt.addingTimeInterval(-240))
        let related = RequestRelatedRecords(egressCheck: check, dnsAnswer: answer)
        let journey = RequestsJourney(record: record, related: related, nodeType: "Hysteria 2", proxyGeo: GeoInfo(countryCode: "US", asn: 36352, organization: "HostPapa"))

        guard journey.stages.count == 6,
              case .entered(let entered) = journey.stages[0], case .dns(let dns) = journey.stages[1], case .rule(let rule) = journey.stages[2],
              case .route(let route) = journey.stages[3], case .connection(let connection) = journey.stages[4], case .end(let end) = journey.stages[5]
        else {
            Issue.record("unexpected stages \(journey.stages)")
            return
        }
        #expect(entered == RequestsJourney.Entered(entry: .virtualInterface(udp: false), sni: "codex-cloud-backend.chatgpt.com"))

        #expect(dns.lookup == .lookedUp(milliseconds: 318.4))
        // Dated by the rule's note asking for it.
        #expect(abs((dns.offset ?? 0) - 0.001155) < 0.000_01)
        #expect(dns.recordCounts == RequestsJourney.DNS.RecordCounts(a: 2, aaaa: 0))
        #expect(dns.cnames == ["codex.chatgpt.com.cdn.cloudflare.net"])
        #expect(dns.answer == answer)
        // The address rules matched on is the IP shown, so it is said once.
        #expect(dns.matchedIP == nil)
        #expect(dns.shownIP == RequestsJourney.ShownIP(ip: "172.64.155.209", source: .ruleDNS, age: F.at("02:50:13.229850").timeIntervalSince(record.startedAt)))
        // A proxy policy resolves the name again on the proxy.
        #expect(dns.resolvedByProxy)

        #expect(rule.decision == .matched("RULE-SET claude.list"))
        #expect(rule.subRule == "IP-CIDR 172.64.0.0/13(in claude.list)")
        #expect(route.hops == [
            .entry(.virtualInterface(udp: false)),
            .group("AI"),
            .node("AT&T-RackNerd-Hysteria2", type: "Hysteria 2"),
            .proxyServer("23.254.139.175", geo: GeoInfo(countryCode: "US", asn: 36352, organization: "HostPapa")),
            .exit("38.150.10.4", location: "Los Angeles, US", age: -240),
            .destination("codex-cloud-backend.chatgpt.com:443", address: nil),
        ])
        #expect(connection == RequestsJourney.Connection(offset: F.at("02:50:13.230404").timeIntervalSince(record.startedAt), reused: true,
                                                          connector: "SGHysteriaMasterConnector-2"))
        #expect(end.reason == "Closed by remote")
        #expect(!end.isError)
        #expect(end.inBytes == 5_120)
    }

    @Test func saysTheProxyResolvedAGlobalModeRequest() throws {
        let record = F.globalModeReset()
        let error = ProxyNodeError(deviceID: F.mac, policy: "AT&T-RackNerd-Hysteria2", lineHash: "POLICY::1", at: record.completedAt!,
                                   targetHost: record.host, error: "Stream closed")
        // An egress check through another policy says nothing about this request's exit.
        let check = EgressSample(policyPath: ["DIRECT"], ip: "203.0.113.9", location: nil, network: nil, latencyMs: nil, isCurrent: true,
                                 checkedAt: record.startedAt)
        let journey = RequestsJourney(record: record, related: RequestRelatedRecords(egressCheck: check, proxyErrors: [error]))

        let dns = try #require(journey.stages.compactMap { if case .dns(let dns) = $0 { dns } else { nil } }.first)
        #expect(dns.lookup == nil)
        #expect(dns.resolvedByProxy)
        #expect(dns.shownIP == RequestsJourney.ShownIP(ip: "43.175.21.9", source: .tidemarkLookup, age: -180))

        let rule = try #require(journey.stages.compactMap { if case .rule(let rule) = $0 { rule } else { nil } }.first)
        #expect(rule.decision == .global(policy: "AI"))

        let route = try #require(journey.stages.compactMap { if case .route(let route) = $0 { route } else { nil } }.first)
        #expect(route.hops == [
            .entry(.httpProxy), .group("AI"), .node("AT&T-RackNerd-Hysteria2", type: nil), .proxyServer("23.254.139.175", geo: nil),
            .destination("collect.moomoo.com:443", address: nil),
        ])

        guard case .end(let end) = journey.stages.last else {
            Issue.record("no end stage")
            return
        }
        #expect(end.reason == "TCP error: Connection reset")
        #expect(end.isError)
        #expect(end.state == .completed)
        #expect(end.proxyError == error)
    }

    @Test func aDirectIPLiteralNeedsNoDNS() {
        let record = F.record(
            host: "183.3.226.35", started: "09:00:00.000000", setup: "09:00:00.020000", completed: nil,
            notes: [
                "09:00:00.000000 [Connection] Handled by VIF",
                "09:00:00.001000 [Rule] Rule matched: IP-CIDR,183.3.0.0/16",
                "09:00:00.001100 [Rule] Policy decision path: DIRECT",
            ],
            policy: ["DIRECT"], remoteIP: "183.3.226.35", remoteAddress: "183.3.226.35"
        )
        let journey = RequestsJourney(record: record)
        #expect(!journey.stages.contains { if case .dns = $0 { true } else { false } })
        // Still open: no end yet.
        #expect(!journey.stages.contains { if case .end = $0 { true } else { false } })
        let route = journey.stages.compactMap { if case .route(let route) = $0 { route } else { nil } }.first
        #expect(route?.hops == [.entry(.virtualInterface(udp: false)), .direct, .destination("183.3.226.35:443", address: nil)])
    }

    @Test func aDirectDomainShowsTheAddressSurgeConnectedTo() {
        var record = F.record(
            host: "res.wx.qq.com", started: "09:00:00.000000", setup: "09:00:00.020000", completed: "09:00:01.000000",
            notes: ["09:00:00.001100 [Rule] Policy decision path: DIRECT", "09:00:01.000000 [Connection] Disconnect: Broken pipe (POSIX:32)"],
            policy: ["DIRECT"], remoteIP: "58.251.111.103", remoteAddress: "58.251.111.103"
        )
        record.remoteIPSource = .surge
        let journey = RequestsJourney(record: record)
        let route = journey.stages.compactMap { if case .route(let route) = $0 { route } else { nil } }.first
        #expect(route?.hops.last == .destination("res.wx.qq.com:443", address: "58.251.111.103"))
        let dns = journey.stages.compactMap { if case .dns(let dns) = $0 { dns } else { nil } }.first
        #expect(dns?.resolvedByProxy == false)
        #expect(dns?.shownIP?.source == .surge)
        guard case .end(let end) = journey.stages.last else {
            Issue.record("no end stage")
            return
        }
        #expect(end.isError)
    }

    @Test func aRejectGoesNowhere() {
        let record = F.record(host: "ads.example.com", started: "09:00:00.000000", setup: nil, completed: "09:00:00.001000",
                              notes: [], policy: ["REJECT"], remoteAddress: nil, rule: "DOMAIN-SUFFIX,example.com")
        let route = RequestsJourney(record: record).stages.compactMap { if case .route(let route) = $0 { route } else { nil } }.first
        #expect(route?.hops == [.reject("REJECT")])
    }

    @Test func readsAnEntryFromTheNotesWhenTheRecordLacksIt() {
        let udp = F.record(host: "time.apple.com", started: "09:00:00.000000", setup: nil, completed: nil,
                           notes: ["09:00:00.000000 [UDP] Init packet: 198.18.0.1:52000 -> 198.18.0.20:123"], policy: ["DIRECT"], remoteAddress: nil)
        #expect(RequestsJourney(record: udp).stages.first == .entered(RequestsJourney.Entered(entry: .virtualInterface(udp: true), sni: nil)))
    }

    @Test func formatsOffsets() {
        #expect(RequestsJourney.offsetLabel(0) == "+0 ms")
        #expect(RequestsJourney.offsetLabel(0.000_828) == "+0.8 ms")
        #expect(RequestsJourney.offsetLabel(0.318_4) == "+318 ms")
        #expect(RequestsJourney.offsetLabel(4.213) == "+4.21 s")
        #expect(RequestsJourney.offsetLabel(65) == "+65.0 s")
    }

    @Test func shortensDNSOverHTTPSServers() {
        #expect(RequestsJourney.serverLabel("https://cloudflare-dns.com/dns-query") == "cloudflare-dns.com")
        #expect(RequestsJourney.serverLabel("223.5.5.5") == "223.5.5.5")
    }

    @Test func sortsEndReasons() {
        #expect(RequestsJourney.EndKind("Closed by remote") == .closedByRemote)
        #expect(RequestsJourney.EndKind("Closed by client") == .closedByClient)
        #expect(RequestsJourney.EndKind("Connection closed") == .closed)
        #expect(RequestsJourney.EndKind("Closed for inactivity") == .idle)
        #expect(RequestsJourney.EndKind("TCP error: Connection reset") == .reset)
        #expect(RequestsJourney.EndKind("Broken pipe (POSIX:32)") == .brokenPipe)
        #expect(RequestsJourney.EndKind("ICMP closed") == .unreachable)
        #expect(RequestsJourney.EndKind("Something new") == .other("Something new"))
    }

    @Test func listsOnlyNodesTypes() {
        let groups = [
            SurgePolicyGroup(name: "AI", options: [
                SurgePolicyOption(name: "AT&T-RackNerd-Hysteria2", typeDescription: "Hysteria 2", isGroup: false),
                SurgePolicyOption(name: "Select", typeDescription: "Manual Selection Group", isGroup: true),
            ]),
        ]
        #expect(RequestsNodeTypes.nodeTypes(in: groups) == ["AT&T-RackNerd-Hysteria2": "Hysteria 2"])
    }
}

@MainActor
struct RequestsJourneyLabelTests {
    private func withLanguage(_ language: String, _ body: () -> Void) {
        let saved = Localizer.shared.override
        Localizer.shared.override = language
        body()
        Localizer.shared.override = saved
    }

    @Test func namesEveryRemoteIPSource() {
        withLanguage("en") {
            #expect(RemoteIPSource.allCases.map(RequestsJourneyLabels.source) == [
                "The host is this IP address", "Address Surge connected to", "Address Surge matched rules on",
                "Looked up by Tidemark", "From Surge's cache",
            ])
            #expect(RequestsJourneyLabels.shownIPDetail(.init(ip: "1.2.3.4", source: .tidemarkLookup, age: -180)) == "Looked up by Tidemark, 3 min before the request")
            #expect(RequestsJourneyLabels.shownIPDetail(.init(ip: "1.2.3.4", source: .surgeCache, age: 0.2)) == "From Surge's cache, as the request started")
            // Resolved during the request: its time adds nothing.
            #expect(RequestsJourneyLabels.shownIPDetail(.init(ip: "1.2.3.4", source: .ruleDNS, age: 0.3)) == "Address Surge matched rules on")
            #expect(RequestsJourneyLabels.shownIPDetail(.init(ip: "1.2.3.4", source: nil, age: nil)) == nil)
        }
        withLanguage("zh-Hans") {
            guard Localizer.shared.bundle != nil else { return }
            for source in RemoteIPSource.allCases {
                #expect(RequestsJourneyLabels.source(source).unicodeScalars.contains { $0.value >= 0x4E00 }, "\(source)")
            }
            #expect(RequestsJourneyLabels.shownIPDetail(.init(ip: "1.2.3.4", source: .tidemarkLookup, age: -180)) == "由 Tidemark 查询，请求前 3 分钟")
        }
    }

    @Test func namesEveryEndReason() {
        let reasons = ["Closed by remote", "Closed by client", "Connection closed", "Closed for inactivity", "TCP error: Connection reset",
                       "Broken pipe (POSIX:32)", "ICMP closed", "Something new"]
        withLanguage("en") {
            #expect(reasons.map(RequestsJourneyLabels.endReason) == [
                "Closed by the server", "Closed by the app", "Connection closed", "Closed after a while without traffic", "Connection reset",
                "Broken pipe", "Destination unreachable (ICMP)", "Something new",
            ])
        }
        withLanguage("zh-Hans") {
            guard Localizer.shared.bundle != nil else { return }
            #expect(RequestsJourneyLabels.endReason("TCP error: Connection reset") == "连接被重置")
            // Wording Tidemark does not know stays Surge's.
            #expect(RequestsJourneyLabels.endReason("Something new") == "Something new")
        }
    }

    @Test func spellsSpansOfTime() {
        withLanguage("en") {
            #expect(RequestsJourneyLabels.relative(-180) == "3 min before the request")
            #expect(RequestsJourneyLabels.relative(0.4) == "as the request started")
            #expect(RequestsJourneyLabels.relative(45) == "45 s after the request started")
            #expect(RequestsJourneyLabels.duration(0.42) == "0.42 s")
            #expect(RequestsJourneyLabels.duration(7200) == "2 h")
            #expect(RequestsJourneyLabels.duration(3 * 86400) == "3 d")
        }
    }
}
