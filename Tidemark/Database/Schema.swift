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
        /// The oldest schema version whose Tidemark can still write correctly once this migration is applied
        /// (`schema_migrations.requires_version`, from v2 on). An older Tidemark that finds a newer migration
        /// requiring more than it knows stops writing instead of failing on every statement.
        var requiresVersion: Int? = nil
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
