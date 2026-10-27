# Tidemark database

Tidemark keeps everything in one PostgreSQL database (PostgreSQL 14 or later; developed against 18.3).
The app creates and upgrades the schema itself from the migrations in `Tidemark/Database/Schema.swift`.
Several Macs can write to the same database at once.

On every connect Tidemark reads `schema_migrations` without taking any lock. Only when this build has a
migration to apply does it take an advisory lock (waiting at most 30 s for another Mac's migration), apply
each pending migration in one transaction and record it in that same transaction. A Mac with nothing to
apply never waits for another Mac.

A migration that copies rows into a table it creates (v5) commits its statements first, which releases the locks they
took, then copies in batches of 10,000 rows of the source table, each in a transaction of its own with the migration's
limits, and records itself only after the last batch. The copy walks the source's primary key and skips what is there
already (`ON CONFLICT DO NOTHING`), so a copy that stopped (a lost connection, a quit) resumes after the last row it
copied when the migration runs again. It still holds the migration lock, so another Mac applying the same migration
waits for it (at most 30 s, then retries); Macs with nothing to apply, older builds among them, never do.

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
| 4 | What happened to a request on its way ([Request details](#request-details)): `requests.timing`, `entry_mode`, `original_policy`, `modified`, `end_reason`, `remote_ip_source` and `remote_ip_resolved_at` (nullable, no default: a catalog-only change); the tables `dns_answers` and `proxy_errors`; `requests_host_started_idx` on `requests (host, started_at DESC)`, `requests_remote_ip_started_idx` on `requests (remote_ip, started_at DESC)` for the requests that reached one IP (History opened from an IP of Domains & IPs), `requests_ended_error_idx` on `requests (started_at DESC)` for the requests that ended with an error (a partial index whose predicate is History's "ended with an error" filter, so that filter over all time never reads the rows before v4) and an index by host on each new table, built concurrently. Additive only (`requires_version` 1): every older Tidemark keeps writing, and its writes never touch the new columns. |
| 5 | `app_host_sources`, each app's processes of a domain or IP: `host_sources` has no app in its key, so an executable two monitored apps both ran to one address had one row per Mac, under the app that used it last, counting both apps' requests. Every `host_sources` row with an app is copied into it (`backfilled`), in batches after the table's transaction commits (about 20 s per million rows of `host_sources`). Additive only (`requires_version` 1): older builds keep writing `host_sources` alone. |

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
| Maintenance: backfill, deleting an app | 10 min (`SET LOCAL`) | 10 s | 60 s |
| Merging devices: every transaction of a merge | 10 min (`SET LOCAL`) | 1 s (`SET LOCAL`, below capture's; the transaction is tried again) | 60 s |
| Capture writes (`Tidemark writer`) | 15 s | 5 s | 15 s |
| Closing (or counting) requests of ended sessions or that ended while Tidemark was not running | 15 s (`SET LOCAL`) | 10 s | 60 s |
| Migration transactions, and each batch of a migration's copy | 5 min | 3 s per statement (retried) | 60 s |
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
the two writer connections. The call ends as soon as the connection is closed, even when it was rolling
back or about to send its next statement: PostgresNIO never answers a statement sent on a connection that
finished closing. A connection closed by anything else (the server, the network, the pool shutting down)
fails its call as unreachable within about two seconds unless the call finished first, so no call waits
for such a statement until its limit. The rollback and session cleanup are skipped on a closed connection
(its transaction, settings and locks ended with it).

Each Mac keeps its connection URL, password included, in its preferences (`db.url` in `io.tidemark.Tidemark`),
not in the Keychain; Settings › Database shows the password masked.
URLs without `sslmode` use `prefer` for remote hosts (TLS when the server offers it) and `disable` for
loopback; `sslmode=require`, `verify-ca` and `verify-full` (with `sslrootcert=`) are supported.

## Tables

| Table | One row per | Notes |
|---|---|---|
| `devices` | Mac writing to the database | `id` is derived from the Mac's hardware UUID ([Device identity](#device-identity)); `row_count` and `last_write_at` drive the "Macs writing to this database" list; `is_remote` is set only on rows earlier versions stored for a remote Surge (Tidemark now reads this Mac's Surge only), which are never merged |
| `apps` | monitored app, shared by every Mac | matched by bundle `path`; `archived_at` set when archived |
| `app_installs` | (app, Mac) | whether the bundle path exists on that Mac |
| `requests` | Surge request | the main log; upserted as the request progresses |
| `processes` | (Mac, PID, start time) | process tree with `parent_id`; PIDs are reused, so the start time is part of the key |
| `app_hosts` | (app, domain or IP) | a monitored app's inventory; `first_seen` within 24 h means NEW |
| `host_sources` | (domain or IP, Mac, source process or probe) | the global Domains & IPs page, and the processes listed under a domain or IP of an app's Domains & IPs tab (`app_id`, the app the process's requests rolled up to when it last reached the address) |
| `app_host_sources` | (app, domain or IP, Mac, source process) | each app's processes of a domain or IP, with that app's own requests (schema v5); `backfilled` while a row holds what v5 copied from `host_sources` |
| `alerts` | first contact of a monitored app with a new site, host or IP | `read_at` is null while unread |
| `mutes` | host pattern earlier versions muted (`host`, `IP` or `*.example.com`) | unused: Tidemark has no mutes and neither reads nor writes it, so every host alerts. Schema v1 creates it with `*.apple.com`, `*.icloud.com` and `*.mzstatic.com`; it stays, since migrations are never edited |
| `ip_info` | IP address | GeoIP / ASN cache from Surge's databases |
| `host_insights` | (host, language) | no longer used: it held on-device explanations of hosts, a feature Tidemark removed; the table stays because migrations are never edited |
| `probe_sessions`, `probe_hosts` | site probe, and each host it reached | `first_ms` / `last_ms` are relative to the probe start |
| `egress_checks`, `egress_changes` | egress IP per policy per check, and changes of the current egress | |
| `dns_answers` | (Mac, domain, time) | a resolution Surge's DNS made, from its `dns` watch event, completed from `dump dns` ([Request details](#request-details)) |
| `proxy_errors` | (Mac, proxy node, time, target host) | an error a proxy node reported (`proxy-runtime-status`) |
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
| `timing` | Surge's `timingRecords`, `[{"duration":0.318429,"name":"DNS Lookup"}]` (seconds); only rule mode times anything, so NULL in global-proxy mode |
| `entry_mode` | how the request reached Surge (`takeoverMode`): 1 = HTTP proxy listener, 20 = virtual interface (UDP), 40 = virtual interface (TCP) |
| `original_policy`, `modified` | Surge's `originalPolicyName` (only when it differs from the final policy) and `modified` flag |
| `end_reason` | why the connection ended, in Surge's words without a trailing period: the last `Disconnect:` note (`Closed by remote`, `Closed by client`, `Connection closed`, `TCP error: Connection reset`, `Broken pipe (POSIX:32)`) or the UDP close note (`Closed for inactivity`, `ICMP closed`). Surge reports resets and broken pipes as completed, so `state` says `completed` for them; anything but the first three and `Closed for inactivity` counts as ended with an error. `notes` stay the source of truth |
| `remote_ip_source` | where `remote_ip` came from: `literal` (the host is an IP), `surge` (Surge's remote address of a DIRECT connection), `rule-dns` (the address Surge resolved to match IP rules, `[Rule] DNS completed…`), `tidemark-lookup` (Tidemark's own `dns lookup` through Surge, also while Surge's cache holds that answer) or `surge-cache` (an unexpired entry of Surge's DNS cache that Surge resolved by itself, or a static mapping of its profile). Only `literal` and `surge` are the address the connection used: a proxy resolves the host again on its side, out of sight |
| `remote_ip_resolved_at` | when that address was resolved or reported: the `[Rule] DNS completed` note, Tidemark's lookup, the `dns` event of a cached answer (when Tidemark saw it; otherwise when Tidemark first read the entry, never older than its TTL), the connection's setup for `surge`; NULL for `literal` |

A rewrite merges into the stored row as before: values that settle never regress, and a v4 column keeps its stored
value when a write has none (rows an earlier build spooled carry none; an earlier build's own upserts never name the
v4 columns). `remote_ip_source` and `remote_ip_resolved_at` follow `remote_ip`: a write of the same address keeps them
unless it names new ones, and a write of another address without a source leaves them NULL rather than describing the
previous address.

### Request details

Surge keeps only its last ~200 finished requests (a few minutes on a busy Mac) and no history, so Tidemark records
what it can learn about a request's way while it happens. Neither table below carries a request ID: a request joins
them by host and time, always on its own Mac (`device_id`; each Mac has its own Surge).

* **DNS answers** (`dns_answers`) — Surge's `dns` watch event (`{"domain","server","interface","data":[IPs]}`) is
  stored once the next `dump dns` read (every 30 s) completes it with the CNAME `path`, the lookup's `log` line,
  `time_cost_ms` and `expires_at`; an answer no read matches (re-resolved meanwhile) is stored as the event had it,
  about a minute later. `resolved_at` is when the event arrived. `by_tidemark` marks answers Tidemark's own
  `dns lookup` caused. In global-proxy mode Surge resolves nothing locally for proxied requests (the proxy does), so
  the answers there are Tidemark's lookups and DIRECT traffic's.

  A request's answer is the latest for its host on its Mac at or before the moment it needed one (when its
  `remote_ip` was resolved, `remote_ip_resolved_at`, at most a minute after the start, or else its start, plus a
  second for the event to arrive) that still held when the request started: not expired by then or, with no
  `expires_at` (no read completed it), resolved within the hour before. An answer that expired before the start never
  served the request, however recent. Nothing older than a day is searched (Surge's cache holds some answers for
  hours), so the primary key's backward scan stays short.

  ```sql
  SELECT * FROM dns_answers
  WHERE device_id = :'device' AND domain = :'host'
    AND resolved_at <= :'moment' AND resolved_at >= :'started_at'::timestamptz - interval '1 day'
    AND (expires_at >= :'started_at' OR expires_at IS NULL AND resolved_at >= :'started_at'::timestamptz - interval '1 hour')
  ORDER BY resolved_at DESC LIMIT 1;
  ```

* **Proxy errors** (`proxy_errors`) — `proxy-runtime-status <line hash>` lists a proxy node's last 15 errors
  (`{"error":"Stream closed","time":…,"targetHostname":…}`). Once a minute Tidemark asks about the nodes (final
  policies) that carried requests in the last minute, never per request: three surge-cli processes a minute at most,
  the nodes asked least recently first, so with more than three busy nodes each is asked every few minutes. A node's
  line hash comes from `dump traffic`, read before a node missing from it is asked (at most every 10 minutes), and
  read again when Surge no longer knows a node by its hash or reloads its profile. `line_hash` is what the node was
  asked by: its `POLICY::…` hash, or its name when Surge lists none. An error is stored once per Mac, node (`policy`),
  time and host, the primary key, whichever way the node was asked: a node may be asked by name before `dump traffic`
  lists its hash, and a hash changes with the profile. A burst of more than 15 errors on a node between two of its
  polls loses the oldest ones.

  A request's errors are its host's (or IP literal's) on its Mac within a second of its completion
  (`|completed_at - at| < 1 s`).

  ```sql
  SELECT * FROM proxy_errors
  WHERE device_id = :'device' AND target_host = :'host'
    AND at > :'completed_at'::timestamptz - interval '1 second' AND at < :'completed_at'::timestamptz + interval '1 second';
  ```

`relatedRecords(of:)` also finds a request's first-contact alert (`alerts.request_id`), its site probe
(`probe_session_id`), the current egress check of its Mac nearest its start and the latest change of the current
egress at or before its start (`egress_checks` are kept for 30 days, `egress_changes` for good).

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

## Devices

### Device identity

A Mac's `devices.id`, the `device_id` of every row it writes, is a name-based UUID (RFC 9562 version 5, SHA-1) of
its hardware UUID under Tidemark's own namespace:

```
device_id = uuid5(52DEF2FE-CE96-4221-91B0-8045B3FD8255, IOPlatformUUID in uppercase, as UTF-8)
```

The namespace never changes. The hardware UUID is `IOPlatformUUID` of `IOPlatformExpertDevice` (what System
Information calls Hardware UUID). A Mac keeps its ID whether or not its preferences can be read and across
reinstalls, and the hardware UUID itself never reaches the database. This prints a Mac's ID:

```bash
python3 -c 'import re, subprocess, uuid
hw = re.search(r"\"IOPlatformUUID\" = \"([^\"]+)\"", subprocess.run(["ioreg", "-rd1", "-c", "IOPlatformExpertDevice"], capture_output=True, text=True).stdout).group(1)
print(str(uuid.uuid5(uuid.UUID("52DEF2FE-CE96-4221-91B0-8045B3FD8255"), hw.upper())).upper())'
```

Only a Mac whose hardware UUID cannot be read uses a random ID, generated once and stored in its preferences
(`device.id` in `io.tidemark.Tidemark`). Earlier versions always did, so a launch that could not read the
preferences registered the Mac a second time under a new random ID, stored nowhere. Tidemark merges every earlier
ID of the Mac into the derived one ([below](#merging-devices)), however it finds it:

* The ID still stored in the preferences, when it differs from the derived one. The derived ID is registered with
  the stored row's name, color and age, and the stored ID is forgotten once merged.
* An ID named in the spool or in `auxiliary.json`: those only ever hold this Mac's own work.
* An ID that shares history with the Mac (`devicesSharingHistory`): a Mac, not a remote Surge's row, that recorded
  one of the Mac's Surge sessions (a session is identified by that Surge's start time in milliseconds) or at least
  two of its processes (same PID and start time, to the microsecond). No other Mac shares either. Tidemark looks once
  merging is due, then hourly, and again right after a merge moved rows: merging the stored ID brings its sessions
  to the derived ID, which finds an ID invented while the preferences could not be read.

Merging starts two minutes after the launch first reached PostgreSQL, once the spool is replayed, as maintenance
beside the writes, and only merges an ID nothing wrote under since then (`idleFor`): one that something still writes
under (an older build beside this one, a Mac the preferences were copied to) is left alone until the next launch. A
merge that failed is tried again ten minutes later, then after twice as long each time (four hours at most); once
the server refused it three times in a row it waits for the next launch. It never takes capture offline.

The spool and `auxiliary.json` are written under the Mac's current ID, whatever ID they were saved under: an ID
merged away meanwhile no longer exists, and `requests.device_id` would refuse every row. A replayed row whose key
now matches a stored row merges into it like any rewrite.

### Merging devices

`mergeDevice(from, into, idleFor)` makes one Mac of two device IDs: everything `from` wrote moves to `into`, and
the `from` row is deleted. Its statements are `DeviceMergeSQL` in `Tidemark/Database/PostgresDatabase+DeviceMerge.swift`,
with `$1` = `from` and `$2` = `into`. It runs beside capture's writes, so every transaction is short, has the 10 min
maintenance statement timeout and waits at most 1 s for a lock: when capture holds a row the merge needs, the merge's
transaction fails and is tried again (three times, 1 s apart) rather than capture waiting until it goes offline
(5 s). Should the two still wait for each other, PostgreSQL ends one of the transactions and that one is tried again.

1. `begin`: nothing to do when `from` does not exist (merged already). A remote Surge's row (`is_remote`) is never
   merged, nor merged into. With `idleFor`, `since` is that long before the server's clock, and a `from` that wrote
   at or after it (`last_write_at`) is left alone: something still writes under it. Otherwise `into` is created as a
   copy of `from` when missing; it keeps its name unless it has no requests yet (a row registered moments ago under
   the computer's name), it exists since the earlier `created_at` of the two and last wrote at the later
   `last_write_at`.
2. `requests`, 1,000 rows of `from` per transaction (`$3` = their IDs), 250 ms apart, none once `from` wrote at or
   after `since`. A row whose `(surge_session, surge_id)` `into` already has is a duplicate: `into`'s row is locked
   (in key order, like capture's upserts), takes what only the duplicate knew (completion and state, IP, GeoIP,
   policy, app, process, NEW…) and, when that changes it, a new `updated_at` (other Macs' live tables see it); alerts
   that linked to the duplicate link to it, and the duplicate is deleted. The rest moves (`device_id = into`); a row
   whose process `into` has too (same PID and start time) links to `into`'s. Moved rows keep their `updated_at`: a
   new one would make other Macs read the whole history again and widen every range of `requests_updated_brin_idx`,
   so another Mac shows them under `from` until it reloads. A row whose key capture wrote under `into` meanwhile
   stays for the next batch, which merges it as a duplicate. `row_count` follows on both rows.
3. One last transaction locks `from`'s row (`finishing`, `FOR UPDATE`): every row referencing `from` now waits, so
   nothing can be written under it any more. A `from` that wrote at or after `since` is left in place (what moved
   stays moved); requests written under it since its batches moved go back to step 2. Then:
   * `processes`: one both have (same PID and start time) is merged into `into`'s (earlier first seen, later last
     seen, app, path, parent), its children and requests link to `into`'s, and it is deleted; the rest moves.
   * `app_installs` (the later check wins), `host_sources` and `app_host_sources` (earlier first seen, later last seen
     and its title, counts added; a merged `app_host_sources` row stays `backfilled` only when both were) merge the
     same way. A request both IDs recorded may count twice in a merged `request_count`:
     only when the second ID saw it live, since a launch never counts a request it read back from Surge's recent
     list. (`processes.request_count` is not maintained.)
   * `alerts`, `probe_sessions`, `egress_checks`, `egress_changes`, `dns_answers` and `proxy_errors` move (a DNS answer
     or proxy error `into` has too, same key, is dropped first), `app_hosts.first_device_id` follows, and `from` is
     deleted.

Every step only touches what is still `from`'s, so a merge that stopped half way finishes when it runs again, and
merging twice does nothing. By hand, in psql, once nothing writes under `from` any more: `\set from …` and
`\set into …`, then the same statements with `:'from'::uuid` and `:'into'::uuid` for `$1` and `$2` and NULL for
`begin`'s `$3` and for `since`, the request statements without their batch condition (`… id = ANY($3) AND`, one
batch holding every row) and `rowCounts` with the counts that `dropDuplicates` and `moveRequests` report, then the
statements of step 3 in one transaction.

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

An exact host is served newest first by `requests_host_started_idx` (v4). Every process (and its parents) that talked
to a host, and how each connection ended:

```sql
SELECT started_at, process_name, chain, remote_ip, remote_ip_source, policy_path, end_reason FROM requests
WHERE host = 'api.github.com'
ORDER BY started_at DESC LIMIT 50;
```

Every request that reached an IP, whatever host it named, as Domains & IPs count an IP (a request to an IP literal
has the literal as its remote IP), newest first by `requests_remote_ip_started_idx` (v4):

```sql
SELECT started_at, host, process_name, remote_ip_source, policy_path FROM requests
WHERE remote_ip = '104.18.19.125'
ORDER BY started_at DESC LIMIT 50;
```

Requests of the last day that ended with an error, although Surge reported them completed (served by
`requests_ended_error_idx` (v4) when the condition is written exactly as its predicate):

```sql
SELECT started_at, host, policy, end_reason FROM requests
WHERE end_reason IS NOT NULL
  AND end_reason NOT IN ('Closed by client', 'Closed by remote', 'Closed for inactivity', 'Connection closed')
  AND started_at > now() - interval '1 day'
ORDER BY started_at DESC;
```

Every request that touched a host, by name, process, IP or bundle path (the same index):

```sql
SELECT started_at, process_name, remote_ip, policy_path FROM requests
WHERE (host || E'\n' || COALESCE(process_name, '') || E'\n' || COALESCE(host(remote_ip), '') || E'\n' || COALESCE(bundle_path, ''))
      ILIKE '%api.github.com%'
ORDER BY started_at DESC LIMIT 50;
```

The processes that reached one of an app's domains or IPs, as its Domains & IPs tab lists them under the address (the
tab merges the rows by path in Swift; `kind` and `value` are the primary key's prefix, so only that address's rows are
read):

```sql
SELECT s.source_path, (array_agg(s.source_title ORDER BY s.last_seen DESC))[1] AS name,
       sum(s.request_count) AS requests, min(s.first_seen) AS first_seen, max(s.last_seen) AS last_seen,
       array_agg(DISTINCT d.name) AS macs
FROM host_sources s JOIN devices d ON d.id = s.device_id
WHERE s.kind = 'domain' AND s.value = 'api.github.com' AND s.app_id = (SELECT id FROM apps WHERE name = 'Cursor')
GROUP BY s.source_path ORDER BY requests DESC;
```

Busiest destinations this week:

```sql
SELECT host, count(*) AS requests, count(DISTINCT coalesce(app_id::text, bundle_path)) AS apps
FROM requests WHERE started_at > now() - interval '7 days'
GROUP BY host ORDER BY requests DESC LIMIT 25;
```

## Maintenance

* **Retention** — requests are kept forever: Tidemark never deletes them.
* **Size** — `requests` grows by roughly 2–3 KB per row including its indexes (about 1.3 KB of row data). Check it
  with `SELECT pg_size_pretty(pg_total_relation_size('requests'));`. At about 60,000 requests a day, v4's columns add
  15–25 B a row in global-proxy mode and 60–80 B in rule mode (1–5 MB a day), `requests_host_started_idx` about 3 MB a
  day, `requests_remote_ip_started_idx` about 2 MB and `requests_ended_error_idx` about 0.1 MB (about 6% of requests
  end with an error); `dns_answers` gets a row
  per resolution: in global-proxy mode nearly all are Tidemark's own lookups, about one per hostname in use per TTL of
  its answer, so roughly 3,000–10,000 rows a day on a busy Mac (1–4 MB at about 400 B a row with its indexes; the
  1,000 a day measured before Tidemark honoured Surge's expiry counted almost none of them), more in rule mode,
  bounded by the re-resolutions of the hosts in use. They are kept at full rate, since each is the answer a
  `tidemark-lookup` address came from. `proxy_errors` gets about 100 rows a day. `app_host_sources` has about a row
  for each `host_sources` row with an app (one more for each further app that ran the same process to the same
  address), about 330 B with its primary key: 667,000 rows took 217 MB beside a `host_sources` of a million rows
  (306 MB).
* **Schema changes** — never edit the tables by hand while Tidemark runs; new versions of the app add
  migrations instead of changing existing ones. v5's copy of `host_sources` took 19.5 s for a million rows (101
  batches of about 0.2 s), while writes like capture's on another connection waited 24 ms at most; the same copy as one
  statement in the transaction that creates the table took 14.4 s and held those writes up until their 5 s lock timeout
  (the new table's foreign keys lock `devices` and `apps` until it commits). `SchemaBackfillMeasurement` in
  `TidemarkTests/DatabaseLiveTests.swift` measures both in a throwaway schema when `TIDEMARK_BACKFILL_ROWS` is set.
* **Index builds** — after an upgrade on a large database, `pg_stat_progress_create_index` shows a
  background build's progress (`SELECT * FROM pg_stat_progress_create_index;`). It waits for transactions
  older than itself (a long `pg_dump`, a psql session left idle in a transaction) before it can finish.
  Tidemark logs failed builds under the `database` category of `io.tidemark.Tidemark` and retries them.
* **Merging devices** — Tidemark merges a Mac's earlier IDs by itself ([Device identity](#device-identity)):
  the one its preferences store, the ones its spool names and the ones that share its Surge sessions or processes.
  Its log (`capture` category of `io.tidemark.Tidemark`) says when it merged one or left one alone. A Mac still
  listed twice ("Macs writing to this database"), for instance an ID whose sessions and processes all ended before
  a restart of the Mac and that no longer is in the preferences, is merged by hand with the statements of
  [Merging devices](#merging-devices), once the ID merged away no longer writes.
* **Backfill** — monitoring an app with "include past requests" attributes its past requests in windows of
  50,000 row IDs, then its processes and host sources, each in a statement of its own, then merges the
  rebuilt inventory 500 entries per transaction; capture's writes to the same rows never wait long.
