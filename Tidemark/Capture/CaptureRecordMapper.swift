import Foundation

/// Turns Surge's request records into Tidemark rows.
///
/// Mapping is pure: attribution (`chain`, `appID`), resolved remote IPs, GeoIP data, `isNew` and the
/// database bookkeeping fields are filled in later by the capture pipeline.
enum CaptureRecordMapper {
    /// Maps one Surge request. `chain` is left empty; `bundlePath` comes from the process path or
    /// Surge's `pathForStatistics` until the pipeline resolves the process chain.
    static func record(from request: SurgeRequest, deviceID: DeviceID, session: Int64, now: Date = .now) -> RequestRecord {
        let (host, port) = hostAndPort(remoteHost: request.remoteHost, url: request.url)
        let notes = request.notes ?? []
        let policyPath = policyPath(notes: notes, policyName: request.policyName)
        let leaf = request.processPath.map { [ProcessLink(name: processName(for: $0), pid: request.pid ?? 0, path: $0, startTime: nil)] } ?? []
        return RequestRecord(
            key: RequestKey(deviceID: deviceID, session: session, surgeID: request.id),
            rowID: nil,
            startedAt: date(request.startDate) ?? now,
            setupCompletedAt: date(request.setupCompletedDate),
            completedAt: date(request.completedDate),
            method: nonEmpty(request.method)?.uppercased() ?? "TCP",
            host: host,
            port: port,
            url: nonEmpty(request.url),
            remoteIP: remoteIP(remoteAddress: request.remoteAddress, host: host),
            remoteAddress: nonEmpty(request.remoteAddress),
            geo: nil,
            policyPath: policyPath,
            rule: nonEmpty(request.rule) ?? rule(notes: notes, policyPath: policyPath),
            state: state(of: request),
            inBytes: request.inBytes ?? 0,
            outBytes: request.outBytes ?? 0,
            pid: request.pid,
            processPath: nonEmpty(request.processPath),
            bundlePath: bundlePath(chain: leaf, pathForStatistics: request.pathForStatistics),
            chain: [],
            appID: nil,
            localAddress: localAddress(request.localAddress, port: request.sourcePort),
            interface: nonEmpty(request.interface),
            notes: notes,
            isNew: false,
            writtenAt: nil,
            probeSessionID: nil
        )
    }

    // MARK: Fields

    /// Host (lowercased, without brackets) and port from `remoteHost`, falling back to the URL (plain HTTP
    /// requests report `remoteHost` without a port).
    static func hostAndPort(remoteHost: String?, url: String?) -> (host: String, port: Int?) {
        if let remoteHost = nonEmpty(remoteHost) {
            let (host, port) = HostName.splitHostPort(remoteHost)
            if !host.isEmpty {
                let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
                return (bare.lowercased(), port ?? (url.map { hostAndPort(remoteHost: nil, url: $0).port } ?? nil))
            }
        }
        guard let url = nonEmpty(url) else { return ("", nil) }
        if url.contains("://"), let components = URLComponents(string: url), let host = components.host, !host.isEmpty {
            let bare = host.hasPrefix("[") && host.hasSuffix("]") ? String(host.dropFirst().dropLast()) : host
            return (bare.lowercased(), components.port ?? defaultPort(scheme: components.scheme))
        }
        let authority = url.split(separator: "/", maxSplits: 1).first.map(String.init) ?? url
        let (host, port) = HostName.splitHostPort(authority)
        return (host.lowercased(), port)
    }

    /// Request state from Surge's flags, falling back to its status text.
    static func state(of request: SurgeRequest) -> RequestState {
        if request.rejected == true { return .rejected }
        if request.failed == true { return .failed }
        if request.completed == true { return .completed }
        switch request.status?.lowercased() {
        case "completed": return .completed
        case "failed": return .failed
        case "rejected": return .rejected
        default: return .active
        }
    }

    /// `["AI", "AT&T-RackNerd-Hysteria2"]` from `[Rule] Policy decision path: AI -> AT&T-RackNerd-Hysteria2`,
    /// otherwise the final policy name alone.
    static func policyPath(notes: [String], policyName: String?) -> [String] {
        for note in notes.reversed() {
            guard let text = ruleText(note), let range = text.range(of: "Policy decision path:") else { continue }
            var path = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            if path.hasPrefix("("), path.hasSuffix(")") { path = String(path.dropFirst().dropLast()) }
            let parts = path.components(separatedBy: "->").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            if !parts.isEmpty { return parts }
        }
        if let name = nonEmpty(policyName) { return [name] }
        return []
    }

