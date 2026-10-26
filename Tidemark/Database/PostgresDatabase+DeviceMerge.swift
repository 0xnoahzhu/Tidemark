import Foundation
import PostgresNIO

/// Merging two IDs of one Mac (`mergeDevice`): everything the `from` device wrote moves to `into`, and the `from`
/// row is deleted. Finding a Mac's other IDs (`devicesSharingHistory`).
///
/// The merge runs beside capture's writes, so it never holds what capture needs for long: the request log moves in
/// small batches (`deviceMergeBatchSize` rows), each its own transaction spaced by `maintenancePause`, and every
/// transaction of the merge waits at most `deviceMergeLockTimeout` for a lock, less than capture's writes do: when
/// capture holds a row the merge needs, the merge's transaction gives way (and is tried again) instead of capture's.
/// Processes, installs, host sources and the remaining tables then follow in one last transaction, which also
/// deletes `from`. Every step only touches what is still `from`'s, so a merge that was interrupted (or failed) picks
/// up where it stopped when it runs again, and a merge of a device that is gone does nothing. Every statement runs
/// with the maintenance budget (`maintenanceTimeout`).
///
/// The statements are `DeviceMergeSQL`'s, as executed: the same merge can be run by hand.
extension PostgresDatabase {
    /// Requests moved per transaction: a batch commits within a fraction of capture's 5 s `lock_timeout`
    /// (`SessionLimits.writer`) even on a slow server, so the rows it locks never take capture offline.
    static let deviceMergeBatchSize = 1_000
    /// `lock_timeout` of the merge's transactions, below capture's.
    static let deviceMergeLockTimeout: Duration = .seconds(1)
    /// Attempts per transaction of the merge before it fails: a lock it lost to capture, or a request key capture
    /// wrote meanwhile, makes a transaction fail without changing anything.
    static let deviceMergeAttempts = 3
    /// Pause before a failed transaction of the merge is tried again.
    static let deviceMergeRetryPause: Duration = .seconds(1)

    @discardableResult
    func mergeDevice(_ from: DeviceID, into: DeviceID, idleFor: Duration?) async throws -> DeviceMergeResult {
        try await mergeDevice(from, into: into, idleFor: idleFor, batchSize: Self.deviceMergeBatchSize)
    }

