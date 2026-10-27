import Foundation

/// Versioned schema migrations. Each migration runs once and is recorded in `schema_migrations`.
/// Never edit a migration that has shipped; append a new one instead.
///
/// Migrations run on a live database that several Macs write to at the same time, so from v2 on:
/// * every statement is idempotent (`IF NOT EXISTS`, `IF EXISTS`), because a migration whose record was lost
///   runs again from the start;
/// * DDL runs with a short `lock_timeout` (and is retried), so it never queues every Mac's writes behind it;
/// * nothing rewrites a large table; indexes on large tables are built and dropped `CONCURRENTLY`, outside
///   the transaction (`ConcurrentStep`).
///
/// A migration's transaction is recorded in `schema_migrations` as soon as it commits; its index steps run
/// afterwards, outside the migration lock, and are tracked through the catalog instead (see
/// `PostgresDatabase.migrate()`), so a long index build never keeps any Mac from connecting.
///
/// Statements are written without a schema prefix: `PostgresDatabase` runs them with
/// `search_path = <schema>, public`, so the same migrations build the production schema and the
/// throwaway `tm_test_*` schemas used by the tests. `pg_trgm` always lives in `public` (it is shared
/// by every schema of the database and must never be dropped together with a test schema).
enum Schema {
    struct Migration: Sendable {
        var version: Int
        var name: String
        /// Statements run in one transaction, which also records the migration.
        var sql: String
        /// Index changes that run after `sql` commits, each on its own outside any transaction, so they never
        /// block writes. Writers never depend on them (they only make queries faster): Tidemark applies the
        /// missing ones in the background, in this order, until the catalog shows every one in effect.
        var concurrentSteps: [ConcurrentStep] = []
        /// Rows copied after `sql` commits and before the migration is recorded (see `Backfill`).
        var backfill: Backfill? = nil
        /// The oldest schema version whose Tidemark can still write correctly once this migration is applied
        /// (`schema_migrations.requires_version`, from v2 on). An older Tidemark that finds a newer migration
        /// requiring more than it knows stops writing instead of failing on every statement.
        var requiresVersion: Int? = nil
    }

    /// A copy into a table the migration creates, in batches that each run in a transaction of their own after the
    /// migration's statements commit, still under the migration lock, and before the migration is recorded: the locks
    /// its DDL took (a new table's foreign keys lock the tables they reference, which every Mac's writes need) are
    /// released at once, no statement runs long, and a copy that was interrupted resumes when the migration runs again.
    /// Batches walk the source table's primary key (`key`, compared as one row) and insert with `ON CONFLICT DO NOTHING`.
    struct Backfill: Sendable, Equatable {
        /// The key columns, in order. The statements bind and return them as text.
        var key: [String]
        /// Below every key: where the first batch starts.
        var start: [String]
        /// The last key copied, the start of a copy that resumes (no row: start from `start`).
        var resume: String
        /// One batch: copies what follows the key `$1…$n` (n = `key.count`), at most `$n+1` rows of the source table;
        /// returns the last key it read and the number of rows it read (`n`), no row when it read none.
        var batch: String
        var batchSize: Int
    }

    /// An index change that runs outside the migration's transaction. Each one can tell from the catalog
    /// whether it is already in effect, so applying the steps again is harmless.
    enum ConcurrentStep: Sendable, Equatable {
        /// `CREATE INDEX CONCURRENTLY IF NOT EXISTS <name> ON <table> <definition>`. An invalid index left
        /// behind by an interrupted or failed build is dropped first and built again.
        case createIndex(name: String, table: String, definition: String)
        /// `DROP INDEX CONCURRENTLY IF EXISTS <name>`.
        case dropIndex(name: String)
        /// `ALTER INDEX <name> SET (autosummarize = on)` on a BRIN index, after summarizing the ranges filled
        /// since the last vacuum (`brin_summarize_new_values`). The `ALTER` briefly locks the index, so it
        /// runs with the migrations' short lock timeout and is retried.
        case enableAutosummarize(index: String)

