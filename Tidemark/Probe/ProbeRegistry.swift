import Foundation
import Synchronization

/// Thread-safe record of the running site probe, shared by three parties:
///
/// * the per-session proxy reports every tunnel (host, upstream source port) and its traffic;
/// * the capture pipeline matches Surge records whose source port belongs to the probe and adds the
///   remote IPs Surge saw;
/// * the probe controller reads snapshots to publish the live waterfall.
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

    private struct State {
        var sessionID: UUID?
        var startedAt = Date.distantPast
        var step = 0
        var hosts: [String: HostState] = [:]
        var order: [String] = []
        var ports: [Int: String] = [:]
        var version = 0
    }

    private let state = Mutex(State())

    init() {}

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

    /// Remembers the local source port of an upstream connection to Surge, so Surge's record of it can be
    /// matched to the probe.
    func registerUpstream(port: Int, host: String) {
        state.withLock { s in
            guard s.sessionID != nil else { return }
            s.ports[port] = host.lowercased()
        }
    }

    /// The probe connection that used `sourcePort`, if any.
    func match(sourcePort: Int) -> Match? {
        state.withLock { s in
            guard let id = s.sessionID, let host = s.ports[sourcePort] else { return nil }
            return Match(sessionID: id, host: host)
        }
    }

    /// Adds a remote IP Surge reported for the probe connection on `sourcePort`.
    func addIP(_ ip: String, sourcePort: Int) {
        state.withLock { s in
            guard s.sessionID != nil, let host = s.ports[sourcePort], var existing = s.hosts[host] else { return }
            guard existing.ips.insert(ip).inserted else { return }
            existing.host.ips.append(ip)
            s.hosts[host] = existing
            s.version += 1
        }
    }

    func snapshot() -> Snapshot {
        state.withLock { Self.snapshot(of: $0) }
    }

    private static func snapshot(of s: State) -> Snapshot {
        Snapshot(sessionID: s.sessionID, hosts: s.order.compactMap { s.hosts[$0]?.host }, version: s.version)
    }
}