    /// `mergeDevice(_:into:idleFor:)` moving `batchSize` requests per transaction, each transaction tried up to
    /// `attempts` times.
    @discardableResult
    func mergeDevice(_ from: DeviceID, into: DeviceID, idleFor: Duration? = nil, batchSize: Int,
                     attempts: Int = deviceMergeAttempts) async throws -> DeviceMergeResult {
        var result = DeviceMergeResult()
        guard from != into else { return result }
        let devices = Self.binds(from, into)
        let begin = {
            var binds = devices
            binds.append(idleFor.map(Self.seconds))
            return binds
        }()

        // `from` exists and may be merged; the `into` row exists (a copy of `from`'s when missing) and carries the
        // identity the Mac keeps. `since` is the moment `from` must not write after (server clock).
        let start = try await attempting(attempts) {
            try await self.mergeTransaction { connection -> MergeStart in
                let rows = try await connection.query(PostgresQuery(unsafeSQL: DeviceMergeSQL.begin, binds: begin), logger: Self.logger).collect()
                guard let row = rows.first else { return .nothing }
                let read = PostgresRowReader(row)
                if try read("remote", as: Bool.self) { return .refused(.remoteSurge) }
                if try read("written", as: Bool.self) { return .refused(.stillWriting) }
                for statement in [DeviceMergeSQL.ensureInto, DeviceMergeSQL.identity] {
                    _ = try await connection.query(PostgresQuery(unsafeSQL: statement, binds: devices), logger: Self.logger).collect()
                }
                return .started(since: try read("since", as: Date?.self))
            }
        }
        let since: Date?
        switch start {
        case .nothing: return result
        case .refused(let refusal):
            result.refusal = refusal
            return result
        case .started(let moment): since = moment
        }

        let limit = max(1, batchSize)
        for _ in 0..<max(1, attempts) {
            while true {
                try Task.checkCancellation()
                let step = try await attempting(attempts) {
                    try await self.mergeTransaction { connection in
                        try await Self.mergeRequestBatch(from, into: into, since: since, limit: limit, on: connection)
                    }
                }
                result.requestsMoved += step.moved
                result.duplicatesDropped += step.dropped
                if step.picked < limit { break }
                try await Task.sleep(for: Self.maintenancePause)
            }

            let check = {
                var binds = PostgresBindings()
                binds.append(from)
                binds.append(since)
                return binds
            }()
            let finish = try await attempting(attempts) {
                try await self.mergeTransaction { connection -> MergeFinish in
                    let rows = try await connection.query(PostgresQuery(unsafeSQL: DeviceMergeSQL.finishing, binds: check), logger: Self.logger).collect()
                    guard let row = rows.first else { return .gone }
                    let read = PostgresRowReader(row)
                    if try read("written", as: Bool.self) { return .stillWriting }
                    if try read("requests_left", as: Bool.self) { return .requestsLeft }
                    for statement in DeviceMergeSQL.processes + DeviceMergeSQL.installsAndSources + DeviceMergeSQL.rest {
                        _ = try await connection.query(PostgresQuery(unsafeSQL: statement, binds: devices), logger: Self.logger).collect()
                    }
                    return .done
                }
            }
            switch finish {
            case .done:
                result.merged = true
                return result
            case .gone:
                return result
            case .stillWriting:
                result.refusal = .stillWriting
                return result
            case .requestsLeft:
                // Requests written under `from` since its batches moved (without `idleFor`, or keys capture wrote under
                // `into` meanwhile): another round of batches.
                continue
            }
        }
        result.refusal = .stillWriting
        return result
    }

    func devicesSharingHistory(with device: DeviceID, sessions: [Int64]) async throws -> [DeviceID] {
        var binds = PostgresBindings()
        binds.append(device)
        binds.append(sessions)
        return try await rows(PostgresQuery(unsafeSQL: DeviceMergeSQL.sharingHistory, binds: binds), statementTimeout: Self.longReadTimeout)
            .map { try PostgresRowReader($0)("id", as: UUID.self) }
    }

    private enum MergeStart: Sendable {
        case nothing
        case refused(DeviceMergeResult.Refusal)
        case started(since: Date?)
    }

    private enum MergeFinish: Sendable {
        case done, gone, stillWriting, requestsLeft
    }

    /// A transaction of the merge: maintenance statement budget, and a lock wait shorter than capture's.
    private func mergeTransaction<Result: Sendable>(_ body: @escaping @Sendable (PostgresConnection) async throws -> Result) async throws -> Result {
        let lockTimeout = PostgresQuery(unsafeSQL: "SET LOCAL lock_timeout = '\(Self.setting(Self.deviceMergeLockTimeout))'")
        return try await withTransaction(statementTimeout: Self.maintenanceTimeout) { connection in
            try await connection.query(lockTimeout, logger: Self.logger)
            return try await body(connection)
        }
    }

    /// Runs `body` up to `attempts` times, `deviceMergeRetryPause` apart. A transaction that failed changed nothing.
    private func attempting<Result: Sendable>(_ attempts: Int, _ body: () async throws -> Result) async throws -> Result {
        var attempt = 1
        while true {
            do {
                return try await body()
            } catch let error as CancellationError {
                throw error
            } catch {
                guard attempt < attempts, !Task.isCancelled else { throw error }
                attempt += 1
                try await Task.sleep(for: Self.deviceMergeRetryPause)
            }
        }
    }