        /// The index the step changes.
        var indexName: String {
            switch self {
            case .createIndex(let name, _, _), .dropIndex(let name): name
            case .enableAutosummarize(let index): index
            }
        }
    }

    static var latestVersion: Int { migrations.last?.version ?? 0 }

    static let bootstrap = """
    CREATE TABLE IF NOT EXISTS schema_migrations (
        version    integer PRIMARY KEY,
        name       text NOT NULL,
        applied_at timestamptz NOT NULL DEFAULT now()
    );
    """

    static let migrations: [Migration] = [
        Migration(version: 1, name: "initial", sql: v1),
        Migration(version: 2, name: "write path and egress details", sql: v2, concurrentSteps: v2Indexes, requiresVersion: 1),
        Migration(version: 3, name: "active requests and brin autosummarize", sql: "", concurrentSteps: v3Indexes, requiresVersion: 1),
        Migration(version: 4, name: "request details, dns answers and proxy errors", sql: v4, concurrentSteps: v4Indexes, requiresVersion: 1),
        Migration(version: 5, name: "host sources per app", sql: v5, backfill: v5Backfill, requiresVersion: 1),
    ]

    /// v5 — `app_host_sources`, the processes that reached a domain or IP per app: `host_sources` has no app in its
    /// key, so an executable two monitored apps both ran to one address (`node`, `curl`, `git`) has one row per Mac,
    /// under the app that used it last, counting both apps' requests. Capture writes the new table beside
    /// `host_sources`, in the same statement, for every request attributed to an app; older builds keep writing
    /// `host_sources` only (`requiresVersion` 1), which `hostProcesses` reads for what only they recorded.
    ///
    /// `backfilled` marks a row copied from `host_sources` (by the backfill below or a device merge, or merged from such
    /// rows only): it holds `host_sources`' figures, every app's requests of that Mac and process, until capture first
    /// writes the row for the app's own requests, continuing from them.
    private static let v5 = """
    CREATE TABLE IF NOT EXISTS app_host_sources (
        app_id        uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
        kind          text NOT NULL CHECK (kind IN ('domain', 'ip')),
        value         text NOT NULL,
        device_id     uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        source_path   text NOT NULL,
        source_title  text NOT NULL,
        first_seen    timestamptz NOT NULL,
        last_seen     timestamptz NOT NULL,
        request_count bigint NOT NULL DEFAULT 0,
        bundle_path   text,
        backfilled    boolean NOT NULL DEFAULT false,
        PRIMARY KEY (app_id, kind, value, device_id, source_path)
    );
    """

    /// v5's copy of every `host_sources` row that has an app, in batches of 10,000 rows of `host_sources` in primary-key
    /// order (a range scan of its primary key each). Rows whose app was deleted meanwhile fail the batch on the foreign
    /// key, and the migration tries again.
    private static let v5Backfill = Backfill(
        key: ["kind", "value", "device_id", "source_path"],
        start: ["", "", "00000000-0000-0000-0000-000000000000", ""],
        resume: """
            SELECT a.kind, a.value, a.device_id::text AS device_id, a.source_path FROM app_host_sources a WHERE a.backfilled
            ORDER BY a.kind DESC, a.value DESC, a.device_id DESC, a.source_path DESC LIMIT 1
            """,
        batch: """
            WITH batch AS (
                SELECT s.kind, s.value, s.device_id, s.source_path, s.source_title, s.app_id, s.first_seen, s.last_seen,
                       s.request_count, s.bundle_path
                FROM host_sources s
                WHERE (s.kind, s.value, s.device_id, s.source_path) > ($1::text, $2::text, $3::uuid, $4::text)
                ORDER BY s.kind, s.value, s.device_id, s.source_path
                LIMIT $5
            ), copied AS (
                INSERT INTO app_host_sources (app_id, kind, value, device_id, source_path, source_title, first_seen, last_seen,
                                              request_count, bundle_path, backfilled)
                SELECT b.app_id, b.kind, b.value, b.device_id, b.source_path, b.source_title, b.first_seen, b.last_seen,
                       b.request_count, b.bundle_path, true
                FROM batch b WHERE b.app_id IS NOT NULL
                ON CONFLICT (app_id, kind, value, device_id, source_path) DO NOTHING
            )
            SELECT b.kind, b.value, b.device_id::text AS device_id, b.source_path, (SELECT count(*) FROM batch) AS n
            FROM batch b ORDER BY b.kind DESC, b.value DESC, b.device_id DESC, b.source_path DESC LIMIT 1
            """,
        batchSize: 10_000
    )

