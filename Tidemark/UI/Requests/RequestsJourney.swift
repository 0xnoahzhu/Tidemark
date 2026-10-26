import Foundation

/// What happened to one request, in the order it happened, for the inspector's Journey: how it reached Surge, the DNS
/// it needed, the rule, the route out, the connection and how it ended.
///
/// Built from the record, whose notes stay the source of truth, and the records Tidemark joined to it by host and
/// time (`RequestRelatedRecords`). A stage is left out when nothing tells about it; offsets are seconds from the
/// request's start, nil when no note dates the stage.
struct RequestsJourney: Equatable {
    enum Stage: Equatable {
        case entered(Entered)
        case dns(DNS)
        case rule(Rule)
        case route(Route)
        case connection(Connection)
        case end(End)
    }

    /// How the request reached Surge.
    struct Entered: Equatable {
        var offset: TimeInterval? = 0
        var entry: RequestEntry?
        /// The server name of the client's TLS Client Hello, which Surge read.
        var sni: String?
    }

    /// The DNS the request needed.
    struct DNS: Equatable {
        enum Lookup: Equatable {
            /// Surge looked the host up for rule matching, in this many milliseconds when it said.
            case lookedUp(milliseconds: Double?)
            /// Surge took the answer from its cache.
            case cached
        }

        /// `A record count: 2, AAAA record count: 0` of Surge's note.
        struct RecordCounts: Equatable {
            var a: Int
            var aaaa: Int
        }

        var offset: TimeInterval?
        /// What Surge did for rule matching (rule mode).
        var lookup: Lookup?
        var recordCounts: RecordCounts?
        /// The address rule matching used, when it is not the remote IP shown.
        var matchedIP: String?
        /// Surge's answer for the host that held at the start: its server, CNAME path and addresses.
        var answer: DNSAnswer?
        /// The proxy resolved the host on its side, which this Mac never sees: a proxy policy always resolves remotely.
        var resolvedByProxy = false
        /// The remote IP the request shows and where it came from.
        var shownIP: ShownIP?

        /// The names between the host and its addresses in the answer's CNAME path.
        var cnames: [String] {
            guard let path = answer?.path else { return [] }
            let host = answer?.domain ?? ""
            return path.components(separatedBy: "->")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { name in
                    !name.isEmpty && name.caseInsensitiveCompare(host) != .orderedSame
                        && !name.split(separator: ",").allSatisfy { HostName.isIPAddress($0.trimmingCharacters(in: .whitespaces)) }
                }
        }
    }

    /// The remote IP a request shows, where it came from (`RemoteIPSource`) and when, from the request's start.
    struct ShownIP: Equatable {
        var ip: String
        var source: RemoteIPSource?
        /// Negative when it was resolved before the request started.
        var age: TimeInterval?
    }

    /// The routing decision.
    struct Rule: Equatable {
        enum Decision: Equatable {
            /// `RULE-SET claude.list`, `DOMAIN-SUFFIX,cursor.sh`, `FINAL`
            case matched(String)
            /// Global proxy mode sent it over this policy.
            case global(policy: String)
            /// All-direct mode.
            case allDirect
        }

        var offset: TimeInterval?
        var decision: Decision
        /// `IP-CIDR 172.64.0.0/13(in claude.list)`
        var subRule: String?
        /// The policy Surge picked before the final one, when they differ.
        var originalPolicy: String?
    }

    /// The hops Surge's record shows, from this Mac to the destination. Router-level hops are not in it.
    struct Route: Equatable {
        var offset: TimeInterval?
        var hops: [Hop]
    }

    enum Hop: Equatable {
        /// How it reached Surge (the virtual interface or the HTTP proxy).
        case entry(RequestEntry)
        /// A policy group on the decision path.
        case group(String)
        /// The proxy node it left through, with its type (`Hysteria 2`) when Surge's policy groups name it.
        case node(String, type: String?)
        case direct
        /// A reject policy (`REJECT`, `REJECT-TINYGIF`).
        case reject(String)
        /// The proxy server Surge connected to (`23.254.139.175 (Proxy)`), with what Tidemark knows of its network.
        case proxyServer(String, geo: GeoInfo?)
        /// The exit IP Tidemark's egress check saw for the same policy, and when, from the request's start.
        case exit(String, location: String?, age: TimeInterval)
        /// `host:port`; for a direct connection also the address Surge connected to.
        case destination(String, address: String?)
    }

