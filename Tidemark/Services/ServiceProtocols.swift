import Foundation

// Contracts between Tidemark's layers. Concrete implementations live in:
//   SurgeClient          → Surge/      (SurgeCLIClient)
//   ProcessInspecting    → Process/    (LibProcInspector)
//   SiteClassifying      → Process/    (PublicSuffixClassifier)
//   TidemarkDatabase     → Database/   (PostgresDatabase)
//   Engine protocols     → Capture/, Probe/, Egress/
// UI code depends only on these protocols and on the observable state in State/.

// MARK: - Surge

/// Connection target for surge-cli.
struct SurgeEndpoint: Hashable, Sendable, Codable {
    /// Absolute path of the surge-cli executable.
    var cliPath: String
    /// `host:port` of a remote Surge controller (`--remote`); nil for the local instance.
    var remote: String?
    /// Password for the remote controller; passed through `--password-stdin`, never argv.
    var password: String?

    static let defaultCLIPaths = [
        "/Applications/Surge.app/Contents/Applications/surge-cli",
        "/usr/local/bin/surge-cli",
        "/opt/homebrew/bin/surge-cli",
    ]
}

/// Talks to Surge through `surge-cli --raw`.
protocol SurgeClient: Sendable {
    var endpoint: SurgeEndpoint { get }

    /// Long-running subscription to `request`, `request-update`, `real-time-speed`, `environment`,
    /// `reload` and `shutdown` events. The stream finishes when the child process exits; callers
    /// reconnect with backoff.
    func events() -> AsyncThrowingStream<SurgeEvent, Error>

    func status() async throws -> SurgeStatus
    func environment() async throws -> SurgeEnvironment
    /// The 200 most recent requests (`dump recent`), used to backfill on (re)connect.
    func recentRequests() async throws -> [SurgeRequest]
    func activeRequests() async throws -> [SurgeRequest]
    func dnsLookup(_ domain: String) async throws -> SurgeDNSLookup
    /// Surge's DNS cache: domain → addresses (`dump dns`).
    func dnsCache() async throws -> [String: [String]]
    func geoIP(_ ip: String) async throws -> SurgeGeoIP
    func ruleMatch(host: String, processPath: String?) async throws -> SurgeRuleMatch
    func httpProbe(url: String, policy: String?) async throws -> SurgeHTTPProbe
    /// Policy groups with their options and current selection.
    func policyGroups() async throws -> [SurgePolicyGroup]
    /// External IP as seen through a policy. `policy` is a name or a `POLICY::` line hash;
    /// nil tests the default route (`test external-ip`).
    func externalIP(policy: String?) async throws -> String
    /// Round-trip latency in milliseconds through a policy (name or line hash), nil when unavailable.
    func policyLatency(policy: String) async throws -> Int?
    func network() async throws -> ThisMacNetwork
    /// Port of Surge's HTTP proxy listener (`http-listen`, usually 6152).
    func httpProxyPort() async throws -> Int
}

// MARK: - Processes

/// A live process as reported by libproc.
struct LiveProcess: Hashable, Sendable {
    var pid: Int32
    var parentPID: Int32
    var name: String
    var path: String?
    var startTime: Date
}

/// Reads the local process table (only meaningful for requests from this Mac's own Surge).
protocol ProcessInspecting: Sendable {
    func process(pid: Int32) -> LiveProcess?
    /// Ancestry of `pid`, root → leaf, excluding launchd (PID 1) and the kernel (PID 0).
    /// Returns an empty array when the PID no longer exists or was reused after `notAfter`
    /// (i.e. the live process started after the request did).
    func chain(pid: Int32, notAfter: Date?) -> [ProcessLink]
    /// `true` if a process with this PID and start time is still running.
    func isRunning(pid: Int32, startTime: Date) -> Bool
}

/// Registrable-domain logic backed by the Public Suffix List.
protocol SiteClassifying: Sendable {
    /// `objects.githubusercontent.com` → `githubusercontent.com`; IP literals are returned unchanged.
    func site(for host: String) -> String
}

// MARK: - Database

/// Every database read and write Tidemark performs. Implemented with PostgresNIO.
protocol TidemarkDatabase: Sendable {
    // Connection & schema
    func connect() async throws
    /// Applies pending migrations; returns the schema version afterwards.
    @discardableResult func migrate() async throws -> Int
    /// Round trip of `SELECT 1`, plus the bare server version (`18.3`).
    func ping() async throws -> (roundTrip: Duration, serverVersion: String)
    func schemaVersion() async throws -> Int
    func tableNames() async throws -> [String]

