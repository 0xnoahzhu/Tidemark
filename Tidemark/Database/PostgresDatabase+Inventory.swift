import Foundation
import PostgresNIO

extension PostgresDatabase {
    // MARK: - App inventory

    /// Columns of an `app_hosts` row in `VALUES` order, with their casts.
    static let appHostColumns: [(name: String, cast: String)] = [
        ("app_id", "uuid"), ("kind", "text"), ("value", "text"), ("site", "text"), ("first_seen", "timestamptz"),
        ("last_seen", "timestamptz"), ("request_count", "int8"), ("process_name", "text"), ("policy", "text"),
        ("geo", "jsonb"), ("is_direct", "bool"), ("hosts", "text[]"), ("first_device_id", "uuid"),
    ]

    /// `INSERT INTO app_hosts AS h … <conflict> RETURNING app_id, kind, value`, one bind more per host than
    /// `appHostColumns` (its position). Hosts of apps that no longer exist are skipped (instead of failing
    /// the batch on the foreign key) and an unknown first Mac is stored as NULL. Rows are inserted in the
    /// given order, so concurrent inserts that were sorted the same way lock rows in the same order.
    static func appHostInsert(_ hosts: ArraySlice<AppHost>, conflict: String) throws -> PostgresQuery {
        let names = appHostColumns.map(\.name)
        var sql = SQL("INSERT INTO app_hosts AS h (\(names.joined(separator: ", "))) SELECT ")
        sql.append(names.map { $0 == "first_device_id" ? "d.id" : "v.\($0)" }.joined(separator: ", "))
        sql.append(" FROM (VALUES ")
        for (index, host) in hosts.enumerated() {
            if index > 0 { sql.append(", ") }
            let placeholders = [
                sql.bind(host.appID), sql.bind(host.kind.rawValue), sql.bind(host.value), sql.bind(host.site),
                sql.bind(host.firstSeen), sql.bind(host.lastSeen), sql.bind(host.requestCount), sql.bind(host.processName),
                sql.bind(host.policy), sql.bind(try host.geo.map { try jsonText($0) }), sql.bind(host.isDirect), sql.bind(host.hosts),
                sql.bind(host.firstDeviceID),
            ]
            let row = zip(placeholders, appHostColumns).map { "\($0)::\($1.cast)" } + ["\(sql.bind(Int32(clamping: index)))::int4"]
            sql.append("(" + row.joined(separator: ", ") + ")")
        }
        sql.append(") AS v(\(names.joined(separator: ", ")), position) JOIN apps a ON a.id = v.app_id ")
        sql.append("LEFT JOIN devices d ON d.id = v.first_device_id ORDER BY v.position ")
        sql.append("\(conflict) RETURNING h.app_id, h.kind, h.value")
        return sql.query
    }

    /// Every inventory value per app. The sets hold the plain values (`api.github.com`,
    /// `104.18.19.125`) of both kinds; a hostname can never collide with an IP address.
    func knownHosts() async throws -> [AppID: Set<String>] {
        var result: [AppID: Set<String>] = [:]
        for row in try await rows("SELECT app_id, value FROM app_hosts") {
            let read = PostgresRowReader(row)
            result[try read("app_id", as: UUID.self), default: []].insert(try read("value", as: String.self))
        }
        return result
    }