    /// The matched rule (`DOMAIN-SUFFIX,cursor.sh`, `FINAL`), `Global · <policy>` in global-proxy mode,
    /// `Direct` in all-direct mode, or nil when the notes don't say.
    static func rule(notes: [String], policyPath: [String]) -> String? {
        var subRule: String?
        var outbound: String?
        for note in notes {
            guard let text = ruleText(note) else { continue }
            if let value = value(after: "Rule matched:", in: text), !text.hasPrefix("Sub-rule") {
                return cleanRule(value, policy: policyPath.first)
            }
            if subRule == nil, let value = value(after: "Sub-rule matched:", in: text) {
                subRule = cleanRule(value, policy: policyPath.first)
            }
            if let value = value(after: "Global proxy outbound mode:", in: text) {
                outbound = "Global · \(value)"
            } else if text.contains("All direct outbound mode") {
                outbound = "Direct"
            }
        }
        return subRule ?? outbound
    }

    /// The destination IP when Surge knows it: `remoteAddress` for direct connections (not `… (Proxy)`),
    /// else the host itself when it is an IP literal. Proxied hostnames are resolved later.
    static func remoteIP(remoteAddress: String?, host: String) -> String? {
        if let address = nonEmpty(remoteAddress)?.trimmingCharacters(in: .whitespaces), !address.hasSuffix("(Proxy)") {
            if HostName.isIPv4(address) { return address }
            // `1.2.3.4:443` / `[2001:db8::1]:443` (checked before bare IPv6, which also contains colons).
            let (ip, port) = HostName.splitHostPort(address)
            if port != nil, HostName.isIPAddress(ip) { return stripBrackets(ip) }
            if HostName.isIPAddress(address) { return stripBrackets(address) }
        }
        return HostName.isIPAddress(host) ? stripBrackets(host) : nil
    }

    /// `10.1.2.133:65374`, or `[fe80::1]:65374` for IPv6.
    static func localAddress(_ address: String?, port: Int?) -> String? {
        guard let address = nonEmpty(address) else { return nil }
        guard let port else { return address }
        return address.contains(":") ? "[\(address)]:\(port)" : "\(address):\(port)"
    }

    /// The top-most `.app` bundle in the chain (root first), else Surge's `pathForStatistics`, without a
    /// trailing slash.
    static func bundlePath(chain: [ProcessLink], pathForStatistics: String?) -> String? {
        for link in chain {
            if let path = link.path, let bundle = outermostBundle(in: path) { return bundle }
        }
        // Surge reports system daemons as the literal `SYSTEM`; only real paths are bundles.
        guard var path = nonEmpty(pathForStatistics), path.hasPrefix("/") else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// `/Applications/Cursor.app` from `/Applications/Cursor.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper`.
    static func outermostBundle(in path: String) -> String? {
        if let range = path.range(of: ".app/") { return String(path[..<range.lowerBound]) + ".app" }
        if path.hasSuffix(".app") { return path }
        return nil
    }

    /// Executable name from a path.
    static func processName(for path: String) -> String {
        let name = (path as NSString).lastPathComponent
        return name.isEmpty ? path : name
    }

    /// Surge reports unset dates as `0`.
    static func date(_ seconds: Double?) -> Date? {
        guard let seconds, seconds > 0 else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    // MARK: Helpers

    /// The text of a `[Rule]` note (`HH:mm:ss.ffffff [Rule] text`), or of an unparseable note that still
    /// mentions a rule decision.
    private static func ruleText(_ note: String) -> String? {
        if let parsed = RequestTiming.parse(note: note) {
            return parsed.tag.caseInsensitiveCompare("Rule") == .orderedSame ? parsed.text : nil
        }
        if let range = note.range(of: "[Rule]") { return note[range.upperBound...].trimmingCharacters(in: .whitespaces) }
        return nil
    }

    private static func value(after prefix: String, in text: String) -> String? {
        guard let range = text.range(of: prefix) else { return nil }
        let value = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// Drops a trailing `,<policy>` so `DOMAIN-SUFFIX,cursor.sh,AI` reads as `DOMAIN-SUFFIX,cursor.sh`.
    private static func cleanRule(_ rule: String, policy: String?) -> String {
        var parts = rule.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if parts.count >= 2, let policy, parts.last?.caseInsensitiveCompare(policy) == .orderedSame {
            parts.removeLast()
        }
        return parts.joined(separator: ",")
    }

    private static func defaultPort(scheme: String?) -> Int? {
        switch scheme?.lowercased() {
        case "http", "ws": 80
        case "https", "wss": 443
        default: nil
        }
    }

    private static func stripBrackets(_ s: String) -> String {
        s.hasPrefix("[") && s.hasSuffix("]") ? String(s.dropFirst().dropLast()) : s
    }

    private static func nonEmpty(_ s: String?) -> String? {
        guard let s, !s.isEmpty else { return nil }
        return s
    }
}
