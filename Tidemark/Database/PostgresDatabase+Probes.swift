import Foundation
import PostgresNIO

extension PostgresDatabase {
    // MARK: - Site probes

    /// Upserts the session and replaces its hosts in one transaction. Host times are stored in
    /// milliseconds since the probe started.
    func saveProbeSession(_ session: ProbeSession) async throws {
        let steps = try Self.jsonText(session.steps)
        let upsert: PostgresQuery = """
            INSERT INTO probe_sessions (id, device_id, url, host, mode, started_at, ended_at, steps)
            VALUES (\(session.id), \(session.deviceID), \(session.url), \(session.host), \(session.mode.rawValue),
                    \(session.startedAt), \(session.endedAt), \(steps)::jsonb)
            ON CONFLICT (id) DO UPDATE SET
                device_id = excluded.device_id, url = excluded.url, host = excluded.host, mode = excluded.mode,
                started_at = excluded.started_at, ended_at = excluded.ended_at, steps = excluded.steps
            """
        let clear: PostgresQuery = "DELETE FROM probe_hosts WHERE session_id = \(session.id)"

        var seen = Set<String>()
        let hosts = session.hosts.filter { seen.insert($0.host).inserted }
        var inserts: [PostgresQuery] = []
        for chunk in Self.chunks(hosts, bindsPerItem: 7) {
            var sql = SQL("INSERT INTO probe_hosts (session_id, host, first_ms, last_ms, request_count, ips, step) VALUES ")
            for (index, host) in chunk.enumerated() {
                if index > 0 { sql.append(", ") }
                let values = [
                    sql.bind(session.id) + "::uuid", sql.bind(host.host) + "::text",
                    sql.bind(Self.milliseconds(host.firstAt)) + "::int4", sql.bind(Self.milliseconds(host.lastAt)) + "::int4",
                    sql.bind(Int32(clamping: host.requestCount)) + "::int4", sql.bind(host.ips) + "::text[]", sql.bind(Int32(clamping: host.step)) + "::int4",
                ]
                sql.append("(" + values.joined(separator: ", ") + ")")
            }
            inserts.append(sql.query)
        }

        try await withTransaction { [inserts] connection in
            try await connection.query(upsert, logger: Self.logger)
            try await connection.query(clear, logger: Self.logger)
            for insert in inserts { try await connection.query(insert, logger: Self.logger) }
        }
    }

    /// Newest first, with their hosts ordered by first activity.
    func probeSessions(limit: Int) async throws -> [ProbeSession] {
        try await withConnection { connection in
            var sessions: [ProbeSession] = []
            for row in try await connection.query("""
                SELECT id, device_id, url, host, mode, started_at, ended_at, steps
                FROM probe_sessions ORDER BY started_at DESC LIMIT \(max(0, limit))
                """, logger: Self.logger).collect() {
                let read = PostgresRowReader(row)
                sessions.append(ProbeSession(
                    id: try read("id"),
                    deviceID: try read("device_id"),
                    url: try read("url"),
                    host: try read("host"),
                    mode: ProbeDeviceMode(rawValue: try read("mode", as: String.self)) ?? .desktop,
                    startedAt: try read("started_at"),
                    endedAt: try read("ended_at"),
                    steps: try read.json("steps", as: [ProbeStep].self) ?? [],
                    hosts: []
                ))
            }
            guard !sessions.isEmpty else { return [] }

            var hosts: [UUID: [ProbeHost]] = [:]
            for row in try await connection.query("""
                SELECT session_id, host, first_ms, last_ms, request_count, ips, step
                FROM probe_hosts WHERE session_id = ANY(\(sessions.map(\.id))) ORDER BY first_ms, host
                """, logger: Self.logger).collect() {
                let read = PostgresRowReader(row)
                hosts[try read("session_id", as: UUID.self), default: []].append(ProbeHost(
                    host: try read("host"),
                    firstAt: Double(try read("first_ms", as: Int.self)) / 1_000,
                    lastAt: Double(try read("last_ms", as: Int.self)) / 1_000,
                    requestCount: try read("request_count"),
                    ips: try read("ips"),
                    step: try read("step")
                ))
            }
            for index in sessions.indices { sessions[index].hosts = hosts[sessions[index].id] ?? [] }
            return sessions
        }
    }

