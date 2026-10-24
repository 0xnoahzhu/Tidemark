import Foundation
import PostgresNIO

extension PostgresDatabase {
    // MARK: - Upsert

    /// Columns written by `upsertRequests`, in `VALUES` order, with the cast each placeholder gets.
    /// `leaf_pid` / `leaf_start` identify the chain's leaf process to resolve `process_id`.
    private static let requestValueColumns: [(name: String, cast: String)] = [
        ("device_id", "uuid"), ("surge_session", "int8"), ("surge_id", "int8"), ("started_at", "timestamptz"),
        ("setup_completed_at", "timestamptz"), ("completed_at", "timestamptz"), ("method", "text"), ("host", "text"),
        ("port", "int4"), ("url", "text"), ("is_ip_literal", "bool"), ("remote_ip", "inet"), ("remote_address", "text"),
        ("geo", "jsonb"), ("policy", "text"), ("policy_path", "text[]"), ("rule", "text"), ("state", "text"),
        ("in_bytes", "int8"), ("out_bytes", "int8"), ("pid", "int4"), ("process_name", "text"), ("process_path", "text"),
        ("bundle_path", "text"), ("chain", "jsonb"), ("app_id", "uuid"), ("is_new", "bool"), ("local_address", "text"),
        ("interface", "text"), ("notes", "text[]"), ("probe_session_id", "uuid"), ("leaf_pid", "int4"), ("leaf_start", "timestamptz"),
    ]

    /// How a re-written request merges into the stored row. Values that can only grow or settle
    /// (bytes, completion, terminal state, attribution, first-contact flag) never regress, so batches
    /// replayed out of order from the offline spool cannot undo newer data. `written_at` keeps the
    /// first write; `updated_at` marks every write for `requestsWritten(after:)`.
    private static let requestMergeSQL = """
        started_at = excluded.started_at,
        setup_completed_at = COALESCE(excluded.setup_completed_at, r.setup_completed_at),
        completed_at = COALESCE(excluded.completed_at, r.completed_at),
        method = excluded.method,
        host = excluded.host,
        port = COALESCE(excluded.port, r.port),
        url = COALESCE(excluded.url, r.url),
        is_ip_literal = excluded.is_ip_literal,
        remote_ip = COALESCE(excluded.remote_ip, r.remote_ip),
        remote_address = COALESCE(excluded.remote_address, r.remote_address),
        geo = COALESCE(excluded.geo, r.geo),
        policy = COALESCE(excluded.policy, r.policy),
        policy_path = CASE WHEN cardinality(excluded.policy_path) > 0 THEN excluded.policy_path ELSE r.policy_path END,
        rule = COALESCE(excluded.rule, r.rule),
        state = CASE WHEN excluded.state = 'active' AND r.state <> 'active' THEN r.state ELSE excluded.state END,
        in_bytes = GREATEST(r.in_bytes, excluded.in_bytes),
        out_bytes = GREATEST(r.out_bytes, excluded.out_bytes),
        pid = COALESCE(excluded.pid, r.pid),
        process_id = COALESCE(excluded.process_id, r.process_id),
        process_name = COALESCE(excluded.process_name, r.process_name),
        process_path = COALESCE(excluded.process_path, r.process_path),
        bundle_path = COALESCE(excluded.bundle_path, r.bundle_path),
        chain = CASE WHEN jsonb_array_length(excluded.chain) > 0 THEN excluded.chain ELSE r.chain END,
        app_id = COALESCE(excluded.app_id, r.app_id),
        is_new = r.is_new OR excluded.is_new,
        local_address = COALESCE(excluded.local_address, r.local_address),
        interface = COALESCE(excluded.interface, r.interface),
        notes = CASE WHEN cardinality(excluded.notes) >= cardinality(r.notes) THEN excluded.notes ELSE r.notes END,
        probe_session_id = COALESCE(excluded.probe_session_id, r.probe_session_id),
        updated_at = now()
        """