    /// One batch of `from`'s requests: duplicates of `into`'s rows are merged into them and dropped, the rest
    /// moves. Picks nothing once `from` wrote after `since`. Returns how many rows the batch picked, moved and dropped.
    private static func mergeRequestBatch(_ from: DeviceID, into: DeviceID, since: Date?, limit: Int, on connection: PostgresConnection) async throws
        -> (picked: Int, moved: Int64, dropped: Int64) {
        var pick = PostgresBindings()
        pick.append(from)
        pick.append(Int64(limit))
        pick.append(since)
        let ids = try await connection.query(PostgresQuery(unsafeSQL: DeviceMergeSQL.requestBatch, binds: pick), logger: logger).collect()
            .map { try PostgresRowReader($0)("id", as: Int64.self) }
        guard !ids.isEmpty else { return (0, 0, 0) }

        var batch = binds(from, into)
        batch.append(ids)
        for statement in [DeviceMergeSQL.lockDuplicates, DeviceMergeSQL.mergeDuplicates, DeviceMergeSQL.relinkAlerts] {
            _ = try await connection.query(PostgresQuery(unsafeSQL: statement, binds: batch), logger: logger).collect()
        }
        func count(_ statement: String) async throws -> Int64 {
            try await connection.query(PostgresQuery(unsafeSQL: statement, binds: batch), logger: logger).collect().first
                .map { try PostgresRowReader($0)("n", as: Int64.self) } ?? 0
        }
        let dropped = try await count(DeviceMergeSQL.dropDuplicates)
        let moved = try await count(DeviceMergeSQL.moveRequests)

        var counts = binds(from, into)
        counts.append(moved)
        counts.append(moved + dropped)
        _ = try await connection.query(PostgresQuery(unsafeSQL: DeviceMergeSQL.rowCounts, binds: counts), logger: logger).collect()
        return (ids.count, moved, dropped)
    }

    /// `$1` = `from`, `$2` = `into`.
    private static func binds(_ from: DeviceID, _ into: DeviceID) -> PostgresBindings {
        var binds = PostgresBindings()
        binds.append(from)
        binds.append(into)
        return binds
    }

    private static func seconds(_ duration: Duration) -> Double {
        let (seconds, attoseconds) = duration.components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}

/// The statements of `mergeDevice` and `devicesSharingHistory`, as executed. `$1` is the device merged away (`from`)
/// and `$2` the device it is merged into (`into`); the request statements also take the batch's request IDs as `$3`
/// (`int8[]`), except `requestBatch` (`$2` = the batch size, `$3` = `since`), `rowCounts` (`$3` = requests moved,
/// `$4` = requests moved or dropped) and `finishing` (`$2` = `since`).
///
/// By hand, in psql (`\set from '…'` and `\set into '…'`), once nothing writes under `from` any more: run `begin`
/// (with NULL for `$3`, then `since` is NULL), `ensureInto` and `identity`; then the request statements with
/// `ARRAY(SELECT id FROM requests WHERE device_id = :'from')` as `$3` (one batch holding every row) and the counts
/// they report; then `processes`, `installsAndSources` and `rest` in one transaction.
enum DeviceMergeSQL {
    /// One row when `from` exists: whether `from` or `into` is a remote Surge, `since` (`$3` seconds before now, NULL
    /// without `$3`) and whether `from` wrote after it.
    static let begin = """
        SELECT f.is_remote OR COALESCE(i.is_remote, false) AS remote,
               now() - make_interval(secs => $3::float8) AS since,
               COALESCE(f.last_write_at >= now() - make_interval(secs => $3::float8), false) AS written
        FROM devices f LEFT JOIN devices i ON i.id = $2
        WHERE f.id = $1
        """

    /// Creates `into` as a copy of `from` when it does not exist yet.
    static let ensureInto = """
        INSERT INTO devices (id, name, model, short_name, hue, is_remote, created_at)
        SELECT $2, f.name, f.model, f.short_name, f.hue, f.is_remote, f.created_at FROM devices f WHERE f.id = $1
        ON CONFLICT (id) DO NOTHING
        """

