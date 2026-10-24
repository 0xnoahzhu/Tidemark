import Foundation

/// Identifies one Surge request across restarts and Macs.
///
/// Surge request IDs restart whenever the engine restarts, so the engine start time
/// (`session`, milliseconds since 1970) is part of the key.
struct RequestKey: Hashable, Codable, Sendable {
    var deviceID: DeviceID
    var session: Int64
    var surgeID: Int64
}

enum RequestState: String, Codable, Sendable, CaseIterable {
    case active
    case completed
    case failed
    case rejected
}

/// A request as Tidemark stores and displays it (row in `requests`).
struct RequestRecord: Identifiable, Hashable, Codable, Sendable {
    var key: RequestKey
    /// Primary key in PostgreSQL once the row has been written.
    var rowID: Int64?

    var startedAt: Date
    var setupCompletedAt: Date?
    var completedAt: Date?

    /// Surge's method: `HTTPS`, `TCP`, `UDP`, or an HTTP verb such as `GET` / `POST`.
    var method: String
    /// Hostname (or IP literal) without the port.
    var host: String
    var port: Int?
    var url: String?

    /// Best known destination IP (Surge's remote address for DIRECT, otherwise a resolved address).
    var remoteIP: String?
    /// Raw `remoteAddress` from Surge, e.g. `23.254.139.175 (Proxy)`.
    var remoteAddress: String?
    var geo: GeoInfo?

    /// Policy decision path, e.g. `["AI", "AT&T-RackNerd-Hysteria2"]` or `["DIRECT"]`.
    var policyPath: [String]
    var rule: String?

    var state: RequestState
    var inBytes: Int64
    var outBytes: Int64

    var pid: Int32?
    var processPath: String?
    /// Top-most `.app` bundle in the process chain (or Surge's `pathForStatistics`).
    var bundlePath: String?
    /// Process ancestry, root → leaf; the leaf is the process that opened the connection.
    var chain: [ProcessLink]
    /// Monitored app the request rolled up to, if any.
    var appID: AppID?

    var localAddress: String?
    var interface: String?
    var notes: [String]

    /// First contact of the attributed app with this host or IP.
    var isNew: Bool
    var writtenAt: Date?
    var probeSessionID: UUID?

    var id: RequestKey { key }
    var deviceID: DeviceID { key.deviceID }

    /// Name of the process that sent the request (leaf of the chain).
    var processName: String {
        if let leaf = chain.last { return leaf.name }
        if let processPath { return URL(fileURLWithPath: processPath).lastPathComponent }
        return "Unknown"
    }

    var isIPLiteral: Bool { HostName.isIPAddress(host) }
    var totalBytes: Int64 { inBytes + outBytes }

    /// `AI › AT&T-RackNerd-Hysteria2`
    var policyDisplay: String { policyPath.isEmpty ? "—" : policyPath.joined(separator: " › ") }
    var finalPolicy: String? { policyPath.last }

    var duration: TimeInterval? {
        guard let end = completedAt else { return nil }
        return max(0, end.timeIntervalSince(startedAt))
    }

    var isTunnel: Bool { ["HTTPS", "TCP", "UDP", "CONNECT"].contains(method.uppercased()) }
}

/// Helpers for classifying host strings.
enum HostName {
    static func isIPv4(_ s: String) -> Bool {
        let parts = s.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { p in
            guard !p.isEmpty, p.count <= 3, p.allSatisfy(\.isNumber), let v = Int(p) else { return false }
            return v <= 255
        }
    }

    static func isIPAddress(_ s: String) -> Bool {
        if isIPv4(s) { return true }
        let bare = s.hasPrefix("[") && s.hasSuffix("]") ? String(s.dropFirst().dropLast()) : s
        return bare.contains(":") && bare.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." || $0 == "%" }
    }

    /// Splits `host:port` (also `[v6]:port`) into its parts.
    static func splitHostPort(_ s: String) -> (host: String, port: Int?) {
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            let host = String(s[s.index(after: s.startIndex)..<close])
            let rest = s[s.index(after: close)...]
            let port = rest.hasPrefix(":") ? Int(rest.dropFirst()) : nil
            return (host, port)
        }
        let colons = s.filter { $0 == ":" }.count
        if colons == 1, let idx = s.lastIndex(of: ":") {
            return (String(s[..<idx]), Int(s[s.index(after: idx)...]))
        }
        return (s, nil)
    }
}