    /// Upserts requests by `(device_id, surge_session, surge_id)` in one transaction, in multi-row
    /// statements below the bind limit, then adds the number of new rows to each device's `row_count`.
    ///
    /// `process_id` is resolved from the chain's leaf `(pid, startTime)` when `upsertProcessChain`
    /// already stored that process. Duplicate keys inside one batch are merged first (PostgreSQL
    /// refuses to update the same row twice in one statement).
    @discardableResult
    func upsertRequests(_ rows: [RequestRecord]) async throws -> [RequestKey: Int64] {
        guard !rows.isEmpty else { return [:] }
        let batch = Self.coalesced(rows)
        var statements: [PostgresQuery] = []
        for chunk in Self.chunks(batch, bindsPerItem: Self.requestValueColumns.count) {
            statements.append(try Self.requestUpsertStatement(chunk))
        }
        let devices = Set(batch.map(\.key.deviceID))

        return try await withTransaction { [statements] connection in
            var ids: [RequestKey: Int64] = [:]
            ids.reserveCapacity(batch.count)
            var inserted: [DeviceID: Int64] = [:]
            for statement in statements {
                for row in try await connection.query(statement, logger: Self.logger).collect() {
                    let read = PostgresRowReader(row)
                    let key = RequestKey(
                        deviceID: try read("device_id", as: UUID.self),
                        session: try read("surge_session", as: Int64.self),
                        surgeID: try read("surge_id", as: Int64.self)
                    )
                    ids[key] = try read("id", as: Int64.self)
                    if try read("inserted", as: Bool.self) { inserted[key.deviceID, default: 0] += 1 }
                }
            }
            var bump = SQL("UPDATE devices d SET row_count = d.row_count + v.n, last_write_at = now() FROM (VALUES ")
            for (index, device) in devices.sorted(by: { $0.uuidString < $1.uuidString }).enumerated() {
                if index > 0 { bump.append(", ") }
                bump.append("(\(bump.bind(device))::uuid, \(bump.bind(inserted[device] ?? 0))::int8)")
            }
            bump.append(") AS v(id, n) WHERE d.id = v.id")
            try await connection.query(bump.query, logger: Self.logger)
            return ids
        }
    }

    private static func requestUpsertStatement(_ chunk: ArraySlice<RequestRecord>) throws -> PostgresQuery {
        let names = requestValueColumns.map(\.name)
        let insertColumns = names.filter { $0 != "leaf_pid" && $0 != "leaf_start" }
        var sql = SQL("INSERT INTO requests AS r (\(insertColumns.joined(separator: ", ")), process_id) SELECT ")
        sql.append(insertColumns.map { "v.\($0)" }.joined(separator: ", "))
        sql.append(", p.id FROM (VALUES ")
        for (index, record) in chunk.enumerated() {
            if index > 0 { sql.append(", ") }
            let leaf = record.chain.last
            let leafStart = leaf?.startTime
            let processName: String? = record.chain.isEmpty && record.processPath == nil ? nil : record.processName
            let placeholders: [String] = [
                sql.bind(record.key.deviceID),
                sql.bind(record.key.session),
                sql.bind(record.key.surgeID),
                sql.bind(record.startedAt),
                sql.bind(record.setupCompletedAt),
                sql.bind(record.completedAt),
                sql.bind(record.method),
                sql.bind(record.host),
                sql.bind(record.port),
                sql.bind(record.url),
                sql.bind(record.isIPLiteral),
                sql.bind(inetText(record.remoteIP)),
                sql.bind(record.remoteAddress),
                sql.bind(try record.geo.map { try jsonText($0) }),
                sql.bind(record.finalPolicy),
                sql.bind(record.policyPath),
                sql.bind(record.rule),
                sql.bind(record.state.rawValue),
                sql.bind(record.inBytes),
                sql.bind(record.outBytes),
                sql.bind(record.pid),
                sql.bind(processName),
                sql.bind(record.processPath),
                sql.bind(record.bundlePath),
                sql.bind(try jsonText(record.chain)),
                sql.bind(record.appID),
                sql.bind(record.isNew),
                sql.bind(record.localAddress),
                sql.bind(record.interface),
                sql.bind(record.notes),
                sql.bind(record.probeSessionID),
                sql.bind(leafStart == nil ? nil : leaf?.pid),
                sql.bind(leafStart),
            ]
            let row = zip(placeholders, requestValueColumns).map { "\($0)::\($1.cast)" }
            sql.append("(" + row.joined(separator: ", ") + ")")
        }
        sql.append(") AS v(\(names.joined(separator: ", "))) ")
        sql.append("LEFT JOIN processes p ON p.device_id = v.device_id AND p.pid = v.leaf_pid AND p.start_time = v.leaf_start ")
        sql.append("ON CONFLICT (device_id, surge_session, surge_id) DO UPDATE SET \(requestMergeSQL) ")
        sql.append("RETURNING r.id, r.device_id, r.surge_session, r.surge_id, (r.xmax = 0) AS inserted")
        return sql.query
    }

