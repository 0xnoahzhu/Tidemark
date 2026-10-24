import Foundation
import os

/// Settings the pipeline reads from `Preferences`.
struct CaptureSettings: Sendable, Equatable {
    /// Device the rows are written under: this Mac, or the row of a remote Surge.
    var deviceID: DeviceID
    /// Surge runs on another machine: there is no local process table.
    var isRemote: Bool
    var batchRows: Int
    var batchInterval: TimeInterval
    /// Tidemark's own executable. Its requests (site probe forwarders, IP lookups) never roll up to a
    /// monitored app, and Surge records from it may belong to a site probe.
    var ownExecutablePath: String?

    /// Tidemark's own bundle (`/Applications/Tidemark.app`), shown as the app of its own requests.
    var ownBundlePath: String? { ownExecutablePath.flatMap(CaptureRecordMapper.outermostBundle(in:)) }
}

/// Surge events the main actor reacts to (egress checks, status).
enum CaptureSurgeSignal: Hashable, Sendable {
    case environmentChanged
    case reload
    case shutdown
    /// The stream suggests Surge's engine restarted (request IDs started over, a second subscription
    /// acknowledgement): re-read `status` and compare the session key.
    case sessionCheck
}

/// Coalesced changes for the main actor, drained about four times a second.
struct CaptureUIUpdate: Sendable {
    /// Rows that changed since the last drain (new rows included).
    var records: [RequestRecord] = []
    /// Keys of rows first seen since the last drain.
    var fresh: Set<RequestKey> = []
    /// Requests first seen from the live stream (backfill excluded).
    var newRequests = 0
    /// Rows PostgreSQL inserted (rewrites of rows it already had are not counted).
    var rowsWritten = 0
    var lastWriteAt: Date?
    /// Rows waiting because PostgreSQL is unreachable: the on-disk spool, plus the rows queued in memory
    /// while offline (not the batch that is about to be written normally).
    var bufferedRows = 0
    var speed: SurgeSpeed?
    /// Alerts inserted by this Mac, with their database IDs.
    var alerts: [AlertItem] = []
    /// Apps whose inventory grew.
    var inventoryChanged: Set<AppID> = []
    var signals: [CaptureSurgeSignal] = []
    /// Set once when a write failed and the pipeline went offline.
    var databaseFailure: String?
    /// The error behind `databaseFailure` (the engine describes it in the UI language).
    var databaseError: (any Error)?
    var databaseOnline = false
    /// Another Mac had already recorded inventory entries this Mac believed were new: the local index is stale.
    var lostInventoryRace = false
}