    /// `into` keeps its name, unless it has no requests yet: it was registered moments ago under the computer's
    /// name, and the name `from` had (one the user may have chosen) is the one the Mac is known by. It exists since
    /// the earlier of the two, and last wrote at the later.
    static let identity = """
        UPDATE devices i SET
            name = CASE WHEN EXISTS (SELECT 1 FROM requests r WHERE r.device_id = $2) THEN i.name ELSE f.name END,
            short_name = CASE WHEN EXISTS (SELECT 1 FROM requests r WHERE r.device_id = $2) THEN i.short_name ELSE f.short_name END,
            model = COALESCE(i.model, f.model),
            created_at = LEAST(i.created_at, f.created_at),
            last_write_at = GREATEST(i.last_write_at, f.last_write_at)
        FROM devices f WHERE i.id = $2 AND f.id = $1
        """

    /// The next batch of `from`'s requests (`$2` = the batch size); none once `from` wrote at or after `$3` (`since`).
    static let requestBatch = """
        SELECT r.id FROM requests r
        WHERE r.device_id = $1
          AND NOT EXISTS (SELECT 1 FROM devices d WHERE d.id = $1 AND d.last_write_at >= $3::timestamptz)
        LIMIT $2
        """

    /// Locks the `into` rows the batch duplicates, in key order like capture's upserts. A row capture holds makes the
    /// batch wait at most `deviceMergeLockTimeout`; the batch then fails and is tried again. Should the merge and
    /// capture still wait for each other, PostgreSQL ends one of the two transactions, and that one is tried again.
    static let lockDuplicates = """
        SELECT i.id FROM requests i JOIN requests f
            ON i.device_id = $2 AND i.surge_session = f.surge_session AND i.surge_id = f.surge_id
        WHERE f.id = ANY($3) AND f.device_id = $1
        ORDER BY i.surge_session, i.surge_id
        FOR UPDATE OF i
        """

    /// What a duplicate's `into` row becomes (`i`): its own data, plus what only the duplicate (`f`) knew.
    private static let mergedColumns: [(name: String, value: String)] = [
        ("setup_completed_at", "COALESCE(i.setup_completed_at, f.setup_completed_at)"),
        ("completed_at", "COALESCE(i.completed_at, f.completed_at)"),
        ("state", "CASE WHEN i.state = 'active' AND f.state <> 'active' THEN f.state ELSE i.state END"),
        ("port", "COALESCE(i.port, f.port)"),
        ("url", "COALESCE(i.url, f.url)"),
        ("remote_ip", "COALESCE(i.remote_ip, f.remote_ip)"),
        ("remote_address", "COALESCE(i.remote_address, f.remote_address)"),
        ("geo", "COALESCE(i.geo, f.geo)"),
        ("policy", "COALESCE(i.policy, f.policy)"),
        ("policy_path", "CASE WHEN cardinality(i.policy_path) > 0 THEN i.policy_path ELSE f.policy_path END"),
        ("rule", "COALESCE(i.rule, f.rule)"),
        ("in_bytes", "GREATEST(i.in_bytes, f.in_bytes)"),
        ("out_bytes", "GREATEST(i.out_bytes, f.out_bytes)"),
        ("pid", "COALESCE(i.pid, f.pid)"),
        ("process_id", """
            COALESCE(i.process_id,
                    (SELECT pi.id FROM processes pf JOIN processes pi ON pi.device_id = $2 AND pi.pid = pf.pid AND pi.start_time = pf.start_time
                     WHERE pf.id = f.process_id),
                    f.process_id)
            """),
        ("process_name", "COALESCE(i.process_name, f.process_name)"),
        ("process_path", "COALESCE(i.process_path, f.process_path)"),
        ("bundle_path", "COALESCE(i.bundle_path, f.bundle_path)"),
        ("chain", "CASE WHEN jsonb_array_length(i.chain) > 0 THEN i.chain ELSE f.chain END"),
        ("app_id", "COALESCE(i.app_id, f.app_id)"),
        ("is_new", "i.is_new OR f.is_new"),
        ("local_address", "COALESCE(i.local_address, f.local_address)"),
        ("interface", "COALESCE(i.interface, f.interface)"),
        ("notes", "CASE WHEN cardinality(i.notes) >= cardinality(f.notes) THEN i.notes ELSE f.notes END"),
        ("probe_session_id", "COALESCE(i.probe_session_id, f.probe_session_id)"),
        ("written_at", "LEAST(i.written_at, f.written_at)"),
        ("timing", "COALESCE(i.timing, f.timing)"),
        ("entry_mode", "COALESCE(i.entry_mode, f.entry_mode)"),
        ("original_policy", "COALESCE(i.original_policy, f.original_policy)"),
        ("modified", "COALESCE(i.modified, f.modified)"),
        ("end_reason", "COALESCE(i.end_reason, f.end_reason)"),
        // Where the address came from follows the address the row keeps.
        ("remote_ip_source", """
            CASE WHEN i.remote_ip IS NULL THEN f.remote_ip_source
                 WHEN i.remote_ip = f.remote_ip THEN COALESCE(i.remote_ip_source, f.remote_ip_source)
                 ELSE i.remote_ip_source END
            """),
        ("remote_ip_resolved_at", """
            CASE WHEN i.remote_ip IS NULL THEN f.remote_ip_resolved_at
                 WHEN i.remote_ip = f.remote_ip THEN COALESCE(i.remote_ip_resolved_at, f.remote_ip_resolved_at)
                 ELSE i.remote_ip_resolved_at END
            """),
    ]