    /// One record per key, sorted by key so concurrent batches lock rows in the same order.
    private static func coalesced(_ rows: [RequestRecord]) -> [RequestRecord] {
        var merged: [RequestKey: RequestRecord] = [:]
        merged.reserveCapacity(rows.count)
        for row in rows {
            if let earlier = merged[row.key] {
                var later = row
                later.isNew = later.isNew || earlier.isNew
                later.appID = later.appID ?? earlier.appID
                later.remoteIP = later.remoteIP ?? earlier.remoteIP
                later.geo = later.geo ?? earlier.geo
                later.completedAt = later.completedAt ?? earlier.completedAt
                later.setupCompletedAt = later.setupCompletedAt ?? earlier.setupCompletedAt
                if later.chain.isEmpty { later.chain = earlier.chain }
                if later.policyPath.isEmpty { later.policyPath = earlier.policyPath }
                merged[row.key] = later
            } else {
                merged[row.key] = row
            }
        }
        return merged.values.sorted { a, b in
            if a.key.deviceID != b.key.deviceID { return a.key.deviceID.uuidString < b.key.deviceID.uuidString }
            if a.key.session != b.key.session { return a.key.session < b.key.session }
            return a.key.surgeID < b.key.surgeID
        }
    }

    // MARK: - Reads

    static let requestSelect = """
        r.id, r.device_id, r.surge_session, r.surge_id, r.started_at, r.setup_completed_at, r.completed_at,
        r.method, r.host, r.port, r.url, host(r.remote_ip) AS remote_ip, r.remote_address, r.geo, r.policy_path,
        r.rule, r.state, r.in_bytes, r.out_bytes, r.pid, r.process_path, r.bundle_path, r.chain, r.app_id,
        r.local_address, r.interface, r.notes, r.is_new, r.updated_at, r.probe_session_id
        """

    /// Decodes a row selected with `requestSelect`. `writtenAt` is the time of the row's latest write
    /// (`updated_at`), the cursor for `requestsWritten(after:)`.
    static func decodeRequest(_ row: PostgresRow) throws -> RequestRecord {
        let read = PostgresRowReader(row)
        return RequestRecord(
            key: RequestKey(
                deviceID: try read("device_id"),
                session: try read("surge_session"),
                surgeID: try read("surge_id")
            ),
            rowID: try read("id", as: Int64.self),
            startedAt: try read("started_at"),
            setupCompletedAt: try read("setup_completed_at"),
            completedAt: try read("completed_at"),
            method: try read("method"),
            host: try read("host"),
            port: try read("port", as: Int?.self),
            url: try read("url"),
            remoteIP: try read("remote_ip"),
            remoteAddress: try read("remote_address"),
            geo: try read.json("geo", as: GeoInfo.self),
            policyPath: try read("policy_path"),
            rule: try read("rule"),
            state: RequestState(rawValue: try read("state", as: String.self)) ?? .active,
            inBytes: try read("in_bytes"),
            outBytes: try read("out_bytes"),
            pid: try read("pid", as: Int32?.self),
            processPath: try read("process_path"),
            bundlePath: try read("bundle_path"),
            chain: try read.json("chain", as: [ProcessLink].self) ?? [],
            appID: try read("app_id"),
            localAddress: try read("local_address"),
            interface: try read("interface"),
            notes: try read("notes"),
            isNew: try read("is_new"),
            writtenAt: try read("updated_at", as: Date.self),
            probeSessionID: try read("probe_session_id")
        )
    }

