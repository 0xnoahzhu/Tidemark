import Foundation
import PostgresNIO

extension PostgresDatabase {
    // MARK: - Devices

    /// Inserts or updates the device's identity; never touches `row_count`, `last_write_at` or `created_at`.
    func upsertDevice(_ device: Device) async throws {
        try await execute("""
            INSERT INTO devices (id, name, model, short_name, hue, is_remote, created_at)
            VALUES (\(device.id), \(device.name), \(device.model), \(device.shortName), \(device.hue)::real, \(device.isRemoteSurge), \(device.createdAt))
            ON CONFLICT (id) DO UPDATE SET
                name = excluded.name, model = excluded.model, short_name = excluded.short_name,
                hue = excluded.hue, is_remote = excluded.is_remote
            """)
    }

    func devices() async throws -> [Device] {
        try await rows("""
            SELECT id, name, model, short_name, hue, is_remote, row_count, last_write_at, created_at
            FROM devices ORDER BY created_at, name
            """).map { row in
            let read = PostgresRowReader(row)
            return Device(
                id: try read("id"),
                name: try read("name"),
                model: try read("model"),
                shortName: try read("short_name"),
                hue: try read.double("hue"),
                isRemoteSurge: try read("is_remote"),
                rowCount: try read("row_count"),
                lastWriteAt: try read("last_write_at"),
                createdAt: try read("created_at")
            )
        }
    }

    /// Renames a Mac and re-derives its badge label (`Device.shortName(for:)`).
    func renameDevice(_ id: DeviceID, name: String) async throws {
        try await execute("UPDATE devices SET name = \(name), short_name = \(Device.shortName(for: name)) WHERE id = \(id)")
    }

    // MARK: - Apps

    func apps() async throws -> [MonitoredApp] {
        try await rows("""
            SELECT id, name, path, bundle_id, tile_letter, tile_hue, include_children, alert_rule, alert_new_ip, archived_at, created_at
            FROM apps ORDER BY created_at, name
            """).map { row in
            let read = PostgresRowReader(row)
            return MonitoredApp(
                id: try read("id"),
                name: try read("name"),
                path: try read("path"),
                bundleID: try read("bundle_id"),
                tileLetter: try read("tile_letter"),
                tileHue: try read.double("tile_hue"),
                includeChildren: try read("include_children"),
                alertRule: AlertRule(rawValue: try read("alert_rule", as: String.self)) ?? .anyHost,
                alertNewIP: try read("alert_new_ip"),
                archivedAt: try read("archived_at"),
                createdAt: try read("created_at")
            )
        }
    }

    func insertApp(_ app: MonitoredApp) async throws {
        try await execute("""
            INSERT INTO apps (id, name, path, bundle_id, tile_letter, tile_hue, include_children, alert_rule, alert_new_ip, archived_at, created_at, updated_at)
            VALUES (\(app.id), \(app.name), \(app.path), \(app.bundleID), \(app.tileLetter), \(app.tileHue)::real, \(app.includeChildren),
                    \(app.alertRule.rawValue), \(app.alertNewIP), \(app.archivedAt), \(app.createdAt), now())
            """)
    }

    func updateApp(_ app: MonitoredApp) async throws {
        try await execute("""
            UPDATE apps SET name = \(app.name), path = \(app.path), bundle_id = \(app.bundleID), tile_letter = \(app.tileLetter),
                tile_hue = \(app.tileHue)::real, include_children = \(app.includeChildren), alert_rule = \(app.alertRule.rawValue),
                alert_new_ip = \(app.alertNewIP), archived_at = \(app.archivedAt), updated_at = now()
            WHERE id = \(app.id)
            """)
    }

