import Foundation
import Synchronization

/// Thread-safe record of the running site probe, shared by three parties:
///
/// * the per-session proxy reports every tunnel (host, upstream source address and port) and its traffic;
/// * the capture pipeline matches Surge records whose source port belongs to the probe and adds the
///   remote IPs Surge saw;
/// * the probe controller reads snapshots to publish the live waterfall.
///
/// A source port belongs to the probe only while its upstream connection is open and for `portGrace`
/// after it closed (Surge's records can trail the close), so an unrelated Tidemark connection that later
/// gets the same ephemeral port is not taken for the probe.
final class ProbeRegistry: Sendable {
    /// A Surge record that belongs to the running probe.
    struct Match: Hashable, Sendable {
        var sessionID: UUID
        var host: String
    }

    /// Hosts in first-contact order; `version` changes whenever anything changed.
    struct Snapshot: Sendable {
        var sessionID: UUID?
        var hosts: [ProbeHost]
        var version: Int
    }

    private struct HostState {
        var host: ProbeHost
        var ips: Set<String>
    }

    /// An upstream connection to Surge opened by the probe proxy.
    private struct Upstream {
        var host: String
        /// Local address the connection was made from (`127.0.0.1`), nil when unknown.
        var sourceAddress: String?
        var closedAt: Date?
    }

    private struct State {
        var sessionID: UUID?
        var startedAt = Date.distantPast
        var step = 0
        var hosts: [String: HostState] = [:]
        var order: [String] = []
        var ports: [Int: Upstream] = [:]
        var version = 0
    }

    private let state = Mutex(State())
    /// How long the source port of a closed upstream connection still matches Surge records.
    let portGrace: TimeInterval

    init(portGrace: TimeInterval = 30) {
        self.portGrace = portGrace
    }

    var isActive: Bool { state.withLock { $0.sessionID != nil } }

    /// Starts recording a new session, discarding any previous one.
    func begin(sessionID: UUID, startedAt: Date) {
        state.withLock { s in
            s = State()
            s.sessionID = sessionID
            s.startedAt = startedAt
            s.version = 1
        }
    }

    /// Ends the session and returns its final hosts.
    @discardableResult
    func end() -> Snapshot {
        state.withLock { s in
            let snapshot = Self.snapshot(of: s)
            s = State()
            return snapshot
        }
    }

    /// Index into the session's steps of the action that new hosts are attributed to.
    func setStep(_ index: Int) {
        state.withLock { $0.step = max(0, index) }
    }

    /// A browser connection to `host` was accepted.
    func connectionOpened(host: String, at date: Date = .now) {
        let host = host.lowercased()
        state.withLock { s in
            guard s.sessionID != nil else { return }
            let t = max(0, date.timeIntervalSince(s.startedAt))
            if var existing = s.hosts[host] {
                existing.host.requestCount += 1
                existing.host.lastAt = max(existing.host.lastAt, t)
                s.hosts[host] = existing
            } else {
                s.hosts[host] = HostState(host: ProbeHost(host: host, firstAt: t, lastAt: t, requestCount: 1, ips: [], step: s.step), ips: [])
                s.order.append(host)
            }
            s.version += 1
        }
    }

    /// Bytes moved on a connection to `host`.
    func activity(host: String, at date: Date = .now) {
        let host = host.lowercased()
        state.withLock { s in
            guard s.sessionID != nil, var existing = s.hosts[host] else { return }
            let t = max(0, date.timeIntervalSince(s.startedAt))
            guard t - existing.host.lastAt >= 0.05 else { return }
            existing.host.lastAt = t
            s.hosts[host] = existing
            s.version += 1
        }
    }

    /// Remembers the local source address and port of an upstream connection to Surge, so Surge's record
    /// of it can be matched to the probe.
    func registerUpstream(port: Int, host: String, sourceAddress: String? = nil) {
        state.withLock { s in
            guard s.sessionID != nil else { return }
            s.ports[port] = Upstream(host: host.lowercased(), sourceAddress: sourceAddress.map(Self.normalizedAddress), closedAt: nil)
        }
    }

    /// The upstream connection on `port` closed; its port stops matching new Surge records `portGrace` later.
    func upstreamClosed(port: Int, at date: Date = .now) {
        state.withLock { s in
            guard s.ports[port] != nil else { return }
            s.ports[port]?.closedAt = date
            // Forget ports that closed long ago, so a long session does not keep every port it ever used.
            // (Records matched in time may still report a resolved IP a little later; see `addIP`.)
            let horizon = date.addingTimeInterval(-10 * portGrace)
            s.ports = s.ports.filter { ($0.value.closedAt ?? .distantFuture) >= horizon }
        }
    }

    /// The probe connection that used `sourcePort`, if any. When `sourceAddress` (Surge's `sourceAddress`)
    /// is given, it must be the address the probe connected from: records of connections Surge captured on
    /// its virtual interface (`198.18.0.1`) share the port space with its proxy clients (`127.0.0.1`).
    func match(sourcePort: Int, sourceAddress: String? = nil, at date: Date = .now) -> Match? {
        state.withLock { s in
            guard let id = s.sessionID,
                  let upstream = Self.upstream(in: s, port: sourcePort, sourceAddress: sourceAddress, at: date, grace: portGrace)
            else { return nil }
            return Match(sessionID: id, host: upstream.host)
        }
    }

    /// Adds a remote IP Surge reported for the probe connection on `sourcePort`. The capture pipeline calls
    /// this only for records it matched, so the IP is accepted even when it resolves after the grace.
    func addIP(_ ip: String, sourcePort: Int, sourceAddress: String? = nil) {
        state.withLock { s in
            guard s.sessionID != nil,
                  let upstream = Self.upstream(in: s, port: sourcePort, sourceAddress: sourceAddress, at: nil, grace: portGrace),
                  var existing = s.hosts[upstream.host] else { return }
            guard existing.ips.insert(ip).inserted else { return }
            existing.host.ips.append(ip)
            s.hosts[upstream.host] = existing
            s.version += 1
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { Self.snapshot(of: $0) }
    }

    /// `::ffff:127.0.0.1` and `127.0.0.1` compare equal; brackets and an IPv6 zone are dropped.
    static func normalizedAddress(_ address: String) -> String {
        var value = address.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).lowercased()
        if let percent = value.firstIndex(of: "%") { value = String(value[..<percent]) }
        let mapped = String(value.dropFirst("::ffff:".count))
        if value.hasPrefix("::ffff:"), HostName.isIPv4(mapped) { value = mapped }
        return value
    }

    /// The upstream connection on `port`; with `date`, only while open or within `grace` after it closed.
    private static func upstream(in s: State, port: Int, sourceAddress: String?, at date: Date?, grace: TimeInterval) -> Upstream? {
        guard let upstream = s.ports[port] else { return nil }
        if let date, let closedAt = upstream.closedAt, date.timeIntervalSince(closedAt) > grace { return nil }
        if let sourceAddress, !sourceAddress.isEmpty, let own = upstream.sourceAddress, normalizedAddress(sourceAddress) != own {
            return nil
        }
        return upstream
    }

    private static func snapshot(of s: State) -> Snapshot {
        Snapshot(sessionID: s.sessionID, hosts: s.order.compactMap { s.hosts[$0]?.host }, version: s.version)
    }
}