    /// v4 — what happened to a request on its way, recorded while Surge still has it (it keeps only its last ~200
    /// finished requests). Additive only, so every older Tidemark keeps writing (`requiresVersion` 1): its upserts
    /// never name the new columns, and this build's merge keeps a stored value a write without one would erase.
    ///
    /// * `requests`: Surge's `timing` records, `entry_mode` (`takeoverMode`), `original_policy` (only when it
    ///   differs), `modified`, the `end_reason` parsed from the notes, and where `remote_ip` came from and when
    ///   (`remote_ip_source`, `remote_ip_resolved_at`). Nullable without a default, so adding them is a
    ///   catalog-only change: nothing is rewritten. One `ALTER`, taken before the new tables lock `devices`, so
    ///   the migration never waits for `requests` while holding a lock capture's writes need.
    /// * `dns_answers`: Surge's `dns` watch events, completed from `dump dns`, per Mac.
    /// * `proxy_errors`: the errors `proxy-runtime-status` reports for the proxy nodes that carry requests, keyed by
    ///   the node's name: Tidemark may ask a node by name before Surge lists its line hash, and a line hash changes
    ///   with the profile, while the node lists the same errors.
    private static let v4 = """
    ALTER TABLE requests
        ADD COLUMN IF NOT EXISTS timing jsonb,
        ADD COLUMN IF NOT EXISTS entry_mode smallint,
        ADD COLUMN IF NOT EXISTS original_policy text,
        ADD COLUMN IF NOT EXISTS modified boolean,
        ADD COLUMN IF NOT EXISTS end_reason text,
        ADD COLUMN IF NOT EXISTS remote_ip_source text,
        ADD COLUMN IF NOT EXISTS remote_ip_resolved_at timestamptz;

    CREATE TABLE IF NOT EXISTS dns_answers (
        device_id    uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        domain       text NOT NULL,
        resolved_at  timestamptz NOT NULL,
        server       text,
        interface    text,
        addresses    text[] NOT NULL DEFAULT '{}',
        path         text,
        log          text,
        time_cost_ms real,
        expires_at   timestamptz,
        by_tidemark  boolean NOT NULL DEFAULT false,
        PRIMARY KEY (device_id, domain, resolved_at)
    );

    CREATE TABLE IF NOT EXISTS proxy_errors (
        device_id   uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        policy      text NOT NULL,
        line_hash   text NOT NULL,
        at          timestamptz NOT NULL,
        target_host text NOT NULL,
        error       text NOT NULL,
        PRIMARY KEY (device_id, policy, at, target_host)
    );
    """

    /// v4 indexes, built concurrently.
    ///
    /// * `requests_host_started_idx`: one host's requests, newest first (`requests(forHost:)`, History with an
    ///   exact host). `host` and `started_at` never change once written, so progress rewrites stay HOT.
    /// * `requests_remote_ip_started_idx`: the requests that reached one IP, newest first (`RequestQuery.remoteIP`,
    ///   History opened from an IP of Domains & IPs). `remote_ip` changes only when the address becomes known or
    ///   another source names another one, so progress rewrites stay HOT.
    /// * `dns_answers_domain_idx`, `proxy_errors_target_idx`: a host's answers and errors on every Mac (the primary
    ///   keys lead with the Mac).
    /// * `requests_ended_error_idx`: the requests that ended with an error (`RequestQuery.endedWithError`), newest
    ///   first, so their count, histogram and pages over all time read only them, not every row before v4 (whose
    ///   `end_reason` is NULL). Its predicate is `PostgresDatabase.endedWithErrorCondition`. `end_reason` is set once,
    ///   in the rewrite that completes a request, which leaves `requests_active_idx` anyway, so no HOT update is lost.
    private static let v4Indexes: [ConcurrentStep] = [
        .createIndex(name: "requests_host_started_idx", table: "requests", definition: "(host, started_at DESC)"),
        .createIndex(name: "requests_remote_ip_started_idx", table: "requests", definition: "(remote_ip, started_at DESC)"),
        .createIndex(name: "dns_answers_domain_idx", table: "dns_answers", definition: "(domain, resolved_at DESC)"),
        .createIndex(name: "proxy_errors_target_idx", table: "proxy_errors", definition: "(target_host, at DESC)"),
        .createIndex(
            name: "requests_ended_error_idx", table: "requests",
            definition: "(started_at DESC) WHERE end_reason IS NOT NULL AND end_reason NOT IN "
                + "('Closed by client', 'Closed by remote', 'Closed for inactivity', 'Connection closed')"
        ),
    ]

