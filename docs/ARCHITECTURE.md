# Tidemark architecture

Tidemark is a native macOS app (SwiftUI, Swift 6, macOS 27) that keeps every request Surge handles in
PostgreSQL, rolls each request up to the app that caused it, and alerts when a monitored app reaches a
domain or IP it has never used before.

```
 surge-cli --raw watch request request-update real-time-speed environment reload shutdown
        │  (one JSON object per line)
        ▼
 SurgeCLIClient ──► CaptureEngine ──► WriteBuffer ──► PostgresDatabase ──► PostgreSQL
                       │   ▲               │ (spool to disk while offline)
     LibProcInspector ─┘   │               ▼
     PublicSuffixClassifier│          LiveState / CatalogState / AlertState (MainActor, @Observable)
     DNS + GeoIP caches ───┘               ▼
                                     SwiftUI: main window · menu bar extra · settings
```

## Layers and directories

| Directory | Contents | Depends on |
|---|---|---|
| `Model/` | Value types shared by every layer (`RequestRecord`, `MonitoredApp`, `AlertItem`, …) | Foundation |
| `Services/` | Protocols (`SurgeClient`, `ProcessInspecting`, `SiteClassifying`, `TidemarkDatabase`, `CaptureActions`, `ProbeActions`, `EgressActions`), Surge wire types, inert placeholders | Model |
| `State/` | `@MainActor @Observable` state objects and `AppModel`, the root injected into SwiftUI | Model, Services |
| `Support/` | Formatters, Keychain, request timing builder | Model |
| `Localization/` | `Localizer`, `tr()` / `trf()` / `trn()` | — |
| `Surge/` | `SurgeCLIClient`: runs surge-cli, parses events, reconnects | Services |
| `Process/` | `LibProcInspector` (libproc), `PublicSuffixClassifier` (bundled PSL) | Services |
| `Database/` | `Schema` migrations, `PostgresDatabase` (PostgresNIO), `WriteBuffer` + disk spool | Services |
| `Capture/` | `CaptureEngine`: attribution, first-contact detection, alerts, notifications, stats, retention | all protocols, State |
| `Probe/` | Per-session CONNECT proxy and the probe controller | Services, State |
| `Egress/` | Egress monitor (per-policy external IP, latency, change log, IP lookup) | Services, State |
| `UI/` | SwiftUI views; `Theme/` tokens and `Components/` shared views | State |
| `App/` | `TidemarkApp` scenes, `AppDelegate`, `AppBootstrap` (composition root), commands | everything |

UI code never talks to concrete services: it reads `AppModel`'s state objects and calls the protocol-typed
services on `AppModel` (`model.database`, `model.capture`, `model.probeActions`, `model.egressActions`).
`AppBootstrap` replaces the placeholders with real implementations at launch.

## Surge integration

All Surge access goes through `surge-cli --raw` (JSON output). The executable lives at
`/Applications/Surge.app/Contents/Applications/surge-cli` (also linked from `/usr/local/bin/surge-cli`).
For a remote Surge, add `--remote host:port` and send the password on stdin with `--password-stdin`
(never in argv).

* **Stream** — `watch request request-update real-time-speed environment reload shutdown`. First line is
  `{"result":"Event subscribed"}`. `request` and `request-update` events have the same shape
  (`SurgeRequest`) and carry no event name: a request is *new* the first time its `id` is seen.
  `request-update` fires about once per second for every active connection (~100 events/s on a busy
  Mac), so updates are coalesced in memory. Speed events look like
  `{"in":23416,"out":1140,"downloadSpeedHistory":[…],"uploadSpeedHistory":[…]}`.
* **Sessions** — request IDs restart when the Surge engine restarts. `status` → `start-time` (seconds)
  is the session key; the DB key is `(device_id, surge_session_ms, surge_id)`.
* **Backfill** — on (re)connect, `dump recent` returns the last 200 requests with full details.
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
`pathForStatistics`, the only option for a remote Surge) and land only in the global log.

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
4. Post a macOS notification (UserNotifications). Bursts are grouped: one notification per app per 30 s.
   Alerts written by *other* Macs are polled and shown only if enabled.

