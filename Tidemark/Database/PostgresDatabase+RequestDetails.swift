import Foundation
import PostgresNIO

/// DNS answers and proxy node errors (schema v4), and the records the UI shows beside one request.
///
/// Neither table carries a request ID: a request joins its DNS answer by host and time, and its proxy errors by
/// host and completion time, always on the request's own Mac (each Mac has its own Surge).
extension PostgresDatabase {
    // MARK: - Writes

    /// Upserts by `(device_id, domain, resolved_at)` on the writer pool; a column the stored answer has and the new
    /// one lacks (written before `dump dns` completed it) is kept.
    func saveDNSAnswers(_ answers: [DNSAnswer]) async throws {
        guard !answers.isEmpty else { return }
        // One row per key and statement: PostgreSQL refuses to update a row twice in one statement.
        var seen = Set<String>()
        let unique = Array(answers.reversed().filter { seen.insert(Self.dnsAnswerKey($0)).inserted }.reversed())
        let columns = ["device_id", "domain", "resolved_at", "server", "interface", "addresses", "path", "log", "time_cost_ms", "expires_at", "by_tidemark"]
        var statements: [PostgresQuery] = []
        for chunk in Self.chunks(unique, bindsPerItem: columns.count) {
            var sql = SQL("INSERT INTO dns_answers AS d (\(columns.joined(separator: ", "))) VALUES ")
            for (index, answer) in chunk.enumerated() {
                if index > 0 { sql.append(", ") }
                let values = [
                    sql.bind(answer.deviceID) + "::uuid", sql.bind(answer.domain) + "::text", sql.bind(answer.resolvedAt) + "::timestamptz",
                    sql.bind(answer.server) + "::text", sql.bind(answer.interface) + "::text", sql.bind(answer.addresses) + "::text[]",
                    sql.bind(answer.path) + "::text", sql.bind(answer.log) + "::text", sql.bind(answer.timeCostMs) + "::float8::real",
                    sql.bind(answer.expiresAt) + "::timestamptz", sql.bind(answer.byTidemark) + "::bool",
                ]
                sql.append("(" + values.joined(separator: ", ") + ")")
            }
            sql.append("""
                 ON CONFLICT (device_id, domain, resolved_at) DO UPDATE SET
                    server = COALESCE(excluded.server, d.server),
                    interface = COALESCE(excluded.interface, d.interface),
                    addresses = CASE WHEN cardinality(excluded.addresses) > 0 THEN excluded.addresses ELSE d.addresses END,
                    path = COALESCE(excluded.path, d.path),
                    log = COALESCE(excluded.log, d.log),
                    time_cost_ms = COALESCE(excluded.time_cost_ms, d.time_cost_ms),
                    expires_at = COALESCE(excluded.expires_at, d.expires_at),
                    by_tidemark = d.by_tidemark OR excluded.by_tidemark
                """)
            statements.append(sql.query)
        }
        try await withTransaction(on: .writer) { [statements] connection in
            for statement in statements { try await connection.query(statement, logger: Self.logger) }
        }
    }

    /// Inserts on the writer pool; an error already stored (same Mac, node, time and host: a node lists its last 15
    /// errors every time it is asked, by whichever name or line hash) is skipped.
    func saveProxyErrors(_ errors: [ProxyNodeError]) async throws {
        guard !errors.isEmpty else { return }
        let columns = ["device_id", "policy", "line_hash", "at", "target_host", "error"]
        var statements: [PostgresQuery] = []
        for chunk in Self.chunks(errors, bindsPerItem: columns.count) {
            var sql = SQL("INSERT INTO proxy_errors (\(columns.joined(separator: ", "))) VALUES ")
            for (index, error) in chunk.enumerated() {
                if index > 0 { sql.append(", ") }
                let values = [
                    sql.bind(error.deviceID) + "::uuid", sql.bind(error.policy) + "::text", sql.bind(error.lineHash) + "::text",
                    sql.bind(error.at) + "::timestamptz", sql.bind(error.targetHost) + "::text", sql.bind(error.error) + "::text",
                ]
                sql.append("(" + values.joined(separator: ", ") + ")")
            }
            sql.append(" ON CONFLICT (device_id, policy, at, target_host) DO NOTHING")
            statements.append(sql.query)
        }
        try await withTransaction(on: .writer) { [statements] connection in
            for statement in statements { try await connection.query(statement, logger: Self.logger) }
        }
    }