    /// Whether Surge set up a connection for it or reused one.
    struct Connection: Equatable {
        var offset: TimeInterval?
        var reused: Bool
        /// `SGHysteriaMasterConnector-2`
        var connector: String?
    }

    /// How it ended.
    struct End: Equatable {
        var offset: TimeInterval?
        /// Surge's words (`TCP error: Connection reset`), nil when its notes do not say.
        var reason: String?
        var state: RequestState
        /// The error the proxy node reported for the host as the request ended.
        var proxyError: ProxyNodeError?
        var duration: TimeInterval?
        var inBytes: Int64
        var outBytes: Int64

        /// The connection ended with an error, whatever state Surge reported.
        var isError: Bool {
            state == .failed || state == .rejected || reason.map(RequestEndReason.isError) == true
        }
    }

    var stages: [Stage]

    /// The journey of `record`. `related` holds Tidemark's joined records (nil until they arrive); `nodeType` names the
    /// final policy's type and `proxyGeo` the proxy server's network, when known.
    init(record: RequestRecord, related: RequestRelatedRecords? = nil, nodeType: String? = nil, proxyGeo: GeoInfo? = nil) {
        let notes = Notes(record)
        var stages: [Stage] = []

        let entry = record.entry ?? notes.entry
        if entry != nil || notes.sni != nil {
            stages.append(.entered(Entered(entry: entry, sni: notes.sni)))
        }

        let dns = Self.dns(record, notes: notes, answer: related?.dnsAnswer)
        if let dns { stages.append(.dns(dns)) }

        // The stored rule first: capture cleaned it (`DOMAIN-SUFFIX,cursor.sh` without its policy).
        if let decision = Self.decision(fromRule: record.rule) ?? notes.decision {
            let rule = Rule(offset: notes.ruleOffset, decision: decision, subRule: notes.subRule, originalPolicy: record.originalPolicy)
            stages.append(.rule(rule))
        }

        let hops = Self.hops(record, entry: entry, related: related, nodeType: nodeType, proxyGeo: proxyGeo)
        if !hops.isEmpty {
            stages.append(.route(Route(offset: notes.decisionOffset, hops: hops)))
        }

        if let connection = notes.connection { stages.append(.connection(connection)) }

        if record.completedAt != nil || record.state == .failed || record.state == .rejected {
            stages.append(.end(End(
                offset: record.completedAt.map { max(0, $0.timeIntervalSince(record.startedAt)) },
                reason: record.endReason ?? CaptureRecordMapper.endReason(notes: record.notes),
                state: record.state,
                proxyError: related?.proxyErrors.first,
                duration: record.duration,
                inBytes: record.inBytes,
                outBytes: record.outBytes
            )))
        }
        self.stages = stages
    }

    // MARK: Stages

    /// Nil for an IP literal (nothing to resolve) and when nothing tells about the host's DNS.
    private static func dns(_ record: RequestRecord, notes: Notes, answer: DNSAnswer?) -> DNS? {
        guard !record.isIPLiteral else { return nil }
        var dns = DNS(offset: notes.dnsOffset, lookup: notes.lookup, recordCounts: notes.recordCounts, answer: answer)
        if case .lookedUp(nil) = dns.lookup, let duration = RequestTiming.dnsLookupDuration(of: record) {
            dns.lookup = .lookedUp(milliseconds: duration * 1000)
        }
        dns.resolvedByProxy = isProxied(record)
        if let ip = record.remoteIP, record.remoteIPSource != .literal {
            let age = record.remoteIPResolvedAt.map { $0.timeIntervalSince(record.startedAt) }
            dns.shownIP = ShownIP(ip: ip, source: record.remoteIPSource, age: age)
        }
        if let matched = notes.matchedIP, matched != dns.shownIP?.ip { dns.matchedIP = matched }
        guard dns.lookup != nil || dns.answer != nil || dns.resolvedByProxy || dns.shownIP != nil else { return nil }
        return dns
    }

    /// The decision a stored rule tells (`Global · AI`, `Direct`, else the matched rule).
    private static func decision(fromRule rule: String?) -> Rule.Decision? {
        guard let rule, !rule.isEmpty else { return nil }
        if rule.hasPrefix("Global · ") { return .global(policy: String(rule.dropFirst("Global · ".count))) }
        if rule == "Direct" { return .allDirect }
        return .matched(rule)
    }

