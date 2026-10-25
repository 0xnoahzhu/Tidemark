# Tidemark architecture

Tidemark is a native macOS app (SwiftUI, Swift 6, macOS 27) that keeps every request Surge handles in
PostgreSQL, rolls each request up to the app that caused it, and alerts when a monitored app reaches a
domain or IP it has never used before.

```
 surge-cli --raw watch request request-update real-time-speed environment reload shutdown
        │  (one JSON object per line)
        ▼
 SurgeCLIClient ──► CaptureEngine ──► CaptureWriteBuffer ──► PostgresDatabase ──► PostgreSQL
                       │   ▲                   │ (spool to disk while offline)
     LibProcInspector ─┘   │                   ▼
     PublicSuffixClassifier│              LiveState / CatalogState / AlertState (MainActor, @Observable)
     DNS + GeoIP caches ───┘                   ▼
                                         SwiftUI: main window · menu bar extra · settings
```

## Layers and directories

| Directory | Contents | Depends on |
|---|---|---|
| `Model/` | Value types shared by every layer (`RequestRecord`, `MonitoredApp`, `AlertItem`, …) | Foundation |
| `Services/` | Protocols (`SurgeClient`, `ProcessInspecting`, `SiteClassifying`, `TidemarkDatabase`, `CaptureActions`, `ProbeActions`, `EgressActions`, `HostInsightProviding`), Surge wire types, inert placeholders | Model |
| `State/` | `@MainActor @Observable` state objects and `AppModel`, the root injected into SwiftUI | Model, Services |
| `Support/` | Formatters, Keychain, request timing builder, `AppNaming` (an app's name everywhere: Finder's display name of its bundle) | Model |
| `Localization/` | `Localizer`, `tr()` / `trf()` / `trn()` | — |
| `Surge/` | `SurgeCLIClient`: runs surge-cli, parses events, reconnects | Services |
| `Process/` | `LibProcInspector` (libproc), `PublicSuffixClassifier` (bundled PSL) | Services |
| `Database/` | `Schema` migrations, `PostgresDatabase` (PostgresNIO) | Services |
| `Capture/` | `CaptureEngine` + `CapturePipeline`: attribution, first-contact detection, alerts, notifications, write buffer, disk spool, stats | all protocols, State |
| `Probe/` | Per-session CONNECT proxy and the probe controller | Services, State |
| `Egress/` | Egress monitor (per-policy external IP, latency, change log, IP lookup) | Services, State |
| `Insight/` | `HostInsightService`: on-device explanations of hosts (FoundationModels), cached in memory and in `host_insights` | Services |
| `Intents/` | App Intents: Shortcuts and Siri actions, `MonitoredAppEntity` | State |
| `UI/` | SwiftUI views; `Theme/` tokens and `Components/` shared views | State |
| `App/` | `TidemarkApp` scenes, `AppDelegate`, `AppBootstrap` (composition root), commands | everything |

UI code never talks to concrete services: it reads `AppModel`'s state objects and calls the protocol-typed
services on `AppModel` (`model.database`, `model.capture`, `model.probeActions`, `model.egressActions`).
`AppBootstrap` replaces the placeholders with real implementations at launch.

## Surge integration

All Surge access goes through `surge-cli --raw` (JSON output). The executable lives at
`/Applications/Surge.app/Contents/Applications/surge-cli` (also linked from `/usr/local/bin/surge-cli`).
Tidemark reads this Mac's Surge: Settings offer no remote Surge, and the remote controller password earlier
versions kept in the Keychain is deleted at launch. The client still supports one, adding `--remote host:port`
and sending a password on stdin with `--password-stdin` (never in argv). A stream that
ends or fails is always restarted, with backoff.

* **Stream** — `watch request request-update real-time-speed environment reload shutdown`. First line is
  `{"result":"Event subscribed"}`. `request` and `request-update` events have the same shape
  (`SurgeRequest`) and carry no event name: a request is *new* the first time its `id` is seen.
  `request-update` fires about once per second for every active connection (~100 events/s on a busy
  Mac), so updates are coalesced in memory. Speed events look like
  `{"in":23416,"out":1140,"downloadSpeedHistory":[…],"uploadSpeedHistory":[…]}`.
* **Sessions** — request IDs restart when the Surge engine restarts. `status` → `start-time` (seconds)
  is the session key; the DB key is `(device_id, surge_session_ms, surge_id)`.
