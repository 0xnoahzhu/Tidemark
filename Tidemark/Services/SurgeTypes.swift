import Foundation

// Wire types for `surge-cli --raw` JSON. Field names mirror Surge's controller protocol (v25, Surge Mac 6.10).

/// A request record as emitted by `dump recent|active` and by the `request` / `request-update` watch events.
///
/// The first `request` event arrives when the connection is created, before policy, notes and byte counts
/// are known; `request-update` events carry the same shape with more fields filled in.
struct SurgeRequest: Decodable, Sendable, Hashable {
    var id: Int64
    var remoteHost: String?
    var url: String?
    var method: String?
    var status: String?
    var processPath: String?
    var pathForStatistics: String?
    var pid: Int32?
    var policyName: String?
    var originalPolicyName: String?
    /// The matched rule as Surge reports it, e.g. `DOMAIN-SET proxy.list` (absent in global-proxy mode).
    var rule: String?
    /// Per-phase timings, e.g. `[{"name":"Rule Evaluating","duration":0.0053,"durationInMillisecond":5}]`.
    var timingRecords: [SurgeTimingRecord]?
    var remoteAddress: String?
    var localAddress: String?
    var sourceAddress: String?
    var sourcePort: Int?
    var interface: String?
    var deviceName: String?
    var notes: [String]?
    var inBytes: Int64?
    var outBytes: Int64?
    var inCurrentSpeed: Int64?
    var outCurrentSpeed: Int64?
    var inMaxSpeed: Int64?
    var outMaxSpeed: Int64?
    /// Seconds since 1970.
    var startDate: Double?
    var setupCompletedDate: Double?
    var completedDate: Double?
    var completed: Bool?
    var failed: Bool?
    var rejected: Bool?
    var modified: Bool?
    var replica: Bool?
    var local: Bool?
    var takeoverMode: Int?
    var engineIdentifier: Int?

    enum CodingKeys: String, CodingKey {
        case id, remoteHost, method, status, processPath, pathForStatistics, pid, policyName, originalPolicyName
        case rule, timingRecords
        case remoteAddress, localAddress, sourceAddress, sourcePort, interface, deviceName, notes
        case inBytes, outBytes, inCurrentSpeed, outCurrentSpeed, inMaxSpeed, outMaxSpeed
        case startDate, setupCompletedDate, completedDate, completed, failed, rejected, modified, replica, local
        case takeoverMode, engineIdentifier
        case url = "URL"
    }
}

/// One timed phase of a request as recorded by Surge.
struct SurgeTimingRecord: Decodable, Sendable, Hashable {
    var name: String
    /// Seconds.
    var duration: Double
    var durationInMillisecond: Int?
}

/// `real-time-speed` watch event: bytes per second, plus a 20-sample history.
struct SurgeSpeed: Decodable, Sendable, Hashable {
    var `in`: Int64
    var out: Int64
    var downloadSpeedHistory: [Int64]?
    var uploadSpeedHistory: [Int64]?
}

/// `surge-cli --raw status`
struct SurgeStatus: Decodable, Sendable, Hashable {
    var version: String?
    var build: String?
    var profile: String?
    var mode: String?
    var globalPolicy: String?
    var deviceName: String?
    var deviceIdentifier: String?
    var controllerProtocol: Int?
    /// Engine start time, seconds since 1970. Used as the request-ID session key.
    var startTime: Double?
    var uptime: Double?
    var features: [String: Bool]?

    enum CodingKeys: String, CodingKey {
        case version, build, profile, mode, features, uptime
        case globalPolicy = "global-policy"
        case deviceName = "device-name"
        case deviceIdentifier = "device-identifier"
        case controllerProtocol = "controller-protocol"
        case startTime = "start-time"
    }
}

/// One policy option inside a policy group (`policy-group list|get`).
struct SurgePolicyOption: Decodable, Sendable, Hashable {
    var name: String
    var typeDescription: String?
    /// `POLICY::<md5>`; accepted by `test-policy`, `test-policy-external-ip` and `proxy-runtime-status`
    /// even when the plain name (from a policy-path subscription) is not.
    var lineHash: String?
    var enabled: Bool?
    var isGroup: Bool?
}

/// A policy group and its current selection.
struct SurgePolicyGroup: Sendable, Hashable {
    var name: String
    /// `Manual Selection Group`, `URL Test Group`, … (tells an auto-test pick from a manual switch).
    var type: String? = nil
    var options: [SurgePolicyOption]
    /// Currently selected option, if known (from `environment` → `ProxyGroupSelection`).
    var selected: String?
}

/// `surge-cli --raw environment` (subset).
struct SurgeEnvironment: Sendable, Hashable {
    /// 0 = Direct, 1 = Global Proxy, 2 = Rule.
    var proxyMode: Int?
    var globalPolicy: String?
    var groupSelections: [String: String]
}

/// `surge-cli --raw dns lookup <domain>`
struct SurgeDNSLookup: Decodable, Sendable, Hashable {
    var domain: String?
    var server: String?
    var path: String?
    var v4Addresses: [String]?
    var v6Addresses: [String]?
    var durationMs: Double?
    var expiresIn: Double?

    enum CodingKeys: String, CodingKey {
        case domain, server, path, v4Addresses, v6Addresses
        case durationMs = "duration-ms"
        case expiresIn = "expires-in"
    }