    /// The key `dns_answers` stores an answer under, to the microsecond PostgreSQL keeps.
    private static func dnsAnswerKey(_ answer: DNSAnswer) -> String {
        "\(answer.deviceID.uuidString)|\(answer.domain)|\(Int64((answer.resolvedAt.timeIntervalSince1970 * 1_000_000).rounded()))"
    }

    // MARK: - Reads

    private static let dnsAnswerSelect = """
        SELECT a.device_id, a.domain, a.resolved_at, a.server, a.interface, a.addresses, a.path, a.log,
               a.time_cost_ms::float8 AS time_cost_ms, a.expires_at, a.by_tidemark
        FROM dns_answers a
        """

    private static let proxyErrorSelect = "SELECT e.device_id, e.policy, e.line_hash, e.at, e.target_host, e.error FROM proxy_errors e"

    static func decodeDNSAnswer(_ row: PostgresRow) throws -> DNSAnswer {
        let read = PostgresRowReader(row)
        return DNSAnswer(
            deviceID: try read("device_id"),
            domain: try read("domain"),
            resolvedAt: try read("resolved_at"),
            server: try read("server"),
            interface: try read("interface"),
            addresses: try read("addresses"),
            path: try read("path"),
            log: try read("log"),
            timeCostMs: try read("time_cost_ms"),
            expiresAt: try read("expires_at"),
            byTidemark: try read("by_tidemark")
        )
    }

    static func decodeProxyError(_ row: PostgresRow) throws -> ProxyNodeError {
        let read = PostgresRowReader(row)
        return ProxyNodeError(
            deviceID: try read("device_id"),
            policy: try read("policy"),
            lineHash: try read("line_hash"),
            at: try read("at"),
            targetHost: try read("target_host"),
            error: try read("error")
        )
    }

    /// Newest first (`dns_answers_domain_idx`, or the primary key with one Mac).
    func dnsAnswers(forHost host: String, from: Date?, to: Date?, scope: DeviceScope, limit: Int) async throws -> [DNSAnswer] {
        var sql = SQL(Self.dnsAnswerSelect + " WHERE a.domain = ")
        sql.append(sql.bind(Self.answerDomain(host)))
        if let device = scope.deviceID { sql.append(" AND a.device_id = \(sql.bind(device))") }
        if let from { sql.append(" AND a.resolved_at >= \(sql.bind(from))") }
        if let to { sql.append(" AND a.resolved_at <= \(sql.bind(to))") }
        sql.append(" ORDER BY a.resolved_at DESC, a.device_id LIMIT \(sql.bind(max(0, limit)))")
        return try await rows(sql.query).map(Self.decodeDNSAnswer)
    }

    /// Newest first (`proxy_errors_target_idx`).
    func proxyErrors(forHost host: String, from: Date?, to: Date?, scope: DeviceScope, limit: Int) async throws -> [ProxyNodeError] {
        var sql = SQL(Self.proxyErrorSelect + " WHERE e.target_host = ")
        sql.append(sql.bind(Self.exactHost(host)))
        if let device = scope.deviceID { sql.append(" AND e.device_id = \(sql.bind(device))") }
        if let from { sql.append(" AND e.at >= \(sql.bind(from))") }
        if let to { sql.append(" AND e.at <= \(sql.bind(to))") }
        sql.append(" ORDER BY e.at DESC, e.policy LIMIT \(sql.bind(max(0, limit)))")
        return try await rows(sql.query).map(Self.decodeProxyError)
    }

    func proxyErrors(for request: RequestRecord) async throws -> [ProxyNodeError] {
        guard let sql = Self.proxyErrorsQuery(for: request) else { return [] }
        return try await rows(sql.query).map(Self.decodeProxyError)
    }

