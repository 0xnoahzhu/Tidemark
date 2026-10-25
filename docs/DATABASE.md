# Tidemark database

Tidemark keeps everything in one PostgreSQL database (PostgreSQL 14 or later; developed against 18.3).
The app creates and upgrades the schema itself from the migrations in `Tidemark/Database/Schema.swift`.
Several Macs can write to the same database at once.

On every connect Tidemark reads `schema_migrations` without taking any lock. Only when this build has a
migration to apply does it take an advisory lock (waiting at most 30 s for another Mac's migration), apply
each pending migration in one transaction and record it in that same transaction. A Mac with nothing to
apply never waits for another Mac.

Index changes (`CREATE INDEX CONCURRENTLY`, `DROP INDEX CONCURRENTLY`, BRIN settings) are not part of
those transactions and are not recorded: Tidemark compares the catalog with what the applied migrations
ask for and applies whatever is missing under a second, per-schema advisory lock, so one Mac builds while
every other Mac keeps connecting and writing. On small tables (up to 16 MB) this happens while
connecting; on larger ones it runs in the background with no statement or lock timeout (these builds
block no reads or writes), retrying with a backoff of 30 s up to 15 min after a failure. A build that
fails drops the invalid index it left behind, so it is never maintained by writes in the meantime.

All timestamps are `timestamptz` (stored in UTC). Request IDs from Surge restart whenever the Surge engine
restarts, so a request is identified by `(device_id, surge_session, surge_id)`, where `surge_session` is the
engine start time in milliseconds.

## Schema versions

| Version | Changes |
|---|---|
| 1 | Initial tables. |
| 2 | `egress_checks.network_type` / `has_ipv6`; `requests` fillfactor 80; the btree on `requests.updated_at` replaced by a BRIN index (so rewriting a request row can stay a HOT update on PostgreSQL 16+); one trigram index over host, process name, remote IP and bundle path for searches, replacing the separate `host`, host-trigram and remote-IP indexes; `host_sources_last_seen_idx` dropped (no query used it); `schema_migrations.requires_version`. |
| 3 | `requests_active_idx`, a partial index on `requests (device_id, surge_session) WHERE state = 'active'`, so closing the requests left active by an ended Surge session or by a crash reads only the rows still active; `autosummarize = on` for the BRIN index on `requests.updated_at`, so block ranges are summarized as they fill instead of at the next vacuum. Index changes only: every older Tidemark keeps writing. |

Indexes are built and dropped `CONCURRENTLY`, so an upgrade does not block reads or writes (v3's BRIN
setting locks that index for a moment and gives up after 3 s, to try again). Tidemark builds whose schema
is 2 applied a migration's index steps while holding the migration lock and recorded the migration only
afterwards: while such a build upgraded a large database, every other Mac that reconnected failed to
connect (and spooled) until the build finished. Later builds take the migration lock only for the
migrations' transactions, so a Mac still running a schema-2 build connects normally while a later build
creates indexes.

A migration records the oldest schema its writers still understand (`requires_version`). A Mac running an
older Tidemark keeps writing as long as that version is not newer than its own schema, and otherwise asks to
be updated.

## Connections

Tidemark opens a 6-connection pool for reads and a 2-connection writer pool (`Tidemark writer` in
`pg_stat_activity`). Each sets `statement_timeout`, `lock_timeout` and `idle_in_transaction_session_timeout`:

| Work | Statement | Lock | Idle in transaction |
|---|---|---|---|
| Reads, settings (`Tidemark`) | 30 s | 10 s | 60 s |
| Reads over a long history: History pages, totals and histogram, the policy list, an app's counters and process tree, the backfill preview | 5 min (`SET LOCAL` in its own transaction) | 10 s | 60 s |
| Maintenance: retention, backfill, deleting an app | 10 min (`SET LOCAL`) | 10 s | 60 s |
| Capture writes (`Tidemark writer`) | 15 s | 5 s | 15 s |
| Closing (or counting) requests of ended sessions or that ended while Tidemark was not running | 15 s (`SET LOCAL`) | 10 s | 60 s |
| Migration transactions | 5 min | 3 s per statement (retried) | 60 s |
| Index builds of migrations | none | none in the background; 10 s while connecting; 3 s for a BRIN setting | 60 s |

The capture writes and the session closing stay below capture's own 20 s bound per write, so the server
cancels a statement capture already gave up on. A statement cancelled at its statement timeout fails as
timed out ("PostgreSQL query timed out: the server cancelled it after …"), so a slow query is not mistaken
for a server that cannot be reached; like an unreachable server, it never makes capture set rows aside.
The server's message names the timeout; when the server writes its messages in another language
(`lc_messages`, which only a superuser can change), a cancelled call that ran at least as long as its
statement timeout counts as timed out, and other cancels (`pg_cancel_backend`) as unreachable.

On top of these, Tidemark closes a connection whose call has gone unanswered for twice its statement
timeout plus 5 s, 15 min for a migration and 6 h for index builds (a server that vanished without closing
the TCP connection, e.g. while the Mac slept; the call fails as timed out), and
a writer connection as soon as capture gives up on its call. Its transaction then rolls back instead of
committing later (unless its `COMMIT` was already under way), and calls capture abandoned never hold on to
the two writer connections.

URLs without `sslmode` use `prefer` for remote hosts (TLS when the server offers it) and `disable` for
loopback; `sslmode=require`, `verify-ca` and `verify-full` (with `sslrootcert=`) are supported.

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
| `started_at`, `setup_completed_at`, `completed_at` | Surge's timestamps. When Tidemark never saw a request end (Surge restarted, or the connection ended while Tidemark was not running), `completed_at` is the request's last write by Tidemark (its last observed change), never later than the restart or relaunch and never before `started_at` |
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
| `written_at`, `updated_at` | first and latest write by Tidemark, set by the server (`now()`, the writing transaction's start) |

### Rows other Macs write

Every Mac shows the rows the other Macs write in its live table. Every 2 s it reads them in the server's write
order, `(updated_at, id)`, from the position it reached:

```sql
SELECT … FROM requests r
WHERE r.updated_at >= $1 AND (r.updated_at, r.id) > ($1, $2) AND r.device_id <> $3
ORDER BY r.updated_at, r.id LIMIT 300;
```

The row comparison is the keyset; the plain `updated_at` bound beside it is what the BRIN index
`requests_updated_brin_idx` can serve, so a poll reads only the block ranges written since (an index serves a
row comparison only when it is a btree over those columns). A poll reads page after page until one comes back
shorter than the limit, at most ten pages; a poll that stopped there lets the next one carry on from where it
stopped. A row written again gets a later `updated_at` and is read again.

Positions come from the server only, so the Macs' clocks never take part: each poll first reads the server's
clock (`SELECT now()`). The first poll starts a minute before it, and so does a poll whose position fell further
behind (after a sleep, an outage or a burst too large to keep up with): the rows in between are skipped, since
the live table only shows recent rows, and no page reads more than about a minute of writes. A poll that read
everything moves its position up to the server's clock, so while the other Macs write nothing a poll reads only
the last few seconds of this Mac's own rows. Because `updated_at` is the writing transaction's start, a
transaction that commits late adds rows just behind a position already read: each poll that starts afresh steps
back 3 s and skips the `(id, updated_at)` positions it already returned.

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

There is no index on `requests.host` (v2 dropped it): filter hosts through the search expression below,
which the trigram index `requests_search_trgm_idx` serves, and add an exact condition when needed. A plain
`WHERE host = …` reads the table newest first until it has found enough rows, which for a rare host means
most of the table.

Every process (and its parents) that talked to a host:

```sql
SELECT started_at, process_name, chain, remote_ip, policy_path FROM requests
WHERE (host || E'\n' || COALESCE(process_name, '') || E'\n' || COALESCE(host(remote_ip), '') || E'\n' || COALESCE(bundle_path, ''))
      ILIKE '%api.github.com%'
  AND host = 'api.github.com'
ORDER BY started_at DESC LIMIT 50;
```

Every request that touched a host, by name, process, IP or bundle path (the same index):

```sql
SELECT started_at, process_name, remote_ip, policy_path FROM requests
WHERE (host || E'\n' || COALESCE(process_name, '') || E'\n' || COALESCE(host(remote_ip), '') || E'\n' || COALESCE(bundle_path, ''))
      ILIKE '%api.github.com%'
ORDER BY started_at DESC LIMIT 50;
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
* **Index builds** — after an upgrade on a large database, `pg_stat_progress_create_index` shows a
  background build's progress (`SELECT * FROM pg_stat_progress_create_index;`). It waits for transactions
  older than itself (a long `pg_dump`, a psql session left idle in a transaction) before it can finish.
  Tidemark logs failed builds under the `database` category of `io.tidemark.Tidemark` and retries them.
* **Backfill** — monitoring an app with "include past requests" attributes its past requests in windows of
  50,000 row IDs, then its processes and host sources, each in a statement of its own, then merges the
  rebuilt inventory 500 entries per transaction; capture's writes to the same rows never wait long.