    /// `INSERT … ON CONFLICT DO NOTHING RETURNING`: only rows this call created come back, so when two
    /// Macs see the same first contact at once exactly one of them alerts. Hosts of deleted apps are
    /// skipped (never returned). `firstDeviceID` records the Mac that made first contact.
    func insertAppHosts(_ hosts: [AppHost]) async throws -> [AppHost] {
        guard !hosts.isEmpty else { return [] }
        // Unique and sorted by key, so concurrent inserts from several Macs lock rows in the same order.
        var unique: [AppHostKey: AppHost] = [:]
        for host in hosts where unique[AppHostKey(host)] == nil { unique[AppHostKey(host)] = host }
        let batch = unique.values.sorted { AppHostKey($0) < AppHostKey($1) }
        let statements = try Self.chunks(batch, bindsPerItem: Self.appHostColumns.count + 1).map {
            try Self.appHostInsert($0, conflict: "ON CONFLICT (app_id, kind, value) DO NOTHING")
        }
        let created = try await withTransaction(on: .writer) { [statements] connection in
            var keys = Set<AppHostKey>()
            for statement in statements {
                for row in try await connection.query(statement, logger: Self.logger).collect() {
                    let read = PostgresRowReader(row)
                    keys.insert(AppHostKey(appID: try read("app_id"), kind: try read("kind"), value: try read("value")))
                }
            }
            return keys
        }
        var remaining = created
        return hosts.filter { remaining.remove(AppHostKey($0)) != nil }
    }

    /// Adds `requestCount` (a delta) to known entries, advances `last_seen`, unions `hosts`, ORs
    /// `is_direct`, and replaces `policy` / `geo` when given. Unknown entries are ignored.
    func touchAppHosts(_ hosts: [AppHost]) async throws {
        guard !hosts.isEmpty else { return }
        var merged: [AppHostKey: AppHost] = [:]
        for host in hosts {
            let key = AppHostKey(host)
            guard var existing = merged[key] else { merged[key] = host; continue }
            existing.requestCount += host.requestCount
            existing.lastSeen = max(existing.lastSeen, host.lastSeen)
            existing.policy = host.policy ?? existing.policy
            existing.geo = host.geo ?? existing.geo
            existing.isDirect = existing.isDirect || host.isDirect
            existing.hosts = Array(Set(existing.hosts).union(host.hosts)).sorted()
            merged[key] = existing
        }
        let batch = merged.values.sorted { AppHostKey($0) < AppHostKey($1) }

        var statements: [PostgresQuery] = []
        for chunk in Self.chunks(batch, bindsPerItem: 9) {
            var sql = SQL("""
                UPDATE app_hosts h SET
                    last_seen = GREATEST(h.last_seen, v.last_seen),
                    request_count = h.request_count + v.delta,
                    policy = COALESCE(v.policy, h.policy),
                    geo = COALESCE(v.geo, h.geo),
                    is_direct = h.is_direct OR v.is_direct,
                    hosts = CASE WHEN cardinality(v.hosts) = 0 THEN h.hosts
                                 ELSE ARRAY(SELECT DISTINCT x FROM unnest(h.hosts || v.hosts) AS x ORDER BY x) END
                FROM (VALUES
                """)
            for (index, host) in chunk.enumerated() {
                if index > 0 { sql.append(", ") }
                let values = [
                    sql.bind(host.appID) + "::uuid", sql.bind(host.kind.rawValue) + "::text", sql.bind(host.value) + "::text",
                    sql.bind(host.lastSeen) + "::timestamptz", sql.bind(host.requestCount) + "::int8", sql.bind(host.policy) + "::text",
                    try sql.bindJSON(host.geo), sql.bind(host.isDirect) + "::bool", sql.bind(host.hosts) + "::text[]",
                ]
                sql.append("(" + values.joined(separator: ", ") + ")")
            }
            sql.append(") AS v(app_id, kind, value, last_seen, delta, policy, geo, is_direct, hosts) WHERE h.app_id = v.app_id AND h.kind = v.kind AND h.value = v.value")
            statements.append(sql.query)
        }
        try await withTransaction(on: .writer) { [statements] connection in
            for statement in statements { try await connection.query(statement, logger: Self.logger) }
        }
    }

