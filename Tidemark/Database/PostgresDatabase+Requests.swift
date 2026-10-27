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
        ("interface", "text"), ("notes", "text[]"), ("probe_session_id", "uuid"),
        ("timing", "jsonb"), ("entry_mode", "int2"), ("original_policy", "text"), ("modified", "bool"), ("end_reason", "text"),
        ("remote_ip_source", "text"), ("remote_ip_resolved_at", "timestamptz"),
        ("leaf_pid", "int4"), ("leaf_start", "timestamptz"),
    ]

    /// How a re-written request merges into the stored row. Values that can only grow or settle
    /// (bytes, completion, terminal state, attribution, first-contact flag) never regress, so batches
    /// replayed out of order from the offline spool cannot undo newer data. `written_at` keeps the
    /// first write; `updated_at` marks every write for `requestsWritten(after:)`.
    ///
    /// The v4 columns keep a stored value when a write has none: rows spooled by an earlier build carry none
    /// (an earlier build's own upserts never name them). Where `remote_ip` came from follows `remote_ip`: a
    /// write that keeps the address keeps its source unless it names one, and a write of another address
    /// without a source (an earlier build's) leaves the source unknown rather than wrong.
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
        timing = COALESCE(excluded.timing, r.timing),
        entry_mode = COALESCE(excluded.entry_mode, r.entry_mode),
        original_policy = COALESCE(excluded.original_policy, r.original_policy),
        modified = COALESCE(excluded.modified, r.modified),
        end_reason = COALESCE(excluded.end_reason, r.end_reason),
        remote_ip_source = CASE WHEN excluded.remote_ip IS NULL THEN r.remote_ip_source
                                WHEN excluded.remote_ip = r.remote_ip THEN COALESCE(excluded.remote_ip_source, r.remote_ip_source)
                                ELSE excluded.remote_ip_source END,
        remote_ip_resolved_at = CASE WHEN excluded.remote_ip IS NULL THEN r.remote_ip_resolved_at
                                     WHEN excluded.remote_ip = r.remote_ip THEN COALESCE(excluded.remote_ip_resolved_at, r.remote_ip_resolved_at)
                                     ELSE excluded.remote_ip_resolved_at END,
        updated_at = now()
        """

    /// Upserts requests by `(device_id, surge_session, surge_id)` in one transaction, in multi-row
    /// statements below the bind limit, then adds the number of new rows to each device's `row_count`.
    ///
    /// `process_id` is resolved from the chain's leaf `(pid, startTime)` when `upsertProcessChain`
    /// already stored that process. An `appID` whose app was deleted (possibly by another Mac) is written
    /// as NULL instead of failing the batch on the foreign key. Duplicate keys inside one batch are merged
    /// first (PostgreSQL refuses to update the same row twice in one statement).
    @discardableResult
    func upsertRequests(_ rows: [RequestRecord]) async throws -> [RequestKey: Int64] {
        try await upsertRequestsCountingInserts(rows).ids
    }

    /// `upsertRequests`, also reporting how many rows were new (PostgreSQL's `xmax = 0` on the returned row).
    func upsertRequestsCountingInserts(_ rows: [RequestRecord]) async throws -> RequestUpsertResult {
        guard !rows.isEmpty else { return RequestUpsertResult(ids: [:], inserted: 0) }
        let batch = Self.coalesced(rows)
        var statements: [PostgresQuery] = []
        for chunk in Self.chunks(batch, bindsPerItem: Self.requestValueColumns.count) {
            statements.append(try Self.requestUpsertStatement(chunk))
        }
        let devices = Set(batch.map(\.key.deviceID))

        return try await withTransaction(on: .writer) { [statements] connection in
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
            return RequestUpsertResult(ids: ids, inserted: Int(inserted.values.reduce(0, +)))
        }
    }

    /// Marks `deviceID`'s rows that are still `active` from Surge sessions before `session` completed, and
    /// bumps `updated_at` so other Macs see the change. Runs whenever capture starts a session (every launch
    /// and every Surge restart).
    ///
    /// A completion time already stored is kept. Otherwise the request ended some time after Tidemark last
    /// wrote it (`updated_at`, its last observed change; in an `UPDATE` it still holds the previous write)
    /// and no later than `date` (the new session's start), so the earlier of the two is stored, never a time
    /// before the request started. `requests_active_idx` (v3) keeps the statement to the few rows still
    /// active; its time limit stays below capture's per-write bound.
    func closeActiveRequests(deviceID: DeviceID, before session: Int64, at date: Date) async throws -> Int64 {
        var sql = SQL()
        Self.appendCloseActive(deviceID: deviceID, before: session, at: date, to: &sql)
        return try await sessionClose(sql)
    }

    /// Marks `deviceID`'s rows of `session` that are still `active` but that Surge no longer lists completed,
    /// with the same completion estimate as `closeActiveRequests` (the last write, at most `date`). Rows that
    /// started at or after `startedBefore` are left alone. Reads only the session's active rows
    /// (`requests_active_idx`).
    func closeVanishedRequests(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date, at date: Date) async throws -> Int64 {
        var sql = SQL()
        Self.appendCloseVanished(deviceID: deviceID, session: session, keeping: surgeIDs, startedBefore: startedBefore, at: date, to: &sql)
        return try await sessionClose(sql)
    }

    /// The rows `closeVanishedRequests` would close, counted on the same index.
    func countVanishedRequests(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date) async throws -> Int64 {
        var sql = SQL("SELECT count(*) AS n FROM requests")
        Self.appendVanishedCondition(deviceID: deviceID, session: session, keeping: surgeIDs, startedBefore: startedBefore, to: &sql)
        return try await rows(sql.query, statementTimeout: Self.sessionCloseTimeout).first
            .map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
    }

    /// Runs a statement of `appendCloseActive` / `appendCloseVanished` and returns the rows it closed.
    private func sessionClose(_ sql: SQL) async throws -> Int64 {
        try await withTransaction(statementTimeout: Self.sessionCloseTimeout) { connection in
            try await connection.query(sql.query, logger: Self.logger).collect().first
                .map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
        }
    }

    /// Appends the `closeActiveRequests` statement. Its condition is `requests_active_idx`'s: the device, the
    /// partial index's `state = 'active'` and a range of the index's Surge sessions.
    static func appendCloseActive(deviceID: DeviceID, before session: Int64, at date: Date, to sql: inout SQL) {
        let completion = completionEstimate(at: date, in: &sql)
        let device = sql.bind(deviceID)
        let before = sql.bind(session)
        sql.append("WITH closed AS (UPDATE requests SET state = 'completed', updated_at = now(), completed_at = \(completion)")
        sql.append(" WHERE device_id = \(device) AND state = 'active' AND surge_session < \(before)")
        sql.append(" RETURNING 1) SELECT count(*) AS n FROM closed")
    }

    /// Appends the `closeVanishedRequests` statement.
    static func appendCloseVanished(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date, at date: Date,
                                    to sql: inout SQL) {
        let completion = completionEstimate(at: date, in: &sql)
        sql.append("WITH closed AS (UPDATE requests SET state = 'completed', updated_at = now(), completed_at = \(completion)")
        appendVanishedCondition(deviceID: deviceID, session: session, keeping: surgeIDs, startedBefore: startedBefore, to: &sql)
        sql.append(" RETURNING 1) SELECT count(*) AS n FROM closed")
    }

    /// ` WHERE …` for `deviceID`'s rows of `session` still active, started before `startedBefore` and not in
    /// `surgeIDs`; `requests_active_idx` finds the session's active rows.
    private static func appendVanishedCondition(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date,
                                                to sql: inout SQL) {
        let device = sql.bind(deviceID)
        let surgeSession = sql.bind(session)
        let before = sql.bind(startedBefore)
        let kept = sql.bind(surgeIDs)
        sql.append(" WHERE device_id = \(device) AND surge_session = \(surgeSession) AND state = 'active'")
        sql.append(" AND started_at < \(before) AND NOT (surge_id = ANY(\(kept)::int8[]))")
    }

    /// `completed_at` of a request closed without having been seen to end: a stored completion is kept;
    /// otherwise the row's last write by Tidemark (`updated_at`, its last observed change; in an `UPDATE` it
    /// still holds the previous write), capped at `date` and never before the request started.
    private static func completionEstimate(at date: Date, in sql: inout SQL) -> String {
        "COALESCE(completed_at, GREATEST(started_at, LEAST(updated_at, \(sql.bind(date))::timestamptz)))"
    }

    /// Statement timeout of `closeActiveRequests` / `closeVanishedRequests` / `countVanishedRequests`: below
    /// capture's 20 s bound per write, so the server stops a statement capture gave up on.
    static let sessionCloseTimeout: Duration = .seconds(15)

    private static func requestUpsertStatement(_ chunk: ArraySlice<RequestRecord>) throws -> PostgresQuery {
        let names = requestValueColumns.map(\.name)
        let insertColumns = names.filter { $0 != "leaf_pid" && $0 != "leaf_start" }
        var sql = SQL("INSERT INTO requests AS r (\(insertColumns.joined(separator: ", ")), process_id) SELECT ")
        // A deleted app's ID becomes NULL (the LEFT JOIN finds no app) instead of violating the foreign key.
        sql.append(insertColumns.map { $0 == "app_id" ? "a.id" : "v.\($0)" }.joined(separator: ", "))
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
                sql.bind(try record.timing.flatMap { $0.isEmpty ? nil : try jsonText($0) }),
                sql.bind(record.entryMode.map { Int16(clamping: $0) }),
                sql.bind(record.originalPolicy),
                sql.bind(record.modified),
                sql.bind(record.endReason),
                sql.bind(record.remoteIPSource?.rawValue),
                sql.bind(record.remoteIPResolvedAt),
                sql.bind(leafStart == nil ? nil : leaf?.pid),
                sql.bind(leafStart),
            ]
            let row = zip(placeholders, requestValueColumns).map { "\($0)::\($1.cast)" }
            sql.append("(" + row.joined(separator: ", ") + ")")
        }
        sql.append(") AS v(\(names.joined(separator: ", "))) ")
        sql.append("LEFT JOIN processes p ON p.device_id = v.device_id AND p.pid = v.leaf_pid AND p.start_time = v.leaf_start ")
        sql.append("LEFT JOIN apps a ON a.id = v.app_id ")
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
                if later.remoteIP == earlier.remoteIP, later.remoteIPSource == nil {
                    later.remoteIPSource = earlier.remoteIPSource
                    later.remoteIPResolvedAt = later.remoteIPResolvedAt ?? earlier.remoteIPResolvedAt
                }
                later.timing = later.timing ?? earlier.timing
                later.entryMode = later.entryMode ?? earlier.entryMode
                later.originalPolicy = later.originalPolicy ?? earlier.originalPolicy
                later.modified = later.modified ?? earlier.modified
                later.endReason = later.endReason ?? earlier.endReason
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
        r.local_address, r.interface, r.notes, r.is_new, r.updated_at, r.probe_session_id,
        r.timing, r.entry_mode, r.original_policy, r.modified, r.end_reason, r.remote_ip_source, r.remote_ip_resolved_at
        """

    /// Decodes a row selected with `requestSelect`. `writtenAt` is the time of the row's latest write
    /// (`updated_at`); with `rowID` it is the row's position for `requestsWritten(after:)`.
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
            probeSessionID: try read("probe_session_id"),
            timing: try read.json("timing", as: [RequestTimingRecord].self),
            entryMode: try read("entry_mode", as: Int16?.self).map(Int.init),
            originalPolicy: try read("original_policy"),
            modified: try read("modified"),
            endReason: try read("end_reason"),
            // A source a later Tidemark added reads as unknown.
            remoteIPSource: try read("remote_ip_source", as: String?.self).flatMap(RemoteIPSource.init(rawValue:)),
            remoteIPResolvedAt: try read("remote_ip_resolved_at")
        )
    }

    /// The time window a query covers: its `range` up to now (no lower bound for "All time").
    struct TimeWindow: Sendable, Equatable {
        var lower: Date?

        init(lower: Date?) {
            self.lower = lower
        }

        init(_ query: RequestQuery, now: Date = .now) {
            lower = query.range.lowerBound(now: now)
        }
    }

    /// Apps whose name contains the query's search term (`searchApps` of `appendFilters`); no round trip
    /// without a search.
    private func searchApps(for query: RequestQuery) async throws -> [AppID] {
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !search.isEmpty else { return [] }
        return try await rows("SELECT id FROM apps WHERE name ILIKE \(Self.containsPattern(search)) ORDER BY id")
            .map { try PostgresRowReader($0)("id", as: UUID.self) }
    }

    /// Appends ` WHERE …` for a request query (`r` aliases `requests`). A search matches the host, process
    /// name, remote IP or bundle path, or attributes the request to one of `searchApps` (the apps whose name
    /// matches, resolved beforehand: a bound list lets the planner combine the trigram index and the app
    /// index, where a subquery made it scan the whole range).
    static func appendFilters(_ query: RequestQuery, window: TimeWindow, searchApps: [AppID] = [], to sql: inout SQL) {
        let conditions = filterConditions(query, window: window, searchApps: searchApps, sql: &sql)
        if !conditions.isEmpty { sql.append(" WHERE " + conditions.joined(separator: " AND ")) }
    }

    /// The conditions `appendFilters` joins, their values bound in `sql`.
    static func filterConditions(_ query: RequestQuery, window: TimeWindow, searchApps: [AppID] = [], sql: inout SQL) -> [String] {
        var conditions: [String] = []
        if let device = query.scope.deviceID { conditions.append("r.device_id = \(sql.bind(device))") }
        if let lower = window.lower { conditions.append("r.started_at >= \(sql.bind(lower))") }
        // A start read back from a row, compared exactly (`bindInstant`), so that row itself is listed.
        if let until = query.until { conditions.append("r.started_at <= \(sql.bindInstant(until))") }
        if let app = query.appID { conditions.append("r.app_id = \(sql.bind(app))") }
        if let policy = query.policy { conditions.append("r.policy = \(sql.bind(policy))") }
        switch query.status {
        case .any: break
        case .completed: conditions.append("r.state = 'completed'")
        case .active: conditions.append("r.state = 'active'")
        case .failed: conditions.append("r.state IN ('failed', 'rejected')")
        }
        // `requests_host_started_idx` (v4) serves one host newest first.
        if let host = query.host.map(Self.exactHost) { conditions.append("r.host = \(sql.bind(host))") }
        // `requests_remote_ip_started_idx` (v4) serves one IP newest first; a value that is no IP matches nothing.
        if let ip = query.remoteIP {
            conditions.append(Self.inetText(ip).map { "r.remote_ip = \(sql.bind($0))::inet" } ?? "false")
        }
        if query.endedWithError { conditions.append(Self.endedWithErrorCondition) }
        let search = query.search.trimmingCharacters(in: .whitespacesAndNewlines)
        if !search.isEmpty {
            let p = sql.bind(containsPattern(search))
            // The indexed text separates its columns with newlines; a term containing one must match one column.
            var arms = search.contains("\n")
                ? ["r.host ILIKE \(p)", "r.process_name ILIKE \(p)", "host(r.remote_ip) ILIKE \(p)", "r.bundle_path ILIKE \(p)"]
                : ["\(Schema.requestSearchText) ILIKE \(p)"]
            if !searchApps.isEmpty { arms.append("r.app_id = ANY(\(sql.bind(searchApps))::uuid[])") }
            conditions.append("(" + arms.joined(separator: " OR ") + ")")
        }
        return conditions
    }

    /// A host as `requests.host` stores it: lowercased, an IPv6 literal without brackets.
    static func exactHost(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : trimmed
    }

    /// `RequestRecord.endedWithError` in SQL: an end reason that is not one of `RequestEndReason.normal`. It is the
    /// predicate of `requests_ended_error_idx` (schema v4), which serves it only while the two stay the same.
    static let endedWithErrorCondition: String = {
        let normal = RequestEndReason.normal.sorted().map { "'" + $0.replacingOccurrences(of: "'", with: "''") + "'" }
        return "(r.end_reason IS NOT NULL AND r.end_reason NOT IN (\(normal.joined(separator: ", "))))"
    }()

    /// Rows newest first with a total. The total counts every row matching the filters (ignoring `offset`);
    /// it is exact up to 100,000 matches, beyond that (and for the unfiltered "All time" view) it comes from
    /// the planner / table statistics.
    func queryRequests(_ query: RequestQuery) async throws -> RequestPage {
        let clock = ContinuousClock()
        let start = clock.now
        let window = TimeWindow(query)
        let apps = try await searchApps(for: query)

        var select = SQL("SELECT \(Self.requestSelect) FROM requests r")
        Self.appendFilters(query, window: window, searchApps: apps, to: &select)
        select.append(" ORDER BY r.started_at DESC, r.id DESC LIMIT \(select.bind(max(0, query.limit))) OFFSET \(select.bind(max(0, query.offset)))")
        let rowsQuery = select.query

        async let page = rows(rowsQuery, statementTimeout: Self.longReadTimeout)
        async let total = totalCount(for: query, window: window, searchApps: apps)
        let records = try await page.map(Self.decodeRequest)
        let count = try await total
        return RequestPage(rows: records, totalCount: max(count, Int64(query.offset + records.count)), elapsed: start.duration(to: clock.now))
    }

    func request(id: Int64) async throws -> RequestRecord? {
        try await rows("SELECT \(unescaped: Self.requestSelect) FROM requests r WHERE r.id = \(id)").first.map(Self.decodeRequest)
    }

    /// Walks up from the request in History's order, `(started_at, id)`: the plain bound on `started_at` lets the index of
    /// a host or an IP (or of the start time) begin at the request, and the limit ends the walk.
    func newerRequestStarts(than request: RequestRecord, matching query: RequestQuery, limit: Int) async throws -> [Date] {
        guard let rowID = request.rowID, limit > 0 else { return [] }
        let apps = try await searchApps(for: query)
        var sql = SQL("SELECT r.started_at FROM requests r, (SELECT started_at, id FROM requests WHERE id = ")
        sql.append(sql.bind(rowID) + ") t")
        let conditions = Self.filterConditions(query, window: TimeWindow(query), searchApps: apps, sql: &sql)
            + ["r.started_at >= t.started_at", "(r.started_at, r.id) > (t.started_at, t.id)"]
        sql.append(" WHERE " + conditions.joined(separator: " AND "))
        sql.append(" ORDER BY r.started_at, r.id LIMIT \(sql.bind(limit))")
        return try await rows(sql.query, statementTimeout: Self.longReadTimeout).map { try PostgresRowReader($0)("started_at", as: Date.self) }
    }

    private static let exactCountCap: Int64 = 100_000

    private func totalCount(for query: RequestQuery, window: TimeWindow, searchApps: [AppID]) async throws -> Int64 {
        let unfiltered = window.lower == nil && query.until == nil && query.appID == nil && query.policy == nil && query.status == .any
            && query.host == nil && query.remoteIP == nil && !query.endedWithError && query.search.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        Self.appendFilters(query, window: window, searchApps: searchApps, to: &count)
        count.append(" LIMIT \(Self.exactCountCap + 1)) AS capped")
        let exact = try await rows(count.query, statementTimeout: Self.longReadTimeout).first.map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
        guard exact > Self.exactCountCap else { return exact }

        var explain = SQL("EXPLAIN (FORMAT JSON) SELECT 1 FROM requests r")
        Self.appendFilters(query, window: window, searchApps: searchApps, to: &explain)
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

    /// `buckets` equal slices from the range's lower bound (the oldest matching request for "All time") to now, or to the
    /// query's `until`.
    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram {
        let now = Date.now
        var window = TimeWindow(query, now: now)
        let end = query.until.map { min($0, now) } ?? now
        guard buckets > 0 else { return Histogram(start: end, end: end, counts: []) }
        let apps = try await searchApps(for: query)

        if window.lower == nil {
            var oldest = SQL("SELECT min(r.started_at) AS oldest FROM requests r")
            Self.appendFilters(query, window: window, searchApps: apps, to: &oldest)
            window.lower = try await rows(oldest.query, statementTimeout: Self.longReadTimeout).first.flatMap { try PostgresRowReader($0)("oldest", as: Date?.self) }
        }
        guard let start = window.lower, start < end else {
            return Histogram(start: end, end: end, counts: Array(repeating: 0, count: buckets))
        }

        // Clamped to 1…buckets: the row that defines `start` can land just below it after the round trip
        // through `Date` (float rounding), and `width_bucket` would then report bucket 0.
        var sql = SQL("SELECT GREATEST(LEAST(width_bucket(extract(epoch FROM r.started_at)::float8, ")
        let low = sql.bind(start.timeIntervalSince1970)
        let high = sql.bind(end.timeIntervalSince1970)
        let count = sql.bind(buckets)
        sql.append("\(low)::float8, \(high)::float8, \(count)::int4), \(count)::int4), 1) AS bucket, count(*) AS n FROM requests r")
        Self.appendFilters(query, window: TimeWindow(lower: start), searchApps: apps, to: &sql)
        sql.append(" GROUP BY bucket")

        var counts = Array(repeating: Int64(0), count: buckets)
        for row in try await rows(sql.query, statementTimeout: Self.longReadTimeout) {
            let read = PostgresRowReader(row)
            let bucket = try read("bucket", as: Int.self)
            if (1...buckets).contains(bucket) { counts[bucket - 1] += try read("n", as: Int64.self) }
        }
        return Histogram(start: start, end: end, counts: counts)
    }

    /// Rows written or updated by other Macs strictly after `cursor` in `(updated_at, id)` order, oldest first.
    /// Rows carry their position in `rowID` and `writtenAt`. `updated_at` is the writing transaction's start
    /// time (`now()`), so a transaction that commits late adds rows just behind positions already read: poll
    /// again from a few seconds behind the newest position and skip positions already seen.
    func requestsWritten(after cursor: RequestWriteCursor, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] {
        var sql = SQL()
        Self.appendRequestsWritten(after: cursor, excluding: excluding, limit: limit, to: &sql)
        return try await rows(sql.query).map(Self.decodeRequest)
    }

    /// Appends the `requestsWritten(after:)` statement. The row comparison is the keyset; the plain
    /// `updated_at` bound beside it is what the BRIN index on `updated_at` can serve (an index only matches a
    /// row comparison when it is a btree over those columns), so a poll reads only the recent block ranges.
    static func appendRequestsWritten(after cursor: RequestWriteCursor, excluding: DeviceID?, limit: Int, to sql: inout SQL) {
        let updatedAt = sql.bindInstant(cursor.updatedAt)
        sql.append("SELECT \(requestSelect) FROM requests r WHERE r.updated_at >= \(updatedAt)")
        sql.append(" AND (r.updated_at, r.id) > (\(updatedAt), \(sql.bind(cursor.rowID))::int8)")
        if let excluding { sql.append(" AND r.device_id <> \(sql.bind(excluding))") }
        sql.append(" ORDER BY r.updated_at, r.id LIMIT \(sql.bind(max(0, limit)))")
    }

    /// The server's clock as a position before every row written from now on: a transaction that starts later
    /// writes a later `updated_at`, and row IDs start at 1.
    func requestWritePosition() async throws -> RequestWriteCursor {
        guard let row = try await rows("SELECT now() AS now").first else {
            throw DatabaseError.query("The server did not report its time.")
        }
        return RequestWriteCursor(updatedAt: try PostgresRowReader(row)("now", as: Date.self), rowID: 0)
    }

    /// Final policies seen since `since` (all time when nil), sorted by name.
    func distinctPolicies(since: Date?) async throws -> [String] {
        var sql = SQL("SELECT DISTINCT r.policy FROM requests r WHERE r.policy IS NOT NULL")
        if let since { sql.append(" AND r.started_at >= \(sql.bind(since))") }
        sql.append(" ORDER BY r.policy")
        return try await rows(sql.query, statementTimeout: Self.longReadTimeout).map { try PostgresRowReader($0)("policy", as: String.self) }
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

    /// Pause between two batches of maintenance work on the request log.
    static let maintenancePause: Duration = .milliseconds(250)
}