    /// Deleting the row cascades to `app_installs`, `app_hosts` and `alerts`; requests, processes and
    /// host sources keep their rows and lose `app_id` (`ON DELETE SET NULL`).
    ///
    /// The app's requests are detached first, in batches that each commit on their own, so an app with
    /// millions of requests is never rewritten by one statement holding their row locks (and the flush of
    /// its still-active requests) for minutes. Writes that still carry the app's ID afterwards store NULL.
    func deleteApp(_ id: AppID) async throws {
        let batchSize = 10_000
        while true {
            try Task.checkCancellation()
            let detached = try await withTransaction(statementTimeout: Self.maintenanceTimeout) { connection in
                try await connection.query("""
                    WITH batch AS (
                        SELECT id FROM requests WHERE app_id = \(id) LIMIT \(batchSize)
                    ), detached AS (
                        UPDATE requests r SET app_id = NULL FROM batch WHERE r.id = batch.id RETURNING 1
                    )
                    SELECT count(*) AS n FROM detached
                    """, logger: Self.logger).collect().first.map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
            }
            if detached < Int64(batchSize) { break }
            try await Task.sleep(for: Self.maintenancePause)
        }
        try await withTransaction(statementTimeout: Self.maintenanceTimeout) { connection in
            _ = try await connection.query("DELETE FROM apps WHERE id = \(id)", logger: Self.logger).collect()
        }
    }

    /// Records whether the app's bundle exists on the Mac; nothing happens when the app was deleted.
    func setInstalled(appID: AppID, deviceID: DeviceID, installed: Bool) async throws {
        try await execute("""
            INSERT INTO app_installs (app_id, device_id, installed, checked_at)
            SELECT a.id, \(deviceID), \(installed), now() FROM apps a WHERE a.id = \(appID)
            ON CONFLICT (app_id, device_id) DO UPDATE SET installed = excluded.installed, checked_at = now()
            """)
    }

    func installs() async throws -> [AppID: [DeviceID: Bool]] {
        var result: [AppID: [DeviceID: Bool]] = [:]
        for row in try await rows("SELECT app_id, device_id, installed FROM app_installs") {
            let read = PostgresRowReader(row)
            result[try read("app_id", as: UUID.self), default: [:]][try read("device_id", as: UUID.self)] = try read("installed", as: Bool.self)
        }
        return result
    }

    /// Header counters. Inventory counts follow `appHosts(_:scope:)` (a single Mac sees the entries it
    /// reported in `host_sources`); requests and processes are counted for the scope's device.
    func appStats(_ id: AppID, scope: DeviceScope) async throws -> AppStats {
        var sql = SQL("WITH h AS (SELECT h.kind, h.site, h.is_direct, h.first_seen FROM app_hosts h WHERE h.app_id = ")
        let app = sql.bind(id)
        sql.append(app)
        var device: String?
        if let deviceID = scope.deviceID {
            let placeholder = sql.bind(deviceID)
            device = placeholder
            sql.append(" AND \(Self.reportedBy(placeholder))")
        }
        sql.append("""
            )
            SELECT count(*) FILTER (WHERE kind = 'domain') AS domains,
                   count(*) FILTER (WHERE kind = 'ip') AS ips,
                   count(DISTINCT site) FILTER (WHERE kind = 'domain') AS sites,
                   count(*) FILTER (WHERE kind = 'ip' AND is_direct) AS direct_ips,
                   count(*) FILTER (WHERE first_seen > now() - interval '24 hours') AS new_24h,
                   count(*) FILTER (WHERE kind = 'domain' AND first_seen > now() - interval '24 hours') AS new_domains_24h,
                   (SELECT count(*) FROM requests r WHERE r.app_id = \(app)\(device.map { " AND r.device_id = \($0)" } ?? "")) AS requests,
                   (SELECT count(DISTINCT COALESCE(p.path, p.name)) FROM processes p WHERE p.app_id = \(app)\(device.map { " AND p.device_id = \($0)" } ?? "")) AS processes
            FROM h
            """)
        guard let row = try await rows(sql.query).first else { return AppStats() }
        let read = PostgresRowReader(row)
        return AppStats(
            domains: try read("domains", as: Int.self),
            ips: try read("ips", as: Int.self),
            requests: try read("requests", as: Int64.self),
            processes: try read("processes", as: Int.self),
            newIn24h: try read("new_24h", as: Int.self),
            newDomainsIn24h: try read("new_domains_24h", as: Int.self),
            sites: try read("sites", as: Int.self),
            directIPs: try read("direct_ips", as: Int.self)
        )
    }

    /// `app_hosts h` row reported by the device bound at `device` (for device-scoped inventories).
    static func reportedBy(_ device: String) -> String {
        "EXISTS (SELECT 1 FROM host_sources s WHERE s.kind = h.kind AND s.value = h.value AND s.device_id = \(device) AND s.app_id = h.app_id)"
    }

