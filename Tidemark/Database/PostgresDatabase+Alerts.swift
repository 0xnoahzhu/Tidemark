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

    /// Inserts alerts and returns the stored ones with their database IDs, in input order.
    ///
    /// * An alert of an app that was deleted meanwhile (possibly by another Mac) is skipped instead of
    ///   failing the batch on the foreign key; a request row that is gone is unlinked.
    /// * Idempotent: an alert identical to a stored one in app, kind, value, Mac and creation time is the
    ///   same alert (a batch retried after a commit whose reply was lost) and comes back with the stored ID
    ///   instead of being inserted twice. Duplicates within `alerts` are stored once.
    @discardableResult
    func insertAlerts(_ alerts: [AlertItem]) async throws -> [AlertItem] {
        guard !alerts.isEmpty else { return [] }
        struct Key: Hashable {
            var app: AppID, kind: HostKind, value: String, device: DeviceID, createdAt: Date
            init(_ alert: AlertItem) {
                app = alert.appID
                kind = alert.kind
                value = alert.value
                device = alert.deviceID
                createdAt = alert.createdAt
            }
        }
        var seen = Set<Key>()
        let unique = alerts.filter { seen.insert(Key($0)).inserted }

        let columns = ["device_id", "app_id", "kind", "scope", "value", "site", "host", "ip", "geo", "process_name", "is_direct", "request_id", "created_at", "read_at"]
        let sameAlert = "al.app_id = v.app_id AND al.kind = v.kind AND al.value = v.value AND al.device_id = v.device_id AND al.created_at = v.created_at"
        var statements: [(insert: PostgresQuery, lookup: PostgresQuery)] = []
        var offset = 0
        for chunk in Self.chunks(unique, bindsPerItem: columns.count + 1) {
            func values(_ sql: inout SQL) throws {
                sql.append("(VALUES ")
                for (index, alert) in chunk.enumerated() {
                    if index > 0 { sql.append(", ") }
                    let values = [
                        sql.bind(Int32(clamping: offset + index)) + "::int4",
                        sql.bind(alert.deviceID) + "::uuid", sql.bind(alert.appID) + "::uuid", sql.bind(alert.kind.rawValue) + "::text",
                        sql.bind(alert.scope.rawValue) + "::text", sql.bind(alert.value) + "::text", sql.bind(alert.site) + "::text",
                        sql.bind(alert.host) + "::text", sql.bind(alert.ip) + "::text", try sql.bindJSON(alert.geo),
                        sql.bind(alert.processName) + "::text", sql.bind(alert.isDirect) + "::bool", sql.bind(alert.requestRowID) + "::int8",
                        sql.bind(alert.createdAt) + "::timestamptz", sql.bind(alert.readAt) + "::timestamptz",
                    ]
                    sql.append("(" + values.joined(separator: ", ") + ")")
                }
                sql.append(") AS v(position, \(columns.joined(separator: ", ")))")
            }
            var insert = SQL("INSERT INTO alerts (\(columns.joined(separator: ", "))) SELECT ")
            insert.append(columns.map { $0 == "request_id" ? "rq.id" : "v.\($0)" }.joined(separator: ", "))
            insert.append(" FROM ")
            try values(&insert)
            insert.append("""
                 JOIN apps a ON a.id = v.app_id LEFT JOIN requests rq ON rq.id = v.request_id
                WHERE NOT EXISTS (SELECT 1 FROM alerts al WHERE \(sameAlert))
                ORDER BY v.position
                """)
            var lookup = SQL("SELECT DISTINCT ON (v.position) v.position, al.id FROM ")
            try values(&lookup)
            lookup.append(" JOIN alerts al ON \(sameAlert) ORDER BY v.position, al.id")
            statements.append((insert.query, lookup.query))
            offset += chunk.count
        }

        let ids = try await withTransaction(on: .writer) { [statements] connection in
            var ids: [Int: Int64] = [:]
            for statement in statements {
                try await connection.query(statement.insert, logger: Self.logger)
                for row in try await connection.query(statement.lookup, logger: Self.logger).collect() {
                    let read = PostgresRowReader(row)
                    ids[Int(try read("position", as: Int32.self))] = try read("id", as: Int64.self)
                }
            }
            return ids
        }
        return unique.enumerated().compactMap { position, alert in
            guard let id = ids[position] else { return nil }
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
}