    /// A batch row whose key `into` already has is a duplicate: the `into` row keeps its data and takes what only
    /// the duplicate knew (completion, IP, GeoIP, attribution, process…). Its process becomes the `into` process
    /// with the same PID and start time when there is one. Only rows this changes are written, with a new
    /// `updated_at`, so other Macs' live tables see the change.
    static let mergeDuplicates: String = {
        let names = mergedColumns.map(\.name)
        return """
            WITH merged AS (
                SELECT i.id, \(mergedColumns.map { "\($0.value) AS \($0.name)" }.joined(separator: ",\n        "))
                FROM requests f JOIN requests i ON i.device_id = $2 AND i.surge_session = f.surge_session AND i.surge_id = f.surge_id
                WHERE f.id = ANY($3) AND f.device_id = $1
            )
            UPDATE requests r SET \(names.map { "\($0) = m.\($0)" }.joined(separator: ", ")), updated_at = now()
            FROM merged m
            WHERE r.id = m.id
              AND (\(names.map { "r.\($0)" }.joined(separator: ", "))) IS DISTINCT FROM (\(names.map { "m.\($0)" }.joined(separator: ", ")))
            """
    }()

    /// Alerts that link to a duplicate link to the `into` row instead.
    static let relinkAlerts = """
        UPDATE alerts a SET request_id = i.id
        FROM requests f JOIN requests i ON i.device_id = $2 AND i.surge_session = f.surge_session AND i.surge_id = f.surge_id
        WHERE f.id = ANY($3) AND f.device_id = $1 AND a.request_id = f.id
        """

    /// Drops the duplicates; returns their number (`n`).
    static let dropDuplicates = """
        WITH dropped AS (
            DELETE FROM requests f USING requests i
            WHERE f.id = ANY($3) AND f.device_id = $1
              AND i.device_id = $2 AND i.surge_session = f.surge_session AND i.surge_id = f.surge_id
            RETURNING 1
        )
        SELECT count(*) AS n FROM dropped
        """