    // MARK: - Backfill

    /// Exact bundle paths (with and without a trailing slash) and a LIKE pattern for paths inside it.
    static func bundleMatch(_ bundlePath: String) -> (paths: [String], pattern: String) {
        var root = bundlePath.trimmingCharacters(in: .whitespacesAndNewlines)
        while root.count > 1, root.hasSuffix("/") { root.removeLast() }
        return ([root, root + "/"], escapeLike(root) + "/%")
    }

    func countRequests(inBundle bundlePath: String) async throws -> Int64 {
        let match = Self.bundleMatch(bundlePath)
        return try await rows("""
            SELECT count(*) AS n FROM requests r WHERE r.bundle_path = ANY(\(match.paths)) OR r.process_path LIKE \(match.pattern)
            """).first.map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
    }

    /// Attributes unattributed requests, processes and host sources inside `bundlePath` to the app, then
    /// rebuilds its inventory from every request attributed to it (domains from hostnames, IPs from
    /// destination addresses or IP-literal hosts; `is_direct` when the host itself was an IP). Existing
    /// inventory rows keep their earliest first-seen time and first Mac. Returns the number of requests
    /// newly attributed.
    ///
    /// Requests are attributed in windows of row IDs, each its own short transaction, so a large history
    /// never sits in one long transaction; the processes, host sources and inventory follow in one
    /// transaction. Running it again picks up where an interrupted run stopped.
    func backfill(appID: AppID, bundlePath: String) async throws -> Int64 {
        let match = Self.bundleMatch(bundlePath)
        let classifier = siteClassifier

        let bounds = try await rows("""
            SELECT min(r.id) AS low, max(r.id) AS high FROM requests r
            WHERE r.app_id IS NULL AND (r.bundle_path = ANY(\(match.paths)) OR r.process_path LIKE \(match.pattern))
            """).first.map { row in
            let read = PostgresRowReader(row)
            return (low: try read("low", as: Int64?.self), high: try read("high", as: Int64?.self))
        }
        var updated: Int64 = 0
        if let low = bounds?.low, let high = bounds?.high {
            let window: Int64 = 50_000
            var start = low
            while start <= high {
                try Task.checkCancellation()
                let (from, end) = (start, start + window)
                updated += try await withTransaction(statementTimeout: Self.maintenanceTimeout) { connection in
                    try await connection.query("""
                        WITH updated AS (
                            UPDATE requests r SET app_id = \(appID)
                            WHERE r.id >= \(from) AND r.id < \(end) AND r.app_id IS NULL
                              AND (r.bundle_path = ANY(\(match.paths)) OR r.process_path LIKE \(match.pattern))
                            RETURNING 1
                        )
                        SELECT count(*) AS n FROM updated
                        """, logger: Self.logger).collect().first.map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
                }
                start = end
            }
        }

        try await withTransaction(statementTimeout: Self.maintenanceTimeout) { connection in
            // The slow reads come first and take no row locks; the writes at the end lock the rows the
            // capture writer also touches only briefly (it waits at most its 5 s lock timeout).
            var hosts: [AppHost] = []
            for row in try await connection.query(Self.backfillDomains(appID), logger: Self.logger).collect() {
                let read = PostgresRowReader(row)
                let value = try read("value", as: String.self)
                hosts.append(AppHost(
                    appID: appID, kind: .domain, value: value, site: classifier.site(for: value),
                    firstSeen: try read("first_seen"), lastSeen: try read("last_seen"), requestCount: try read("n"),
                    processName: try read("process_name"), policy: try read("policy"), geo: try read.json("geo", as: GeoInfo.self),
                    isDirect: false, hosts: [], firstDeviceID: try read("first_device_id")
                ))
            }
            for row in try await connection.query(Self.backfillIPs(appID), logger: Self.logger).collect() {
                let read = PostgresRowReader(row)
                hosts.append(AppHost(
                    appID: appID, kind: .ip, value: try read("value"), site: nil,
                    firstSeen: try read("first_seen"), lastSeen: try read("last_seen"), requestCount: try read("n"),
                    processName: try read("process_name"), policy: try read("policy"), geo: try read.json("geo", as: GeoInfo.self),
                    isDirect: try read("is_direct"), hosts: try read("hosts"), firstDeviceID: try read("first_device_id")
                ))
            }

            try await connection.query("""
                UPDATE processes SET app_id = \(appID) WHERE app_id IS NULL AND path LIKE \(match.pattern)
                """, logger: Self.logger)
            try await connection.query("""
                UPDATE host_sources SET app_id = \(appID)
                WHERE app_id IS NULL AND (bundle_path = ANY(\(match.paths)) OR source_path LIKE \(match.pattern))
                """, logger: Self.logger)
            for chunk in Self.chunks(hosts, bindsPerItem: Self.appHostColumns.count + 1) {
                let statement = try Self.appHostInsert(chunk, conflict: """
                    ON CONFLICT (app_id, kind, value) DO UPDATE SET
                        site = COALESCE(h.site, excluded.site),
                        first_seen = LEAST(h.first_seen, excluded.first_seen),
                        first_device_id = CASE WHEN excluded.first_seen <= h.first_seen THEN COALESCE(excluded.first_device_id, h.first_device_id)
                                               ELSE h.first_device_id END,
                        last_seen = GREATEST(h.last_seen, excluded.last_seen),
                        request_count = GREATEST(h.request_count, excluded.request_count),
                        process_name = COALESCE(h.process_name, excluded.process_name),
                        policy = CASE WHEN excluded.last_seen >= h.last_seen THEN COALESCE(excluded.policy, h.policy) ELSE COALESCE(h.policy, excluded.policy) END,
                        geo = CASE WHEN excluded.last_seen >= h.last_seen THEN COALESCE(excluded.geo, h.geo) ELSE COALESCE(h.geo, excluded.geo) END,
                        is_direct = h.is_direct OR excluded.is_direct,
                        hosts = ARRAY(SELECT DISTINCT x FROM unnest(h.hosts || excluded.hosts) AS x ORDER BY x)
                    """)
                try await connection.query(statement, logger: Self.logger)
            }
        }
        return updated
    }