    private static func milliseconds(_ seconds: TimeInterval) -> Int32 {
        guard seconds.isFinite else { return 0 }
        return Int32(clamping: Int64((seconds * 1_000).rounded()))
    }

    // MARK: - Egress

    /// Stores one check round and prunes this Mac's samples older than 30 days.
    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws {
        guard !samples.isEmpty else { return }
        var inserts: [PostgresQuery] = []
        for chunk in Self.chunks(samples, bindsPerItem: 11) {
            var sql = SQL("""
                INSERT INTO egress_checks (device_id, checked_at, policy_path, ip, location, network, latency_ms, is_current, error, network_type, has_ipv6) VALUES
                """)
            for (index, sample) in chunk.enumerated() {
                sql.append(index > 0 ? ", " : " ")
                let values = [
                    sql.bind(deviceID) + "::uuid", sql.bind(sample.checkedAt) + "::timestamptz", sql.bind(sample.policyPath) + "::text[]",
                    sql.bind(Self.inetText(sample.ip)) + "::inet", sql.bind(sample.location) + "::text", sql.bind(sample.network) + "::text",
                    sql.bind(sample.latencyMs.map { Int32(clamping: $0) }) + "::int4", sql.bind(sample.isCurrent) + "::bool",
                    sql.bind(sample.error) + "::text", sql.bind(sample.networkType) + "::text", sql.bind(sample.hasIPv6) + "::bool",
                ]
                sql.append("(" + values.joined(separator: ", ") + ")")
            }
            inserts.append(sql.query)
        }
        let prune: PostgresQuery = "DELETE FROM egress_checks WHERE device_id = \(deviceID) AND checked_at < now() - interval '30 days'"
        try await withTransaction { [inserts] connection in
            for insert in inserts { try await connection.query(insert, logger: Self.logger) }
            try await connection.query(prune, logger: Self.logger)
        }
    }

    /// The latest sample per policy among this Mac's checks of the last hour before its newest check
    /// (so policies removed from the profile drop out). Exactly one sample — the policy of the most
    /// recent check flagged current — is current. Current first, then by policy path.
    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample] {
        try await rows("""
            WITH recent AS (
                SELECT * FROM egress_checks
                WHERE device_id = \(deviceID)
                  AND checked_at >= (SELECT max(checked_at) - interval '1 hour' FROM egress_checks WHERE device_id = \(deviceID))
            ), latest AS (
                SELECT DISTINCT ON (policy_path) * FROM recent ORDER BY policy_path, checked_at DESC, id DESC
            ), chosen AS (
                SELECT policy_path FROM recent WHERE is_current ORDER BY checked_at DESC, id DESC LIMIT 1
            )
            SELECT l.policy_path, host(l.ip) AS ip, l.location, l.network, l.latency_ms, l.checked_at, l.error,
                   l.network_type, l.has_ipv6,
                   COALESCE(l.policy_path = (SELECT policy_path FROM chosen), false) AS is_current
            FROM latest l
            ORDER BY is_current DESC, l.policy_path
            """).map { row in
            let read = PostgresRowReader(row)
            return EgressSample(
                policyPath: try read("policy_path"),
                ip: try read("ip"),
                location: try read("location"),
                network: try read("network"),
                latencyMs: try read("latency_ms", as: Int?.self),
                isCurrent: try read("is_current"),
                checkedAt: try read("checked_at"),
                error: try read("error"),
                networkType: try read("network_type"),
                hasIPv6: try read("has_ipv6")
            )
        }
    }

    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws {
        guard let ip = Self.inetText(change.ip) else { throw DatabaseError.query("Not an IP address: \(change.ip)") }
        try await execute("""
            INSERT INTO egress_changes (device_id, changed_at, ip, policy_path, reason)
            VALUES (\(deviceID), \(change.changedAt), \(ip)::inet, \(change.policyPath), \(change.reason))
            """)
    }

    /// Newest first.
    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange] {
        try await rows("""
            SELECT id, changed_at, host(ip) AS ip, policy_path, reason FROM egress_changes
            WHERE device_id = \(deviceID) ORDER BY changed_at DESC, id DESC LIMIT \(max(0, limit))
            """).map { row in
            let read = PostgresRowReader(row)
            return EgressChange(
                id: try read("id"),
                changedAt: try read("changed_at"),
                ip: try read("ip"),
                policyPath: try read("policy_path"),
                reason: try read("reason")
            )
        }
    }
}