    // Devices
    func upsertDevice(_ device: Device) async throws
    func devices() async throws -> [Device]
    func renameDevice(_ id: DeviceID, name: String) async throws

    // Apps
    func apps() async throws -> [MonitoredApp]
    func insertApp(_ app: MonitoredApp) async throws
    func updateApp(_ app: MonitoredApp) async throws
    /// Removes the app, its inventory, alerts and settings. Requests stay and lose their `app_id`.
    func deleteApp(_ id: AppID) async throws
    func setInstalled(appID: AppID, deviceID: DeviceID, installed: Bool) async throws
    /// appID → deviceID → installed
    func installs() async throws -> [AppID: [DeviceID: Bool]]
    func appStats(_ id: AppID, scope: DeviceScope) async throws -> AppStats
    /// Number of requests (any device) whose process lives in `bundlePath`, for the backfill preview.
    func countRequests(inBundle bundlePath: String) async throws -> Int64
    /// Attributes past requests in `bundlePath` to `appID` and rebuilds its inventory. Returns rows touched.
    func backfill(appID: AppID, bundlePath: String) async throws -> Int64

    // Requests
    /// Upserts by `(device_id, surge_session, surge_id)`. Returns the row IDs.
    @discardableResult func upsertRequests(_ rows: [RequestRecord]) async throws -> [RequestKey: Int64]
    func queryRequests(_ query: RequestQuery) async throws -> RequestPage
    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram
    /// Rows inserted or updated by devices other than `excluding` strictly after `cursor` in the server's write
    /// order `(updated_at, id)`, oldest first, at most `limit` (live view for other Macs). Page by passing the
    /// last row's position (`RequestWriteCursor(_:)`) until a page comes back shorter than `limit`; a row
    /// written again moves to the end of the order. `updated_at` is the writing transaction's start time, so a
    /// transaction that commits late adds rows just behind positions already read: poll again from a few
    /// seconds behind the newest position read and skip the positions already seen.
    func requestsWritten(after cursor: RequestWriteCursor, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord]
    /// The server's current position in that order (its own clock, before every row written from now on),
    /// where polling `requestsWritten(after:)` starts. This Mac's clock never takes part.
    func requestWritePosition() async throws -> RequestWriteCursor
    func distinctPolicies(since: Date?) async throws -> [String]
    func countRequests(since: Date, scope: DeviceScope) async throws -> Int64
    /// Fast estimate of the total row count (`pg_class.reltuples` refined by exact counts when small).
    func estimatedRequestCount() async throws -> Int64
    /// Deletes requests that started before `olderThan`, only `deviceID`'s rows when given (each Mac applies
    /// its own retention setting to its own history), every Mac's rows when nil.
    func deleteRequests(olderThan: Date, deviceID: DeviceID?) async throws -> Int64
    /// Upserts like `upsertRequests` and also reports how many rows were inserted rather than updated.
    func upsertRequestsCountingInserts(_ rows: [RequestRecord]) async throws -> RequestUpsertResult
    /// Marks `deviceID`'s rows that are still `active` from Surge sessions before `session` completed: Surge
    /// restarted, so they will never be updated again. A stored `completed_at` is kept; otherwise it becomes
    /// `GREATEST(started_at, LEAST(updated_at, date))`, the row's last write (its last observed change) capped
    /// at `date` (the new session's start) and never before the request started. `updated_at` moves on, so
    /// other Macs see the change. Returns the rows changed.
    func closeActiveRequests(deviceID: DeviceID, before session: Int64, at date: Date) async throws -> Int64
    /// Marks `deviceID`'s rows of `session` that are still `active` but that Surge no longer lists as active
    /// (`keeping` holds the IDs `dump active` returned) completed, with the same `completed_at` as
    /// `closeActiveRequests`: a stored one, otherwise the row's last write capped at `date` (the listing's
    /// time) and never before the request started. Rows that started at or after `startedBefore` are left
    /// alone: they may be newer than the listing. Closes connections that ended while Tidemark was not
    /// running. Returns the rows changed.
    func closeVanishedRequests(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date, at date: Date) async throws -> Int64
    /// The number of rows `closeVanishedRequests` would close with the same arguments, without closing them.
    func countVanishedRequests(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date) async throws -> Int64