    var addresses: [String] { (v4Addresses ?? []) + (v6Addresses ?? []) }
}

/// `dns` watch event: a resolution Surge's DNS just made, e.g. `{"data":["104.26.8.187","172.67.75.219"],
/// "interface":"","domain":"proxycheck.io","server":"https://cloudflare-dns.com/dns-query"}`. No request ID: Surge
/// resolves a domain once for every request that needs it while the answer lasts.
struct SurgeDNSEvent: Decodable, Sendable, Hashable {
    var domain: String
    var server: String?
    var interface: String?
    var data: [String]?

    /// The answer's IP addresses, in Surge's order.
    var addresses: [String] { (data ?? []).filter(HostName.isIPAddress) }
}

/// One entry of `surge-cli --raw dump dns`: an answer in Surge's DNS cache (`dnsCache`), or a static mapping of its
/// profile (`local`). Surge keeps expired answers listed for hours, so `expires` decides whether one still holds.
struct SurgeDNSRecord: Sendable, Hashable {
    /// Lowercased, without a trailing dot.
    var domain: String
    /// IP addresses only (a static mapping may name another host instead, and then has none).
    var addresses: [String]
    /// e.g. `https://cloudflare-dns.com/dns-query`
    var server: String? = nil
    var interface: String? = nil
    /// The CNAME chain, e.g. `www.qualcomm.cn -> www.qualcomm.cn.cdn.cloudflare.net -> 172.64.144.37, 104.18.43.219`.
    var path: String? = nil
    /// e.g. `160.59ms Receive an A answer from https://cloudflare-dns.com/dns-query`
    var logs: [String] = []
    /// Seconds the lookup took (`timeCost`).
    var timeCost: Double? = nil
    /// When the answer expires (`expiresTime`); nil for a static mapping, which never does, and for a cached answer
    /// Surge gave no usable expiry, which Tidemark never uses (it looks the host up instead).
    var expires: Date? = nil
    /// A static mapping of the profile, not a lookup.
    var isLocal = false
}

/// `surge-cli --raw proxy-runtime-status <policy>` (subset): a proxy node's type and the last errors it reported
/// (Surge keeps 15).
struct SurgeProxyRuntimeStatus: Sendable, Hashable {
    struct ProxyError: Sendable, Hashable {
        /// e.g. `Stream closed`
        var message: String
        var time: Date
        /// Host name or IP the failed connection was for.
        var targetHost: String
    }

    /// e.g. `Hysteria 2`
    var type: String?
    var errors: [ProxyError]
}

/// `surge-cli --raw geoip <ip>`
struct SurgeGeoIP: Decodable, Sendable, Hashable {
    var address: String?
    var country: String?
    var asn: Int?
    var organization: String?
}

/// `surge-cli --raw http probe <url> [policy]`
struct SurgeHTTPProbe: Decodable, Sendable, Hashable {
    struct Header: Decodable, Sendable, Hashable { var name: String; var value: String }
    var method: String?
    var status: Int?
    var durationMs: Double?
    var policy: String?
    var rule: String?
    var url: String?
    var headers: [Header]?

    enum CodingKeys: String, CodingKey {
        case method, status, policy, rule, url, headers
        case durationMs = "duration-ms"
    }
}

/// `surge-cli --raw rule match <host>`
struct SurgeRuleMatch: Decodable, Sendable, Hashable {
    var policy: String?
    var rule: String?
}

/// Events delivered by `surge-cli --raw watch request request-update real-time-speed dns …`.
enum SurgeEvent: Sendable {
    /// `{"result":"Event subscribed"}`
    case subscribed
    /// A new request or an update of a known one (same shape; distinguish by ID).
    case request(SurgeRequest)
    case speed(SurgeSpeed)
    /// Surge's DNS resolved a domain.
    case dns(SurgeDNSEvent)
    /// The outbound mode, a policy-group selection or another environment key changed.
    case environmentChanged
    /// The profile was reloaded.
    case reload
    /// Surge is shutting down; the stream will end.
    case shutdown
    /// Any other line, kept for diagnostics.
    case other(String)
}

/// Errors surfaced by the Surge client.
enum SurgeError: Error, Sendable, Equatable, LocalizedError {
    case cliNotFound(path: String)
    case commandFailed(command: String, message: String)
    case decoding(command: String, message: String)
    case timedOut(command: String)

    /// English, and stable: the egress monitor stores it in `egress_checks.error`, where other Macs and later
    /// versions read it (`EgressFormat.error`), so the wording must not change. The UI describes these errors
    /// in its own language (`CaptureEngine.message(for:)`, `ProbeController.listenerFailure`).
    var errorDescription: String? {
        switch self {
        case .cliNotFound(let path): "surge-cli was not found at \(path)."
        case .commandFailed(let command, let message): "surge-cli \(command) failed: \(message)"
        case .decoding(let command, let message): "Could not read the output of surge-cli \(command): \(message)"
        case .timedOut(let command): "surge-cli \(command) timed out."
        }
    }

    /// The exit status in a `commandFailed` message when surge-cli printed no reason of its own
    /// (`SurgeOutputParser.failureMessage` then reports `exit status N`, which the UI words in its own
    /// language); nil for a message surge-cli wrote.
    static func exitStatus(inFailureMessage message: String) -> Int32? {
        message.wholeMatch(of: /exit status (-?\d+)/).flatMap { Int32($0.1) }
    }
}
