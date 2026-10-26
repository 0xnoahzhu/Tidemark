# Tidemark architecture

Tidemark is a native macOS app (SwiftUI, Swift 6, macOS 27) that keeps every request Surge handles in
PostgreSQL, rolls each request up to the app that caused it, and alerts when a monitored app reaches a
domain or IP it has never used before.

```
 surge-cli --raw watch request request-update real-time-speed dns environment reload shutdown
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
| `Services/` | Protocols (`SurgeClient`, `ProcessInspecting`, `SiteClassifying`, `TidemarkDatabase`, `CaptureActions`, `ProbeActions`, `EgressActions`), Surge wire types, inert placeholders | Model |
| `State/` | `@MainActor @Observable` state objects and `AppModel`, the root injected into SwiftUI | Model, Services |
| `Support/` | Formatters, request timing builder, `AppNaming` (an app's name everywhere: Finder's display name of its bundle), `DeviceIdentity` (this Mac's device ID) | Model |
| `Localization/` | `Localizer`, `tr()` / `trf()` / `trn()` | — |
| `Surge/` | `SurgeCLIClient`: runs surge-cli, parses events, reconnects | Services |
| `Process/` | `LibProcInspector` (libproc), `PublicSuffixClassifier` (bundled PSL) | Services |
| `Database/` | `Schema` migrations, `PostgresDatabase` (PostgresNIO) | Services |
| `Capture/` | `CaptureEngine` + `CapturePipeline`: attribution, first-contact detection, alerts, notifications, write buffer, disk spool, stats | all protocols, State |
| `Probe/` | Per-session CONNECT proxy and the probe controller | Services, State |
| `Egress/` | Egress monitor (per-policy external IP, latency, change log, IP lookup) | Services, State |
| `Intents/` | App Intents: Shortcuts and Siri actions, `MonitoredAppEntity` | State |
| `UI/` | SwiftUI views; `Theme/` tokens and `Components/` shared views | State |
| `App/` | `TidemarkApp` scenes, `AppDelegate`, `AppBootstrap` (composition root), commands | everything |

UI code never talks to concrete services: it reads `AppModel`'s state objects and calls the protocol-typed
services on `AppModel` (`model.database`, `model.capture`, `model.probeActions`, `model.egressActions`).
`AppBootstrap` replaces the placeholders with real implementations at launch.

## Surge integration

All Surge access goes through `surge-cli --raw` (JSON output). The executable lives at
`/Applications/Surge.app/Contents/Applications/surge-cli` (also linked from `/usr/local/bin/surge-cli`).
Tidemark reads this Mac's Surge only; there is no remote Surge. A remote controller password that 0.1.0 kept
in the login keychain (`io.tidemark.Tidemark` / `surge.remote.password`) is never read or deleted; users can
delete it in Keychain Access. A stream that ends or fails is always restarted, with backoff.

* **Stream** — `watch request request-update real-time-speed dns environment reload shutdown`. First line is
  `{"result":"Event subscribed"}`. `request` and `request-update` events have the same shape
  (`SurgeRequest`) and carry no event name: a request is *new* the first time its `id` is seen.
  `request-update` fires about once per second for every active connection (~100 events/s on a busy
  Mac), so updates are coalesced in memory. Speed events look like
  `{"in":23416,"out":1140,"downloadSpeedHistory":[…],"uploadSpeedHistory":[…]}`. A `dns` event
  (`{"domain":…,"server":…,"interface":"","data":[IPs]}`, a few a minute) is a resolution Surge's DNS made; the
  next `dump dns` read completes it with the CNAME path, log line, time and expiry, and it is stored in
  `dns_answers`, marked when Tidemark's own lookup caused it ([DATABASE.md › Request details](DATABASE.md#request-details)).
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
  connections. In rule mode the notes name the address Surge resolved to match IP rules (`[Rule] DNS completed, IPv4
  address for matching: …`). Other hostnames are resolved through Surge: a `dump dns` cache read every 30 s, whose
  answers count only until Surge's own `expiresTime` (Surge keeps expired answers listed for hours, and an answer
  without one is not used), and `dns lookup <host>` for the rest. A lookup reports no TTL (`expires-in` 0), so its
  answer counts for a minute, or for as long as Surge's cache holds the same addresses, and keeps its label meanwhile.
  A hostname in use is therefore looked up about once per TTL of its answer (mostly 1–5 minutes; Surge caches some for
  hours). In global-proxy mode Surge resolves nothing itself for proxied requests, so nearly every proxied hostname is
  Tidemark's to look up: on a Mac sending about 60 requests a minute to 40–60 hostnames, roughly 3–10 lookups a minute
  while it is busy (at most 4 at a time), each a short surge-cli process, a query to Surge's DNS server (DoH on the
  sampled Mac) and a `dns_answers` row. A proxy resolves the host again on its side, out of sight, so every request
  records where its address came from and when (`remote_ip_source`: `literal`, `surge`, `rule-dns`, `tidemark-lookup`,
  `surge-cache`). IP-literal hosts (`149.154.175.60:443`) are *direct* IPs ("by IP, no hostname").
* **GeoIP** — `geoip <ip>` → `{country, asn, organization}`; cached in `ip_info`.
* **Policies** — `policy-group list` / `dump policy-group-sub-policies` give options with a `lineHash`
  (`POLICY::…`). Policies that come from a policy-path subscription are **not** addressable by name:
  `test-policy-external-ip` and `test-policy` must be given the line hash. `environment` →
  `ProxyGroupSelection` gives each group's current choice; `ProxyMode` 0/1/2 = direct/global/rule.
* **Proxy errors** — a proxy node keeps its last 15 errors (`proxy-runtime-status <line hash>` →
  `{"errors":[{"error":"Stream closed","time":…,"targetHostname":…}]}`). Once a minute Tidemark asks the nodes (final
  policies) that carried requests in the last minute, the ones asked least recently first, and stores the errors each
  had not listed before in `proxy_errors`: three short-lived surge-cli processes a minute at most, never one per
  request, so with more than three busy nodes (a load-balance group, say) each is asked every few minutes, and one
  with more than 15 errors in between loses the oldest. The line hashes come from `dump traffic`, read before a node
  missing from them is asked (at most every 10 minutes, one of the three processes); a node with none is asked by
  name, and one Surge cannot report on waits 10 minutes. A hash changes with the profile or a policy-path
  subscription: a node Surge no longer knows by a hash read 10 minutes ago or more is asked by a fresh one, read in
  the next minute, and a profile reload or a new Surge session forgets them all.
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
`pathForStatistics` when the process is gone; Surge reports system daemons as the literal
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
3. Insert an alert when the app's alert settings ask for one (any new host or only new sites, new IPs).
   Nothing is muted: there are no mute patterns, so Apple's own hosts (`*.apple.com`, `*.icloud.com`,
   `*.mzstatic.com`) alert like any other. Entries stay marked NEW for 24 hours.
4. Post a macOS notification (UserNotifications), always: there are no notification settings. It reads like
   the design's banner: "Tidemark", then "Raycast reached a new site" and "notion.com · first host
   api.notion.com · via node", and its one action, "View", opens the app's Domains & IPs. Bursts are grouped:
   one notification per app and Mac per 30 s. Alerts written by *other* Macs are polled and posted on this Mac
   too, led by that Mac's name, unless their app is archived (pausing an app's monitoring here only stops this
   Mac's alerts).

## Database

`Database/Schema.swift` holds versioned migrations (`schema_migrations`). Main tables: `devices`, `apps`,
`app_installs`, `processes`, `requests`, `app_hosts`, `host_sources`, `ip_info`, `alerts`,
`probe_sessions`, `probe_hosts`, `egress_checks`, `egress_changes` (`mutes` is still created, but nothing reads or
writes it any more). Connecting reads `schema_migrations`
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
  earlier ones). A Surge restart still closes the old session's requests.
* **Offline** — when PostgreSQL is unreachable rows are appended to a JSON-lines spool in
  `~/Library/Application Support/Tidemark/spool/` (up to 500,000 rows) and replayed on reconnect.
  `shared-state.json` keeps the last known apps and inventory index so attribution and first-contact
  detection keep working when Tidemark starts without a database (the mute patterns earlier versions saved
  there are ignored), and `auxiliary.json` keeps unwritten
  inventory and alert work across a quit. Everything on disk is this Mac's own, so it is replayed under this
  Mac's current device ID, whatever ID it was saved under: an earlier ID may have been merged away meanwhile (see
  [Multi-Mac](#multi-mac)), and a row of a device that no longer exists would be refused. A replayed row whose key
  now matches a stored row merges into it like any rewrite. The ID it was saved under is this Mac's too, and is
  merged into the current one.
* **Merging devices** — `mergeDevice(from, into:, idleFor:)` moves everything one device ID wrote to another and
  deletes the first: requests in batches of 1,000, each its own transaction (a request the target already has is
  merged into the target's row and dropped), then, with `from`'s row locked, processes, installs, host sources and
  the rest. Every transaction waits at most 1 s for a lock, less than capture's writes, so the merge gives way to
  capture (and tries again) instead of the other way round. With `idleFor` it leaves `from` alone when something
  wrote under it during that time or while the merge ran. It is resumable and idempotent. Capture runs it as
  maintenance beside the writes, after the closes of a round (requests it moves that earlier sessions left active
  are closed in the next round), with its own retry time and backoff, and never takes capture offline.
  [DATABASE.md › Merging devices](DATABASE.md#merging-devices) has the statements.
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
* **Credentials** — Settings › Database has one URL field, saved as typed, password included (in the user info
  or as libpq's `password` parameter), in `UserDefaults` (`db.url`). Tidemark keeps nothing in the Keychain:
  ad-hoc signed builds made every new build ask for access to it. The field shows the password masked
  (`postgres://tide:••••••••@127.0.0.1:5432/tidemark`), libpq's `sslpassword` too, and a mask left in place (or
  what is left of it) keeps the saved one unless a new one is typed; the field left as shown saves nothing. Text
  that is not a `postgres://` or `postgresql://` URL is not stored at all, since it could hold a password the mask
  cannot find. Logs and error messages name the server as `host:port/database`
  (`PostgresConnectionURL.redacted`), and an invalid URL only with its password and `sslpassword` removed
  (`PostgresConnectionURL.redact`). `TIDEMARK_DATABASE_URL` (environment) overrides the saved URL for
  development.