    /// Per hostname of the app's requests: first/last seen, count, the Mac and process of the first
    /// request, the latest policy and GeoIP. `DISTINCT ON` picks each first/latest value with one sort
    /// instead of building an array of every request per host.
    private static func backfillDomains(_ appID: AppID) -> PostgresQuery {
        """
        WITH base AS MATERIALIZED (
            SELECT r.host AS value, r.started_at, r.device_id, r.process_name, r.policy_path, r.geo
            FROM requests r WHERE r.app_id = \(appID) AND NOT r.is_ip_literal
        ), totals AS (
            SELECT value, min(started_at) AS first_seen, max(started_at) AS last_seen, count(*) AS n FROM base GROUP BY value
        ), first_request AS (
            SELECT DISTINCT ON (value) value, device_id FROM base ORDER BY value, started_at
        ), first_process AS (
            SELECT DISTINCT ON (value) value, process_name FROM base WHERE process_name IS NOT NULL ORDER BY value, started_at
        ), latest_policy AS (
            SELECT DISTINCT ON (value) value, array_to_string(policy_path, ' › ') AS policy FROM base
            WHERE cardinality(policy_path) > 0 ORDER BY value, started_at DESC
        ), latest_geo AS (
            SELECT DISTINCT ON (value) value, geo FROM base WHERE geo IS NOT NULL ORDER BY value, started_at DESC
        )
        SELECT t.value, t.first_seen, t.last_seen, t.n, f.device_id AS first_device_id, p.process_name, l.policy, g.geo
        FROM totals t
        LEFT JOIN first_request f USING (value) LEFT JOIN first_process p USING (value)
        LEFT JOIN latest_policy l USING (value) LEFT JOIN latest_geo g USING (value)
        """
    }