    // Processes
    /// Upserts by `(device_id, pid, start_time)`; links parents in chain order. Returns the leaf row ID.
    @discardableResult func upsertProcessChain(deviceID: DeviceID, chain: [ProcessLink], appID: AppID?) async throws -> Int64?
    func processTree(appID: AppID, scope: DeviceScope) async throws -> [ProcessNode]

    // Inventory
    /// Loads every known (kind, value) per app, used to detect first contact.
    func knownHosts() async throws -> [AppID: Set<String>]
    /// Inserts first-contact rows. Returns the subset that was actually new (another Mac may have won the race).
    func insertAppHosts(_ hosts: [AppHost]) async throws -> [AppHost]
    /// Bumps `last_seen` / `request_count` / `policy` / `hosts` for known entries.
    func touchAppHosts(_ hosts: [AppHost]) async throws
    func appHosts(_ appID: AppID, scope: DeviceScope) async throws -> [AppHost]
    /// Records `(kind, value, device, source path)` for the global inventory.
    func touchHostSources(_ sources: [HostSourceTouch]) async throws
    func inventory(kind: HostKind?, search: String, scope: DeviceScope) async throws -> [InventoryEntry]

    // IP info
    func ipInfo(_ ip: String) async throws -> GeoInfo?
    func saveIPInfo(_ ip: String, geo: GeoInfo) async throws

    // Alerts & mutes
    @discardableResult func insertAlerts(_ alerts: [AlertItem]) async throws -> [AlertItem]
    func alerts(filter: AlertFilter, appID: AppID?, scope: DeviceScope, limit: Int) async throws -> [AlertItem]
    func alerts(after id: Int64, excluding: DeviceID?) async throws -> [AlertItem]
    func unreadAlertCount(scope: DeviceScope) async throws -> Int
    func markAlertsRead(_ ids: [Int64]) async throws
    /// Marks every unread alert read, limited to `appID` when given and to the scope's Mac.
    func markAllAlertsRead(appID: AppID?, scope: DeviceScope) async throws
    func deleteAlert(_ id: Int64) async throws
    func mutes() async throws -> [String]
    func addMute(_ pattern: String) async throws
    func removeMute(_ pattern: String) async throws

    // Site probes
    func saveProbeSession(_ session: ProbeSession) async throws
    func probeSessions(limit: Int) async throws -> [ProbeSession]
    func deleteProbeSession(_ id: UUID) async throws

    // Host insights (on-device model output, shared cache)
    func hostInsight(_ host: String, language: String) async throws -> HostInsight?
    func saveHostInsight(_ insight: HostInsight) async throws

    // Egress
    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws
    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample]
    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws
    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange]
}

/// Result of `upsertRequestsCountingInserts`.
struct RequestUpsertResult: Sendable {
    var ids: [RequestKey: Int64]
    /// Rows that did not exist before (updates of known rows are not counted).
    var inserted: Int
}

/// Position in the order rows are written to `requests`: `(updated_at, id)`, both set by the server.
/// `requestsWritten(after:)` returns the rows strictly after it.
struct RequestWriteCursor: Hashable, Comparable, Sendable {
    var updatedAt: Date
    var rowID: Int64

    /// Before every row.
    static let start = RequestWriteCursor(updatedAt: .distantPast, rowID: 0)

    init(updatedAt: Date, rowID: Int64) {
        self.updatedAt = updatedAt
        self.rowID = rowID
    }

    /// The position of a row read from the database; nil for a record that was never written.
    init?(_ record: RequestRecord) {
        guard let updatedAt = record.writtenAt, let rowID = record.rowID else { return nil }
        self.init(updatedAt: updatedAt, rowID: rowID)
    }

    static func < (a: RequestWriteCursor, b: RequestWriteCursor) -> Bool {
        a.updatedAt != b.updatedAt ? a.updatedAt < b.updatedAt : a.rowID < b.rowID
    }
}

extension TidemarkDatabase {
    /// Default for test doubles: every written row counts as inserted.
    func upsertRequestsCountingInserts(_ rows: [RequestRecord]) async throws -> RequestUpsertResult {
        let ids = try await upsertRequests(rows)
        return RequestUpsertResult(ids: ids, inserted: ids.count)
    }

    func closeActiveRequests(deviceID: DeviceID, before session: Int64, at date: Date) async throws -> Int64 { 0 }

    func closeVanishedRequests(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date, at date: Date) async throws -> Int64 { 0 }

    func countVanishedRequests(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date) async throws -> Int64 { 0 }
}

