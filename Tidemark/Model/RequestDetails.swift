import Foundation

// What Tidemark records about how a request went (schema v4): Surge's timings, entry path and end reason, where
// the remote IP came from, the DNS answers Surge's resolver gave and the errors its proxy nodes reported. Surge
// keeps only its last ~200 finished requests, so all of it is recorded as it happens.

/// One phase Surge timed for a request (`timingRecords`), e.g. `DNS Lookup` or `Rule Evaluating`.
struct RequestTimingRecord: Hashable, Codable, Sendable {
    var name: String
    /// Seconds.
    var duration: Double
}

/// How a request reached Surge (`takeoverMode`, `requests.entry_mode`).
enum RequestEntry: Hashable, Sendable {
    /// Surge's HTTP proxy listener (apps using the system proxy, the site probe).
    case httpProxy
    /// Surge's virtual interface (enhanced mode).
    case virtualInterface(udp: Bool)
    /// A mode Tidemark does not know.
    case other(Int)

    init(mode: Int) {
        switch mode {
        case 1: self = .httpProxy
        case 20: self = .virtualInterface(udp: true)
        case 40: self = .virtualInterface(udp: false)
        default: self = .other(mode)
        }
    }
}

/// Why a connection ended (`RequestRecord.endReason`, `requests.end_reason`): Surge's wording in its last
/// `Disconnect:` note (`Closed by remote`, `TCP error: Connection reset`, `Broken pipe (POSIX:32)`), or the UDP
/// close note (`Closed for inactivity`, `ICMP closed`), without a trailing period.
///
/// Surge marks resets and broken pipes completed, not failed, so the end reason is the only place they show.
/// It is parsed defensively and never replaces the notes, which stay the source of truth.
enum RequestEndReason {
    /// Endings that are no error: either side closed the connection, or a UDP flow went idle. Everything else
    /// counts as an error, including `ICMP closed` (the destination was unreachable) and wording Tidemark does
    /// not know yet.
    static let normal: Set<String> = ["Closed by remote", "Closed by client", "Connection closed", "Closed for inactivity"]

    static func isError(_ reason: String) -> Bool { !normal.contains(reason) }
}

/// Where a request's `remoteIP` came from (`requests.remote_ip_source`). Only `literal` and `surge` name the
/// address the connection really used; for a proxied request the proxy resolves the host again on its side, out
/// of sight, so the other sources are Tidemark's best guess.
enum RemoteIPSource: String, Codable, Sendable, CaseIterable {
    /// The host is an IP address.
    case literal
    /// Surge's remote address of a connection it made itself (DIRECT).
    case surge
    /// The address Surge resolved to match IP rules (`[Rule] DNS completed, IPv4 address for matching: …`).
    case ruleDNS = "rule-dns"
    /// Tidemark's own `dns lookup` through Surge.
    case tidemarkLookup = "tidemark-lookup"
    /// An entry of Surge's DNS cache that had not expired, or a static mapping of its profile.
    case surgeCache = "surge-cache"
}

/// A resolution Surge's DNS made (row in `dns_answers`): its `dns` watch event, completed from the matching entry
/// of `dump dns`. No request ID: requests join it by host and time.
struct DNSAnswer: Hashable, Codable, Sendable {
    var deviceID: DeviceID
    /// Lowercased, without a trailing dot.
    var domain: String
    /// When the answer arrived (Tidemark received the watch event).
    var resolvedAt: Date
    /// e.g. `https://cloudflare-dns.com/dns-query`
    var server: String?
    var interface: String?
    var addresses: [String]
    /// The CNAME chain, e.g. `www.qualcomm.cn -> www.qualcomm.cn.cdn.cloudflare.net -> 172.64.144.37, 104.18.43.219`.
    var path: String?
    /// Surge's log of the lookup, e.g. `160.59ms Receive an A answer from https://cloudflare-dns.com/dns-query`.
    var log: String?
    /// How long the lookup took.
    var timeCostMs: Double?
    var expiresAt: Date?
    /// Tidemark's own `dns lookup` caused it.
    var byTidemark: Bool = false
}

extension RequestRecord {
    /// When the request needed its host's address, for joining its DNS answer (the latest one at or before this, on
    /// its Mac): when Surge's rule matching or Tidemark resolved the address it shows (within a minute of the start),
    /// otherwise its start; plus a second for the watch event to arrive.
    var dnsAnswerMoment: Date {
        let resolved = remoteIPResolvedAt.map { min(max($0, startedAt), startedAt.addingTimeInterval(60)) } ?? startedAt
        return resolved.addingTimeInterval(1)
    }
}

/// An error a proxy node reported (`proxy-runtime-status` → `errors`, row in `proxy_errors`). A node keeps only
/// its last 15, so Tidemark polls the nodes that carry requests. Requests join it by host and completion time.
struct ProxyNodeError: Hashable, Codable, Sendable {
    var deviceID: DeviceID
    /// The node's name (a request's final policy); it identifies the error, with the time and host.
    var policy: String
    /// What Tidemark asked the node by: its `POLICY::…` line hash, or its name when Surge listed none.
    var lineHash: String
    /// When the error happened (Surge's clock, this Mac's).
    var at: Date
    /// Host name or IP the failed connection was for.
    var targetHost: String
    /// e.g. `Stream closed`
    var error: String
}

/// Tidemark's other records about one request (`relatedRecords(of:)`). Only the alert and the probe session link
/// to it; the rest is found by host and time on the request's Mac.
struct RequestRelatedRecords: Hashable, Sendable {
    /// The first-contact alert the request raised.
    var alert: AlertItem?
    /// The site probe it belonged to.
    var probeSession: ProbeSession?
    /// The current egress check nearest to its start (checks are kept for 30 days).
    var egressCheck: EgressSample?
    /// The latest change of the current egress at or before its start.
    var egressChange: EgressChange?
    /// The latest DNS answer for its host at or before the moment it needed one.
    var dnsAnswer: DNSAnswer?
    /// Errors its proxy reported for its host within a second of its end.
    var proxyErrors: [ProxyNodeError] = []
}