    /// Per destination IP (the resolved address, or the host itself when it was an IP) of the app's
    /// requests, like `backfillDomains`, plus whether it was reached directly and the hostnames behind it.
    private static func backfillIPs(_ appID: AppID) -> PostgresQuery {
        """
        WITH base AS MATERIALIZED (
            SELECT COALESCE(host(r.remote_ip), CASE WHEN r.is_ip_literal THEN r.host END) AS value,
                   r.host, r.is_ip_literal, r.started_at, r.device_id, r.process_name, r.policy_path, r.geo
            FROM requests r WHERE r.app_id = \(appID) AND (r.remote_ip IS NOT NULL OR r.is_ip_literal)
        ), totals AS (
            SELECT value, min(started_at) AS first_seen, max(started_at) AS last_seen, count(*) AS n,
                   bool_or(is_ip_literal) AS is_direct,
                   COALESCE(array_agg(DISTINCT host) FILTER (WHERE NOT is_ip_literal), '{}') AS hosts
            FROM base GROUP BY value
        ), first_request AS (
            SELECT DISTINCT ON (value) value, device_id FROM base ORDER BY value, started_at
        ), first_process AS (
            SELECT DISTINCT ON (value) value, process_name FROM base WHERE process_name IS NOT NULL ORDER BY value, started_at
        ), latest_policy AS (
            SELECT DISTINCT ON (value) value, array_to_string(policy_path, ' › ') AS policy FROM base
            WHERE cardinality(policy_path) > 0 ORDER BY value, started_at DESC
        ), latest_geo AS (
            SELECT DISTINCT ON (value) value, geo FROM base WHERE geo IS NOT NULL ORDER BY value, started_at DESC
        )
        SELECT t.value, t.first_seen, t.last_seen, t.n, t.is_direct, t.hosts, f.device_id AS first_device_id,
               p.process_name, l.policy, g.geo
        FROM totals t
        LEFT JOIN first_request f USING (value) LEFT JOIN first_process p USING (value)
        LEFT JOIN latest_policy l USING (value) LEFT JOIN latest_geo g USING (value)
        """
    }

    // MARK: - Processes

    /// Upserts each link that has a start time (root → leaf) by `(device_id, pid, start_time)`, links
    /// every row to the previous stored link as its parent, bumps `last_seen` and, when `appID` is
    /// given, attributes the whole chain to that app (NULL when the app was deleted meanwhile). Returns the
    /// leaf's row ID.
    @discardableResult
    func upsertProcessChain(deviceID: DeviceID, chain: [ProcessLink], appID: AppID?) async throws -> Int64? {
        var seen = Set<Int32>()
        let links = chain.filter { $0.startTime != nil && seen.insert($0.pid).inserted }
        guard !links.isEmpty else { return nil }

        var insert = SQL("INSERT INTO processes AS p (device_id, pid, start_time, name, path, app_id) SELECT v.device_id, v.pid, v.start_time, v.name, v.path, a.id FROM (VALUES ")
        for (index, link) in links.enumerated() {
            if index > 0 { insert.append(", ") }
            let values = [
                insert.bind(deviceID) + "::uuid", insert.bind(link.pid) + "::int4", insert.bind(link.startTime) + "::timestamptz",
                insert.bind(link.name) + "::text", insert.bind(link.path) + "::text", insert.bind(appID) + "::uuid",
            ]
            insert.append("(" + values.joined(separator: ", ") + ")")
        }
        insert.append("""
            ) AS v(device_id, pid, start_time, name, path, app_id) LEFT JOIN apps a ON a.id = v.app_id
            ON CONFLICT (device_id, pid, start_time) DO UPDATE SET
                name = excluded.name, path = COALESCE(excluded.path, p.path),
                app_id = COALESCE(excluded.app_id, p.app_id), last_seen = now()
            RETURNING p.id, p.pid
            """)
        let insertQuery = insert.query

        return try await withTransaction(on: .writer) { connection in
            var ids: [Int32: Int64] = [:]
            for row in try await connection.query(insertQuery, logger: Self.logger).collect() {
                let read = PostgresRowReader(row)
                ids[try read("pid", as: Int32.self)] = try read("id", as: Int64.self)
            }
            let ordered = links.compactMap { ids[$0.pid] }
            if ordered.count > 1 {
                var link = SQL("UPDATE processes p SET parent_id = v.parent_id FROM (VALUES ")
                for index in 1..<ordered.count {
                    if index > 1 { link.append(", ") }
                    link.append("(\(link.bind(ordered[index]))::int8, \(link.bind(ordered[index - 1]))::int8)")
                }
                link.append(") AS v(id, parent_id) WHERE p.id = v.id AND p.parent_id IS DISTINCT FROM v.parent_id")
                try await connection.query(link.query, logger: Self.logger)
            }
            return ordered.last
        }
    }