    /// Moves the rest of the batch; returns their number (`n`). A row whose process `into` has too (same PID and
    /// start time) links to that one. A row whose key capture wrote under `into` since `dropDuplicates` stays: the
    /// next batch merges it as a duplicate. Moved rows keep their `updated_at`: their data did not change, and a
    /// new one would make other Macs read the whole history again (and widen every range of
    /// `requests_updated_brin_idx`), so another Mac shows them under the `from` ID until it reloads.
    static let moveRequests = """
        WITH moved AS (
            UPDATE requests r SET device_id = $2,
                process_id = COALESCE(
                    (SELECT pi.id FROM processes pf JOIN processes pi ON pi.device_id = $2 AND pi.pid = pf.pid AND pi.start_time = pf.start_time
                     WHERE pf.id = r.process_id),
                    r.process_id)
            WHERE r.id = ANY($3) AND r.device_id = $1
              AND NOT EXISTS (SELECT 1 FROM requests i WHERE i.device_id = $2 AND i.surge_session = r.surge_session AND i.surge_id = r.surge_id)
            RETURNING 1
        )
        SELECT count(*) AS n FROM moved
        """

    /// `$3` = requests moved (added to `into`), `$4` = requests moved or dropped (taken from `from`).
    static let rowCounts = """
        UPDATE devices d SET row_count = GREATEST(0, CASE WHEN d.id = $2 THEN d.row_count + $3 ELSE d.row_count - $4 END)
        WHERE d.id = $1 OR d.id = $2
        """

    /// Locks `from`'s row (none when it is gone) before the last step: whether it wrote at or after `$2` (`since`), and
    /// whether requests are still left under it. While the row is locked nothing can write under `from` (every row
    /// referencing it waits for the lock), so the last step moves everything it still has.
    static let finishing = """
        SELECT COALESCE(d.last_write_at >= $2::timestamptz, false) AS written,
               EXISTS (SELECT 1 FROM requests r WHERE r.device_id = $1) AS requests_left
        FROM devices d WHERE d.id = $1
        FOR UPDATE
        """

    /// A process both have (same PID and start time) is merged into `into`'s: earlier first seen, later last seen,
    /// and its children and requests link to `into`'s before it is deleted. The rest moves.
    static let processes = [
        """
        UPDATE processes i SET
            first_seen = LEAST(i.first_seen, f.first_seen),
            last_seen = GREATEST(i.last_seen, f.last_seen),
            request_count = i.request_count + f.request_count,
            app_id = COALESCE(i.app_id, f.app_id),
            path = COALESCE(i.path, f.path),
            parent_id = COALESCE(i.parent_id,
                (SELECT pi.id FROM processes pf JOIN processes pi ON pi.device_id = $2 AND pi.pid = pf.pid AND pi.start_time = pf.start_time
                 WHERE pf.id = f.parent_id),
                f.parent_id)
        FROM processes f
        WHERE f.device_id = $1 AND i.device_id = $2 AND i.pid = f.pid AND i.start_time = f.start_time
        """,
        """
        UPDATE processes c SET parent_id = i.id
        FROM processes f JOIN processes i ON i.device_id = $2 AND i.pid = f.pid AND i.start_time = f.start_time
        WHERE f.device_id = $1 AND c.parent_id = f.id
        """,
        """
        UPDATE requests r SET process_id = i.id
        FROM processes f JOIN processes i ON i.device_id = $2 AND i.pid = f.pid AND i.start_time = f.start_time
        WHERE f.device_id = $1 AND r.process_id = f.id
        """,
        """
        DELETE FROM processes f USING processes i
        WHERE f.device_id = $1 AND i.device_id = $2 AND i.pid = f.pid AND i.start_time = f.start_time
        """,
        "UPDATE processes SET device_id = $2 WHERE device_id = $1",
    ]