    /// v3 — index changes only, so every older Tidemark keeps writing (`requiresVersion` 1).
    ///
    /// * `requests_active_idx`: the rows still `active`, by device and Surge session. Closing the requests of
    ///   an ended Surge session (`closeActiveRequests`, on every launch) and the ones that ended while
    ///   Tidemark was not running (`closeVanishedRequests`, on every stream connect) read only these rows
    ///   instead of every row of the device or session. It stays tiny: a row leaves it when its request
    ///   ends. Rewrites that keep the state (progress updates) stay HOT where they were (PostgreSQL 16+);
    ///   only a request's one change from `active` to a final state now touches the indexes.
    /// * `requests_updated_brin_idx` gets `autosummarize`: without it the block ranges filled since the last
    ///   vacuum stay unsummarized and every `requestsWritten(after:)` poll rechecks all of their rows.
    private static let v3Indexes: [ConcurrentStep] = [
        .createIndex(name: "requests_active_idx", table: "requests", definition: "(device_id, surge_session) WHERE state = 'active'"),
        .enableAutosummarize(index: "requests_updated_brin_idx"),
    ]

    /// The text every request search matches (`requests_search_trgm_idx`, v2): host, process name, remote IP
    /// and bundle path, separated by newlines so a search term without a newline can only match inside one
    /// of them. `PostgresDatabase` must search exactly this expression for the index to apply. It is part of
    /// migration v2: never change it (a different search needs a new constant and a new index).
    static let requestSearchText = #"(host || E'\n' || COALESCE(process_name, '') || E'\n' || COALESCE(host(remote_ip), '') || E'\n' || COALESCE(bundle_path, ''))"#

    /// v2 — tuning for a request log whose rows are rewritten several times each, and egress IP details.
    ///
    /// * `egress_checks.network_type`, `has_ipv6`: the `EgressSample` fields of the same name. Nullable
    ///   columns without a default are a catalog-only change.
    /// * `requests` fillfactor 80: room on every page for a request's progress rewrites (bytes, state,
    ///   completion) to stay on its page as HOT updates, which touch no index at all. It only applies to
    ///   pages filled from now on; nothing is rewritten.
    /// * `schema_migrations.requires_version`: lets older builds tell whether they may still write
    ///   (`Migration.requiresVersion`). v2 keeps v1 builds working: they only miss the new columns.
    private static let v2 = """
    ALTER TABLE egress_checks ADD COLUMN IF NOT EXISTS network_type text;
    ALTER TABLE egress_checks ADD COLUMN IF NOT EXISTS has_ipv6 boolean;
    ALTER TABLE requests SET (fillfactor = 80);
    ALTER TABLE schema_migrations ADD COLUMN IF NOT EXISTS requires_version integer;
    """