/// Processes Surge events off the main actor: maps and attributes requests, resolves remote IPs and GeoIP
/// data, detects first contact, batches writes (spooling to disk while PostgreSQL is unreachable) and
/// accumulates UI changes that the engine drains periodically.
///
/// The pipeline's state is internal (not private) only so its extensions in other files can reach it.
actor CapturePipeline {
    struct Entry {
        var record: RequestRecord
        var pathForStatistics: String?
        var sourcePort: Int?
        /// Surge's `sourceAddress` (`127.0.0.1` for proxy clients such as the probe, `198.18.0.1` for VIF flows).
        var sourceAddress: String? = nil
        /// Surge's name of the device that made the request (LAN clients of a gateway Surge).
        var deviceName: String?
        var appsVersion: Int
        /// When this pipeline first saw the request.
        var firstSeen: Date
        var lastQueued: Date
        /// Latest event (or backfill) that reported the request.
        var lastSeen: Date
        var dirty = false
        /// Changed in a way worth writing soon (attribution, remote IP, GeoIP, NEW, probe), not only bytes.
        var urgent = false
        var finishedAt: Date?
        var probeMatched = false
        /// First seen in `dump recent`: a previous run may already have counted it in the inventory.
        var backfilled = false
        /// Its first-contact evaluation drafted an alert; a late IP must not add a second one.
        var alertDrafted = false
        var domainSourceRecorded = false
        var ipSourceRecorded = false
    }

    /// Closing of `deviceID`'s rows left active by Surge sessions before `before`.
    struct SessionClose: Equatable, Sendable {
        var before: Int64
        var at: Date
    }

    /// Closing of `deviceID`'s rows of `session` that `dump active` no longer listed at `at` (`keeping` holds
    /// the listed IDs; rows that started at or after `startedBefore` may be newer than the listing).
    struct VanishedClose: Equatable, Sendable {
        var deviceID: DeviceID
        var session: Int64
        var keeping: Set<Int64>
        var startedBefore: Date
        var at: Date
    }

    static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "capture")

    /// Seconds to wait for a remote IP and its GeoIP data before evaluating first contact without them.
    let contactGrace: TimeInterval
    /// Active requests are rewritten at most this often while they change.
    let activeRewriteInterval: TimeInterval = 10
    /// Rows with attribution, IP, GeoIP or NEW changes are rewritten after this short pause (to coalesce them).
    let urgentRewriteDelay: TimeInterval = 2
    let maxConcurrentLookups = 4
    /// Longest wait for a new app's inventory before its first contacts are evaluated anyway.
    let inventoryWait: TimeInterval = 120
    /// A process that keeps making requests is upserted again this often, keeping its `last_seen` fresh.
    let processRetouchInterval: TimeInterval = 180
    /// How long a request may stay without a process path before its host sources are recorded without one.
    let sourceWait: TimeInterval = 10
    /// Longest single database write; a statement stuck on a dead connection fails over to the spool.
    let writeTimeout: Duration
    /// Longest regular flush (all of its statements together).
    let flushBudget: Duration = .seconds(30)
    /// Longest flush when Tidemark quits (the rest goes to the spool).
    let finalFlushBudget: Duration = .seconds(3)
    /// The local snapshot of the shared state is rewritten at most this often.
    let snapshotInterval: TimeInterval = 600
    /// Longest wait for one maintenance statement (closing rows of ended sessions). Longer than the server's
    /// own 10-minute limit for these statements, so a new attempt never overlaps one still running there.
    let maintenanceBudget: Duration = .seconds(660)
    /// A failed maintenance statement is tried again after this long, or after the next reconnect.
    let maintenanceRetryInterval: TimeInterval = 600
    /// Margin on `dump active`'s time for a remote Surge, whose clock may differ from this Mac's.
    let remoteClockMargin: TimeInterval = 60

    // Dependencies
    var database: any TidemarkDatabase
    var surge: any SurgeClient
    let processes: any ProcessInspecting
    let classifier: any SiteClassifying
    let probes: ProbeRegistry
    var settings: CaptureSettings

    // Session
    var session: Int64 = 0
    /// Bumped whenever the session or the recording device changes; backfills of an older epoch are dropped.
    var epoch = 0
    var recording = true
    var entries: [Int64: Entry] = [:]
    var ignored: Set<Int64> = []
    /// Highest request ID seen in this session and its start (IDs grow with time within one engine session).
    var maxSeen: (id: Int64, startedAt: Date)?
    /// Events held while the engine checks whether Surge restarted (their IDs look recycled).
    var held: [SurgeRequest] = []
    var holdingSince: Date?
    var lastSessionCheckSignal: Date?
    var lastEventAt: Date?
    var sessionCloses: [DeviceID: SessionClose] = [:]
    var vanishedCloses: [VanishedClose] = []
    /// The maintenance round in progress (one at a time).
    var maintenanceTask: Task<Void, Never>?
    var maintenanceRetryAt = Date.distantPast

    // Attribution and inventory
    var attributor: CaptureAttributor
    var monitored: [AppID: MonitoredApp] = [:]
    /// Every app (archived ones included), for the local snapshot.
    var allApps: [MonitoredApp] = []
    var paused: Set<AppID> = []
    var mutes: [String] = []
    var known = CaptureKnownHosts()
    var knownLoaded = false
    /// New apps whose inventory (and backfill) is still loading → give up waiting at this time.
    var awaitingInventory: [AppID: Date] = [:]
    var upsertedProcesses: [CaptureAttributor.ProcessKey: (appID: AppID?, at: Date)] = [:]
    /// surge ID → evaluate first contact no later than this.
    var contactQueue: [Int64: Date] = [:]
    /// `appID|kind:value` → request that found the host first.
    var hostOrigins: [String: RequestKey] = [:]

    // Lookups
    var dnsCache: [String: (ips: [String], expires: Date)] = [:]
    var dnsFailures: [String: Date] = [:]
    var dnsQueue: [String] = []
    var dnsInFlight: Set<String> = []
    var waitingForHost: [String: Set<Int64>] = [:]
    var geoCache: [String: GeoInfo] = [:]
    var geoFailures: [String: Date] = [:]
    var geoQueue: [String] = []
    var geoInFlight: Set<String> = []
    var waitingForGeo: [String: Set<Int64>] = [:]

    // Writes
    var buffer: CaptureWriteBuffer
    var spool: CaptureSpool
    let sidecar: CaptureSidecar
    var online = false
    var isFlushing = false
    var flushStartedAt: Date?
    /// What the flush in progress has not written yet. When that flush is stuck at quit, its rows are spooled
    /// and the rest is kept in `auxiliary.json`.
    var inFlightBatch: CaptureWriteBuffer.Batch?
    /// Inventory entries being inserted right now (not in the database yet, not in the buffer either).
    var inFlightHosts: [AppHost] = []
    var lastScan = Date.distantPast
    var lastEviction = Date.distantPast
    var lastWriteAt: Date?
    var lastSnapshotAt: Date?
    /// A statement of the current flush or replay succeeded: refusals are then about the data, not the server.
    var writesSucceeded = false
    var auxiliaryRestored = false

    // UI
    var pending = CaptureUIUpdate()
    var changed: [RequestKey: RequestRecord] = [:]
    var fresh: Set<RequestKey> = []

    init(
        settings: CaptureSettings,
        database: any TidemarkDatabase,
        surge: any SurgeClient,
        processes: any ProcessInspecting,
        classifier: any SiteClassifying,
        probes: ProbeRegistry,
        spool: CaptureSpool,
        contactGrace: TimeInterval = 2.5,
        writeTimeout: Duration = .seconds(20)
    ) {
        self.settings = settings
        self.database = database
        self.surge = surge
        self.processes = processes
        self.classifier = classifier
        self.probes = probes
        self.spool = spool
        self.sidecar = CaptureSidecar(directory: spool.directory)
        self.contactGrace = contactGrace
        self.writeTimeout = writeTimeout
        attributor = CaptureAttributor(isRemote: settings.isRemote)
        buffer = CaptureWriteBuffer(batchRows: settings.batchRows, batchInterval: settings.batchInterval)
    }

    // MARK: Configuration

    func setServices(surge: any SurgeClient, database: any TidemarkDatabase) {
        self.surge = surge
        self.database = database
    }

    /// Applies new settings. A new recording device (local ↔ remote Surge) ends the old stream's requests:
    /// they are written (active ones closed) before the in-memory state is dropped.
    func update(settings new: CaptureSettings, now: Date = .now) {
        if new.deviceID != settings.deviceID || new.isRemote != settings.isRemote {
            retireEntries(closingAt: nil, now: now)
            let apps = attributor.apps
            attributor = CaptureAttributor(isRemote: new.isRemote)
            attributor.setApps(apps)
            clearSessionState()
            upsertedProcesses.removeAll()
            epoch += 1
        }
        settings = new
        setBatching(rows: new.batchRows, interval: new.batchInterval)
    }

    func setBatching(rows: Int, interval: TimeInterval) {
        buffer.batchRows = max(1, rows)
        buffer.batchInterval = max(0.05, interval)
        settings.batchRows = rows
        settings.batchInterval = interval
    }

    func setSpoolLimit(_ limit: Int) { spool.limit = max(1, limit) }

    /// Apps (archived ones are ignored) and the apps paused for this session. Live requests are
    /// re-attributed right away, so rows that get no further updates (backfill) roll up too.
    func setApps(_ apps: [MonitoredApp], paused: Set<AppID>, now: Date = .now) {
        let version = attributor.appsVersion
        allApps = apps
        attributor.setApps(apps)
        monitored = Dictionary(attributor.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.paused = paused
        guard attributor.appsVersion != version else { return }
        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            let before = entry.record
            refreshAttribution(&entry, id: id, now: now)
            if entry.record != before {
                entry.dirty = true
                entry.urgent = true
                markChanged(entry.record, fresh: false)
            }
            entries[id] = entry
        }
    }

    /// A newly monitored app's inventory (and backfill) arrives with the next `loadKnownHosts()`; until then
    /// (at most `inventoryWait`) its first contacts wait, so its whole history doesn't look new.
    func awaitInventory(for appID: AppID, now: Date = .now) {
        awaitingInventory[appID] = now.addingTimeInterval(inventoryWait)
    }

    func setMutes(_ patterns: [String]) { mutes = patterns }

    /// Pausing drops every event (no writes, no alerts); requests first seen while paused stay ignored.
    func setRecording(_ on: Bool) {
        recording = on
        if !on { contactQueue.removeAll() }
    }

    /// Loads every app's inventory for first-contact detection. Entries still on their way to the database
    /// stay known.
    func loadKnownHosts() async throws {
        let waiting = Set(awaitingInventory.keys)
        let loaded = try await database.knownHosts()
        var index = CaptureKnownHosts(loaded: loaded, classifier: classifier)
        for host in buffer.pendingNewHosts + inFlightHosts {
            index.insert(kind: host.kind, value: host.value, appID: host.appID, site: host.site)
        }
        known = index
        knownLoaded = true
        for id in waiting { awaitingInventory[id] = nil }
    }

    /// Adds inventory entries other Macs recorded since the last load (nothing known is forgotten).
    func mergeKnownHosts() async throws {
        let loaded = try await database.knownHosts()
        known.merge(loaded, classifier: classifier)
        knownLoaded = true
    }

    /// The shared state saved by an earlier run, used when PostgreSQL is unreachable at launch: first contact
    /// is then detected against the saved inventory (the database still decides which Mac was first).
    func restoreSnapshot() -> CaptureStateSnapshot? {
        guard !knownLoaded, let snapshot = sidecar.loadSnapshot() else { return nil }
        known = CaptureKnownHosts(loaded: snapshot.known, classifier: classifier)
        knownLoaded = true
        mutes = snapshot.mutes
        return snapshot
    }

    /// Forgets a deleted app: no more attribution, inventory or alerts, and nothing queued may still point at
    /// its row (rows and chains are kept without the link).
    func purgeApp(_ id: AppID, now: Date = .now) {
        known.remove(appID: id)
        monitored[id] = nil
        awaitingInventory[id] = nil
        buffer.purge(appID: id)
        for key in Array(entries.keys) where entries[key]?.record.appID == id {
            guard var entry = entries[key] else { continue }
            entry.record.appID = nil
            entry.record.isNew = false
            entry.dirty = true
            entries[key] = entry
            contactQueue[key] = nil
            markChanged(entry.record, fresh: false)
        }
        let prefix = id.uuidString + "|"
        hostOrigins = hostOrigins.filter { !$0.key.hasPrefix(prefix) }
        upsertedProcesses = upsertedProcesses.filter { $0.value.appID != id }
    }

    // MARK: Sessions

    /// Starts a Surge engine session (request IDs restart with every engine start). The previous session's
    /// requests are written and its active ones closed at the new session's start; rows of earlier sessions
    /// still active in PostgreSQL are closed once everything queued for them is written. Returns the epoch
    /// backfills of this session must carry.
    @discardableResult
    func beginSession(_ newSession: Int64, now: Date = .now) -> Int {
        guard newSession != session else { return epoch }
        let boundary = Date(timeIntervalSince1970: Double(newSession) / 1000)
        if session != 0 { retireEntries(closingAt: boundary, now: now) }
        if newSession > 0 { sessionCloses[settings.deviceID] = SessionClose(before: newSession, at: boundary) }
        session = newSession
        clearSessionState()
        epoch += 1
        return epoch
    }

    var currentSession: Int64 { session }
    var currentEpoch: Int { epoch }

    /// The engine re-read Surge's start time after a `sessionCheck`. The same session releases the events held
    /// meanwhile; a new one is begun by the stream restart that follows.
    func confirmSession(_ startMilliseconds: Int64, now: Date = .now) {
        guard startMilliseconds == session, holdingSince != nil else { return }
        let events = held
        held = []
        holdingSince = nil
        // Accept their IDs as this session's from now on.
        maxSeen = nil
        for request in events { ingest(request, backfill: false, now: now, trusted: true) }
    }

    /// Writes what the current entries still owe before they are dropped: first contacts still in their
    /// grace period are evaluated, sources are recorded, active requests are closed (they will never be
    /// updated again; at `boundary`, else when last seen) and changed rows are queued.
    func retireEntries(closingAt boundary: Date?, now: Date) {
        processContacts(now: now.addingTimeInterval(contactGrace), only: nil)
        for id in Array(entries.keys) {
            guard var entry = entries[id] else { continue }
            if entry.record.state == .active {
                entry.record.state = .completed
                entry.record.completedAt = max(entry.record.startedAt, min(boundary ?? entry.lastSeen, now))
                entry.finishedAt = now
                entry.dirty = true
                markChanged(entry.record, fresh: false)
            }
            recordSources(&entry, now: now, force: true)
            if entry.dirty { enqueue(&entry, now: now) }
            entries[id] = entry
        }
    }

    func clearSessionState() {
        entries.removeAll()
        ignored.removeAll()
        contactQueue.removeAll()
        waitingForHost.removeAll()
        waitingForGeo.removeAll()
        held.removeAll()
        holdingSince = nil
        maxSeen = nil
    }

    // MARK: Database state

    var isOnline: Bool { online }

    /// Marks PostgreSQL reachable (writes go out and the spool is replayed) or unreachable (rows are spooled).
    /// Maintenance that failed or waited while offline is tried again once the connection is back.
    func setDatabaseOnline(_ on: Bool) {
        if on, !online { maintenanceRetryAt = .distantPast }
        online = on
    }

    // MARK: Events

    /// When the current stream last delivered anything (Surge sends a speed event every second).
    var lastStreamEventAt: Date? { lastEventAt }

    /// Consumes a `watch` stream until it ends.
    func consume(_ stream: AsyncThrowingStream<SurgeEvent, Error>) async throws {
        lastEventAt = .now
        var subscriptions = 0
        for try await event in stream {
            let now = Date.now
            lastEventAt = now
            switch event {
            case .request(let request): ingest(request, now: now)
            case .speed(let speed): pending.speed = speed
            case .environmentChanged: pending.signals.append(.environmentChanged)
            case .reload: pending.signals.append(.reload)
            case .shutdown: pending.signals.append(.shutdown)
            case .subscribed:
                subscriptions += 1
                // A second acknowledgement on one stream: the controller re-subscribed, perhaps for a new engine.
                if subscriptions > 1 { signalSessionCheck(now: now) }
            case .other: break
            }
        }
    }

    /// Requests from `dump recent` / `dump active` after a (re)connect; known ones become updates. Results
    /// that arrive after the session or device changed (`epoch`) are dropped.
    func ingestBackfill(_ requests: [SurgeRequest], epoch expected: Int? = nil, now: Date = .now) {
        if let expected, expected != epoch { return }
        for request in requests.sorted(by: { $0.id < $1.id }) { ingest(request, backfill: true, now: now) }
    }

    /// After a (re)connect within a session: requests still active here that Surge no longer lists as active
    /// ended while the stream was away. They are closed when last seen.
    func reconcileActive(_ active: Set<Int64>, fetchedAt: Date, epoch expected: Int, now: Date = .now) {
        guard expected == epoch else { return }
        for id in Array(entries.keys) {
            guard var entry = entries[id], entry.record.state == .active, !active.contains(id), entry.lastSeen < fetchedAt else { continue }
            entry.record.state = .completed
            entry.record.completedAt = max(entry.record.startedAt, entry.lastSeen)
            entry.finishedAt = now
            recordSources(&entry, now: now, force: true)
            enqueue(&entry, now: now)
            entries[id] = entry
            markChanged(entry.record, fresh: false)
        }
    }

    /// Schedules closing this session's rows the database still holds as active although `dump active` no
    /// longer lists them (connections that ended while Tidemark was not running). It runs as maintenance
    /// once PostgreSQL is reachable and the spool is replayed (spooled rows of a crashed run would otherwise
    /// come back active), and a newer listing of the same session replaces an older one.
    func closeVanished(_ active: Set<Int64>, fetchedAt: Date, epoch expected: Int) {
        guard expected == epoch, session != 0 else { return }
        let margin = settings.isRemote ? remoteClockMargin : 0
        let close = VanishedClose(deviceID: settings.deviceID, session: session, keeping: active,
                                  startedBefore: fetchedAt.addingTimeInterval(-margin), at: fetchedAt)
        vanishedCloses.removeAll { $0.deviceID == close.deviceID && $0.session == close.session }
        vanishedCloses.append(close)
    }

    /// One `request` / `request-update` event.
    func ingest(_ request: SurgeRequest, backfill: Bool = false, now: Date = .now) {
        ingest(request, backfill: backfill, now: now, trusted: false)
    }

    private func ingest(_ request: SurgeRequest, backfill: Bool, now: Date, trusted: Bool) {
        guard recording else {
            if entries[request.id] == nil {
                if ignored.count > 100_000 { ignored.removeAll() }
                ignored.insert(request.id)
            }
            return
        }
        if ignored.contains(request.id) { return }
        if !backfill, !trusted, holdingSince != nil || looksRecycled(request, now: now) {
            hold(request, now: now)
            return
        }
        let mapped = CaptureRecordMapper.record(from: request, deviceID: settings.deviceID, session: session, now: now)
        if var entry = entries[request.id] {
            update(&entry, with: mapped, request: request, now: now)
            entries[request.id] = entry
        } else {
            create(mapped, request: request, backfill: backfill, now: now)
        }
        if request.id > (maxSeen?.id ?? .min) { maxSeen = (request.id, mapped.startedAt) }
    }

    /// Request IDs start over when Surge's engine restarts. Within one session a request's start time never
    /// changes, a lower ID never started later than a higher one, and a request that started moments ago
    /// has an ID close to the highest one (long-lived connections with low IDs started long ago).
    private func looksRecycled(_ request: SurgeRequest, now: Date) -> Bool {
        guard let start = CaptureRecordMapper.date(request.startDate) else { return false }
        if let entry = entries[request.id] {
            return abs(start.timeIntervalSince(entry.record.startedAt)) > 5
        }
        guard let maxSeen, request.id < maxSeen.id else { return false }
        if start.timeIntervalSince(maxSeen.startedAt) > 5 { return true }
        return maxSeen.id - request.id > 1000 && request.id < maxSeen.id / 2 && now.timeIntervalSince(start) < 30
    }

    private func hold(_ request: SurgeRequest, now: Date) {
        if holdingSince == nil {
            holdingSince = now
            Self.log.info("Request IDs look recycled; holding events until Surge's session is checked")
            signalSessionCheck(now: now)
        }
        if held.count < 5_000 { held.append(request) }
    }

    private func signalSessionCheck(now: Date) {
        if let last = lastSessionCheckSignal, now.timeIntervalSince(last) < 5 { return }
        lastSessionCheckSignal = now
        if !pending.signals.contains(.sessionCheck) { pending.signals.append(.sessionCheck) }
    }

    /// Held events nobody confirmed: ask again, and give up after a minute (the stream restart's backfill
    /// recovers recent requests of a new session).
    private func expireHeld(now: Date) {
        guard let since = holdingSince else { return }
        let age = now.timeIntervalSince(since)
        if age > 60 {
            Self.log.error("Dropping \(self.held.count) events held for a session check that never answered")
            held.removeAll()
            holdingSince = nil
        } else if age > 10 {
            signalSessionCheck(now: now)
        }
    }

    private func create(_ mapped: RequestRecord, request: SurgeRequest, backfill: Bool, now: Date) {
        var entry = Entry(record: mapped, pathForStatistics: request.pathForStatistics, sourcePort: request.sourcePort,
                          sourceAddress: request.sourceAddress, deviceName: request.deviceName, appsVersion: attributor.appsVersion, firstSeen: now, lastQueued: now,
                          lastSeen: now, backfilled: backfill)
        let attribution = attribution(for: entry.record, pathForStatistics: entry.pathForStatistics, reuseChain: false)
        entry.record.chain = attribution.chain
        entry.record.appID = attribution.appID
        entry.record.bundlePath = attribution.bundlePath ?? entry.record.bundlePath
        queueChain(attribution, now: now)

        matchProbe(&entry)
        resolveAddress(&entry, id: request.id, now: now)
        if entry.record.state != .active { entry.finishedAt = now }
        recordSources(&entry, now: now)
        entries[request.id] = entry

        buffer.add(request: entry.record)
        if let appID = entry.record.appID, isMonitoring(appID) {
            contactQueue[request.id] = now.addingTimeInterval(contactGrace)
        }
        markChanged(entry.record, fresh: true)
        if !backfill { pending.newRequests += 1 }
        processContacts(now: now, only: request.id)
    }

    private func update(_ entry: inout Entry, with mapped: RequestRecord, request: SurgeRequest, now: Date) {
        let before = entry.record
        var record = entry.record
        let wasActive = record.state == .active
        record.setupCompletedAt = mapped.setupCompletedAt ?? record.setupCompletedAt
        record.completedAt = mapped.completedAt ?? record.completedAt
        record.method = mapped.method
        if !mapped.host.isEmpty { record.host = mapped.host }
        record.port = mapped.port ?? record.port
        record.url = mapped.url ?? record.url
        record.remoteAddress = mapped.remoteAddress ?? record.remoteAddress
        if !mapped.policyPath.isEmpty { record.policyPath = mapped.policyPath }
        record.rule = mapped.rule ?? record.rule
        // A late `dump recent` snapshot must not turn a finished request back into an active one.
        if record.state == .active || mapped.state != .active { record.state = mapped.state }
        record.inBytes = max(record.inBytes, mapped.inBytes)
        record.outBytes = max(record.outBytes, mapped.outBytes)
        record.localAddress = mapped.localAddress ?? record.localAddress
        record.interface = mapped.interface ?? record.interface
        if !mapped.notes.isEmpty, mapped.notes.count >= record.notes.count { record.notes = mapped.notes }
        record.pid = mapped.pid ?? record.pid
        record.processPath = mapped.processPath ?? record.processPath
        entry.sourcePort = request.sourcePort ?? entry.sourcePort
        entry.sourceAddress = request.sourceAddress ?? entry.sourceAddress
        entry.pathForStatistics = request.pathForStatistics ?? entry.pathForStatistics
        entry.deviceName = request.deviceName ?? entry.deviceName
        entry.lastSeen = now

        let hadIP = record.remoteIP != nil
        if let ip = mapped.remoteIP, ip != record.remoteIP {
            record.remoteIP = ip
            record.geo = geoCache[ip]
        }
        entry.record = record
        // The process may only be known now, or the monitored apps changed.
        if entry.appsVersion != attributor.appsVersion || (record.chain.isEmpty && record.processPath != nil) {
            refreshAttribution(&entry, id: request.id, now: now)
        }
        matchProbe(&entry)
        resolveAddress(&entry, id: request.id, now: now)
        if !hadIP, entry.probeMatched, let port = entry.sourcePort, let ip = entry.record.remoteIP {
            probes.addIP(ip, sourcePort: port, sourceAddress: entry.sourceAddress)
        }
        recordSources(&entry, now: now)

        let finished = wasActive && entry.record.state != .active
        if finished {
            entry.finishedAt = now
            enqueue(&entry, now: now)
        } else if entry.record != before {
            entry.dirty = true
            if entry.record.remoteIP != before.remoteIP || entry.record.appID != before.appID
                || entry.record.probeSessionID != before.probeSessionID || entry.record.geo != before.geo {
                entry.urgent = true
            }
        } else {
            return
        }
        markChanged(entry.record, fresh: false)
        // Contact evaluation reads the stored entry.
        entries[request.id] = entry
        if finished { processContacts(now: now, only: request.id) }
        if !hadIP, entry.record.remoteIP != nil { lateIPContact(id: request.id, now: now) }
        if let stored = entries[request.id] { entry = stored }
    }

    // MARK: Attribution

    /// `true` for Tidemark's own requests (the site probe's forwarder, IP lookups).
    func isOwn(_ record: RequestRecord, chain: [ProcessLink]? = nil) -> Bool {
        guard let own = settings.ownExecutablePath else { return false }
        return record.processPath == own || (chain ?? record.chain).last?.path == own
    }

    /// The request's process chain and monitored app. Tidemark's own requests never roll up to an app, even
    /// when Tidemark was launched from inside a monitored app's process tree; they show under Tidemark.
    private func attribution(for record: RequestRecord, pathForStatistics: String?, reuseChain: Bool) -> CaptureAttributor.Attribution {
        let chain = reuseChain && !record.chain.isEmpty
            ? record.chain
            : attributor.chain(pid: record.pid, processPath: record.processPath, startedAt: record.startedAt, inspector: processes)
        var attribution = attributor.attribute(chain: chain, pathForStatistics: pathForStatistics)
        if isOwn(record, chain: chain) {
            attribution.appID = nil
            attribution.matchedIndex = nil
            attribution.bundlePath = settings.ownBundlePath ?? attribution.bundlePath
        }
        return attribution
    }

    /// Re-runs attribution for a live request and queues first contact when it newly rolls up to a monitoring app.
    private func refreshAttribution(_ entry: inout Entry, id: Int64, now: Date) {
        let attribution = attribution(for: entry.record, pathForStatistics: entry.pathForStatistics, reuseChain: true)
        let newlyAttributed = attribution.appID != nil && attribution.appID != entry.record.appID
        entry.record.chain = attribution.chain
        entry.record.appID = attribution.appID
        entry.record.bundlePath = attribution.bundlePath ?? entry.record.bundlePath
        entry.appsVersion = attributor.appsVersion
        queueChain(attribution, now: now)
        // Traffic from before the app was monitored is history (backfill), not first contact.
        if newlyAttributed, let appID = attribution.appID, isMonitoring(appID),
           let app = monitored[appID], entry.record.startedAt >= app.createdAt {
            contactQueue[id] = now.addingTimeInterval(contactGrace)
        }
    }

    private func queueChain(_ attribution: CaptureAttributor.Attribution, now: Date) {
        guard !settings.isRemote, let leaf = attribution.chain.last, let start = leaf.startTime else { return }
        let key = CaptureAttributor.ProcessKey(pid: leaf.pid, startTime: start)
        // Stored processes are upserted again now and then so `last_seen` (Running / Exited) stays fresh.
        if let stored = upsertedProcesses[key], stored.appID == attribution.appID,
           now.timeIntervalSince(stored.at) < processRetouchInterval { return }
        var chain = attribution.chain
        if attribution.appID != nil, let index = attribution.matchedIndex { chain = Array(chain[index...]) }
        guard chain.allSatisfy({ $0.startTime != nil }) else { return }
        if upsertedProcesses.count > 50_000 { upsertedProcesses.removeAll() }
        upsertedProcesses[key] = (attribution.appID, now)
        buffer.add(chain: chain, appID: attribution.appID)
    }

    private func matchProbe(_ entry: inout Entry) {
        guard !entry.probeMatched, let own = settings.ownExecutablePath, entry.record.processPath == own,
              let port = entry.sourcePort, let match = probes.match(sourcePort: port, sourceAddress: entry.sourceAddress) else { return }
        entry.probeMatched = true
        entry.record.probeSessionID = match.sessionID
        if let ip = entry.record.remoteIP { probes.addIP(ip, sourcePort: port, sourceAddress: entry.sourceAddress) }
    }

    // MARK: Global inventory sources

    /// Records the request's domain and IP in the global inventory (`host_sources`) once each. Sources wait
    /// for Surge to name the process (a later update usually does); `force` records them without one (when the
    /// request finished or waited `sourceWait`). Backfilled requests are skipped like their inventory touches:
    /// a previous run may already have counted them.
    func recordSources(_ entry: inout Entry, now: Date, force: Bool = false) {
        let record = entry.record
        guard !entry.probeMatched, !entry.backfilled, !record.host.isEmpty else { return }
        let wantsDomain = !entry.domainSourceRecorded && !record.isIPLiteral
        let address = record.remoteIP ?? (record.isIPLiteral ? record.host : nil)
        let wantsIP = !entry.ipSourceRecorded && address != nil
        guard wantsDomain || wantsIP else { return }
        let knownPath = record.processPath ?? record.bundlePath
        guard knownPath != nil || force else { return }
        let path = knownPath ?? ""
        let title = knownPath == nil ? (entry.deviceName ?? "") : (record.chain.last?.name ?? record.processName)
        if wantsDomain {
            buffer.add(source: HostSourceTouch(kind: .domain, value: record.host, deviceID: settings.deviceID, sourcePath: path, sourceTitle: title,
                                               appID: record.appID, bundlePath: record.bundlePath, seenAt: now, requestDelta: 1, geo: nil))
            entry.domainSourceRecorded = true
        }
        if wantsIP, let address {
            buffer.add(source: HostSourceTouch(kind: .ip, value: address, deviceID: settings.deviceID, sourcePath: path, sourceTitle: title,
                                               appID: record.appID, bundlePath: record.bundlePath, seenAt: now, requestDelta: 1, geo: record.geo))
            entry.ipSourceRecorded = true
        }
    }

    // MARK: First contact

    func isMonitoring(_ appID: AppID) -> Bool { monitored[appID] != nil && !paused.contains(appID) }

    private func isAwaitingInventory(_ appID: AppID, now: Date) -> Bool {
        guard let deadline = awaitingInventory[appID] else { return false }
        if deadline > now { return true }
        awaitingInventory[appID] = nil
        Self.log.error("Inventory of a new app did not load in time; detecting its first contacts anyway")
        return false
    }

    /// Evaluates queued requests whose remote IP and GeoIP data are known (or whose grace period ran out).
    func processContacts(now: Date, only id: Int64?) {
        let ids = id.map { [$0] } ?? Array(contactQueue.keys)
        for id in ids {
            guard let deadline = contactQueue[id] else { continue }
            guard let entry = entries[id] else {
                contactQueue[id] = nil
                continue
            }
            let record = entry.record
            let awaiting = record.appID.map { isAwaitingInventory($0, now: now) } ?? false
            guard knownLoaded, !awaiting else {
                // Without the inventory every host would look new; skip requests that waited too long.
                if now.timeIntervalSince(deadline) > 60 { contactQueue[id] = nil }
                continue
            }
            let ipReady: Bool
            if let ip = record.remoteIP ?? (record.isIPLiteral ? record.host : nil) {
                ipReady = record.geo != nil || Self.isPrivate(ip) || (geoFailures[ip] ?? .distantPast) > now
            } else {
                ipReady = (dnsFailures[record.host] ?? .distantPast) > now
            }
            guard ipReady || now >= deadline else { continue }
            contactQueue[id] = nil
            evaluateContact(id: id, includeDomain: true)
        }
    }

    /// The IP of a request whose first contact was already evaluated became known later.
    func lateIPContact(id: Int64, now: Date) {
        guard contactQueue[id] == nil, knownLoaded, let entry = entries[id], let appID = entry.record.appID, isMonitoring(appID) else { return }
        evaluateContact(id: id, includeDomain: false)
    }

    private func evaluateContact(id: Int64, includeDomain: Bool) {
        guard var entry = entries[id] else { return }
        let record = entry.record
        guard recording, !isOwn(record), let appID = record.appID, let app = monitored[appID], !paused.contains(appID) else { return }
        // A late IP only adds IP information; its domain was already evaluated (and touched) with the request.
        if !includeDomain, !record.isIPLiteral, !known.containsDomain(record.host, appID: appID) { return }
        var contact = CaptureFirstContactDetector.evaluate(record: record, app: app, known: &known, classifier: classifier, mutes: mutes)
        if entry.backfilled { contact.touches.removeAll() } else if !includeDomain { contact.touches.removeAll { $0.kind == .domain } }
        if !includeDomain, entry.alertDrafted {
            // At most one alert per request, however late its IP resolved: the domain alert covered it.
            contact.alert = nil
            contact.fallback = nil
        }
        if contact.alert != nil {
            entry.alertDrafted = true
            entries[id] = entry
        }
        for host in contact.hosts { hostOrigins["\(appID.uuidString)|\(host.id)"] = record.key }
        if hostOrigins.count > 20_000 { hostOrigins.removeAll() }
        buffer.add(contact)
        if !contact.hosts.isEmpty { pending.inventoryChanged.insert(appID) }
    }

    // MARK: Periodic work

    /// Runs the periodic work until cancelled. Writes run beside it, so a slow database never stalls first
    /// contact deadlines, rewrites or eviction.
    func run(interval: Duration = .milliseconds(100)) async {
        while !Task.isCancelled {
            await tick(now: .now, waitForWrites: false)
            try? await Task.sleep(for: interval)
        }
    }

    /// First-contact deadlines, periodic rewrites of active requests, eviction, flushing, spooling, replay and
    /// maintenance. `waitForWrites` returns only after this round's database work finished (tests).
    func tick(now: Date = .now, waitForWrites: Bool = true) async {
        processContacts(now: now, only: nil)
        if now.timeIntervalSince(lastScan) >= 1 {
            scanForRewrites(now: now)
            lastScan = now
        }
        if now.timeIntervalSince(lastEviction) >= 5 {
            evict(now: now)
            lastEviction = now
        }
        expireHeld(now: now)
        if isFlushing {
            // A write is taking long: new rows go to disk instead of piling up in memory.
            if let started = flushStartedAt, now.timeIntervalSince(started) > 5, buffer.requestCount > 0, buffer.shouldFlush(now: now) {
                spoolRows(buffer.takeRequests())
                buffer.markFlushed(now: now)
            }
        } else if online {
            if buffer.shouldFlush(now: now) || !spool.isEmpty || !auxiliaryRestored || shouldSaveSnapshot(now: now) {
                isFlushing = true
                flushStartedAt = now
                let cycle = Task { await self.writeCycle(now: now) }
                if waitForWrites { await cycle.value }
            }
        } else if buffer.requestCount > 0, buffer.shouldFlush(now: now) {
            spoolRows(buffer.takeRequests())
            buffer.markFlushed(now: now)
        }
        if let maintenance = startMaintenanceIfDue(now: now), waitForWrites { await maintenance.value }
    }

    /// Writes (or spools) everything queued. Waits briefly for a flush in progress; when that flush is stuck
    /// its rows and the queue go to the spool instead. `final` (quitting) also closes active requests,
    /// keeps unwritten first-contact work on disk and saves the shared state snapshot.
    func flushAll(now: Date = .now, final: Bool = false) async {
        for _ in 0..<(final ? 20 : 100) where isFlushing { try? await Task.sleep(for: .milliseconds(50)) }
        if final {
            retireEntries(closingAt: nil, now: now)
        } else {
            processContacts(now: now.addingTimeInterval(contactGrace), only: nil)
            for id in Array(entries.keys) {
                guard var entry = entries[id], entry.dirty else { continue }
                enqueue(&entry, now: now)
                entries[id] = entry
            }
        }
        if isFlushing {
            spoolRows((inFlightBatch?.requests ?? []) + buffer.takeRequests())
            if final, var stuck = inFlightBatch {
                // The process exits before the stuck flush can put its first-contact work back.
                stuck.requests = []
                sidecar.saveAuxiliary(stuck)
            }
        } else if online {
            isFlushing = true
            flushStartedAt = now
            await flushBatch(now: now, budget: final ? finalFlushBudget : flushBudget)
            isFlushing = false
            flushStartedAt = nil
        } else {
            spoolRows(buffer.takeRequests())
        }
        if final {
            sidecar.saveAuxiliary(buffer.takeAuxiliary())
            saveSnapshot(now: now)
        }
    }

    /// Drains the UI changes accumulated since the last call.
    func drainUpdate() -> CaptureUIUpdate {
        var update = pending
        update.records = Array(changed.values)
        update.fresh = fresh
        update.bufferedRows = offlineBacklog
        update.databaseOnline = online
        update.lastWriteAt = lastWriteAt
        pending = CaptureUIUpdate()
        changed.removeAll(keepingCapacity: true)
        fresh.removeAll(keepingCapacity: true)
        return update
    }

    /// Rows waiting because PostgreSQL is unreachable: the spool, plus the queue while offline.
    var offlineBacklog: Int { spool.count + (online ? 0 : buffer.requestCount) }

    /// Same as `offlineBacklog`.
    var bufferedRows: Int { offlineBacklog }

    // MARK: Rewrites and eviction

    func enqueue(_ entry: inout Entry, now: Date) {
        buffer.add(request: entry.record)
        entry.lastQueued = now
        entry.dirty = false
        entry.urgent = false
    }

    private func scanForRewrites(now: Date) {
        var updates: [(Int64, Entry)] = []
        for (id, entry) in entries {
            var updated = entry
            var touched = false
            let sourcesPending = !entry.domainSourceRecorded || !entry.ipSourceRecorded
            if sourcesPending, !entry.backfilled, !entry.probeMatched,
               entry.finishedAt != nil || now.timeIntervalSince(entry.firstSeen) >= sourceWait {
                recordSources(&updated, now: now, force: true)
                touched = updated.domainSourceRecorded != entry.domainSourceRecorded || updated.ipSourceRecorded != entry.ipSourceRecorded
            }
            if updated.dirty {
                let quiet = now.timeIntervalSince(updated.lastQueued)
                let due = updated.record.state != .active || quiet >= activeRewriteInterval || (updated.urgent && quiet >= urgentRewriteDelay)
                if due {
                    enqueue(&updated, now: now)
                    touched = true
                }
            }
            if touched { updates.append((id, updated)) }
        }
        for (id, entry) in updates { entries[id] = entry }
    }

    private func evict(now: Date) {
        entries = entries.filter { id, entry in
            guard let finished = entry.finishedAt else { return true }
            return entry.dirty || contactQueue[id] != nil || now.timeIntervalSince(finished) < 60
        }
        if entries.count > 20_000 {
            let oldest = entries.sorted { $0.value.record.startedAt < $1.value.record.startedAt }.prefix(entries.count - 20_000)
            for (id, entry) in oldest {
                if entry.dirty { buffer.add(request: entry.record) }
                entries[id] = nil
                contactQueue[id] = nil
            }
        }
        // Lookups whose requests are gone have nobody to fill in.
        waitingForHost = waitingForHost.compactMapValues { ids in
            let alive = ids.filter { entries[$0] != nil }
            return alive.isEmpty ? nil : alive
        }
        waitingForGeo = waitingForGeo.compactMapValues { ids in
            let alive = ids.filter { entries[$0] != nil }
            return alive.isEmpty ? nil : alive
        }
        dnsFailures = dnsFailures.filter { $0.value > now }
        geoFailures = geoFailures.filter { $0.value > now }
        awaitingInventory = awaitingInventory.filter { $0.value > now }
    }

    // MARK: UI

    func markChanged(_ record: RequestRecord, fresh isFresh: Bool) {
        changed[record.key] = record
        if isFresh { fresh.insert(record.key) }
    }
}