    /// An app both report keeps the later check. A host source both have (same kind, value and source path) keeps
    /// the earlier first seen and the later last seen (with that observation's title), and adds the counts.
    static let installsAndSources = [
        """
        UPDATE app_installs i SET installed = f.installed, checked_at = f.checked_at
        FROM app_installs f
        WHERE f.device_id = $1 AND i.device_id = $2 AND i.app_id = f.app_id AND f.checked_at > i.checked_at
        """,
        """
        DELETE FROM app_installs f USING app_installs i
        WHERE f.device_id = $1 AND i.device_id = $2 AND i.app_id = f.app_id
        """,
        "UPDATE app_installs SET device_id = $2 WHERE device_id = $1",
        """
        UPDATE host_sources i SET
            first_seen = LEAST(i.first_seen, f.first_seen),
            last_seen = GREATEST(i.last_seen, f.last_seen),
            request_count = i.request_count + f.request_count,
            source_title = CASE WHEN f.last_seen > i.last_seen THEN f.source_title ELSE i.source_title END,
            app_id = COALESCE(i.app_id, f.app_id),
            bundle_path = COALESCE(i.bundle_path, f.bundle_path),
            geo = COALESCE(i.geo, f.geo)
        FROM host_sources f
        WHERE f.device_id = $1 AND i.device_id = $2 AND i.kind = f.kind AND i.value = f.value AND i.source_path = f.source_path
        """,
        """
        DELETE FROM host_sources f USING host_sources i
        WHERE f.device_id = $1 AND i.device_id = $2 AND i.kind = f.kind AND i.value = f.value AND i.source_path = f.source_path
        """,
        "UPDATE host_sources SET device_id = $2 WHERE device_id = $1",
    ]

    /// Alerts, probe sessions, egress checks and changes, DNS answers and proxy errors move; inventory entries `from`
    /// found first name `into`. A DNS answer or proxy error `into` has too (same key: both IDs recorded the same
    /// event) is dropped first. Then `from` is deleted, which would delete what is left of its DNS answers and proxy
    /// errors with it.
    static let rest = [
        "UPDATE alerts SET device_id = $2 WHERE device_id = $1",
        "UPDATE probe_sessions SET device_id = $2 WHERE device_id = $1",
        "UPDATE egress_checks SET device_id = $2 WHERE device_id = $1",
        "UPDATE egress_changes SET device_id = $2 WHERE device_id = $1",
        "UPDATE app_hosts SET first_device_id = $2 WHERE first_device_id = $1",
        """
        DELETE FROM dns_answers f USING dns_answers i
        WHERE f.device_id = $1 AND i.device_id = $2 AND i.domain = f.domain AND i.resolved_at = f.resolved_at
        """,
        "UPDATE dns_answers SET device_id = $2 WHERE device_id = $1",
        """
        DELETE FROM proxy_errors f USING proxy_errors i
        WHERE f.device_id = $1 AND i.device_id = $2 AND i.line_hash = f.line_hash AND i.at = f.at AND i.target_host = f.target_host
        """,
        "UPDATE proxy_errors SET device_id = $2 WHERE device_id = $1",
        "DELETE FROM devices WHERE id = $1",
    ]

    /// `devicesSharingHistory`: `$1` = the device, `$2` = further Surge sessions (`int8[]`). The device's own
    /// sessions are read one index probe each (a skip scan of `requests`' unique key), every other Mac's rows are
    /// probed per session, and its processes against the device's (stopping at the second match).
    static let sharingHistory = """
        WITH RECURSIVE own AS (
            SELECT min(surge_session) AS session FROM requests WHERE device_id = $1
            UNION ALL
            SELECT (SELECT min(r.surge_session) FROM requests r WHERE r.device_id = $1 AND r.surge_session > own.session)
            FROM own WHERE own.session IS NOT NULL
        ), sessions AS (
            SELECT session FROM own WHERE session IS NOT NULL
            UNION
            SELECT unnest($2::int8[])
        )
        SELECT d.id FROM devices d
        WHERE d.id <> $1 AND NOT d.is_remote
          AND (EXISTS (SELECT 1 FROM sessions s JOIN requests r ON r.device_id = d.id AND r.surge_session = s.session)
               OR (SELECT count(*) FROM (
                       SELECT 1 FROM processes p JOIN processes q ON q.device_id = $1 AND q.pid = p.pid AND q.start_time = p.start_time
                       WHERE p.device_id = d.id LIMIT 2) shared) >= 2)
        ORDER BY d.created_at, d.id
        """
}
