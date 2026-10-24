import Foundation
import PostgresNIO

extension PostgresDatabase {
    private static let alertSelect = """
        SELECT a.id, a.device_id, a.app_id, a.kind, a.scope, a.value, a.site, a.host, a.ip, a.geo, a.process_name,
               a.is_direct, a.request_id, a.created_at, a.read_at
        FROM alerts a
        """

    private static func decodeAlert(_ row: PostgresRow) throws -> AlertItem {
        let read = PostgresRowReader(row)
        return AlertItem(
            id: try read("id"),
            deviceID: try read("device_id"),
            appID: try read("app_id"),
            kind: HostKind(rawValue: try read("kind", as: String.self)) ?? .domain,
            scope: AlertScope(rawValue: try read("scope", as: String.self)) ?? .host,
            value: try read("value"),
            site: try read("site"),
            host: try read("host"),
            ip: try read("ip"),
            geo: try read.json("geo", as: GeoInfo.self),
            processName: try read("process_name"),
            isDirect: try read("is_direct"),
            requestRowID: try read("request_id"),
            createdAt: try read("created_at"),
            readAt: try read("read_at")
        )
    }

    /// Inserts alerts and returns them with their database IDs (input order is preserved).
    @discardableResult
    func insertAlerts(_ alerts: [AlertItem]) async throws -> [AlertItem] {
        guard !alerts.isEmpty else { return [] }
        let columns = ["device_id", "app_id", "kind", "scope", "value", "site", "host", "ip", "geo", "process_name", "is_direct", "request_id", "created_at", "read_at"]
        var queries: [PostgresQuery] = []
        for chunk in Self.chunks(alerts, bindsPerItem: columns.count) {
            var sql = SQL("INSERT INTO alerts (\(columns.joined(separator: ", "))) VALUES ")
            for (index, alert) in chunk.enumerated() {
                if index > 0 { sql.append(", ") }
                let values = [
                    sql.bind(alert.deviceID) + "::uuid", sql.bind(alert.appID) + "::uuid", sql.bind(alert.kind.rawValue) + "::text",
                    sql.bind(alert.scope.rawValue) + "::text", sql.bind(alert.value) + "::text", sql.bind(alert.site) + "::text",
                    sql.bind(alert.host) + "::text", sql.bind(alert.ip) + "::text", try sql.bindJSON(alert.geo),
                    sql.bind(alert.processName) + "::text", sql.bind(alert.isDirect) + "::bool", sql.bind(alert.requestRowID) + "::int8",
                    sql.bind(alert.createdAt) + "::timestamptz", sql.bind(alert.readAt) + "::timestamptz",
                ]
                sql.append("(" + values.joined(separator: ", ") + ")")
            }
            sql.append(" RETURNING id")
            queries.append(sql.query)
        }
        let ids = try await withTransaction { [queries] connection in
            var ids: [Int64] = []
            for query in queries {
                for row in try await connection.query(query, logger: Self.logger).collect() {
                    ids.append(try PostgresRowReader(row)("id", as: Int64.self))
                }
            }
            return ids
        }
        guard ids.count == alerts.count else { throw DatabaseError.query("Inserted \(ids.count) of \(alerts.count) alerts.") }
        return zip(alerts, ids).map { alert, id in
            var alert = alert
            alert.id = id
            return alert
        }
    }

    /// Newest first.
    func alerts(filter: AlertFilter, appID: AppID?, scope: DeviceScope, limit: Int) async throws -> [AlertItem] {
        var sql = SQL(Self.alertSelect)
        var conditions: [String] = []
        switch filter {
        case .all: break
        case .unread: conditions.append("a.read_at IS NULL")
        case .domain: conditions.append("a.kind = 'domain'")
        case .ip: conditions.append("a.kind = 'ip'")
        }
        if let appID { conditions.append("a.app_id = \(sql.bind(appID))") }
        if let device = scope.deviceID { conditions.append("a.device_id = \(sql.bind(device))") }
        if !conditions.isEmpty { sql.append(" WHERE " + conditions.joined(separator: " AND ")) }
        sql.append(" ORDER BY a.created_at DESC, a.id DESC LIMIT \(sql.bind(max(0, limit)))")
        return try await rows(sql.query).map(Self.decodeAlert)
    }

    /// Alerts with an ID above `id` written by other Macs, oldest first (so the caller can advance
    /// its cursor to the last ID), at most 500 per call.
    func alerts(after id: Int64, excluding: DeviceID?) async throws -> [AlertItem] {
        var sql = SQL(Self.alertSelect + " WHERE a.id > ")
        sql.append(sql.bind(id))
        if let excluding { sql.append(" AND a.device_id <> \(sql.bind(excluding))") }
        sql.append(" ORDER BY a.id LIMIT 500")
        return try await rows(sql.query).map(Self.decodeAlert)
    }

    func unreadAlertCount(scope: DeviceScope) async throws -> Int {
        var sql = SQL("SELECT count(*) AS n FROM alerts a WHERE a.read_at IS NULL")
        if let device = scope.deviceID { sql.append(" AND a.device_id = \(sql.bind(device))") }
        return try await rows(sql.query).first.map { try PostgresRowReader($0)("n", as: Int.self) } ?? 0
    }

    func markAlertsRead(_ ids: [Int64]) async throws {
        guard !ids.isEmpty else { return }
        try await execute("UPDATE alerts SET read_at = now() WHERE id = ANY(\(ids)) AND read_at IS NULL")
    }

    func markAllAlertsRead(appID: AppID?, scope: DeviceScope) async throws {
        switch (appID, scope.deviceID) {
        case let (app?, device?):
            try await execute("UPDATE alerts SET read_at = now() WHERE read_at IS NULL AND app_id = \(app) AND device_id = \(device)")
        case let (app?, nil):
            try await execute("UPDATE alerts SET read_at = now() WHERE read_at IS NULL AND app_id = \(app)")
        case let (nil, device?):
            try await execute("UPDATE alerts SET read_at = now() WHERE read_at IS NULL AND device_id = \(device)")
        case (nil, nil):
            try await execute("UPDATE alerts SET read_at = now() WHERE read_at IS NULL")
        }
    }

    func deleteAlert(_ id: Int64) async throws {
        try await execute("DELETE FROM alerts WHERE id = \(id)")
    }

    // MARK: - Mutes

    /// Patterns are stored trimmed and lowercased (matching is case-insensitive), oldest first.
    func mutes() async throws -> [String] {
        try await rows("SELECT pattern FROM mutes ORDER BY created_at, pattern").map { try PostgresRowReader($0)("pattern", as: String.self) }
    }

    func addMute(_ pattern: String) async throws {
        let normalized = Self.normalizedMute(pattern)
        guard !normalized.isEmpty else { return }
        try await execute("INSERT INTO mutes (pattern) VALUES (\(normalized)) ON CONFLICT (pattern) DO NOTHING")
    }

    func removeMute(_ pattern: String) async throws {
        try await execute("DELETE FROM mutes WHERE pattern = \(Self.normalizedMute(pattern))")
    }

    private static func normalizedMute(_ pattern: String) -> String {
        pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