## Multi-Mac

Every row carries `device_id`. A Mac's ID is derived from its hardware UUID (`DeviceIdentity`): a name-based UUID
(version 5) of the `IOPlatformUUID` under Tidemark's own namespace, so a Mac keeps its ID whether or not its
preferences can be read, and across reinstalls, while the hardware UUID itself never reaches the shared database
([DATABASE.md › Device identity](DATABASE.md#device-identity) has the derivation). Only a Mac whose hardware UUID
cannot be read falls back to a random ID stored in its preferences (`device.id`).

Earlier versions always used that stored random ID, so a launch that could not read the preferences registered the
Mac a second time, under an ID stored nowhere. Capture merges every earlier ID of this Mac into the derived one
(`mergeDevice`, see [Database](#database)):

* the ID still stored in the preferences, when it differs: the derived ID's row is registered (before writes
  resume, as always) with the earlier row's name, color and age, and the stored ID is forgotten once merged;
* an ID named in the spool or in `auxiliary.json`;
* an ID that shares history with this Mac (`devicesSharingHistory`): a Mac (not a remote Surge's row) that recorded
  one of this Mac's Surge sessions, identified by that Surge's start time in milliseconds, or two of its processes
  (PID and start time). Looked for once merging is due, hourly, and right after a merge moved rows, whose sessions lead
  to an ID invented while the preferences could not be read.

Merging waits two minutes after the launch first reached PostgreSQL and for the spool to be replayed, and skips an
ID that something wrote under since then (an older build beside this one, a Mac the preferences were copied to)
until the next launch. Until an ID has been merged the Mac is listed more than once.

Each Mac records and alerts on its own requests, and every Mac posts the
notifications of every Mac's alerts. The sidebar's Mac menu scopes every page to one Mac or all, except alerts:
the Notifications page, its unread count, "Mark All as Read" and the menu bar list every Mac's alerts. The live
table merges this Mac's stream with rows other Macs wrote (polled by `updated_at` through
`requestsWritten(after:)`, with a few seconds of overlap). Apps are shared by bundle path; each Mac reports in `app_installs` whether the
path exists locally ("Installed on MacBook Pro · Mac mini (Office) · Path not found").

## Site Probe

A probe opens a URL in an isolated `WKWebView` (non-persistent data store) whose
`WKWebsiteDataStore.proxyConfigurations` point at a loopback HTTP CONNECT proxy opened only for that
session. The proxy forwards every tunnel to Surge's HTTP proxy port, so Surge still applies rules and
records IP, policy and rule, while Tidemark knows that every connection on that port belongs to the probe.
Hosts are recorded with their first/last activity relative to the probe start and the step (page load,
click, device switch) that first reached them; the waterfall colors same-site hosts with the accent and
other sites in amber. The proxy matches Surge records to the probe by the forwarder's source port and
address. The forwarder dials the interface Surge's HTTP listener is bound to.

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

Tidemark lives in the menu bar (`StatusItemController`) and shows in the Dock only while one of its windows is open;
no setting changes either. It is an agent app from launch (`LSUIElement`, set through `INFOPLIST_KEY_LSUIElement`), so
no Dock icon flashes at startup. `DockPresence` makes the activation policy `.regular` (a Dock icon, an app switcher
entry, Tidemark's menus in the menu bar) while the main window, Settings or the Site Probe window is on screen or
minimized into the Dock, and `.accessory` again 250 ms after the last of them closes, so moving from one window to
another never takes the icon away. The menu bar panel, sheets, popovers and alerts do not count. A hidden app keeps
its icon while a window that hiding took off screen is still there to come back; once the last of them closes, it
unhides, with nothing to show, and leaves the Dock. Whether Tidemark is in the Dock is its own record, not
`NSApp.activationPolicy()`, which can read `.accessory` for a moment right after the app unhides. It follows each
window's `isVisible` (a window that opens behind other apps posts no occlusion change) and the window and app
notifications, with no polling. The main window opens at launch, so the Dock icon appears with it.
Leaving the Dock while active, Tidemark first hands the focus back to the app that was in front before it. Every way
into a window activates Tidemark first: the menu bar panel's Open Window, Settings… and alerts, a notification's View,
the App Intents (`TidemarkIntents.showMainWindow`) and the menu commands. Each calls `DockPresence.willShowWindow()`
before it activates, which turns Tidemark regular first, so it activates as a regular app and brings its menus into
the menu bar with it; if no window opens after all, it leaves the Dock again 250 ms later. The menu bar panel goes at
once before it activates, rather than fading out: while the panel, a non-activating panel, is key, Tidemark becomes
active only after it has gone, and the new window's title bar stays inactive until then. Turning regular while
already frontmost (the system brought Tidemark forward as an agent: opened again from Finder, Spotlight or the Dock,
or for a foreground App Intent) leaves the previous app's menus in the menu bar, and activating an active app does
nothing, so Tidemark then lends the activation to the Dock and takes it back as it resigns, which takes the focus
from the new window for a moment. Whether Tidemark is in front is `NSRunningApplication.current.isActive`:
`NSApp.isActive` also reads true while the menu bar panel, a non-activating panel, is key. A window that opens behind
other apps takes no focus. While Tidemark is in the Dock, `DockIconUpdater` shows the light or dark `BrandIcon` for
the system's appearance (the Dock follows System Settings, not Settings › Appearance) and the number of unread alerts
as the badge, written afresh to each new Dock tile.

The window follows the "Three-pane · Native" direction of the design: a Liquid Glass sidebar (Mac menu,
Capture, Analyze, Monitored Apps, Archived, Surge/PostgreSQL status footer), a content column per page,
and an inspector beside the Requests page's live and History tables. Native controls are preferred
for switches, tables (`Table`), search fields and sheets; every segmented choice, though, is Tidemark's own
`DesignSegmentedControl`, never the system's: on a rounded fill track with no dividers, each choice shows an SF
Symbol, its title and, where the number is already at hand, a count in a small capsule, and the selected one is
raised on a white cell (20% white in dark mode) with a hairline border. It is 40 px tall in page content and
32 px (`.compact()`) in the window toolbar and Settings, the compact size in a toolbar growing with the UI scale no
taller than the toolbar's 36 pt glass capsule (Settings' grows with the rest of its pane, `inToolbar: false`); a
control with counts drops them, then its icons, where it has too little room. In a toolbar it sits outside the glass
bubble, and VoiceOver and the overflow menu see a picker. Each page draws its title and subtitle in the toolbar's
leading item at the design's size
(`pageToolbar(_:subtitle:items:)`, 15 px bold over 11 px) in place of the system's title, whose size is fixed; it
grows with the UI scale no taller than a toolbar item, and in a narrow window it shortens, the subtitle first, before
the page's items go to the overflow menu. The window keeps the title and subtitle as its own for the Window menu,
Mission Control and VoiceOver. Every window's root
sets the design's line height (`Theme.lineHeight`, CSS `line-height: 1.35`, which SwiftUI also takes as a multiple
of the font's size). The pause /
resume and Stop monitoring confirmations are the design's glass dialogs (`GlassDialog`), laid over the whole
window. Colors come from `Theme` (exact OKLCH conversions of the design tokens); app tiles use the real app
icon when the bundle exists locally. The window chrome is the system's: the sidebar draws its rows on the split
view's own sidebar glass with nothing behind them, and on macOS 27 that glass runs the full height of the window,
edge to edge, with the traffic lights on it (`NSSplitViewItem` draws no floating, inset sidebar pane there).
Settings › General › Liquid Glass tints that glass itself (`SidebarGlassTint` sets its `NSGlassEffectView.tintColor`
to the design's glass color at `--glassA`, with no tint at the Clear end). The Mac menu, the menu bar panel, the
dialogs and the Settings window lay the design's glass color over the system's glass or blur at an opacity of their
own (`GlassSurface`: at least .88 for the Mac menu, .85 for the panel, .6 for the pause dialog, .85 for the
monitoring one and .72 for the Settings window, more as the slider moves toward Tinted), so their text stays legible
over any background.
History runs its page query and its histogram side by side: the rows appear as soon as the page arrives, a
histogram that fails leaves them in place (the chart area says it is unavailable and why), and a newer query
cancels the older one's histogram. Its results live in `AppModel` (`requestsHistory`), so History brought back
within a minute with the same filters, and the same database, shows them at once; once they are more than five
seconds old they are queried again in the background, with no loading state, and only what changed is redrawn.
Results it does not keep are cleared on a return to the page, as on a first visit, while the Live / History switch
leaves them up until the new page arrives. The live table takes in the stream at most twice a second (once a second
while the system asks for reduced resource usage); its filter and the Mac scope apply at once.

The inspector opens on a row of either table, its selection following the keyboard too. Under the connection it tells
the request's journey through Surge (`RequestsJourney`), each stage at its offset from the start and only when
something tells about it: how the request reached Surge; the DNS it needed (in rule mode Surge's lookup for rule
matching and its answer; for a proxied request that the proxy resolved the name on its side, again after any lookup
for rule matching; an answer joined to a request that looked nothing up, as in global proxy mode, only as Tidemark's
own lookup or Surge's resolver answering apart from it; and the remote IP shown with where it came from and how old it
was, an entry of Surge's cache at least that old); the rule; the hops Surge's record shows (entry, policy groups, node
and its type, proxy server, the exit IP the egress check saw for that policy, destination; never router hops); the
connection; and how it ended, with the error its own proxy node reported. Its sources are the request's notes, which
stay the source of truth, and the records joined to it by host and time (`relatedRecords(of:)`), loaded once the
selection rests (`RequestsInspectorDetails`), the related records first; node types come from this Mac's
`policy-group list`, once every ten minutes, and only for this Mac's requests. Surge's log of the request and links to
the first-contact alert, the site probe and the egress change around it follow. The journey and each of its stages are
equatable, so the inspector's other updates leave them alone, and only values the inspector shows nowhere else are
selectable, each selectable text being a text view of its own. The inspector and its scroll view take the size they
are offered without measuring their content (`RequestsInspectorFill`): a flexible frame would have the hosting view's
minimum size lay every text of the request out again on each selection. The timing bar times the wait for the Client
Hello, the DNS lookup Surge timed and the rest of the setup, which in global proxy mode, when the request rode an open
connection of its proxy, is Surge's own work rather than a connect. While the inspector opens, SwiftUI lays the page
out at no height a few times and AppKit's table, seeing none of itself, scrolls to its top; `RequestsTablePlaceKeeper`
puts the rows back, so the selected row stays where it was. `Navigation.openRequests(forHost:)` opens History on one
exact host, shown as a removable chip beside the filters, and the status filter also finds the requests that ended
with an error, which Surge marks completed; it reads the end reason stored since schema v4, so it finds no request
recorded before, which its empty state says.

The Domains & IPs page draws its table itself, as the native inset table looks and behaves (header and separators,
rounded alternate rows continued below the last one, each row one VoiceOver element naming its columns), in one
scroll view whose rows are built as they scroll into view: a `Table` builds and measures every row it shows again on
each switch between All, Domains and IPs and on grouping. `InventoryColumnWidths` sizes the columns as the native
table did: a new table's widths, refitted as the window is resized, header dividers that resize a column, and, when
the columns do not fit, sideways scrolling with square rows. Its lists stay in `AppModel.inventory`
(`InventoryCache`) between visits, sorted once, with their domains and IPs apart: a visit shows the last list at once
and asks PostgreSQL again when it is more than 5 s old, redrawing only when the answer changed, and the open page asks
again 30 s after each answer or failure. A search narrows the cached list as it is typed; the database is asked for
it only when the cached list may lack matches (it holds the query's limit, 2,000 entries, or shows one Mac, while the
database also matches a search against the apps that reached a host on the other Macs).

Strings use `tr("English key", "Table")` with one String Catalog per UI area (`Resources/Localization/*.xcstrings`)
holding the `zh-Hans` translations. Tidemark has no language setting: `Localizer` takes the localization macOS
picked for the app bundle at launch, the first of the system's preferred languages that has a translation (a
language chosen for Tidemark alone in System Settings › General › Language & Region comes first), else English. The
system's menus and alerts read in the same localization, and both keep it until Tidemark quits, so a new language
list applies at the next launch.

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
  cache, which AppKit logs as a reentrant operation in the table's delegate and will turn into an assert. A table
  whose rows have the design's height gets it from a cell's minimum height (the request table's 28 px, less what
  the inset style adds), not from `rowHeight`.
* Sizes in UI code are the design's px through `UIScale` (`14.px`, `.design(12)`, `.designMono(11)`), so the whole
  window grows or shrinks with one factor; hairlines, opacities and the system's chrome stay as they are. Tidemark
  ships at 1.0 (`UIScale.standard`): each design px is one point, so the main window opens at 1248×812 and is at
  least 1000×640. Every page, the menu bar panel, Settings, the sheets and the shared components are written this
  way. Settings' panes grow under the system's tab toolbar, 88 pt at every factor,
  and its native switch and slider are a control size larger from 1.2. `scripts/check-design-px.sh` lists the
  sizes in `Tidemark/UI` still written in points (fonts, stack spacing, padding, frames, corner radii), except the
  few it allows, which the scale must not change (the probe window sized for its web page, Xcode previews).
  The main window's saved frame and sidebar width are forgotten once when the factor asked for changes
  (`MainWindowFrame`), not when a small screen lowers it.
* A toolbar whose page draws its own title (`toolbar(removing: .title)`) needs a `ToolbarSpacer(.flexible)` in
  the same toolbar content as the trailing items, or they follow the title instead of keeping to the trailing end.
  The toolbar keeps a SwiftUI item at its ideal width and drops spaces and items instead of narrowing it, unless
  its content is `toolbarItemCompressible()`, as the page title is.
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