    /// v2 index changes, built and dropped concurrently.
    ///
    /// * `requests.updated_at`: the btree becomes a BRIN index. Every write sets `updated_at`, so with a
    ///   btree no rewrite of a request could be a HOT update: each one added entries to all of the table's
    ///   indexes. PostgreSQL 16+ keeps an update HOT when only summarizing (BRIN) indexes cover the changed
    ///   columns, and on any version the BRIN is a tiny fraction of the btree. Rows are appended in time
    ///   order, so `requestsWritten(after:)` reads only the recent block ranges (plus the pages of
    ///   long-running requests rewritten in place).
    /// * Search: one trigram index over `Schema.requestSearchText` replaces the host-only trigram index,
    ///   which the multi-column search could never use, so History searches over long ranges no longer scan
    ///   every row.
    /// * `requests_host_idx`, `requests_remote_ip_idx` and `host_sources_last_seen_idx` serve no query;
    ///   the last one also made every inventory touch a non-HOT update.
    private static let v2Indexes: [ConcurrentStep] = [
        .createIndex(name: "requests_updated_brin_idx", table: "requests", definition: "USING brin (updated_at) WITH (pages_per_range = 16)"),
        .dropIndex(name: "requests_updated_idx"),
        .createIndex(name: "requests_search_trgm_idx", table: "requests", definition: "USING gin (\(requestSearchText) gin_trgm_ops)"),
        .dropIndex(name: "requests_host_trgm_idx"),
        .dropIndex(name: "requests_host_idx"),
        .dropIndex(name: "requests_remote_ip_idx"),
        .dropIndex(name: "host_sources_last_seen_idx"),
    ]