* **Backfill** — on (re)connect, `dump recent` returns the last 200 requests with full details, and `dump active`
  lists the connections that are still open. Requests the pipeline still holds as active but Surge no longer
  lists are closed; rows of the same Surge session that PostgreSQL still holds as active but the listing lacks
  (connections that ended while Tidemark was not running) are closed by `closeVanishedRequests` as maintenance
  (see [Database](#database)).
* **Liveness** — `real-time-speed` arrives every second while subscribed, so a stream that stays silent for 15 s
  is restarted. `status` is polled every 30 s: a new `start-time` means Surge restarted (even if the watch
  survived), so the stream is restarted and the new session begins before recycled request IDs are recorded.
  The previous session's requests are closed at the new start time, and its rows PostgreSQL still holds as
  active are closed by `closeActiveRequests` as maintenance. `environment` is polled every 60 s as a backstop
  for policy switches the watch did not report.
* **Child processes** — every call runs its own surge-cli child. When a call times out or is cancelled, or the
  consumer of a `watch` stops, its child gets SIGTERM, then SIGKILL after 2 s, and is reaped. Quitting stops
  every child still running (lookups nobody cancelled, one that ignored SIGTERM) before Tidemark exits:
  SIGTERM, then SIGKILL after half a second. A `watch` orphaned by a crash ends at its next event, when
  writing to the closed pipe fails.
* **Process** — `pid`, `processPath`, and `pathForStatistics` (the app bundle, e.g. `/Applications/Grok Bot.app/`).
* **Policy** — `policyName` is the final policy. Notes contain the decision path, e.g.
  `[Rule] Policy decision path: AI -> AT&T-RackNerd-Hysteria2` → `policyPath = ["AI", "AT&T-RackNerd-Hysteria2"]`.
  In rule mode notes also name the matched rule; in global-proxy mode the rule is `Global · <policy>`.
* **Remote IP** — `remoteAddress` is the real destination for DIRECT, but `"<proxy-ip> (Proxy)"` for proxied
  connections. For hostnames we resolve through Surge (`dns lookup <host>`, cached by TTL, plus a periodic
  `dump dns` cache read). IP-literal hosts (`149.154.175.60:443`) are *direct* IPs ("by IP, no hostname").
* **GeoIP** — `geoip <ip>` → `{country, asn, organization}`; cached in `ip_info`.
* **Policies** — `policy-group list` / `dump policy-group-sub-policies` give options with a `lineHash`
  (`POLICY::…`). Policies that come from a policy-path subscription are **not** addressable by name:
  `test-policy-external-ip` and `test-policy` must be given the line hash. `environment` →
  `ProxyGroupSelection` gives each group's current choice; `ProxyMode` 0/1/2 = direct/global/rule.
* **Other commands** — `summary` (interface, IP, router, DNS), `http probe <url> [policy]`,
  `rule match <host> process-path=…`, `test external-ip`, `dump event` / profile (`http-listen` port, usually 6152).

## Attribution

For requests from this Mac's own Surge, `LibProcInspector.chain(pid:notAfter:)` walks `proc_pidinfo`
(`PROC_PIDTBSDINFO` → parent PID and start time; `proc_pidpath` → executable) from the request's process up
to (not including) launchd. A chain is cached by `(pid, start time)`; if the live process started after the
request, the PID was reused and the chain is discarded.

The request belongs to the nearest process in the chain (leaf first) whose executable lives inside a
monitored app's bundle (`MonitoredApp.contains(processPath:)`), so `node` launched by `Cursor Helper
(Plugin)` launched by `Cursor` rolls up to Cursor ("Rolled up to Cursor through 2 parent processes").
Unmonitored requests are shown under the top-most `.app` bundle in the chain (or Surge's
`pathForStatistics`, the only option for a remote Surge; Surge reports system daemons as the literal
`SYSTEM`, which is ignored) and land only in the global log. Tidemark's own requests (the site probe's
forwarder, IP-info lookups) are never attributed to a monitored app, even when Tidemark was launched from
inside one's process tree.

Processes are stored once per `(device, pid, start_time)` with a `parent_id` link; the app's Process Tree
aggregates them by executable path under their parent path, showing the latest PID and Running/Exited.

## First contact and alerts

Each monitored app has an inventory (`app_hosts`): every domain and every IP it used, listed once,
shared by all Macs. On each request attributed to a *monitoring* app (not archived, not paused this
session):

1. If the host is not in the app's inventory → insert it (`ON CONFLICT DO NOTHING RETURNING` decides the
   winner across Macs), mark the request `is_new`.
   * scope `site` when no host of the same registrable domain (`PublicSuffixClassifier.site`) was known —
     "Raycast reached a new site, linear.app";
   * scope `host` otherwise — "Cursor contacted raw.githubusercontent.com".
2. If the destination IP is known and new for the app → insert it; scope `ip` ("Docker connected to
   104.16.98.215", or "connected straight to" when there was no hostname).
3. Insert an alert unless the host/IP matches a mute pattern (`host`, `IP`, `*.example.com`). Muted hosts
   are still recorded. Entries stay marked NEW for 24 hours.
4. Post a macOS notification (UserNotifications), always: there are no notification settings. It reads like
   the design's banner: "Tidemark", then "Raycast reached a new site" and "notion.com · first host
   api.notion.com · via node". Bursts are grouped: one notification per app and Mac per 30 s. Alerts
   written by *other* Macs are polled and posted on this Mac too, led by that Mac's name, unless their host
   is muted or their app is archived (pausing an app's monitoring here only stops this Mac's alerts).

## Database

`Database/Schema.swift` holds versioned migrations (`schema_migrations`). Main tables: `devices`, `apps`,
`app_installs`, `processes`, `requests`, `app_hosts`, `host_sources`, `ip_info`, `alerts`, `mutes`,
`probe_sessions`, `probe_hosts`, `egress_checks`, `egress_changes`. Connecting reads `schema_migrations`
without a lock; only a build with migrations to apply takes the migration lock, and index changes (such as
schema v3's `requests_active_idx`) are built `CONCURRENTLY` outside it, in the background on large tables, so
no Mac waits for another Mac's upgrade. [DATABASE.md](DATABASE.md) describes the schema versions, the
migration runner and every time limit.

* **Writes** go through `CaptureWriteBuffer`: flush every *N* rows or *T* seconds (default 200 rows / 1 s), as
  multi-row `INSERT … ON CONFLICT (device_id, surge_session, surge_id) DO UPDATE`. A request is written when
  first seen, again when it completes, and every ~10 s while it stays active (within ~2 s when its
  attribution, IP, GeoIP data, policy or rule changes). A statement gets at most 20 s and a flush 30 s; a
  statement stuck on a dead connection fails over to the spool.
* **Errors** — every failed write is classified. `DatabaseError.unreachable` (connection lost, server out of
  resources, read-only…) and `DatabaseError.timedOut` (a statement timeout, a call past its limit) keep the
  data and take the pipeline offline; `DatabaseError.query` means the rows themselves were refused. A refused batch of request rows is written again in halves, and only the
  halves the server refuses again are split further, so one bad row costs a few statements rather than one per
  row; other items are retried one by one. Links to apps and probes that no longer exist are dropped, and rows
  that are still refused are quarantined in `spool/rejected.jsonl`. When every row of a batch is refused and
  nothing else in that flush was written, the server is at fault (a full disk, say): the rows are kept, as for
  an unreachable server.
* **Reconnects** — after a failure, reconnects back off from 1 s to 60 s, and the backoff keeps growing until a
  write succeeds, so a server that accepts connections but refuses writes is not hammered. Connecting and the ping get 20 s each
  (migrations are not bounded here, see DATABASE.md), and writes resume before the shared state has loaded.
  Every third failed reconnect in a row builds a fresh client and retires the old pools, whose connections may
  be stuck on dead sockets.
* **Closing ended requests** — rows Surge will never update again are closed as background maintenance beside
  the writes: `closeActiveRequests` for rows of earlier Surge sessions (scheduled at every launch and Surge
  restart) and `closeVanishedRequests` for rows of the current session that `dump active` no longer lists
  (scheduled by `closeVanished` after each backfill). A doubtful listing closes nothing: one with records
  Tidemark could not decode, or an empty one while many requests are known to be active. A round runs once PostgreSQL is reachable, the spool is
  replayed and nothing still queued would write those rows as active again, one round at a time with its own
  time budget. A statement the server refuses is logged and dropped, since it would fail the same way again;
  any other failure (unreachable, timed out) is retried after ten minutes or at the next reconnect. Neither
  takes capture offline. A closed row keeps a completion time it already has; otherwise it ends at its last
  write by Tidemark, never later than the restart or relaunch.
* **Quitting** — the final flush gets 3 s (what it cannot write goes to the spool and `auxiliary.json`), and
  Tidemark exits after 6 s at the latest (plus up to a second for a surge-cli child that ignores SIGTERM, see
  [Surge integration](#surge-integration)). Requests that are still active stay active in PostgreSQL: the
  connection usually outlives Tidemark, and a row stored as completed is never reopened. The next launch
  closes the ones that ended meanwhile (`closeVanished` for the same Surge session, `closeActiveRequests` for
  earlier ones). A Surge restart or a switch of the recording device still closes the old session's requests.
* **Offline** — when PostgreSQL is unreachable rows are appended to a JSON-lines spool in
  `~/Library/Application Support/Tidemark/spool/` (up to 500,000 rows) and replayed on reconnect.
  `shared-state.json` keeps the last known apps, mutes and inventory index so attribution and first-contact
  detection keep working when Tidemark starts without a database, and `auxiliary.json` keeps unwritten
  inventory and alert work across a quit.
* **Pools** — a 6-connection pool for reads and a separate 2-connection writer pool, each with server-side
  `statement_timeout`, `lock_timeout` and `idle_in_transaction_session_timeout`, so a slow page query can
  never starve the writer. Reads over a long history (History pages, totals and histogram, an app's counters…)
  get a longer budget in their own transaction, and every call also has a client-side limit, so a server that
  stopped answering cannot hold a connection forever; cancelling a writer call closes its connection, so its
  transaction rolls back. Either way the call ends as soon as its connection is closed (within about two
  seconds when the server, the network or the pool closed it).
  [DATABASE.md › Connections](DATABASE.md#connections) lists the limits.
* **Counts** — total rows use `pg_class.reltuples` plus rows written since; "today" is an indexed count.
* **Retention** — none: requests are kept forever.
* **Credentials** — Settings › Database has one URL field: a password typed into it (in the user info or as
  libpq's `password` parameter) goes to the Keychain and the field shows it masked
  (`postgres://tide:••••••••@127.0.0.1:5432/tidemark`). The URL is stored without its password in
  `UserDefaults`; text that is not a `postgres://` or `postgresql://` URL is not stored at all, since it could
  hold a password. `TIDEMARK_DATABASE_URL` (environment) overrides both for development.

## Multi-Mac

Every row carries `device_id`. Each Mac records and alerts on its own requests, and every Mac posts the
notifications of every Mac's alerts. The sidebar's Mac menu
scopes every page to one Mac or all. The live table merges this Mac's stream with rows other Macs wrote
(polled by `updated_at` through `requestsWritten(after:)`, with a few seconds of overlap). "Mark All as
Read" only touches the selected Mac's rows. Apps are shared by bundle path; each Mac reports in `app_installs` whether the
path exists locally ("Installed on MacBook Pro · Mac mini (Office) · Path not found").

## Site Probe

A probe opens a URL in an isolated `WKWebView` (non-persistent data store) whose
`WKWebsiteDataStore.proxyConfigurations` point at a loopback HTTP CONNECT proxy opened only for that
session. The proxy forwards every tunnel to Surge's HTTP proxy port, so Surge still applies rules and
records IP, policy and rule, while Tidemark knows that every connection on that port belongs to the probe.
Hosts are recorded with their first/last activity relative to the probe start and the step (page load,
click, device switch) that first reached them; the waterfall colors same-site hosts with the accent and
other sites in amber. The proxy matches Surge records to the probe by the forwarder's source port and
address. The forwarder dials the interface Surge's HTTP listener is bound to. A probe needs this Mac's Surge,
the only one Tidemark reads: a remote Surge would not see the forwarder's source ports.

Stopping a probe waits for the rest of its tail (a probe records until at least 6 s after its first
page load, so a Stop pressed earlier still catches the page's late requests), lets the last Surge records
arrive for a second, then saves the session. Every caller awaits the stop in progress, so Stop followed by
Quit still saves before Tidemark exits; quitting skips the tail and the grace and bounds the two writes. The
controller clears the running probe before the grace and the save, so the web session marks the whole stop
(`isStopping`): Start Probe, New Probe and the window's Start wait for it, Stop turns into a disabled
"Stopping…", the page holds clicks and navigation, and a stop tears down only the page it stopped, never one
a new probe opened.

## Egress IP

For DIRECT, the global policy (proxy mode) and each policy group's current selection, the egress monitor
asks Surge for the external IP through that policy (`test-policy-external-ip <line hash>`), its latency
(`test-policy <line hash>`) and GeoIP data, and stores the samples. The *current* egress is the policy the
outbound mode or FINAL rule uses. A change of the current egress IP is logged with its likely cause
(policy-group switch from an `environment` event, an automatic group's new pick (`policy-group list` reports
the group type), a network change — `NWPathMonitor` updates are confirmed against Surge's `summary`, because
under enhanced mode the system path describes Surge's own utun interface — and a Surge restart from a new
`start-time`). In rule mode the current route is the FINAL rule's policy (`dump rule`). The network type
(hosting, residential…) comes from the IP info service, proxycheck.io, which is always on (there is no
setting for it); it is only asked about Tidemark's own public egress IPs (DIRECT's, this Mac's public address,
among them) and public IPs the user looks up. Country and ASN come from Surge's GeoIP database and reverse DNS
from this Mac's resolver, falling back to the service's host name.

Whether the current egress reaches IPv6 is tested with `http probe` of an IPv6 literal through its policy,
alongside the IP info lookups (an egress IP that is itself IPv6 needs no test). It reads "No IPv6" only when
Surge says the policy has no route: `No outgoing interface`, Surge's own `HTTP request timeout` (about 15 s,
for a proxy that drops IPv6), an unreachable network or host. Tidemark's own 25 s deadline, a missing or
killed surge-cli and every other failure leave IPv6 unknown, and the next check asks again; an answer is
reused for an hour.