    /// The app's inventory, newest first. The inventory is shared by every Mac: with `.all` it lists
    /// everything; with `.device(id)` it keeps the entries that Mac reported for this app through
    /// `touchHostSources` (first-seen, counts and policy stay the shared, all-Mac values).
    func appHosts(_ appID: AppID, scope: DeviceScope) async throws -> [AppHost] {
        var sql = SQL("""
            SELECT h.app_id, h.kind, h.value, h.site, h.first_seen, h.last_seen, h.request_count, h.process_name,
                   h.policy, h.geo, h.is_direct, h.hosts, h.first_device_id
            FROM app_hosts h WHERE h.app_id =
            """)
        sql.append(" " + sql.bind(appID))
        if let device = scope.deviceID { sql.append(" AND " + Self.reportedBy(sql.bind(device))) }
        sql.append(" ORDER BY h.first_seen DESC, h.value")
        return try await rows(sql.query).map { row in
            let read = PostgresRowReader(row)
            return AppHost(
                appID: try read("app_id"),
                kind: HostKind(rawValue: try read("kind", as: String.self)) ?? .domain,
                value: try read("value"),
                site: try read("site"),
                firstSeen: try read("first_seen"),
                lastSeen: try read("last_seen"),
                requestCount: try read("request_count"),
                processName: try read("process_name"),
                policy: try read("policy"),
                geo: try read.json("geo", as: GeoInfo.self),
                isDirect: try read("is_direct"),
                hosts: try read("hosts"),
                firstDeviceID: try read("first_device_id")
            )
        }
    }

    // MARK: - Global inventory

    /// Upserts `(kind, value, device, source path)` observations: `request_count += requestDelta`,
    /// first/last seen widened, title / app / bundle / geo refreshed when given. The app of a source whose
    /// app was deleted is stored as NULL.
    func touchHostSources(_ sources: [HostSourceTouch]) async throws {
        guard !sources.isEmpty else { return }
        struct Key: Hashable { var kind: HostKind; var value: String; var device: DeviceID; var path: String }
        var merged: [Key: (touch: HostSourceTouch, first: Date)] = [:]
        for source in sources {
            let key = Key(kind: source.kind, value: source.value, device: source.deviceID, path: source.sourcePath)
            guard var existing = merged[key] else { merged[key] = (source, source.seenAt); continue }
            existing.first = min(existing.first, source.seenAt)
            existing.touch.requestDelta += source.requestDelta
            existing.touch.seenAt = max(existing.touch.seenAt, source.seenAt)
            existing.touch.sourceTitle = source.sourceTitle
            existing.touch.appID = source.appID ?? existing.touch.appID
            existing.touch.bundlePath = source.bundlePath ?? existing.touch.bundlePath
            existing.touch.geo = source.geo ?? existing.touch.geo
            merged[key] = existing
        }
        let batch = merged.values.sorted { a, b in
            (a.touch.kind.rawValue, a.touch.value, a.touch.deviceID.uuidString, a.touch.sourcePath)
                < (b.touch.kind.rawValue, b.touch.value, b.touch.deviceID.uuidString, b.touch.sourcePath)
        }

        var statements: [PostgresQuery] = []
        for chunk in Self.chunks(batch, bindsPerItem: 11) {
            var sql = SQL("""
                INSERT INTO host_sources AS s (kind, value, device_id, source_path, source_title, app_id, bundle_path, first_seen, last_seen, request_count, geo)
                SELECT v.kind, v.value, v.device_id, v.source_path, v.source_title, a.id, v.bundle_path, v.first_seen, v.last_seen, v.request_count, v.geo
                FROM (VALUES
                """)
            for (index, entry) in chunk.enumerated() {
                if index > 0 { sql.append(",") }
                let touch = entry.touch
                let values = [
                    sql.bind(touch.kind.rawValue) + "::text", sql.bind(touch.value) + "::text", sql.bind(touch.deviceID) + "::uuid",
                    sql.bind(touch.sourcePath) + "::text", sql.bind(touch.sourceTitle) + "::text", sql.bind(touch.appID) + "::uuid",
                    sql.bind(touch.bundlePath) + "::text", sql.bind(entry.first) + "::timestamptz", sql.bind(touch.seenAt) + "::timestamptz",
                    sql.bind(touch.requestDelta) + "::int8", try sql.bindJSON(touch.geo),
                ]
                sql.append(" (" + values.joined(separator: ", ") + ")")
            }
            sql.append("""
                ) AS v(kind, value, device_id, source_path, source_title, app_id, bundle_path, first_seen, last_seen, request_count, geo)
                LEFT JOIN apps a ON a.id = v.app_id
                ON CONFLICT (kind, value, device_id, source_path) DO UPDATE SET
                    source_title = excluded.source_title,
                    app_id = COALESCE(excluded.app_id, s.app_id),
                    bundle_path = COALESCE(excluded.bundle_path, s.bundle_path),
                    first_seen = LEAST(s.first_seen, excluded.first_seen),
                    last_seen = GREATEST(s.last_seen, excluded.last_seen),
                    request_count = s.request_count + excluded.request_count,
                    geo = COALESCE(excluded.geo, s.geo)
                """)
            statements.append(sql.query)
        }
        try await withTransaction(on: .writer) { [statements] connection in
            for statement in statements { try await connection.query(statement, logger: Self.logger) }
        }
    }