    private static let v1 = """
    CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;

    -- Macs (and remote Surge instances) writing to this database.
    CREATE TABLE devices (
        id             uuid PRIMARY KEY,
        name           text NOT NULL,
        model          text,
        short_name     text NOT NULL,
        hue            real NOT NULL DEFAULT 240,
        is_remote      boolean NOT NULL DEFAULT false,
        row_count      bigint NOT NULL DEFAULT 0,
        last_write_at  timestamptz,
        created_at     timestamptz NOT NULL DEFAULT now()
    );

    -- Monitored apps, shared by every Mac. A Mac monitors an app when the bundle path exists locally.
    CREATE TABLE apps (
        id               uuid PRIMARY KEY,
        name             text NOT NULL,
        path             text NOT NULL UNIQUE,
        bundle_id        text,
        tile_letter      text NOT NULL,
        tile_hue         real NOT NULL,
        include_children boolean NOT NULL DEFAULT true,
        alert_rule       text NOT NULL DEFAULT 'any' CHECK (alert_rule IN ('site', 'any', 'off')),
        alert_new_ip     boolean NOT NULL DEFAULT true,
        archived_at      timestamptz,
        created_at       timestamptz NOT NULL DEFAULT now(),
        updated_at       timestamptz NOT NULL DEFAULT now()
    );

    -- Whether each Mac has each monitored app installed.
    CREATE TABLE app_installs (
        app_id     uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
        device_id  uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        installed  boolean NOT NULL,
        checked_at timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (app_id, device_id)
    );

    -- Processes that sent requests. PIDs are reused, so a process is (device, pid, start time).
    CREATE TABLE processes (
        id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id     uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        pid           integer NOT NULL,
        start_time    timestamptz NOT NULL,
        parent_id     bigint REFERENCES processes(id) ON DELETE SET NULL,
        name          text NOT NULL,
        path          text,
        app_id        uuid REFERENCES apps(id) ON DELETE SET NULL,
        first_seen    timestamptz NOT NULL DEFAULT now(),
        last_seen     timestamptz NOT NULL DEFAULT now(),
        request_count bigint NOT NULL DEFAULT 0,
        UNIQUE (device_id, pid, start_time)
    );
    CREATE INDEX processes_app_idx ON processes (app_id) WHERE app_id IS NOT NULL;
    CREATE INDEX processes_parent_idx ON processes (parent_id);

    -- Every request Surge reports. Upserted by (device_id, surge_session, surge_id) as it progresses.
    CREATE TABLE requests (
        id                 bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id          uuid NOT NULL REFERENCES devices(id),
        surge_session      bigint NOT NULL,
        surge_id           bigint NOT NULL,
        started_at         timestamptz NOT NULL,
        setup_completed_at timestamptz,
        completed_at       timestamptz,
        method             text NOT NULL,
        host               text NOT NULL,
        port               integer,
        url                text,
        is_ip_literal      boolean NOT NULL DEFAULT false,
        remote_ip          inet,
        remote_address     text,
        geo                jsonb,
        policy             text,
        policy_path        text[] NOT NULL DEFAULT '{}',
        rule               text,
        state              text NOT NULL CHECK (state IN ('active', 'completed', 'failed', 'rejected')),
        in_bytes           bigint NOT NULL DEFAULT 0,
        out_bytes          bigint NOT NULL DEFAULT 0,
        pid                integer,
        process_id         bigint REFERENCES processes(id) ON DELETE SET NULL,
        process_name       text,
        process_path       text,
        bundle_path        text,
        chain              jsonb NOT NULL DEFAULT '[]',
        app_id             uuid REFERENCES apps(id) ON DELETE SET NULL,
        is_new             boolean NOT NULL DEFAULT false,
        local_address      text,
        interface          text,
        notes              text[] NOT NULL DEFAULT '{}',
        probe_session_id   uuid,
        written_at         timestamptz NOT NULL DEFAULT now(),
        updated_at         timestamptz NOT NULL DEFAULT now(),
        UNIQUE (device_id, surge_session, surge_id)
    );
    CREATE INDEX requests_started_idx ON requests (started_at DESC);
    CREATE INDEX requests_device_started_idx ON requests (device_id, started_at DESC);
    CREATE INDEX requests_app_started_idx ON requests (app_id, started_at DESC) WHERE app_id IS NOT NULL;
    -- Other Macs poll rows written or updated since a cursor (requestsWritten).
    CREATE INDEX requests_updated_idx ON requests (updated_at);
    CREATE INDEX requests_host_idx ON requests (host);
    CREATE INDEX requests_host_trgm_idx ON requests USING gin (host gin_trgm_ops);
    CREATE INDEX requests_remote_ip_idx ON requests (remote_ip);
    CREATE INDEX requests_process_idx ON requests (process_id);
    CREATE INDEX requests_bundle_idx ON requests (bundle_path);
    -- Prefix matches (process_path LIKE '/Applications/X.app/%') for backfill and its preview count.
    CREATE INDEX requests_process_path_idx ON requests (process_path text_pattern_ops);
    CREATE INDEX requests_probe_idx ON requests (probe_session_id) WHERE probe_session_id IS NOT NULL;

    -- Per-app inventory: every domain and IP an app (and its children) used, listed once.
    CREATE TABLE app_hosts (
        app_id          uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
        kind            text NOT NULL CHECK (kind IN ('domain', 'ip')),
        value           text NOT NULL,
        site            text,
        first_seen      timestamptz NOT NULL,
        last_seen       timestamptz NOT NULL,
        first_device_id uuid REFERENCES devices(id) ON DELETE SET NULL,
        request_count   bigint NOT NULL DEFAULT 0,
        process_name    text,
        policy          text,
        geo             jsonb,
        is_direct       boolean NOT NULL DEFAULT false,
        hosts           text[] NOT NULL DEFAULT '{}',
        PRIMARY KEY (app_id, kind, value)
    );
    CREATE INDEX app_hosts_first_seen_idx ON app_hosts (app_id, first_seen DESC);

    -- Global inventory: every (domain or IP, source process) pair, from any process or site probe.
    CREATE TABLE host_sources (
        kind          text NOT NULL CHECK (kind IN ('domain', 'ip')),
        value         text NOT NULL,
        device_id     uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        source_path   text NOT NULL,
        source_title  text NOT NULL,
        app_id        uuid REFERENCES apps(id) ON DELETE SET NULL,
        bundle_path   text,
        first_seen    timestamptz NOT NULL,
        last_seen     timestamptz NOT NULL,
        request_count bigint NOT NULL DEFAULT 0,
        geo           jsonb,
        PRIMARY KEY (kind, value, device_id, source_path)
    );
    CREATE INDEX host_sources_value_trgm_idx ON host_sources USING gin (value gin_trgm_ops);
    CREATE INDEX host_sources_last_seen_idx ON host_sources (last_seen DESC);

    -- GeoIP / ASN / reverse DNS cache.
    CREATE TABLE ip_info (
        ip            inet PRIMARY KEY,
        country_code  text,
        asn           integer,
        organization  text,
        network_type  text,
        reverse_dns   text,
        updated_at    timestamptz NOT NULL DEFAULT now()
    );

    -- First contact of a monitored app with a new site, host or IP.
    CREATE TABLE alerts (
        id            bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id     uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        app_id        uuid NOT NULL REFERENCES apps(id) ON DELETE CASCADE,
        kind          text NOT NULL CHECK (kind IN ('domain', 'ip')),
        scope         text NOT NULL CHECK (scope IN ('site', 'host', 'ip')),
        value         text NOT NULL,
        site          text,
        host          text,
        ip            text,
        geo           jsonb,
        process_name  text NOT NULL,
        is_direct     boolean NOT NULL DEFAULT false,
        request_id    bigint REFERENCES requests(id) ON DELETE SET NULL,
        created_at    timestamptz NOT NULL DEFAULT now(),
        read_at       timestamptz
    );
    CREATE INDEX alerts_created_idx ON alerts (created_at DESC);
    CREATE INDEX alerts_app_idx ON alerts (app_id, created_at DESC);
    CREATE INDEX alerts_unread_idx ON alerts (created_at DESC) WHERE read_at IS NULL;
    -- Backs the ON DELETE SET NULL of request_id when retention deletes requests in batches.
    CREATE INDEX alerts_request_idx ON alerts (request_id) WHERE request_id IS NOT NULL;

    -- Muted host patterns (host, IP or *.example.com). Muted hosts are recorded but never alert.
    CREATE TABLE mutes (
        pattern    text PRIMARY KEY,
        created_at timestamptz NOT NULL DEFAULT now()
    );
    INSERT INTO mutes (pattern) VALUES ('*.apple.com'), ('*.icloud.com'), ('*.mzstatic.com');

    -- Site probes and the hosts each one touched.
    CREATE TABLE probe_sessions (
        id          uuid PRIMARY KEY,
        device_id   uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        url         text NOT NULL,
        host        text NOT NULL,
        mode        text NOT NULL DEFAULT 'desktop' CHECK (mode IN ('desktop', 'iphone')),
        started_at  timestamptz NOT NULL,
        ended_at    timestamptz,
        steps       jsonb NOT NULL DEFAULT '[]'
    );
    CREATE INDEX probe_sessions_started_idx ON probe_sessions (started_at DESC);

    CREATE TABLE probe_hosts (
        session_id    uuid NOT NULL REFERENCES probe_sessions(id) ON DELETE CASCADE,
        host          text NOT NULL,
        first_ms      integer NOT NULL,
        last_ms       integer NOT NULL,
        request_count integer NOT NULL DEFAULT 0,
        ips           text[] NOT NULL DEFAULT '{}',
        step          integer NOT NULL DEFAULT 0,
        PRIMARY KEY (session_id, host)
    );

    -- On-device explanations of hosts, shared by every Mac.
    CREATE TABLE host_insights (
        host          text NOT NULL,
        language      text NOT NULL,
        category      text NOT NULL,
        operator_name text,
        summary       text NOT NULL,
        concern       text,
        model         text,
        created_at    timestamptz NOT NULL DEFAULT now(),
        PRIMARY KEY (host, language)
    );

    -- Egress IP per policy, and changes of the current egress.
    CREATE TABLE egress_checks (
        id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id   uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        checked_at  timestamptz NOT NULL DEFAULT now(),
        policy_path text[] NOT NULL,
        ip          inet,
        location    text,
        network     text,
        latency_ms  integer,
        is_current  boolean NOT NULL DEFAULT false,
        error       text
    );
    CREATE INDEX egress_checks_device_idx ON egress_checks (device_id, checked_at DESC);

    CREATE TABLE egress_changes (
        id          bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        device_id   uuid NOT NULL REFERENCES devices(id) ON DELETE CASCADE,
        changed_at  timestamptz NOT NULL DEFAULT now(),
        ip          inet NOT NULL,
        policy_path text[] NOT NULL,
        reason      text NOT NULL
    );
    CREATE INDEX egress_changes_device_idx ON egress_changes (device_id, changed_at DESC);
    """
}