## UI

The window follows the "Three-pane · Native" direction of the design: a Liquid Glass sidebar (Mac menu,
Capture, Analyze, Monitored Apps, Archived, Surge/PostgreSQL status footer), a content column per page,
and an inspector beside the Requests page's live table (History has none). Native controls are preferred
(segmented pickers, switches, `Table`, search fields, sheets, `confirmationDialog`/alerts). Colors come from
`Theme` (exact OKLCH conversions of the design tokens); app tiles use the real app icon when the bundle
exists locally.
History runs its page query and its histogram side by side: the rows appear as soon as the page arrives, a
histogram that fails leaves them in place (the chart area says it is unavailable and why), and a newer query
cancels the older one's histogram.

Strings use `tr("English key", "Table")` with one String Catalog per UI area (`Resources/Localization/*.xcstrings`)
holding the `zh-Hans` translations; Settings › Language switches at runtime.

## Conventions

* Swift 6 language mode (which implies complete strict concurrency), no warnings.
* Views inside SwiftUI `Table` cells and AppKit-hosted panels do not receive custom environment objects on
  macOS 27: pass `AppModel` explicitly there.
* `searchable` always adds the window's search field after every other toolbar item (a
  `DefaultToolbarItem(kind: .search)` does not move it on macOS 27); a page whose design puts the search field
  between other items puts a `ToolbarSearchField` in its own `ToolbarItem` instead, with a `visibilityPriority`
  that keeps it out of the overflow menu longer than the page's other items (it takes ⌘F itself).
