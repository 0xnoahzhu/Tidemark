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
    /// Tidemark's own executable; Surge records from it may belong to a site probe.
    var ownExecutablePath: String?
}

/// Surge events the main actor reacts to (egress checks, status).
enum CaptureSurgeSignal: Hashable, Sendable {
    case environmentChanged
    case reload
    case shutdown
}

/// Coalesced changes for the main actor, drained about four times a second.
struct CaptureUIUpdate: Sendable {
    /// Rows that changed since the last drain (new rows included).
    var records: [RequestRecord] = []
    /// Keys of rows first seen since the last drain.
    var fresh: Set<RequestKey> = []
    /// Requests first seen from the live stream (backfill excluded).
    var newRequests = 0
    /// Rows written to PostgreSQL for the first time.
    var rowsWritten = 0
    var lastWriteAt: Date?
    var bufferedRows = 0
    var speed: SurgeSpeed?
    /// Alerts inserted by this Mac, with their database IDs.
    var alerts: [AlertItem] = []
    /// Apps whose inventory grew.
    var inventoryChanged: Set<AppID> = []
    var signals: [CaptureSurgeSignal] = []
    /// Set once when a write failed and the pipeline went offline.
    var databaseFailure: String?
    var databaseOnline = false
}

/// Processes Surge events off the main actor: maps and attributes requests, resolves remote IPs and GeoIP
/// data, detects first contact, batches writes (spooling to disk while PostgreSQL is unreachable) and
/// accumulates UI changes that the engine drains periodically.
actor CapturePipeline {
    private struct Entry {
        var record: RequestRecord
        var pathForStatistics: String?
        var sourcePort: Int?
        var appsVersion: Int
        var lastQueued: Date
        var dirty = false
        /// Changed in a way worth writing soon (attribution, remote IP, GeoIP, NEW, probe), not only bytes.
        var urgent = false
        var finishedAt: Date?
        var probeMatched = false
        /// First seen in `dump recent`: a previous run may already have counted it in the inventory.
        var backfilled = false
    }

    private static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "capture")

    /// Seconds to wait for a remote IP and its GeoIP data before evaluating first contact without them.
    let contactGrace: TimeInterval
    /// Active requests are rewritten at most this often while they change.
    let activeRewriteInterval: TimeInterval = 10
    /// Rows with attribution, IP, GeoIP or NEW changes are rewritten after this short pause (to coalesce them).
    let urgentRewriteDelay: TimeInterval = 2
    let maxConcurrentLookups = 4

    // Dependencies
    private var database: any TidemarkDatabase
    private var surge: any SurgeClient
    private let processes: any ProcessInspecting
    private let classifier: any SiteClassifying
    private let probes: ProbeRegistry
    private var settings: CaptureSettings

    // Session
    private var session: Int64 = 0
    private var recording = true
    private var entries: [Int64: Entry] = [:]
    private var ignored: Set<Int64> = []

    // Attribution and inventory
    private var attributor: CaptureAttributor
    private var monitored: [AppID: MonitoredApp] = [:]
    private var paused: Set<AppID> = []
    private var mutes: [String] = []
    private var known = CaptureKnownHosts()
    private var knownLoaded = false
    /// Apps added since the inventory was loaded; their first contacts wait for the next load.
    private var awaitingInventory: Set<AppID> = []
    private var upsertedProcesses: [CaptureAttributor.ProcessKey: AppID?] = [:]
    /// surge ID → evaluate first contact no later than this.
    private var contactQueue: [Int64: Date] = [:]
    /// `appID|kind:value` → request that found the host first.
    private var hostOrigins: [String: RequestKey] = [:]

    // Lookups
    private var dnsCache: [String: (ips: [String], expires: Date)] = [:]
    private var dnsFailures: [String: Date] = [:]
    private var dnsQueue: [String] = []
    private var dnsInFlight: Set<String> = []
    private var waitingForHost: [String: Set<Int64>] = [:]
    private var geoCache: [String: GeoInfo] = [:]
    private var geoFailures: [String: Date] = [:]
    private var geoQueue: [String] = []
    private var geoInFlight: Set<String> = []
    private var waitingForGeo: [String: Set<Int64>] = [:]

    // Writes
    private var buffer: CaptureWriteBuffer
    private var spool: CaptureSpool
    private var online = false
    private var isFlushing = false
    private var lastScan = Date.distantPast
    private var lastEviction = Date.distantPast
    private var lastWriteAt: Date?

    // UI
    private var pending = CaptureUIUpdate()
    private var changed: [RequestKey: RequestRecord] = [:]
    private var fresh: Set<RequestKey> = []

    init(
        settings: CaptureSettings,
        database: any TidemarkDatabase,
        surge: any SurgeClient,
        processes: any ProcessInspecting,
        classifier: any SiteClassifying,
        probes: ProbeRegistry,
        spool: CaptureSpool,
        contactGrace: TimeInterval = 2.5
    ) {
        self.settings = settings
        self.database = database
        self.surge = surge
        self.processes = processes
        self.classifier = classifier
        self.probes = probes
        self.spool = spool
        self.contactGrace = contactGrace
        attributor = CaptureAttributor(isRemote: settings.isRemote)
        buffer = CaptureWriteBuffer(batchRows: settings.batchRows, batchInterval: settings.batchInterval)
    }

    // MARK: Configuration

    func setServices(surge: any SurgeClient, database: any TidemarkDatabase) {
        self.surge = surge
        self.database = database
    }

    func update(settings new: CaptureSettings) {
        if new.deviceID != settings.deviceID || new.isRemote != settings.isRemote {
            let apps = attributor.apps
            attributor = CaptureAttributor(isRemote: new.isRemote)
            attributor.setApps(apps)
            entries.removeAll()
            contactQueue.removeAll()
            upsertedProcesses.removeAll()
        }
        buffer.batchRows = max(1, new.batchRows)
        buffer.batchInterval = max(0.05, new.batchInterval)
        settings = new
    }

    func setSpoolLimit(_ limit: Int) { spool.limit = max(1, limit) }

    /// Apps (archived ones are ignored) and the apps paused for this session. Live requests are
    /// re-attributed right away, so rows that get no further updates (backfill) roll up too.
    func setApps(_ apps: [MonitoredApp], paused: Set<AppID>, now: Date = .now) {
        let version = attributor.appsVersion
        let previous = Set(monitored.keys)
        attributor.setApps(apps)
        monitored = Dictionary(attributor.apps.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        self.paused = paused
        if knownLoaded {
            // A newly added app's inventory (and its backfill) arrives with the next `loadKnownHosts()`.
            awaitingInventory.formUnion(Set(monitored.keys).subtracting(previous))
        }
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

    /// Re-runs attribution for a live request and queues first contact when it newly rolls up to a monitoring app.
    private func refreshAttribution(_ entry: inout Entry, id: Int64, now: Date) {
        var record = entry.record
        let chain = record.chain.isEmpty
            ? attributor.chain(pid: record.pid, processPath: record.processPath, startedAt: record.startedAt, inspector: processes)
            : record.chain
        let attribution = attributor.attribute(chain: chain, pathForStatistics: entry.pathForStatistics)
        let newlyAttributed = attribution.appID != nil && attribution.appID != record.appID
        record.chain = attribution.chain
        record.appID = attribution.appID
        record.bundlePath = attribution.bundlePath ?? record.bundlePath
        entry.record = record
        entry.appsVersion = attributor.appsVersion
        queueChain(attribution)
        // Traffic from before the app was monitored is history (backfill), not first contact.
        if newlyAttributed, let appID = attribution.appID, isMonitoring(appID),
           let app = monitored[appID], record.startedAt >= app.createdAt {
            contactQueue[id] = now.addingTimeInterval(contactGrace)
        }
    }

    func setMutes(_ patterns: [String]) { mutes = patterns }

    /// Pausing drops every event (no writes, no alerts); requests first seen while paused stay ignored.
    func setRecording(_ on: Bool) {
        recording = on
        if !on { contactQueue.removeAll() }
    }

    /// Loads every app's inventory for first-contact detection.
    func loadKnownHosts() async throws {
        let waiting = awaitingInventory
        let loaded = try await database.knownHosts()
        known = CaptureKnownHosts(loaded: loaded, classifier: classifier)
        knownLoaded = true
        awaitingInventory.subtract(waiting)
    }

    func forgetApp(_ id: AppID) {
        known.remove(appID: id)
        monitored[id] = nil
    }

    /// Starts a Surge engine session (request IDs restart with every engine start).
    func beginSession(_ newSession: Int64) {
        guard newSession != session else { return }
        session = newSession
        entries.removeAll()
        ignored.removeAll()
        contactQueue.removeAll()
        waitingForHost.removeAll()
        waitingForGeo.removeAll()
    }

    var currentSession: Int64 { session }

    // MARK: Database state

    var isOnline: Bool { online }

    /// Marks PostgreSQL reachable (writes go out and the spool is replayed) or unreachable (rows are spooled).
    func setDatabaseOnline(_ on: Bool) { online = on }

    // MARK: Events

    /// Consumes a `watch` stream until it ends.
    func consume(_ stream: AsyncThrowingStream<SurgeEvent, Error>) async throws {
        for try await event in stream {
            switch event {
            case .request(let request): ingest(request)
            case .speed(let speed): pending.speed = speed
            case .environmentChanged: pending.signals.append(.environmentChanged)
            case .reload: pending.signals.append(.reload)
            case .shutdown: pending.signals.append(.shutdown)
            case .subscribed, .other: break
            }
        }
    }

    /// Requests from `dump recent` after a (re)connect; known ones become updates.
    func ingestBackfill(_ requests: [SurgeRequest], now: Date = .now) {
        for request in requests.sorted(by: { $0.id < $1.id }) { ingest(request, backfill: true, now: now) }
    }

    /// One `request` / `request-update` event.
    func ingest(_ request: SurgeRequest, backfill: Bool = false, now: Date = .now) {
        guard recording else {
            if entries[request.id] == nil {
                if ignored.count > 100_000 { ignored.removeAll() }
                ignored.insert(request.id)
            }
            return
        }
        if ignored.contains(request.id) { return }
        let mapped = CaptureRecordMapper.record(from: request, deviceID: settings.deviceID, session: session, now: now)
        if var entry = entries[request.id] {
            update(&entry, with: mapped, request: request, now: now)
            entries[request.id] = entry
        } else {
            create(mapped, request: request, backfill: backfill, now: now)
        }
    }

    private func create(_ mapped: RequestRecord, request: SurgeRequest, backfill: Bool, now: Date) {
        var record = mapped
        let chain = attributor.chain(pid: request.pid, processPath: request.processPath, startedAt: record.startedAt, inspector: processes)
        let attribution = attributor.attribute(chain: chain, pathForStatistics: request.pathForStatistics)
        record.chain = attribution.chain
        record.appID = attribution.appID
        record.bundlePath = attribution.bundlePath ?? record.bundlePath
        queueChain(attribution)

        var entry = Entry(record: record, pathForStatistics: request.pathForStatistics, sourcePort: request.sourcePort,
                          appsVersion: attributor.appsVersion, lastQueued: now, backfilled: backfill)
        matchProbe(&entry)
        resolveAddress(&entry, id: request.id, now: now)
        if entry.record.state != .active { entry.finishedAt = now }
        entries[request.id] = entry

        buffer.add(request: entry.record)
        addSources(for: entry, domain: true, ip: entry.record.remoteIP != nil, now: now)
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
        record.state = mapped.state
        record.inBytes = max(record.inBytes, mapped.inBytes)
        record.outBytes = max(record.outBytes, mapped.outBytes)
        record.localAddress = mapped.localAddress ?? record.localAddress
        record.interface = mapped.interface ?? record.interface
        if !mapped.notes.isEmpty { record.notes = mapped.notes }
        record.pid = mapped.pid ?? record.pid
        record.processPath = mapped.processPath ?? record.processPath
        entry.sourcePort = request.sourcePort ?? entry.sourcePort
        entry.pathForStatistics = request.pathForStatistics ?? entry.pathForStatistics

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
        if !hadIP, entry.record.remoteIP != nil {
            addSources(for: entry, domain: false, ip: true, now: now)
            if entry.probeMatched, let port = entry.sourcePort, let ip = entry.record.remoteIP { probes.addIP(ip, sourcePort: port) }
        }

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
    }

    // MARK: Periodic work

    /// Runs the periodic work until cancelled.
    func run(interval: Duration = .milliseconds(100)) async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: interval)
        }
    }

    /// First-contact deadlines, periodic rewrites of active requests, eviction, flushing, spooling and replay.
    func tick(now: Date = .now) async {
        processContacts(now: now, only: nil)
        if now.timeIntervalSince(lastScan) >= 1 {
            scanForRewrites(now: now)
            lastScan = now
        }
        if now.timeIntervalSince(lastEviction) >= 5 {
            evict(now: now)
            lastEviction = now
        }
        guard !isFlushing else { return }
        if online {
            if buffer.shouldFlush(now: now) { await flush(now: now) }
            if online, !spool.isEmpty, !isFlushing { await replayOldestSegment(now: now) }
        } else if buffer.requestCount > 0, buffer.shouldFlush(now: now) {
            spoolRows(buffer.takeRequests())
            buffer.markFlushed(now: now)
        }
    }

    /// Writes (or spools) everything queued. Waits for a flush in progress first.
    func flushAll(now: Date = .now) async {
        for _ in 0..<100 where isFlushing { try? await Task.sleep(for: .milliseconds(50)) }
        processContacts(now: now.addingTimeInterval(contactGrace), only: nil)
        for id in entries.keys {
            guard var entry = entries[id], entry.dirty else { continue }
            enqueue(&entry, now: now)
            entries[id] = entry
        }
        if online {
            await flush(now: now)
        } else {
            spoolRows(buffer.takeRequests())
        }
    }

    /// Drains the UI changes accumulated since the last call.
    func drainUpdate() -> CaptureUIUpdate {
        var update = pending
        update.records = Array(changed.values)
        update.fresh = fresh
        update.bufferedRows = buffer.requestCount + spool.count
        update.databaseOnline = online
        update.lastWriteAt = lastWriteAt
        pending = CaptureUIUpdate()
        changed.removeAll(keepingCapacity: true)
        fresh.removeAll(keepingCapacity: true)
        return update
    }

    /// Rows waiting in memory and on disk.
    var bufferedRows: Int { buffer.requestCount + spool.count }

    // MARK: Lookups

    /// Reads Surge's DNS cache (`dump dns`) and fills waiting requests.
    func refreshDNSCache(now: Date = .now) async {
        guard let cache = try? await surge.dnsCache() else { return }
        for (domain, ips) in cache where !ips.isEmpty {
            dnsCache[domain.lowercased()] = (ips, now.addingTimeInterval(60))
        }
        for host in Array(waitingForHost.keys) {
            if let ips = dnsCache[host]?.ips { applyResolved(host: host, ips: ips, now: now) }
        }
        if dnsCache.count > 50_000 { dnsCache = dnsCache.filter { $0.value.expires > now } }
    }

    private func resolveAddress(_ entry: inout Entry, id: Int64, now: Date) {
        let host = entry.record.host
        if entry.record.remoteIP == nil, !host.isEmpty, !HostName.isIPAddress(host) {
            if let cached = dnsCache[host], cached.expires > now, let ip = Self.preferredIP(cached.ips) {
                entry.record.remoteIP = ip
                if entry.probeMatched, let port = entry.sourcePort { probes.addIP(ip, sourcePort: port) }
            } else if (dnsFailures[host] ?? .distantPast) <= now {
                waitingForHost[host, default: []].insert(id)
                if !dnsInFlight.contains(host), !dnsQueue.contains(host) {
                    if dnsQueue.count >= 512 { dnsQueue.removeFirst() }
                    dnsQueue.append(host)
                }
                pumpDNS()
            }
        }
        if let ip = entry.record.remoteIP, entry.record.geo == nil {
            if let geo = geoCache[ip] {
                entry.record.geo = geo
            } else if !Self.isPrivate(ip), (geoFailures[ip] ?? .distantPast) <= now {
                waitingForGeo[ip, default: []].insert(id)
                if !geoInFlight.contains(ip), !geoQueue.contains(ip) {
                    if geoQueue.count >= 512 { geoQueue.removeFirst() }
                    geoQueue.append(ip)
                }
                pumpGeo()
            }
        }
    }

    private func pumpDNS() {
        while dnsInFlight.count < maxConcurrentLookups, !dnsQueue.isEmpty {
            let host = dnsQueue.removeFirst()
            dnsInFlight.insert(host)
            let surge = self.surge
            Task {
                let result = try? await surge.dnsLookup(host)
                self.didLookup(host: host, result: result)
            }
        }
    }

    private func didLookup(host: String, result: SurgeDNSLookup?, now: Date = .now) {
        dnsInFlight.remove(host)
        if let result, !result.addresses.isEmpty {
            let ttl = min(3600, max(60, result.expiresIn ?? 0))
            dnsCache[host] = (result.addresses, now.addingTimeInterval(ttl))
            applyResolved(host: host, ips: result.addresses, now: now)
        } else {
            dnsFailures[host] = now.addingTimeInterval(120)
            waitingForHost[host] = nil
        }
        pumpDNS()
    }

    private func applyResolved(host: String, ips: [String], now: Date) {
        guard let ids = waitingForHost.removeValue(forKey: host), let ip = Self.preferredIP(ips) else { return }
        for id in ids {
            guard var entry = entries[id], entry.record.remoteIP == nil else { continue }
            entry.record.remoteIP = ip
            entry.record.geo = geoCache[ip]
            entry.dirty = true
            entry.urgent = true
            if entry.probeMatched, let port = entry.sourcePort { probes.addIP(ip, sourcePort: port) }
            resolveAddress(&entry, id: id, now: now)
            entries[id] = entry
            addSources(for: entry, domain: false, ip: true, now: now)
            markChanged(entry.record, fresh: false)
            lateIPContact(id: id, now: now)
        }
    }

    private func pumpGeo() {
        while geoInFlight.count < maxConcurrentLookups, !geoQueue.isEmpty {
            let ip = geoQueue.removeFirst()
            geoInFlight.insert(ip)
            let surge = self.surge
            let database = self.database
            let useDatabase = online
            Task {
                let geo = await Self.lookupGeo(ip: ip, surge: surge, database: database, useDatabase: useDatabase)
                self.didLookupGeo(ip: ip, geo: geo)
            }
        }
    }

    /// GeoIP from the shared `ip_info` cache, else from Surge (and saved for every Mac).
    private static func lookupGeo(ip: String, surge: any SurgeClient, database: any TidemarkDatabase, useDatabase: Bool) async -> GeoInfo? {
        if useDatabase, let cached = try? await database.ipInfo(ip) { return cached }
        guard let result = try? await surge.geoIP(ip) else { return nil }
        let geo = GeoInfo(countryCode: result.country, asn: result.asn, organization: result.organization)
        if useDatabase { try? await database.saveIPInfo(ip, geo: geo) }
        return geo
    }

    private func didLookupGeo(ip: String, geo: GeoInfo?, now: Date = .now) {
        geoInFlight.remove(ip)
        let ids = waitingForGeo.removeValue(forKey: ip) ?? []
        if let geo {
            if geoCache.count > 50_000 { geoCache.removeAll(keepingCapacity: true) }
            geoCache[ip] = geo
            for id in ids {
                guard var entry = entries[id], entry.record.remoteIP == ip, entry.record.geo == nil else { continue }
                entry.record.geo = geo
                entry.dirty = true
                entry.urgent = true
                entries[id] = entry
                markChanged(entry.record, fresh: false)
            }
        } else {
            geoFailures[ip] = now.addingTimeInterval(600)
        }
        pumpGeo()
    }

    /// Prefers an IPv4 address.
    static func preferredIP(_ ips: [String]) -> String? {
        ips.first(where: HostName.isIPv4) ?? ips.first
    }

    /// Loopback, link-local, private, CGNAT and Surge's fake-IP ranges carry no GeoIP data.
    static func isPrivate(_ ip: String) -> Bool {
        if ip.contains(":") {
            let lower = ip.lowercased()
            return lower == "::1" || lower.hasPrefix("fe80") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
        }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (192, 168): return true
        case (172, 16...31), (198, 18...19), (100, 64...127): return true
        default: return false
        }
    }

    // MARK: First contact

    private func isMonitoring(_ appID: AppID) -> Bool { monitored[appID] != nil && !paused.contains(appID) }

    /// Evaluates queued requests whose remote IP and GeoIP data are known (or whose grace period ran out).
    private func processContacts(now: Date, only id: Int64?) {
        let ids = id.map { [$0] } ?? Array(contactQueue.keys)
        for id in ids {
            guard let deadline = contactQueue[id] else { continue }
            guard let entry = entries[id] else {
                contactQueue[id] = nil
                continue
            }
            let record = entry.record
            let awaiting = record.appID.map { awaitingInventory.contains($0) } ?? false
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
            evaluateContact(record: record, includeDomain: true, touch: !entry.backfilled)
        }
    }

    /// The IP of a request whose first contact was already evaluated became known later.
    private func lateIPContact(id: Int64, now: Date) {
        guard contactQueue[id] == nil, knownLoaded, let entry = entries[id], let appID = entry.record.appID, isMonitoring(appID) else { return }
        evaluateContact(record: entry.record, includeDomain: false, touch: !entry.backfilled)
    }

    private func evaluateContact(record: RequestRecord, includeDomain: Bool, touch: Bool) {
        guard recording, let appID = record.appID, let app = monitored[appID], !paused.contains(appID) else { return }
        // A late IP only adds IP information; its domain was already evaluated (and touched) with the request.
        if !includeDomain, !record.isIPLiteral, !known.containsDomain(record.host, appID: appID) { return }
        var contact = CaptureFirstContactDetector.evaluate(record: record, app: app, known: &known, classifier: classifier, mutes: mutes)
        if !touch { contact.touches.removeAll() } else if !includeDomain { contact.touches.removeAll { $0.kind == .domain } }
        for host in contact.hosts { hostOrigins["\(appID.uuidString)|\(host.id)"] = record.key }
        if hostOrigins.count > 20_000 { hostOrigins.removeAll() }
        buffer.add(contact)
        if !contact.hosts.isEmpty { pending.inventoryChanged.insert(appID) }
    }

    // MARK: Writes

    private func enqueue(_ entry: inout Entry, now: Date) {
        buffer.add(request: entry.record)
        entry.lastQueued = now
        entry.dirty = false
        entry.urgent = false
    }

    private func scanForRewrites(now: Date) {
        for (id, entry) in entries where entry.dirty {
            let quiet = now.timeIntervalSince(entry.lastQueued)
            let due = entry.record.state != .active || quiet >= activeRewriteInterval || (entry.urgent && quiet >= urgentRewriteDelay)
            guard due else { continue }
            var updated = entry
            enqueue(&updated, now: now)
            entries[id] = updated
        }
    }

    private func evict(now: Date) {
        entries = entries.filter { id, entry in
            guard let finished = entry.finishedAt else { return true }
            return entry.dirty || contactQueue[id] != nil || now.timeIntervalSince(finished) < 60
        }
        if entries.count > 20_000 {
            let oldest = entries.sorted { $0.value.record.startedAt < $1.value.record.startedAt }.prefix(entries.count - 20_000)
            for (id, _) in oldest { entries[id] = nil }
        }
        dnsFailures = dnsFailures.filter { $0.value > now }
        geoFailures = geoFailures.filter { $0.value > now }
    }

    private func queueChain(_ attribution: CaptureAttributor.Attribution) {
        guard !settings.isRemote, let leaf = attribution.chain.last, let start = leaf.startTime else { return }
        let key = CaptureAttributor.ProcessKey(pid: leaf.pid, startTime: start)
        if let stored = upsertedProcesses[key], stored == attribution.appID { return }
        var chain = attribution.chain
        if attribution.appID != nil, let index = attribution.matchedIndex { chain = Array(chain[index...]) }
        guard chain.allSatisfy({ $0.startTime != nil }) else { return }
        if upsertedProcesses.count > 50_000 { upsertedProcesses.removeAll() }
        upsertedProcesses[key] = attribution.appID
        buffer.add(chain: chain, appID: attribution.appID)
    }

    private func addSources(for entry: Entry, domain: Bool, ip: Bool, now: Date) {
        let record = entry.record
        guard !entry.probeMatched, !record.host.isEmpty else { return }
        let path = record.processPath ?? record.bundlePath ?? "unknown"
        let title = record.chain.last?.name ?? record.processName
        if domain, !record.isIPLiteral {
            buffer.add(source: HostSourceTouch(kind: .domain, value: record.host, deviceID: settings.deviceID, sourcePath: path, sourceTitle: title,
                                               appID: record.appID, bundlePath: record.bundlePath, seenAt: now, requestDelta: 1, geo: nil))
        }
        if ip, let address = record.remoteIP ?? (record.isIPLiteral ? record.host : nil) {
            buffer.add(source: HostSourceTouch(kind: .ip, value: address, deviceID: settings.deviceID, sourcePath: path, sourceTitle: title,
                                               appID: record.appID, bundlePath: record.bundlePath, seenAt: now, requestDelta: 1, geo: record.geo))
        }
    }

    private func matchProbe(_ entry: inout Entry) {
        guard !entry.probeMatched, let own = settings.ownExecutablePath, entry.record.processPath == own,
              let port = entry.sourcePort, let match = probes.match(sourcePort: port) else { return }
        entry.probeMatched = true
        entry.record.probeSessionID = match.sessionID
        if let ip = entry.record.remoteIP { probes.addIP(ip, sourcePort: port) }
    }

    private func flush(now: Date) async {
        isFlushing = true
        defer { isFlushing = false }
        var batch = buffer.takeAll(now: now)
        // Keep request order: while older rows wait on disk, newer ones queue behind them.
        if !spool.isEmpty, !batch.requests.isEmpty {
            spoolRows(batch.requests)
            batch.requests = []
        }
        guard !batch.isEmpty else { return }
        do {
            while let write = batch.chains.first {
                _ = try await database.upsertProcessChain(deviceID: settings.deviceID, chain: write.chain, appID: write.appID)
                batch.chains.removeFirst()
            }
            if !batch.requests.isEmpty {
                let ids = try await database.upsertRequests(batch.requests)
                didWrite(batch.requests, ids: ids, now: now)
                batch.requests = []
            }
            if !batch.newHosts.isEmpty {
                let winners = try await database.insertAppHosts(batch.newHosts)
                batch.alerts.append(contentsOf: confirm(winners: winners, drafts: batch.drafts, now: now))
                batch.newHosts = []
                batch.drafts = []
            } else if !batch.drafts.isEmpty {
                batch.drafts = []
            }
            if !batch.touches.isEmpty {
                try await database.touchAppHosts(batch.touches)
                batch.touches = []
            }
            if !batch.sources.isEmpty {
                try await database.touchHostSources(batch.sources)
                batch.sources = []
            }
            if !batch.alerts.isEmpty {
                let inserted = try await database.insertAlerts(batch.alerts)
                pending.alerts.append(contentsOf: inserted)
                batch.alerts = []
            }
        } catch {
            if !batch.requests.isEmpty {
                spoolRows(batch.requests)
                batch.requests = []
            }
            buffer.restore(batch)
            goOffline(error)
        }
    }

    /// Stores row IDs and write times back into live rows.
    private func didWrite(_ rows: [RequestRecord], ids: [RequestKey: Int64], now: Date) {
        var firstWrites = 0
        for row in rows {
            if row.rowID == nil { firstWrites += 1 }
            guard row.key.session == session, var entry = entries[row.key.surgeID], entry.record.key == row.key else { continue }
            let rowID = ids[row.key] ?? entry.record.rowID
            guard rowID != entry.record.rowID || entry.record.writtenAt == nil else {
                entry.record.writtenAt = now
                entries[row.key.surgeID] = entry
                continue
            }
            entry.record.rowID = rowID
            entry.record.writtenAt = now
            entries[row.key.surgeID] = entry
            markChanged(entry.record, fresh: false)
        }
        pending.rowsWritten += firstWrites
        lastWriteAt = now
    }

    /// Turns drafts whose inventory entry won the cross-Mac race into alerts and marks their requests NEW.
    private func confirm(winners: [AppHost], drafts: [CaptureAlertDraft], now: Date) -> [AlertItem] {
        var alerts: [AlertItem] = []
        let won = Set(winners.map { "\($0.appID.uuidString)|\($0.id)" })
        for key in won {
            guard let origin = hostOrigins.removeValue(forKey: key), origin.session == session,
                  var entry = entries[origin.surgeID], !entry.record.isNew else { continue }
            entry.record.isNew = true
            entry.dirty = true
            entry.urgent = true
            entries[origin.surgeID] = entry
            markChanged(entry.record, fresh: false)
        }
        var seen: Set<String> = []
        for draft in drafts {
            let key = "\(draft.appID.uuidString)|\(draft.hostID)"
            guard won.contains(key), seen.insert(key).inserted else { continue }
            let rowID = draft.requestKey.session == session ? entries[draft.requestKey.surgeID]?.record.rowID : nil
            alerts.append(draft.item(deviceID: settings.deviceID, requestRowID: rowID, createdAt: now))
        }
        return alerts
    }

    private func replayOldestSegment(now: Date) async {
        isFlushing = true
        defer { isFlushing = false }
        guard let segment = spool.oldestSegment() else { return }
        let chunkSize = max(100, min(1000, settings.batchRows))
        var start = 0
        while start < segment.rows.count {
            let chunk = Array(segment.rows[start..<min(start + chunkSize, segment.rows.count)])
            do {
                let ids = try await database.upsertRequests(chunk)
                didWrite(chunk, ids: ids, now: now)
            } catch DatabaseError.query(let message) {
                // A row the server refuses must not block the spool: write the rest one by one.
                Self.log.error("Replay batch rejected: \(message, privacy: .public)")
                for row in chunk {
                    if let ids = try? await database.upsertRequests([row]) { didWrite([row], ids: ids, now: now) }
                }
            } catch {
                goOffline(error)
                return
            }
            start += chunkSize
        }
        spool.removeSegment(segment.id)
    }

    private func spoolRows(_ rows: [RequestRecord]) {
        guard !rows.isEmpty else { return }
        do {
            try spool.append(rows)
        } catch {
            Self.log.error("Could not spool \(rows.count) rows: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func goOffline(_ error: any Error) {
        guard online else { return }
        online = false
        pending.databaseFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        Self.log.error("PostgreSQL write failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: UI

    private func markChanged(_ record: RequestRecord, fresh isFresh: Bool) {
        changed[record.key] = record
        if isFresh { fresh.insert(record.key) }
    }
}