## Database

`Database/Schema.swift` holds versioned migrations (`schema_migrations`). Main tables: `devices`, `apps`,
`app_installs`, `processes`, `requests`, `app_hosts`, `host_sources`, `ip_info`, `alerts`, `mutes`,
`probe_sessions`, `probe_hosts`, `egress_checks`, `egress_changes`.

* **Writes** go through `WriteBuffer`: flush every *N* rows or *T* seconds (default 200 rows / 1 s), as
  multi-row `INSERT … ON CONFLICT (device_id, surge_session, surge_id) DO UPDATE`. A request is written when
  first seen, again when it completes, and every ~10 s while it stays active.
* **Offline** — when PostgreSQL is unreachable rows are appended to a JSON-lines spool in
  `~/Library/Application Support/Tidemark/spool/` (up to 500,000 rows) and replayed on reconnect.
* **Counts** — total rows use `pg_class.reltuples` plus rows written since; "today" is an indexed count.
* **Retention** — optional; deletes requests older than *N* days in batches every hour.
* **Credentials** — the URL is stored without its password in `UserDefaults`; the password lives in the
  Keychain. `TIDEMARK_DATABASE_URL` (environment) overrides both for development.

## Multi-Mac

Every row carries `device_id`. Each Mac records and alerts on its own requests. The sidebar's Mac menu
scopes every page to one Mac or all. The live table merges this Mac's stream with rows other Macs wrote
(polled by `written_at`). Apps are shared by bundle path; each Mac reports in `app_installs` whether the
path exists locally ("Installed on MacBook Pro · Mac mini (Office) · Path not found").

## Site Probe

A probe opens a URL in an isolated `WKWebView` (non-persistent data store) whose
`WKWebsiteDataStore.proxyConfigurations` point at a loopback HTTP CONNECT proxy opened only for that
session. The proxy forwards every tunnel to Surge's HTTP proxy port, so Surge still applies rules and
records IP, policy and rule, while Tidemark knows that every connection on that port belongs to the probe.
Hosts are recorded with their first/last activity relative to the probe start and the step (page load,
click, device switch) that first reached them; the waterfall colors same-site hosts with the accent and
other sites in amber. The proxy matches Surge records to the probe by the forwarder's source port.

## Egress IP

For DIRECT, the global policy (proxy mode) and each policy group's current selection, the egress monitor
asks Surge for the external IP through that policy (`test-policy-external-ip <line hash>`), its latency
(`test-policy <line hash>`) and GeoIP data, and stores the samples. The *current* egress is the policy the
outbound mode or FINAL rule uses. A change of the current egress IP is logged with its likely cause
(policy-group switch from an `environment` event, auto-test pick, network change from `NWPathMonitor`,
Surge restart from a new `start-time`).

## UI

The window follows the "Three-pane · Native" direction of the design: a Liquid Glass sidebar (Mac menu,
Capture, Analyze, Monitored Apps, Archived, Surge/PostgreSQL status footer), a content column per page,
and an inspector on the Requests page. Native controls are preferred (segmented pickers, switches,
`Table`, search fields, sheets, `confirmationDialog`/alerts). Colors come from `Theme` (exact OKLCH
conversions of the design tokens); app tiles use the real app icon when the bundle exists locally.

Strings use `tr("English key", "Table")` with one String Catalog per UI area (`Resources/Localization/*.xcstrings`)
holding the `zh-Hans` translations; Settings › Language switches at runtime.

## Conventions

* Swift 6 language mode, complete strict concurrency, no warnings.
* English for all code, comments, docs and commit messages; other languages only in String Catalogs.
* Conventional Commits (`feat(capture): …`, `fix(ui): …`, `test(database): …`).
* No credentials in the repository.
* Tests use Swift Testing (`import Testing`). Database tests run against a throwaway schema and drop it.

## Building

```bash
brew install xcodegen
xcodegen generate
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild -project Tidemark.xcodeproj -scheme Tidemark -destination 'platform=macOS' build
```