* SwiftUI tables run without NSTableView's estimated row heights (`TableRowHeightDefaults`, registered in
  `TidemarkApp.init`): with them, a table that receives more than 200 rows at once re-enters AppKit's row height
  cache, which AppKit logs as a reentrant operation in the table's delegate and will turn into an assert.
* English for all code, comments, docs and commit messages; other languages only in String Catalogs.
* Conventional Commits (`feat(capture): …`, `fix(ui): …`, `test(database): …`).
* No credentials in the repository.
* Tests use Swift Testing (`import Testing`). Database tests run against a throwaway schema and drop it.

## Building

`Tidemark.xcodeproj` is committed and uses Xcode's synchronized folders (`PBXFileSystemSynchronizedRootGroup`):
the `Tidemark` target compiles everything under `Tidemark/` and the `TidemarkTests` target everything under
`TidemarkTests/`. Add, move or delete files on disk; the project file only changes for build settings,
targets or package dependencies. There is no `Info.plist` or entitlements file: the Info.plist is generated
from `INFOPLIST_KEY_*` build settings and the App Sandbox is off (`ENABLE_APP_SANDBOX = NO`) because Tidemark
runs `surge-cli` and reads other processes' details through libproc. PostgresNIO is a Swift package dependency,
pinned in `Tidemark.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`.

```bash
xcodebuild -project Tidemark.xcodeproj -scheme Tidemark -destination 'platform=macOS' build
```

If `xcode-select` points to the Command Line Tools, prefix the command with
`DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.
