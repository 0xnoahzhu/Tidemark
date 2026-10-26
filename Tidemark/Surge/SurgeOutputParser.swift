import Foundation

/// Everything a finished surge-cli invocation printed.
struct SurgeCommandOutput: Sendable, Hashable {
    var exitStatus: Int32
    var stdout: Data
    var stderr: Data
}

/// Turns `surge-cli --raw` output into Surge wire types. Pure functions, so fixtures can drive them in tests.
///
/// Shapes were verified against Surge Mac 6.10 (controller protocol 25). surge-cli reports failures as
/// `Error: <message>` on standard error with exit status 1; a JSON `{"error": …}` object is handled too.
enum SurgeOutputParser {
    // MARK: - Errors

    /// Returns the JSON payload of a finished command, or throws the failure surge-cli reported.
    static func payload(of output: SurgeCommandOutput, command: String) throws(SurgeError) -> Data {
        if output.exitStatus != 0 {
            throw .commandFailed(command: command, message: failureMessage(stderr: output.stderr, stdout: output.stdout, status: output.exitStatus))
        }
        let head = String(decoding: output.stdout.prefix(512), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if head.hasPrefix("Error:") {
            throw .commandFailed(command: command, message: failureMessage(stderr: Data(), stdout: output.stdout, status: output.exitStatus))
        }
        // Error objects are tiny; skip the extra parse for large payloads such as `dump recent`.
        if head.hasPrefix("{"), output.stdout.count < 4096,
           let probe = try? JSONDecoder().decode(ErrorProbe.self, from: output.stdout),
           let error = probe.error, error != .null {
            throw .commandFailed(command: command, message: error.stringValue ?? error["message"]?.stringValue ?? "\(error)")
        }
        if head.isEmpty {
            throw .decoding(command: command, message: "surge-cli printed nothing.")
        }
        return output.stdout
    }

    /// Readable failure text: standard error (or output) without the `Error:` prefix, else the exit status.
    static func failureMessage(stderr: Data, stdout: Data, status: Int32) -> String {
        for data in [stderr, stdout] {
            var text = String(decoding: data.suffix(4096), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if text.hasPrefix("Error:") { text = String(text.dropFirst("Error:".count)).trimmingCharacters(in: .whitespaces) }
            if !text.isEmpty { return text }
        }
        return "exit status \(status)"
    }

    static func decode<T: Decodable>(_ type: T.Type, from data: Data, command: String) throws(SurgeError) -> T {
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw .decoding(command: command, message: describe(error))
        }
    }

    /// Compact description of a decoding failure (the coding path and the reason).
    static func describe(_ error: any Error) -> String {
        guard let error = error as? DecodingError else { return error.localizedDescription }
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? $0.stringValue }
            return keys.isEmpty ? "top level" : keys.joined(separator: ".")
        }
        switch error {
        case .keyNotFound(let key, let context): return "missing \"\(key.stringValue)\" at \(path(context))"
        case .typeMismatch(let type, let context): return "expected \(type) at \(path(context))"
        case .valueNotFound(let type, let context): return "missing \(type) value at \(path(context))"
        case .dataCorrupted(let context): return "\(context.debugDescription) (\(path(context)))"
        @unknown default: return error.localizedDescription
        }
    }

    // MARK: - Requests

    /// `dump recent` / `dump active` → `{"requests":[…]}`. Records that fail to decode are skipped.
    static func requests(from data: Data, command: String) throws(SurgeError) -> [SurgeRequest] {
        try requestListing(from: data, command: command).requests
    }

    /// `requests(from:command:)`, also counting the records that were skipped.
    static func requestListing(from data: Data, command: String) throws(SurgeError) -> SurgeRequestListing {
        let list = try decode(RequestList.self, from: data, command: command)
        let requests = list.requests.compactMap(\.value).map(normalized)
        return SurgeRequestListing(requests: requests, undecodable: list.requests.count - requests.count)
    }

    /// Surge reports "not yet" as `0` (`completedDate`, `setupCompletedDate`) and has no PID for requests
    /// from other devices; both become nil so that consumers never see 1970 dates or PID 0.
    static func normalized(_ request: SurgeRequest) -> SurgeRequest {
        var request = request
        if let date = request.startDate, date <= 0 { request.startDate = nil }
        if let date = request.setupCompletedDate, date <= 0 { request.setupCompletedDate = nil }
        if let date = request.completedDate, date <= 0 { request.completedDate = nil }
        if let pid = request.pid, pid <= 0 { request.pid = nil }
        return request
    }

    // MARK: - Environment

    /// `environment` → `{"result":"success","environment":{"ProxyMode":1,"AllProxyModePolicyNameKey":"AI",
    /// "ProxyGroupSelection":{"AI":"…"},…}}`. Values may be strings, numbers or booleans.
    static func environment(from data: Data, command: String) throws(SurgeError) -> SurgeEnvironment {
        let root = try decode(SurgeJSONValue.self, from: data, command: command)
        guard let environment = root["environment"]?.objectValue ?? root.objectValue else {
            throw .decoding(command: command, message: "expected an object")
        }
        let globalPolicy = environment["AllProxyModePolicyNameKey"]?.stringValue
        return SurgeEnvironment(
            proxyMode: environment["ProxyMode"]?.intValue,
            globalPolicy: globalPolicy?.isEmpty == false ? globalPolicy : nil,
            groupSelections: environment["ProxyGroupSelection"]?.objectValue?.compactMapValues(\.stringValue) ?? [:]
        )
    }

    // MARK: - DNS

    /// `dump dns` → `{"dnsCache":[{"domain":…,"server":…,"interface":"","data":["1.2.3.4"],"logs":[…],"path":…,
    /// "timeCost":0.16,"expiresTime":1793009456.27}…],"local":[{"domain":…,"data":"1.2.3.4"}…]}`: the cached answers,
    /// then the static mappings. Domains are lowercased; only IP addresses are kept (local mappings may point at
    /// other names), and entries without one are skipped.
    static func dnsCache(from data: Data, command: String) throws(SurgeError) -> [SurgeDNSRecord] {
        let dump = try decode(DNSDump.self, from: data, command: command)
        var records: [SurgeDNSRecord] = []
        for (entry, isLocal) in (dump.dnsCache ?? []).map({ ($0, false) }) + (dump.local ?? []).map({ ($0, true) }) {
            guard let domain = entry.domain.map(dnsDomain), !domain.isEmpty else { continue }
            var addresses: [String] = []
            for address in entry.data?.arrayValue?.compactMap(\.stringValue) ?? entry.data?.stringValue.map({ [$0] }) ?? []
            where HostName.isIPAddress(address) && !addresses.contains(address) {
                addresses.append(address)
            }
            guard !addresses.isEmpty else { continue }
            records.append(SurgeDNSRecord(
                domain: domain, addresses: addresses, server: nonEmpty(entry.server), interface: nonEmpty(entry.interface),
                path: nonEmpty(entry.path), logs: entry.logs ?? [], timeCost: entry.timeCost,
                expires: isLocal ? nil : entry.expiresTime.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil }, isLocal: isLocal
            ))
        }
        return records
    }

    /// A domain as Surge's DNS reports it, lowercased and without a trailing dot.
    static func dnsDomain(_ name: String) -> String {
        var domain = name.trimmingCharacters(in: .whitespaces).lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        return domain
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return value
    }

    // MARK: - Policies

    /// `policy-group list` → `{"groups":[{"name":"AI","type":"Manual Selection Group","selected":"…",
    /// "options":[{"name":…,"typeDescription":…,"lineHash":"POLICY::…","enabled":true,"isGroup":false}]}]}`.
    /// `selections` (from `environment`) fills in groups the list does not report a selection for. The group
    /// `type` is kept, so an automatic pick (URL test, fallback, smart) can be told apart from a manual switch.
    static func policyGroups(from data: Data, selections: [String: String] = [:], command: String) throws(SurgeError) -> [SurgePolicyGroup] {
        let list = try decode(GroupList.self, from: data, command: command)
        return list.groups.map { group in
            let type = group.type?.trimmingCharacters(in: .whitespaces)
            return SurgePolicyGroup(name: group.name, type: type?.isEmpty == false ? type : nil, options: group.options ?? [],
                                    selected: group.selected ?? selections[group.name])
        }
    }

    /// `dump rule` → `{"rules":["DOMAIN-SUFFIX,apple.com,DIRECT",…,"FINAL,Select,dns-failed"],…}`: the policy
    /// the last `FINAL` rule names, nil when there is none.
    static func finalRulePolicy(fromRules data: Data, command: String) throws(SurgeError) -> String? {
        let dump = try decode(RuleDump.self, from: data, command: command)
        for rule in (dump.rules ?? []).reversed() {
            let fields = rule.split(separator: ",", maxSplits: 2, omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 2, fields[0].uppercased() == "FINAL" else { continue }
            let policy = fields[1].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            return policy.isEmpty ? nil : policy
        }
        return nil
    }

    /// `test external-ip` / `test-policy-external-ip <policy>` → `{"address":"203.0.113.7"}`.
    static func externalIP(from data: Data, command: String) throws(SurgeError) -> String {
        let reply = try decode(AddressReply.self, from: data, command: command)
        guard let address = reply.address?.trimmingCharacters(in: .whitespaces), !address.isEmpty else {
            throw .decoding(command: command, message: "no address in the reply")
        }
        return address
    }

    /// `test-policy <policy>` → `{"<name>":{"tcp":138,"available":141,"receive":156,"round-one-total":309}}`,
    /// or `{}` when the policy does not exist or the test failed.
    ///
    /// `available` is the time to get a usable connection (0 when a pooled connection was reused), `receive`
    /// the HTTP round trip through the established tunnel, and `round-one-total` their sum plus overhead.
    /// `receive` is used because it measures the path itself and stays comparable whether or not the test
    /// had to open a new connection; `round-one-total` is the fallback when `receive` is missing.
    static func latency(from data: Data, command: String) throws(SurgeError) -> Int? {
        let root = try decode(SurgeJSONValue.self, from: data, command: command)
        guard let result = root.objectValue?.sorted(by: { $0.key < $1.key }).first?.value else { return nil }
        if let receive = result["receive"]?.intValue, receive > 0 { return receive }
        if let total = result["round-one-total"]?.intValue, total > 0 { return total }
        return nil
    }

    // MARK: - Network

    /// `summary` (sections of titled lines) plus `status` (outbound mode, enhanced mode) → `ThisMacNetwork`.
    static func network(summary data: Data, status: SurgeStatus?, command: String) throws(SurgeError) -> ThisMacNetwork {
        let summary = try decode(Summary.self, from: data, command: command)
        var network = ThisMacNetwork(dnsServers: [], surgeMode: surgeMode(for: status))
        var kind: String?
        var ssid: String?
        for line in (summary.sections ?? []).flatMap({ $0.lines ?? [] }) {
            let title = line.title?.lowercased() ?? ""
            guard let content = line.content?.trimmingCharacters(in: .whitespaces), !content.isEmpty, content != "N/A" else { continue }
            if title == "primary interface type" {
                kind = content
            } else if title == "primary ipv4 interface" {
                network.interface = content
            } else if title == "primary ipv4 address" {
                network.localIP = content
            } else if title == "default ipv4 router" || line.type == 1001 {
                network.router = content
            } else if title == "effective dns server" || line.type == 1002 {
                network.dnsServers = content.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            } else if title.contains("ssid") {
                ssid = content
            }
        }
        if let kind {
            network.interfaceDetail = ssid.map { "\(kind) “\($0)”" } ?? kind
        }
        return network
    }

    /// `Enhanced mode · rule-based`, `System proxy · global proxy`, `Direct`…
    /// The possible values are translated in the `SurgeCLI` string table.
    static func surgeMode(for status: SurgeStatus?) -> String? {
        guard let status else { return nil }
        let route: String? = switch status.mode?.lowercased() {
        case "rule"?: "rule-based"
        case "proxy"?, "global"?: "global proxy"
        case "direct"?: "direct"
        case nil, ""?: nil
        case let other?: other
        }
        let takeover: String? = if status.features?["enhanced-mode"] == true {
            "Enhanced mode"
        } else if status.features?["system-proxy"] == true {
            "System proxy"
        } else {
            nil
        }
        guard let takeover else { return route.map { $0.prefix(1).uppercased() + $0.dropFirst() } }
        return [takeover, route].compactMap { $0 }.joined(separator: " · ")
    }

    /// `dump event` → `{"events":[{"content":"HTTP proxy listen on interface: 0.0.0.0, port: 6152",…}]}`:
    /// the interface and port of the HTTP proxy listener, nil when Surge reports none (its HTTP proxy is off).
    static func httpProxyListener(fromEvents data: Data, command: String) throws(SurgeError) -> SurgeHTTPListener? {
        let dump = try decode(EventDump.self, from: data, command: command)
        for event in dump.events ?? [] {
            guard let content = event.content, content.localizedStandardContains("HTTP proxy listen"),
                  let match = content.firstMatch(of: #/port:\s*(\d+)/#), let port = Int(match.1), (1...65535).contains(port)
            else { continue }
            let interface = content.firstMatch(of: #/interface:\s*([^,\s]+)/#).map { String($0.1) } ?? "0.0.0.0"
            return SurgeHTTPListener(interface: interface, port: port)
        }
        return nil
    }

    /// Port of the HTTP proxy listener (see `httpProxyListener(fromEvents:command:)`).
    static func httpProxyPort(fromEvents data: Data, command: String) throws(SurgeError) -> Int? {
        try httpProxyListener(fromEvents: data, command: command)?.port
    }

    // MARK: - Wire shapes

    private struct ErrorProbe: Decodable {
        var error: SurgeJSONValue?
    }

    /// Decodes an element without failing the surrounding array.
    private struct Lossy<Value: Decodable>: Decodable {
        var value: Value?
        init(from decoder: any Decoder) throws {
            value = try? Value(from: decoder)
        }
    }

    private struct RequestList: Decodable {
        var requests: [Lossy<SurgeRequest>]
    }

    private struct DNSDump: Decodable {
        struct Entry: Decodable {
            var domain: String?
            var data: SurgeJSONValue?
            var server: String?
            var interface: String?
            var path: String?
            var logs: [String]?
            var timeCost: Double?
            var expiresTime: Double?

            enum CodingKeys: String, CodingKey {
                case domain, data, server, interface, path, logs, timeCost, expiresTime
            }

            /// A detail of an unexpected type is dropped rather than failing the whole dump.
            init(from decoder: any Decoder) throws {
                let container = try decoder.container(keyedBy: CodingKeys.self)
                domain = try container.decodeIfPresent(String.self, forKey: .domain)
                data = try container.decodeIfPresent(SurgeJSONValue.self, forKey: .data)
                server = try? container.decodeIfPresent(String.self, forKey: .server)
                interface = try? container.decodeIfPresent(String.self, forKey: .interface)
                path = try? container.decodeIfPresent(String.self, forKey: .path)
                logs = try? container.decodeIfPresent([String].self, forKey: .logs)
                timeCost = try? container.decodeIfPresent(Double.self, forKey: .timeCost)
                expiresTime = try? container.decodeIfPresent(Double.self, forKey: .expiresTime)
            }
        }
        var dnsCache: [Entry]?
        var local: [Entry]?
    }

    private struct GroupList: Decodable {
        struct Group: Decodable {
            var name: String
            var type: String?
            var selected: String?
            var options: [SurgePolicyOption]?
        }
        var groups: [Group]
    }

    private struct AddressReply: Decodable {
        var address: String?
    }

    private struct RuleDump: Decodable {
        var rules: [String]?
    }

    private struct Summary: Decodable {
        struct Section: Decodable {
            var section: String?
            var lines: [Line]?
        }
        struct Line: Decodable {
            var title: String?
            var content: String?
            var type: Int?
        }
        var sections: [Section]?
    }

    private struct EventDump: Decodable {
        struct Event: Decodable {
            var content: String?
            var identifier: String?
        }
        var events: [Event]?
    }
}