    /// The "Domains & IPs" page: `host_sources` grouped by `(kind, value)`, newest first (by first
    /// seen), at most 2,000 entries. `search` matches the value or a source's title. Sources from site
    /// probes (`probe:<session id>`) carry the session ID and read `Site probe · <host>`.
    func inventory(kind: HostKind?, search: String, scope: DeviceScope) async throws -> [InventoryEntry] {
        var conditions: [String] = []
        var sql = SQL()
        if let kind { conditions.append("s.kind = \(sql.bind(kind.rawValue))") }
        if let device = scope.deviceID { conditions.append("s.device_id = \(sql.bind(device))") }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !term.isEmpty {
            let pattern = sql.bind(Self.containsPattern(term))
            conditions.append("(s.value ILIKE \(pattern) OR (s.kind, s.value) IN (SELECT t.kind, t.value FROM host_sources t WHERE t.source_title ILIKE \(pattern)))")
        }
        sql.append("""
            SELECT s.kind, s.value,
                   jsonb_agg(DISTINCT jsonb_build_object(
                       'title', s.source_title, 'path', s.source_path, 'appID', s.app_id,
                       'bundlePath', s.bundle_path, 'probeHost', ps.host)) AS sources,
                   min(s.first_seen) AS first_seen, max(s.last_seen) AS last_seen,
                   sum(s.request_count)::int8 AS requests,
                   (array_agg(s.geo ORDER BY s.last_seen DESC) FILTER (WHERE s.geo IS NOT NULL))[1] AS geo
            FROM host_sources s
            LEFT JOIN probe_sessions ps ON s.source_path LIKE 'probe:%' AND ps.id::text = lower(substr(s.source_path, 7))
            """)
        if !conditions.isEmpty { sql.append(" WHERE " + conditions.joined(separator: " AND ")) }
        sql.append(" GROUP BY s.kind, s.value ORDER BY min(s.first_seen) DESC, s.value LIMIT 2000")

        struct Source: Decodable {
            var title: String
            var path: String
            var appID: UUID?
            var bundlePath: String?
            var probeHost: String?
        }
        return try await rows(sql.query).map { row in
            let read = PostgresRowReader(row)
            let sources = (try read.json("sources", as: [Source].self) ?? []).map { source in
                guard source.path.hasPrefix("probe:") else {
                    return InventorySource(title: source.title, path: source.path, appID: source.appID, probeSessionID: nil, bundlePath: source.bundlePath)
                }
                return InventorySource(
                    title: source.title,
                    path: source.probeHost.map { "Site probe · \($0)" } ?? source.title,
                    appID: source.appID,
                    probeSessionID: UUID(uuidString: String(source.path.dropFirst("probe:".count))),
                    bundlePath: source.bundlePath
                )
            }.sorted { ($0.title, $0.path) < ($1.title, $1.path) }
            return InventoryEntry(
                kind: HostKind(rawValue: try read("kind", as: String.self)) ?? .domain,
                value: try read("value"),
                sources: sources,
                firstSeen: try read("first_seen"),
                lastSeen: try read("last_seen"),
                requestCount: try read("requests"),
                geo: try read.json("geo", as: GeoInfo.self)
            )
        }
    }