    private static func hops(
        _ record: RequestRecord, entry: RequestEntry?, related: RequestRelatedRecords?, nodeType: String?, proxyGeo: GeoInfo?
    ) -> [Hop] {
        guard let final = record.finalPolicy else { return [] }
        var hops: [Hop] = entry.map { [.entry($0)] } ?? []
        hops += record.policyPath.dropLast().map(Hop.group)
        let upper = final.uppercased()
        if upper == "DIRECT" {
            hops.append(.direct)
        } else if upper.hasPrefix("REJECT") {
            // Nothing leaves this Mac.
            hops.append(.reject(final))
            return hops
        } else {
            hops.append(.node(final, type: nodeType))
            if let server = proxyServer(of: record) { hops.append(.proxyServer(server, geo: proxyGeo)) }
        }
        if let exit = exit(of: record, related: related) { hops.append(exit) }
        let port = record.port.map { ":\($0)" } ?? ""
        let host = record.host.contains(":") ? "[\(record.host)]" : record.host
        let address = upper == "DIRECT" && !record.isIPLiteral && record.remoteIPSource == .surge ? record.remoteIP : nil
        hops.append(.destination(host + port, address: address))
        return hops
    }

    /// The exit IP Tidemark saw for the request's own policy: the current egress check nearest its start, else the
    /// latest change of the current egress before it. Nil when the egress then went through another policy.
    private static func exit(of record: RequestRecord, related: RequestRelatedRecords?) -> Hop? {
        guard let final = record.finalPolicy else { return nil }
        if let check = related?.egressCheck, check.policyPath.last == final, let ip = check.ip, check.error == nil {
            return .exit(ip, location: check.location, age: check.checkedAt.timeIntervalSince(record.startedAt))
        }
        if let change = related?.egressChange, change.policyPath.last == final {
            return .exit(change.ip, location: nil, age: change.changedAt.timeIntervalSince(record.startedAt))
        }
        return nil
    }

    /// `23.254.139.175` from `23.254.139.175 (Proxy)`.
    static func proxyServer(of record: RequestRecord) -> String? {
        guard let address = record.remoteAddress?.trimmingCharacters(in: .whitespaces), address.hasSuffix("(Proxy)") else { return nil }
        let server = address.dropLast("(Proxy)".count).trimmingCharacters(in: .whitespaces)
        return server.isEmpty ? nil : server
    }

    /// The request left through a proxy: Surge reported a proxy address, or its final policy is neither DIRECT nor a
    /// reject.
    static func isProxied(_ record: RequestRecord) -> Bool {
        if proxyServer(of: record) != nil { return true }
        guard let final = record.finalPolicy?.uppercased(), !final.isEmpty else { return false }
        return final != "DIRECT" && !final.hasPrefix("REJECT")
    }
}

// MARK: - Notes

extension RequestsJourney {
    /// What a request's notes tell about its journey. Surge does not document its notes, so each fact is read
    /// defensively and a note in an unknown wording is left out.
    struct Notes {
        var entry: RequestEntry?
        var sni: String?
        var dnsOffset: TimeInterval?
        var lookup: DNS.Lookup?
        var recordCounts: DNS.RecordCounts?
        var matchedIP: String?
        var decision: Rule.Decision?
        var ruleOffset: TimeInterval?
        var subRule: String?
        var decisionOffset: TimeInterval?
        var connection: Connection?