    /// Appends ` WHERE …` for a request query (`r` aliases `requests`).
    private static func appendFilters(_ query: RequestQuery, lowerBound: Date?, to sql: inout SQL) {
        var conditions: [String] = []
        if let device = query.scope.deviceID { conditions.append("r.device_id = \(sql.bind(device))") }
        if let lowerBound { conditions.append("r.started_at >= \(sql.bind(lowerBound))") }
        if let app = query.appID { conditions.append("r.app_id = \(sql.bind(app))") }
        if let policy = query.policy { conditions.append("r.policy = \(sql.bind(policy))") }
        switch query.status {
        case .any: break
        case .completed: conditions.append("r.state = 'completed'")
        case .active: conditions.append("r.state = 'active'")
        case .failed: conditions.append("r.state IN ('failed', 'rejected')")
        }
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let p = sql.bind(containsPattern(search))
            conditions.append("""
                (r.host ILIKE \(p) OR r.process_name ILIKE \(p) OR host(r.remote_ip) ILIKE \(p) OR r.bundle_path ILIKE \(p) \
                OR r.app_id IN (SELECT a.id FROM apps a WHERE a.name ILIKE \(p)))
                """)
        }
        if !conditions.isEmpty { sql.append(" WHERE " + conditions.joined(separator: " AND ")) }
    }

    /// Rows newest first with a total. The total is exact up to 100,000 matches; beyond that (and for
    /// the unfiltered "All time" view) it comes from the planner / table statistics.
    func queryRequests(_ query: RequestQuery) async throws -> RequestPage {
        let clock = ContinuousClock()
        let start = clock.now
        let lowerBound = query.range.lowerBound()

        var select = SQL("SELECT \(Self.requestSelect) FROM requests r")
        Self.appendFilters(query, lowerBound: lowerBound, to: &select)
        select.append(" ORDER BY r.started_at DESC, r.id DESC LIMIT \(select.bind(max(0, query.limit))) OFFSET \(select.bind(max(0, query.offset)))")
        let rowsQuery = select.query

        async let page = rows(rowsQuery)
        async let total = totalCount(for: query, lowerBound: lowerBound)
        let records = try await page.map(Self.decodeRequest)
        let count = try await total
        return RequestPage(rows: records, totalCount: max(count, Int64(query.offset + records.count)), elapsed: start.duration(to: clock.now))
    }

    private static let exactCountCap: Int64 = 100_000

    private func totalCount(for query: RequestQuery, lowerBound: Date?) async throws -> Int64 {
        let unfiltered = lowerBound == nil && query.appID == nil && query.policy == nil && query.status == .any
            && query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if unfiltered {
            switch query.scope {
            case .all:
                return try await estimatedRequestCount()
            case .device(let id):
                let rows = try await rows("SELECT row_count FROM devices WHERE id = \(id)")
                if let row = rows.first { return try PostgresRowReader(row)("row_count", as: Int64.self) }
                return 0
            }
        }

        var count = SQL("SELECT count(*) AS n FROM (SELECT 1 FROM requests r")
        Self.appendFilters(query, lowerBound: lowerBound, to: &count)
        count.append(" LIMIT \(Self.exactCountCap + 1)) AS capped")
        let exact = try await rows(count.query).first.map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
        guard exact > Self.exactCountCap else { return exact }

        var explain = SQL("EXPLAIN (FORMAT JSON) SELECT 1 FROM requests r")
        Self.appendFilters(query, lowerBound: lowerBound, to: &explain)
        let plan = try await rows(explain.query).first.map { try PostgresRowReader($0)("QUERY PLAN", as: String.self) } ?? "[]"
        return max(exact, Self.plannedRows(fromExplainJSON: plan) ?? exact)
    }

    /// `Plan Rows` of the top plan node in `EXPLAIN (FORMAT JSON)` output.
    static func plannedRows(fromExplainJSON json: String) -> Int64? {
        struct Entry: Decodable {
            struct Plan: Decodable {
                var rows: Double
                enum CodingKeys: String, CodingKey { case rows = "Plan Rows" }
            }
            var plan: Plan
            enum CodingKeys: String, CodingKey { case plan = "Plan" }
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: Data(json.utf8)), let first = entries.first else { return nil }
        return Int64(first.plan.rows)
    }

    /// `buckets` equal slices from the range's lower bound (or the oldest matching request for
    /// "All time") to now.
    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram {
        let end = Date.now
        guard buckets > 0 else { return Histogram(start: end, end: end, counts: []) }

        var lowerBound = query.range.lowerBound(now: end)
        if lowerBound == nil {
            var oldest = SQL("SELECT min(r.started_at) AS oldest FROM requests r")
            Self.appendFilters(query, lowerBound: nil, to: &oldest)
            lowerBound = try await rows(oldest.query).first.flatMap { try PostgresRowReader($0)("oldest", as: Date?.self) }
        }
        guard let start = lowerBound, start < end else {
            return Histogram(start: end, end: end, counts: Array(repeating: 0, count: buckets))
        }

        // Clamped to 1…buckets: the row that defines `start` can land just below it after the round trip
        // through `Date` (float rounding), and `width_bucket` would then report bucket 0.
        var sql = SQL("SELECT GREATEST(LEAST(width_bucket(extract(epoch FROM r.started_at)::float8, ")
        let low = sql.bind(start.timeIntervalSince1970)
        let high = sql.bind(end.timeIntervalSince1970)
        let count = sql.bind(buckets)
        sql.append("\(low)::float8, \(high)::float8, \(count)::int4), \(count)::int4), 1) AS bucket, count(*) AS n FROM requests r")
        Self.appendFilters(query, lowerBound: start, to: &sql)
        sql.append(" GROUP BY bucket")

        var counts = Array(repeating: Int64(0), count: buckets)
        for row in try await rows(sql.query) {
            let read = PostgresRowReader(row)
            let bucket = try read("bucket", as: Int.self)
            if (1...buckets).contains(bucket) { counts[bucket - 1] += try read("n", as: Int64.self) }
        }
        return Histogram(start: start, end: end, counts: counts)
    }

    /// Rows written or updated after `cursor` by other Macs, newest first. Rows carry their latest
    /// write time in `writtenAt`; poll with a small overlap (e.g. `cursor - 2 s`) and dedupe by key,
    /// because `updated_at` is the writing transaction's start time and a long transaction can commit
    /// rows that are slightly older than rows already seen.
    func requestsWritten(after cursor: Date, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] {
        var sql = SQL("SELECT \(Self.requestSelect) FROM requests r WHERE r.updated_at > ")
        sql.append(sql.bindInstant(cursor))
        if let excluding { sql.append(" AND r.device_id <> \(sql.bind(excluding))") }
        sql.append(" ORDER BY r.updated_at DESC, r.id DESC LIMIT \(sql.bind(max(0, limit)))")
        return try await rows(sql.query).map(Self.decodeRequest)
    }

    /// Final policies seen since `since` (all time when nil), sorted by name.
    func distinctPolicies(since: Date?) async throws -> [String] {
        var sql = SQL("SELECT DISTINCT r.policy FROM requests r WHERE r.policy IS NOT NULL")
        if let since { sql.append(" AND r.started_at >= \(sql.bind(since))") }
        sql.append(" ORDER BY r.policy")
        return try await rows(sql.query).map { try PostgresRowReader($0)("policy", as: String.self) }
    }

    func countRequests(since: Date, scope: DeviceScope) async throws -> Int64 {
        var sql = SQL("SELECT count(*) AS n FROM requests r WHERE r.started_at >= ")
        sql.append(sql.bind(since))
        if let device = scope.deviceID { sql.append(" AND r.device_id = \(sql.bind(device))") }
        return try await rows(sql.query).first.map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
    }

    /// The planner's live estimate (`reltuples` scaled to the table's current size, as the planner
    /// does); exact `count(*)` when the estimate is below 100,000 or unknown (never analyzed).
    func estimatedRequestCount() async throws -> Int64 {
        let estimate = try await rows("""
            SELECT CASE WHEN c.reltuples < 0 OR c.relpages = 0 THEN -1::int8
                        ELSE (c.reltuples / c.relpages * (pg_relation_size(c.oid) / current_setting('block_size')::int8))::int8
                   END AS estimate
            FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
            WHERE n.nspname = \(schema) AND c.relname = 'requests' AND c.relkind = 'r'
            """).first.map { try PostgresRowReader($0)("estimate", as: Int64.self) } ?? -1
        if estimate >= 100_000 { return estimate }
        return try await rows("SELECT count(*) AS n FROM requests").first.map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
    }

    /// Deletes requests that started before `olderThan` (only `deviceID`'s when given) in batches of 10,000
    /// (each its own transaction, so retention never holds long locks) and lowers each device's `row_count`.
    func deleteRequests(olderThan: Date, deviceID: DeviceID?) async throws -> Int64 {
        let batchSize = 10_000
        var total: Int64 = 0
        while true {
            try Task.checkCancellation()
            let deleted = try await rows("""
                WITH doomed AS (
                    SELECT id FROM requests
                    WHERE started_at < \(olderThan) AND (\(deviceID)::uuid IS NULL OR device_id = \(deviceID)::uuid)
                    ORDER BY started_at LIMIT \(batchSize)
                ), gone AS (
                    DELETE FROM requests r USING doomed WHERE r.id = doomed.id RETURNING r.device_id
                ), counts AS (
                    SELECT device_id, count(*) AS n FROM gone GROUP BY device_id
                ), adjusted AS (
                    UPDATE devices d SET row_count = GREATEST(0, d.row_count - counts.n) FROM counts WHERE d.id = counts.device_id
                )
                SELECT COALESCE(sum(n), 0)::int8 AS n FROM counts
                """).first.map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
            total += deleted
            if deleted < Int64(batchSize) { return total }
        }
    }
}