    /// The rows `hostProcesses` reads at most: one per Mac and process that reached the address for the app.
    static let hostProcessRowLimit = 1_000

    /// The processes that reached one of an app's domains or IPs: the app's `host_sources` rows of that address, merged by
    /// executable path in `HostProcess.merge`. A process whose executable reached the address for several apps has one
    /// row per Mac (the table's key has no app), which goes with the app that used it last.
    func hostProcesses(kind: HostKind, value: String, appID: AppID, scope: DeviceScope) async throws -> [HostProcess] {
        let sightings = try await rows(Self.hostProcessSightings(kind: kind, value: value, appID: appID, scope: scope).query).map { row in
            let read = PostgresRowReader(row)
            return HostProcess.Sighting(
                deviceID: try read("device_id"),
                path: try read("source_path"),
                title: try read("source_title"),
                firstSeen: try read("first_seen"),
                lastSeen: try read("last_seen"),
                requestCount: try read("request_count")
            )
        }
        return HostProcess.merge(sightings, scope: scope)
    }

    /// `hostProcesses`' statement: the primary key's `(kind, value)` prefix (`(kind, value, device_id)` with one Mac) reads
    /// only the rows of that address, every app's, a few per process; the most recently seen first, at most
    /// `hostProcessRowLimit`.
    static func hostProcessSightings(kind: HostKind, value: String, appID: AppID, scope: DeviceScope) -> SQL {
        var sql = SQL("""
            SELECT s.device_id, s.source_path, s.source_title, s.first_seen, s.last_seen, s.request_count
            FROM host_sources s WHERE s.kind =
            """)
        sql.append(" " + sql.bind(kind.rawValue) + " AND s.value = " + sql.bind(value))
        if let device = scope.deviceID { sql.append(" AND s.device_id = " + sql.bind(device)) }
        sql.append(" AND s.app_id = " + sql.bind(appID))
        sql.append(" ORDER BY s.last_seen DESC, s.device_id, s.source_path LIMIT \(hostProcessRowLimit)")
        return sql
    }

    // MARK: - IP info

    /// Cached GeoIP data; nil when unknown or when `ip` is not an IP address.
    func ipInfo(_ ip: String) async throws -> GeoInfo? {
        guard let address = Self.inetText(ip) else { return nil }
        guard let row = try await rows("SELECT country_code, asn, organization FROM ip_info WHERE ip = \(address)::inet").first else { return nil }
        let read = PostgresRowReader(row)
        return GeoInfo(countryCode: try read("country_code"), asn: try read("asn", as: Int?.self), organization: try read("organization"))
    }

    /// Caches GeoIP data for an address (ignored when `ip` is not an IP address).
    func saveIPInfo(_ ip: String, geo: GeoInfo) async throws {
        guard let address = Self.inetText(ip) else { return }
        let asn = geo.asn.map { Int32(clamping: $0) }
        try await execute("""
            INSERT INTO ip_info (ip, country_code, asn, organization, updated_at)
            VALUES (\(address)::inet, \(geo.countryCode), \(asn), \(geo.organization), now())
            ON CONFLICT (ip) DO UPDATE SET country_code = excluded.country_code, asn = excluded.asn,
                organization = excluded.organization, updated_at = now()
            """)
    }
}

extension PostgresDatabase {
    /// Primary key of an `app_hosts` row.
    struct AppHostKey: Hashable, Comparable, Sendable {
        var appID: AppID
        var kind: String
        var value: String

        init(appID: AppID, kind: String, value: String) {
            self.appID = appID
            self.kind = kind
            self.value = value
        }

        init(_ host: AppHost) {
            self.init(appID: host.appID, kind: host.kind.rawValue, value: host.value)
        }

        static func < (a: AppHostKey, b: AppHostKey) -> Bool {
            (a.appID.uuidString, a.kind, a.value) < (b.appID.uuidString, b.kind, b.value)
        }
    }
}
