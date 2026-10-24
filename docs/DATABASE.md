# Tidemark database

Tidemark keeps everything in one PostgreSQL database (PostgreSQL 14 or later; developed against 18.3).
The app creates and upgrades the schema itself: on launch it takes an advisory lock, applies any pending
migration from `Tidemark/Database/Schema.swift` inside a transaction and records it in
`schema_migrations`. Several Macs can write to the same database at once.

All timestamps are `timestamptz` (stored in UTC). Request IDs from Surge restart whenever the Surge engine
restarts, so a request is identified by `(device_id, surge_session, surge_id)`, where `surge_session` is the
engine start time in milliseconds.

## Tables

| Table | One row per | Notes |
|---|---|---|
| `devices` | Mac (or remote Surge) writing to the database | `row_count` and `last_write_at` drive the "Macs writing to this database" list |
| `apps` | monitored app, shared by every Mac | matched by bundle `path`; `archived_at` set when archived |
| `app_installs` | (app, Mac) | whether the bundle path exists on that Mac |
| `requests` | Surge request | the main log; upserted as the request progresses |
| `processes` | (Mac, PID, start time) | process tree with `parent_id`; PIDs are reused, so the start time is part of the key |
| `app_hosts` | (app, domain or IP) | a monitored app's inventory; `first_seen` within 24 h means NEW |
| `host_sources` | (domain or IP, Mac, source process or probe) | the global Domains & IPs page |
| `alerts` | first contact of a monitored app with a new site, host or IP | `read_at` is null while unread |
| `mutes` | muted host pattern (`host`, `IP` or `*.example.com`) | muted hosts are still recorded, they just never alert |
| `ip_info` | IP address | GeoIP / ASN cache from Surge's databases |
| `host_insights` | (host, language) | on-device explanations of hosts |
| `probe_sessions`, `probe_hosts` | site probe, and each host it reached | `first_ms` / `last_ms` are relative to the probe start |
| `egress_checks`, `egress_changes` | egress IP per policy per check, and changes of the current egress | |
| `schema_migrations` | applied migration | |

### `requests` columns worth knowing

| Column | Meaning |
|---|---|
| `started_at`, `setup_completed_at`, `completed_at` | Surge's timestamps |
| `method` | `HTTPS`, `TCP`, `UDP`, `QUIC` or an HTTP verb |
| `host`, `port`, `is_ip_literal` | destination as requested; `is_ip_literal` when the app connected to an IP with no hostname |
| `remote_ip`, `geo` | best known destination IP and its GeoIP data (`{"countryCode":"US","asn":13335,"organization":"Cloudflare, Inc."}`) |
| `remote_address` | Surge's raw remote address, e.g. `23.254.139.175 (Proxy)` for proxied connections |
| `policy`, `policy_path`, `rule` | final policy, the policy-group hops (`{AI,AT&T-RackNerd-Hysteria2}`) and the matched rule |
| `state` | `active`, `completed`, `failed` or `rejected` |
| `in_bytes`, `out_bytes` | traffic |
| `process_name`, `process_path`, `pid`, `process_id` | the process that opened the connection |
| `bundle_path` | the outermost `.app` bundle in the process chain (or Surge's statistics path) |
| `chain` | process ancestry, root → leaf: `[{"name","pid","path","startTime"}]` (`startTime` in seconds since 1970) |
| `app_id`, `is_new` | the monitored app it rolled up to, and whether it was that app's first contact with the host or IP |
| `probe_session_id` | set when the request came from a site probe |
| `written_at`, `updated_at` | first and latest write by Tidemark |

## Useful queries

Requests per app today:

```sql
SELECT coalesce(a.name, r.process_name) AS app, count(*) AS requests,
       pg_size_pretty(sum(r.in_bytes + r.out_bytes)) AS traffic
FROM requests r LEFT JOIN apps a ON a.id = r.app_id
WHERE r.started_at >= date_trunc('day', now())
GROUP BY 1 ORDER BY 2 DESC;
```

Domains and IPs each monitored app reached for the first time in the last 24 hours:

```sql
SELECT a.name, h.kind, h.value, h.site, h.first_seen, h.request_count
FROM app_hosts h JOIN apps a ON a.id = h.app_id
WHERE h.first_seen > now() - interval '24 hours'
ORDER BY h.first_seen DESC;
```

Every process (and its parents) that talked to a host:

```sql
SELECT started_at, process_name, chain, remote_ip, policy_path
FROM requests WHERE host = 'api.github.com' ORDER BY started_at DESC LIMIT 50;
```

Busiest destinations this week:

```sql
SELECT host, count(*) AS requests, count(DISTINCT coalesce(app_id::text, bundle_path)) AS apps
FROM requests WHERE started_at > now() - interval '7 days'
GROUP BY host ORDER BY requests DESC LIMIT 25;
```

## Maintenance

* **Retention** — Settings › Database › Keep requests deletes older requests every hour, in batches
  (default: forever).
* **Size** — `requests` grows by roughly 2–3 KB per row including its indexes (about 1.3 KB of row data). Check it with
  `SELECT pg_size_pretty(pg_total_relation_size('requests'));`.
* **Schema changes** — never edit the tables by hand while Tidemark runs; new versions of the app add
  migrations instead of changing existing ones.