        init(_ record: RequestRecord) {
            for raw in record.notes {
                guard let note = RequestTiming.parse(note: raw) else { continue }
                let offset = max(0, RequestTiming.date(of: note, near: record.startedAt).timeIntervalSince(record.startedAt))
                let text = note.text
                switch note.tag.lowercased() {
                case "connection":
                    if entry == nil, text.hasPrefix("Handled by VIF") {
                        entry = .virtualInterface(udp: false)
                    } else if entry == nil, text.hasPrefix("Incoming proxy protocol") {
                        entry = .httpProxy
                    }
                case "udp":
                    if entry == nil, text.hasPrefix("Init packet") { entry = .virtualInterface(udp: true) }
                case "tls":
                    if sni == nil, let value = Self.value(after: "SNI:", in: text) { sni = value }
                case "dns":
                    var began = offset
                    if text.hasPrefix("Use cached DNS result") {
                        lookup = .cached
                    } else if text.hasPrefix("DNS lookup") {
                        let milliseconds = RequestTiming.lookupMilliseconds(in: text)
                        lookup = .lookedUp(milliseconds: milliseconds)
                        // Noted as it completes: the lookup began its duration earlier.
                        began = max(0, offset - (milliseconds ?? 0) / 1000)
                    }
                    // The rule's note asking for the lookup dates the stage when there is one.
                    dnsOffset = dnsOffset ?? began
                    if let a = Self.count(of: "A record count:", in: text), let aaaa = Self.count(of: "AAAA record count:", in: text) {
                        recordCounts = DNS.RecordCounts(a: a, aaaa: aaaa)
                    }
                case "rule":
                    if text.hasPrefix("Rule evaluating requires DNS lookup") {
                        dnsOffset = dnsOffset ?? offset
                    } else if text.hasPrefix("DNS completed"), let match = CaptureRecordMapper.ruleDNSAddress(notes: [raw]) {
                        matchedIP = match.ip
                    } else if text.hasPrefix("Sub-rule matched:") {
                        subRule = subRule ?? Self.value(after: "Sub-rule matched:", in: text)
                    } else if text.hasPrefix("Rule matched:"), let rule = Self.value(after: "Rule matched:", in: text) {
                        decision = .matched(rule)
                        ruleOffset = offset
                    } else if let policy = Self.value(after: "Global proxy outbound mode:", in: text) {
                        decision = .global(policy: policy)
                        ruleOffset = offset
                    } else if text.contains("All direct outbound mode") {
                        decision = .allDirect
                        ruleOffset = offset
                    } else if text.hasPrefix("Policy decision path:") {
                        decisionOffset = offset
                    }
                case "connection-pool", "connector":
                    guard connection == nil else { continue }
                    let lowered = text.lowercased()
                    if lowered.hasPrefix("use an existing") {
                        // `Use an existing master connector: SGHysteriaMasterConnector-2`
                        let connector = Self.value(after: ":", in: text)
                        connection = Connection(offset: offset, reused: true, connector: connector)
                    } else if lowered.contains("new") || lowered.contains("create") {
                        connection = Connection(offset: offset, reused: false, connector: nil)
                    }
                default:
                    break
                }
            }
        }

        private static func value(after prefix: String, in text: String) -> String? {
            guard let range = text.range(of: prefix) else { return nil }
            let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }

        /// `2` from `A record count: 2, AAAA record count: 0` (`AAAA` is matched before `A`).
        private static func count(of label: String, in text: String) -> Int? {
            var searchRange = text.startIndex..<text.endIndex
            while let range = text.range(of: label, range: searchRange) {
                // `A record count:` also ends `AAAA record count:`.
                let isPartOfLonger = range.lowerBound > text.startIndex && text[text.index(before: range.lowerBound)].isLetter
                if !isPartOfLonger {
                    return Int(text[range.upperBound...].trimmingCharacters(in: .whitespaces).prefix { $0.isNumber })
                }
                searchRange = range.upperBound..<text.endIndex
            }
            return nil
        }
    }
}

// MARK: - Labels

extension RequestsJourney {
    /// How an end reason reads: Surge's wording sorted into the endings Tidemark names.
    enum EndKind: Equatable {
        case closedByRemote
        case closedByClient
        case closed
        case idle
        case reset
        case brokenPipe
        case unreachable
        /// Wording Tidemark does not know: shown as Surge wrote it.
        case other(String)

        init(_ reason: String) {
            let lowered = reason.lowercased()
            switch reason {
            case "Closed by remote": self = .closedByRemote
            case "Closed by client": self = .closedByClient
            case "Connection closed": self = .closed
            case "Closed for inactivity": self = .idle
            case _ where lowered.contains("connection reset"): self = .reset
            case _ where lowered.contains("broken pipe"): self = .brokenPipe
            case _ where lowered.contains("icmp"): self = .unreachable
            default: self = .other(reason)
            }
        }
    }

    /// `+0 ms`, `+0.8 ms`, `+318 ms`, `+4.21 s`: a stage's time from the request's start.
    static func offsetLabel(_ seconds: TimeInterval) -> String {
        let milliseconds = max(0, seconds) * 1000
        if milliseconds < 0.05 { return "+0 ms" }
        if milliseconds < 10 { return String(format: "+%.1f ms", milliseconds) }
        if milliseconds < 1000 { return String(format: "+%.0f ms", milliseconds) }
        if milliseconds < 10_000 { return String(format: "+%.2f s", milliseconds / 1000) }
        return String(format: "+%.1f s", milliseconds / 1000)
    }

    /// `cloudflare-dns.com` from a DNS-over-HTTPS server URL; a plain server address as it is.
    static func serverLabel(_ server: String) -> String {
        guard server.contains("://"), let host = URLComponents(string: server)?.host, !host.isEmpty else { return server }
        return host
    }
}