    func relatedRecords(of request: RequestRecord) async throws -> RequestRelatedRecords {
        let device = request.deviceID
        let start = request.startedAt
        var answer = SQL(Self.dnsAnswerSelect + " WHERE a.device_id = ")
        answer.append(answer.bind(device))
        answer.append(" AND a.domain = \(answer.bind(Self.answerDomain(request.host))) AND a.resolved_at <= \(answer.bind(request.dnsAnswerMoment))")
        answer.append(" ORDER BY a.resolved_at DESC LIMIT 1")
        let answerQuery = request.isIPLiteral ? nil : answer.query
        let errorsQuery = Self.proxyErrorsQuery(for: request)?.query
        let egressColumns = "policy_path, host(ip) AS ip, location, network, latency_ms, is_current, checked_at, error, network_type, has_ipv6"

        return try await withConnection { connection in
            var related = RequestRelatedRecords()
            if let rowID = request.rowID {
                related.alert = try await connection.query(
                    "\(unescaped: Self.alertSelect) WHERE a.request_id = \(rowID) ORDER BY a.id LIMIT 1", logger: Self.logger
                ).collect().first.map(Self.decodeAlert)
            }
            if let session = request.probeSessionID {
                let sessions = try await connection.query("""
                    SELECT id, device_id, url, host, mode, started_at, ended_at, steps FROM probe_sessions WHERE id = \(session)
                    """, logger: Self.logger).collect().map(Self.decodeProbeSession)
                related.probeSession = try await Self.withProbeHosts(sessions, on: connection).first
            }
            // The current egress checks just before and after the start (`egress_checks_device_idx`); the nearer wins.
            let checks = try await connection.query("""
                (SELECT \(unescaped: egressColumns) FROM egress_checks
                 WHERE device_id = \(device) AND is_current AND checked_at <= \(start) ORDER BY checked_at DESC LIMIT 1)
                UNION ALL
                (SELECT \(unescaped: egressColumns) FROM egress_checks
                 WHERE device_id = \(device) AND is_current AND checked_at > \(start) ORDER BY checked_at LIMIT 1)
                """, logger: Self.logger).collect().map(Self.decodeEgressSample)
            related.egressCheck = checks.min { abs($0.checkedAt.timeIntervalSince(start)) < abs($1.checkedAt.timeIntervalSince(start)) }
            related.egressChange = try await connection.query("""
                SELECT id, changed_at, host(ip) AS ip, policy_path, reason FROM egress_changes
                WHERE device_id = \(device) AND changed_at <= \(start) ORDER BY changed_at DESC, id DESC LIMIT 1
                """, logger: Self.logger).collect().first.map(Self.decodeEgressChange)
            if let answerQuery {
                related.dnsAnswer = try await connection.query(answerQuery, logger: Self.logger).collect().first.map(Self.decodeDNSAnswer)
            }
            if let errorsQuery {
                related.proxyErrors = try await connection.query(errorsQuery, logger: Self.logger).collect().map(Self.decodeProxyError)
            }
            return related
        }
    }

    /// The errors reported for the request's host on its Mac within a second of its completion, nearest first; nil
    /// for a request that has not completed.
    private static func proxyErrorsQuery(for request: RequestRecord) -> SQL? {
        guard let completed = request.completedAt else { return nil }
        var sql = SQL(proxyErrorSelect + " WHERE e.target_host = ")
        sql.append(sql.bind(exactHost(request.host)))
        sql.append(" AND e.device_id = \(sql.bind(request.deviceID))")
        sql.append(" AND e.at > \(sql.bind(completed.addingTimeInterval(-1))) AND e.at < \(sql.bind(completed.addingTimeInterval(1)))")
        let end = sql.bind(completed)
        sql.append(" ORDER BY abs(extract(epoch FROM e.at - \(end)::timestamptz)), e.at")
        return sql
    }

    /// A host as `dns_answers.domain` stores it: `exactHost` without a trailing dot.
    static func answerDomain(_ host: String) -> String {
        var domain = exactHost(host)
        while domain.hasSuffix(".") { domain.removeLast() }
        return domain
    }
}
