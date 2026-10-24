import Foundation

/// Versioned schema migrations. Each migration runs once, inside a transaction, and is recorded in
/// `schema_migrations`. Never edit a migration that has shipped; append a new one instead.
enum Schema {
    struct Migration: Sendable {
        var version: Int
        var name: String
        var sql: String
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
    ]

    private static let v1 = """
    CREATE EXTENSION IF NOT EXISTS pg_trgm;

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
        geo                text,
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
    CREATE INDEX requests_written_idx ON requests (written_at);
    CREATE INDEX requests_host_idx ON requests (host);
    CREATE INDEX requests_host_trgm_idx ON requests USING gin (host gin_trgm_ops);
    CREATE INDEX requests_remote_ip_idx ON requests (remote_ip);
    CREATE INDEX requests_process_idx ON requests (process_id);
    CREATE INDEX requests_bundle_idx ON requests (bundle_path);
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
        geo             text,
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
        geo           text,
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
        geo           text,
        process_name  text NOT NULL,
        is_direct     boolean NOT NULL DEFAULT false,
        request_id    bigint REFERENCES requests(id) ON DELETE SET NULL,
        created_at    timestamptz NOT NULL DEFAULT now(),
        read_at       timestamptz
    );
    CREATE INDEX alerts_created_idx ON alerts (created_at DESC);
    CREATE INDEX alerts_app_idx ON alerts (app_id, created_at DESC);
    CREATE INDEX alerts_unread_idx ON alerts (created_at DESC) WHERE read_at IS NULL;

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