    /// The app's processes aggregated by executable lineage (root path → … → path), in depth-first
    /// order with siblings in launch order. Each node shows its latest PID and that PID's Mac, the distinct
    /// domains and requests of all its processes, and `isRunning` when one of them was seen in the last
    /// 5 minutes (the UI refines this for processes of this Mac).
    func processTree(appID: AppID, scope: DeviceScope) async throws -> [ProcessNode] {
        var sql = SQL("WITH RECURSIVE app_procs AS (SELECT id, parent_id, device_id, pid, start_time, name, path, first_seen, last_seen FROM processes WHERE app_id = ")
        sql.append(sql.bind(appID))
        if let device = scope.deviceID { sql.append(" AND device_id = \(sql.bind(device))") }
        sql.append("""
            ), walk AS (
                SELECT p.id, ARRAY[COALESCE(p.path, p.name)] AS lineage
                FROM app_procs p
                WHERE p.parent_id IS NULL OR NOT EXISTS (SELECT 1 FROM app_procs q WHERE q.id = p.parent_id)
                UNION ALL
                SELECT c.id, w.lineage || COALESCE(c.path, c.name)
                FROM walk w JOIN app_procs c ON c.parent_id = w.id
                WHERE cardinality(w.lineage) < 32
            ), grouped AS (
                SELECT w.lineage,
                       array_agg(p.id) AS ids,
                       (array_agg(p.name ORDER BY p.start_time DESC))[1] AS name,
                       (array_agg(p.pid ORDER BY p.start_time DESC))[1] AS pid,
                       (array_agg(p.device_id ORDER BY p.start_time DESC))[1] AS device_id,
                       max(p.start_time) AS start_time,
                       (array_agg(p.path ORDER BY p.start_time DESC))[1] AS path,
                       min(p.first_seen) AS first_seen,
                       max(p.last_seen) > now() - interval '5 minutes' AS running
                FROM walk w JOIN app_procs p ON p.id = w.id
                GROUP BY w.lineage
            )
            SELECT g.lineage, g.name, g.pid, g.device_id, g.start_time, g.path, g.first_seen, g.running,
                   COALESCE(s.domains, 0) AS domains, COALESCE(s.requests, 0) AS requests
            FROM grouped g
            LEFT JOIN LATERAL (
                SELECT count(DISTINCT r.host) FILTER (WHERE NOT r.is_ip_literal) AS domains, count(*) AS requests
                FROM requests r WHERE r.process_id = ANY(g.ids)
            ) s ON true
            """)

        struct Entry {
            var lineage: [String]
            var node: ProcessNode
            var firstSeen: Date
        }
        var entries: [Entry] = []
        for row in try await rows(sql.query) {
            let read = PostgresRowReader(row)
            let lineage = try read("lineage", as: [String].self)
            entries.append(Entry(
                lineage: lineage,
                node: ProcessNode(
                    id: lineage.joined(separator: "\n"),
                    name: try read("name"),
                    pid: try read("pid"),
                    startTime: try read("start_time"),
                    path: try read("path"),
                    depth: lineage.count - 1,
                    domainCount: try read("domains", as: Int.self),
                    requestCount: try read("requests", as: Int64.self),
                    isRunning: try read("running"),
                    deviceID: try read("device_id")
                ),
                firstSeen: try read("first_seen")
            ))
        }

        // Depth-first walk; entries whose parent lineage is missing are treated as roots.
        let known = Set(entries.map(\.lineage))
        var children: [[String]: [Entry]] = [:]
        var roots: [Entry] = []
        for entry in entries {
            let parent = Array(entry.lineage.dropLast())
            if !parent.isEmpty, known.contains(parent) { children[parent, default: []].append(entry) } else { roots.append(entry) }
        }
        let launchOrder: (Entry, Entry) -> Bool = { a, b in
            a.firstSeen != b.firstSeen ? a.firstSeen < b.firstSeen : a.node.name.localizedStandardCompare(b.node.name) == .orderedAscending
        }
        var ordered: [ProcessNode] = []
        var stack = roots.sorted(by: launchOrder).reversed().map { ($0, 0) }
        while let (entry, depth) = stack.popLast() {
            var node = entry.node
            node.depth = depth
            ordered.append(node)
            for child in (children[entry.lineage] ?? []).sorted(by: launchOrder).reversed() {
                stack.append((child, depth + 1))
            }
        }
        return ordered
    }
}