/// One `(host or IP, source)` observation for the global inventory (`host_sources`).
struct HostSourceTouch: Hashable, Sendable {
    var kind: HostKind
    var value: String
    var deviceID: DeviceID
    /// Process path, or `probe:<session id>`.
    var sourcePath: String
    var sourceTitle: String
    var appID: AppID?
    var bundlePath: String?
    var seenAt: Date
    var requestDelta: Int64
    var geo: GeoInfo?
}

/// Database failures, classified by whether retrying the same work can succeed.
enum DatabaseError: Error, Sendable, Equatable, LocalizedError {
    case notConfigured
    case invalidURL(String)
    /// The server cannot do the work right now (connection lost, timeout, shutting down, out of
    /// connections or disk, read-only, serialization failure…). Retry later; keep the data.
    case unreachable(String)
    /// The statement itself was rejected (bad data, constraint or foreign-key violation). Retrying the same
    /// rows fails again.
    case query(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: "No PostgreSQL connection is configured."
        case .invalidURL(let url): "Invalid PostgreSQL URL: \(url)"
        case .unreachable(let message): "PostgreSQL is unreachable: \(message)"
        case .query(let message): "PostgreSQL error: \(message)"
        }
    }
}

// MARK: - Engine (actions the UI triggers)

/// Recording, apps, alerts and devices. Implemented by the capture engine.
@MainActor
protocol CaptureActions: AnyObject {
    /// Pause or resume writing requests and firing alerts, updating `LiveState.recording` on the main
    /// actor before returning. Resumes automatically on next launch.
    func setRecording(_ on: Bool)
    /// Reconnects to Surge and PostgreSQL with the current settings.
    func reconnect()

    func monitorApp(path: String, includeChildren: Bool, alertOnDomain: Bool, alertOnIP: Bool, backfill: Bool) async throws -> MonitoredApp
    func updateApp(_ app: MonitoredApp) async throws
    func archiveApp(_ id: AppID) async throws
    func restoreApp(_ id: AppID) async throws
    func deleteApp(_ id: AppID) async throws
    /// Session-only pause of an app's inventory and alerts ("Stop monitoring").
    func setMonitoring(_ id: AppID, enabled: Bool)
    /// Running apps that are not monitored yet, with their backfill counts.
    func monitorCandidates() async -> [AppCandidate]

    func markAlertsRead(_ ids: [Int64]) async
    func markAllAlertsRead(appID: AppID?) async
    /// Mutes `pattern` (`host`, `IP` or `*.example.com`) and removes the given alert from the list.
    func mute(_ pattern: String, dismissingAlert: Int64?) async
    func unmute(_ pattern: String) async

    func renameThisMac(_ name: String) async
    func testDatabaseConnection() async -> Result<String, Error>
}

/// Site Probe sessions. The UI hosts the web view; the engine owns the per-session proxy.
@MainActor
protocol ProbeActions: AnyObject {
    /// Opens a per-session HTTP CONNECT proxy that forwards to Surge and starts recording.
    /// Returns the loopback port the web view must use as its proxy.
    func startProbe(url: String, mode: ProbeDeviceMode, tail: Bool) async throws -> UInt16
    /// Adds a step (page load, click, device switch) to the running probe.
    func recordStep(label: String, url: String?)
    /// Called by the web view when the probe's first page load finishes (switches the phase to recording).
    func pageDidFinishLoading()
    /// Stops recording, saves the session and returns it.
    @discardableResult func stopProbe() async -> ProbeSession?
    func deleteProbe(_ id: UUID) async
}

/// On-device explanations of hosts (FoundationModels). Results are cached in `host_insights`.
@MainActor
protocol HostInsightProviding: AnyObject {
    /// `false` when Apple Intelligence is off, the model is downloading, or the device is unsupported.
    var isAvailable: Bool { get }
    /// Why the model is unavailable, for display (nil when available).
    var unavailableReason: String? { get }
    /// Cached insight, or a fresh one from the model.
    func insight(for context: HostContext) async throws -> HostInsight
    /// The insight for `host` in the current language from memory or the database, without running the model.
    func cachedInsight(for host: String) async -> HostInsight?
    /// Warms the model up (call when the inspector opens and no cached insight exists).
    func prewarm()
}

extension ProbeActions {
    func pageDidFinishLoading() {}
}

/// Egress IP checks and IP lookups.
@MainActor
protocol EgressActions: AnyObject {
    func checkAll() async
    func lookup(ip: String) async -> IPLookupResult
}
