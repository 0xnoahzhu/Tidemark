import Foundation

/// Batches database writes: request rows (coalesced by key), process chains, inventory entries,
/// inventory touches, global host sources, alerts and DNS answers.
///
/// A batch is due every `batchRows` request rows or `batchInterval` seconds, whichever comes first.
/// Auxiliary queues (everything except requests) are capped so a long outage cannot grow memory
/// without bound; requests go to the disk spool instead.
struct CaptureWriteBuffer {
    /// A process chain to upsert, with the app its subtree belongs to and the device it runs on (nil in files
    /// saved before the device was recorded: this Mac's then).
    struct ChainWrite: Hashable, Sendable, Codable {
        var chain: [ProcessLink]
        var appID: AppID?
        var deviceID: DeviceID? = nil
    }

    /// Everything due for one flush, in write order.
    struct Batch: Sendable {
        var chains: [ChainWrite] = []
        var requests: [RequestRecord] = []
        var newHosts: [AppHost] = []
        var drafts: [CaptureAlertDraft] = []
        var touches: [AppHost] = []
        var sources: [HostSourceTouch] = []
        var alerts: [AlertItem] = []
        var dnsAnswers: [DNSAnswer] = []

        var isEmpty: Bool { requests.isEmpty && auxiliaryIsEmpty }

        /// Nothing but request rows (or nothing at all).
        var auxiliaryIsEmpty: Bool {
            chains.isEmpty && newHosts.isEmpty && drafts.isEmpty && touches.isEmpty && sources.isEmpty && alerts.isEmpty && dnsAnswers.isEmpty
        }
    }

    var batchRows: Int
    var batchInterval: TimeInterval
    /// Cap for each auxiliary queue.
    let auxiliaryLimit: Int
    private(set) var lastFlush: Date

    private var requests: [RequestKey: RequestRecord] = [:]
    private var order: [RequestKey] = []
    private var chains: [ChainWrite] = []
    private var newHosts: [AppHost] = []
    private var drafts: [CaptureAlertDraft] = []
    private var alerts: [AlertItem] = []
    private var touches: [String: AppHost] = [:]
    private var touchOrder: [String] = []
    private var sources: [String: HostSourceTouch] = [:]
    private var sourceOrder: [String] = []
    private var dnsAnswers: [DNSAnswer] = []

    init(batchRows: Int, batchInterval: TimeInterval, auxiliaryLimit: Int = 50_000, now: Date = .now) {
        self.batchRows = max(1, batchRows)
        self.batchInterval = max(0.05, batchInterval)
        self.auxiliaryLimit = auxiliaryLimit
        self.lastFlush = now
    }

    /// Request rows waiting to be written.
    var requestCount: Int { order.count }

    var isEmpty: Bool { order.isEmpty && auxiliaryIsEmpty }

    var auxiliaryIsEmpty: Bool {
        chains.isEmpty && newHosts.isEmpty && drafts.isEmpty && alerts.isEmpty && touches.isEmpty && sources.isEmpty && dnsAnswers.isEmpty
    }

    /// Inventory entries queued for insertion (still optimistic: not in the database yet).
    var pendingNewHosts: [AppHost] { newHosts }

    /// Request rows waiting to be written, oldest first (without taking them).
    var queuedRequests: [RequestRecord] { order.compactMap { requests[$0] } }

    /// `true` when `batchRows` rows are waiting or `batchInterval` passed since the last flush.
    func shouldFlush(now: Date) -> Bool {
        if order.count >= batchRows { return true }
        return !isEmpty && now.timeIntervalSince(lastFlush) >= batchInterval
    }

    // MARK: Adding

    /// Queues a request row; a newer version of a queued row replaces it in place.
    mutating func add(request: RequestRecord) {
        if requests.updateValue(request, forKey: request.key) == nil { order.append(request.key) }
    }

    mutating func add(chain: [ProcessLink], appID: AppID?, deviceID: DeviceID? = nil) {
        guard !chain.isEmpty, chains.count < auxiliaryLimit else { return }
        chains.append(ChainWrite(chain: chain, appID: appID, deviceID: deviceID))
    }

    /// Queues a request's new inventory entries with their alert drafts. Entries and drafts are capped
    /// together, so a draft is never queued without the entry whose insert decides it.
    mutating func add(_ contact: CaptureFirstContact) {
        if !contact.hosts.isEmpty, newHosts.count + contact.hosts.count <= auxiliaryLimit {
            newHosts.append(contentsOf: contact.hosts)
            for draft in [contact.alert, contact.fallback].compactMap({ $0 }) { drafts.append(draft) }
        }
        for touch in contact.touches { add(touch: touch) }
    }

    mutating func add(alert: AlertItem) {
        guard alerts.count < auxiliaryLimit else { return }
        alerts.append(alert)
    }

    mutating func add(dnsAnswer: DNSAnswer) {
        guard dnsAnswers.count < auxiliaryLimit else { return }
        dnsAnswers.append(dnsAnswer)
    }

    /// Aggregates inventory touches per `(app, kind, value)`.
    mutating func add(touch: AppHost) {
        let key = "\(touch.appID.uuidString)|\(touch.id)"
        if var existing = touches[key] {
            existing.requestCount += touch.requestCount
            existing.lastSeen = max(existing.lastSeen, touch.lastSeen)
            existing.policy = touch.policy ?? existing.policy
            existing.geo = touch.geo ?? existing.geo
            for host in touch.hosts where !existing.hosts.contains(host) && existing.hosts.count < 16 {
                existing.hosts.append(host)
            }
            touches[key] = existing
        } else if touchOrder.count < auxiliaryLimit {
            touches[key] = touch
            touchOrder.append(key)
        }
    }

    /// Aggregates global-inventory observations per `(kind, value, device, source path)`.
    mutating func add(source: HostSourceTouch) {
        let key = "\(source.kind.rawValue):\(source.value)|\(source.deviceID.uuidString)|\(source.sourcePath)"
        if var existing = sources[key] {
            existing.requestDelta += source.requestDelta
            existing.seenAt = max(existing.seenAt, source.seenAt)
            existing.geo = source.geo ?? existing.geo
            existing.appID = source.appID ?? existing.appID
            sources[key] = existing
        } else if sourceOrder.count < auxiliaryLimit {
            sources[key] = source
            sourceOrder.append(key)
        }
    }

    // MARK: Taking

    /// Removes and returns everything queued, and restarts the interval.
    mutating func takeAll(now: Date) -> Batch {
        var batch = takeAuxiliary()
        batch.requests = takeRequests()
        lastFlush = now
        return batch
    }

    /// Removes and returns the queued request rows only (used to spool them while offline).
    mutating func takeRequests() -> [RequestRecord] {
        let rows = order.compactMap { requests[$0] }
        requests.removeAll(keepingCapacity: true)
        order.removeAll(keepingCapacity: true)
        return rows
    }

    /// Removes and returns everything except request rows (kept on disk when Tidemark quits offline).
    mutating func takeAuxiliary() -> Batch {
        var batch = Batch()
        batch.chains = chains
        batch.newHosts = newHosts
        batch.drafts = drafts
        batch.alerts = alerts
        batch.touches = touchOrder.compactMap { touches[$0] }
        batch.sources = sourceOrder.compactMap { sources[$0] }
        batch.dnsAnswers = dnsAnswers
        chains.removeAll()
        newHosts.removeAll()
        drafts.removeAll()
        alerts.removeAll()
        touches.removeAll()
        touchOrder.removeAll()
        sources.removeAll()
        sourceOrder.removeAll()
        dnsAnswers.removeAll()
        return batch
    }

    /// Marks the interval as restarted without taking anything (after spooling).
    mutating func markFlushed(now: Date) { lastFlush = now }

    /// Puts back the parts of a failed batch that are not spooled (everything but requests), ahead of
    /// anything queued since.
    mutating func restore(_ batch: Batch) {
        chains = Array((batch.chains + chains).prefix(auxiliaryLimit))
        newHosts = Array((batch.newHosts + newHosts).prefix(auxiliaryLimit))
        drafts = Array((batch.drafts + drafts).prefix(auxiliaryLimit))
        alerts = Array((batch.alerts + alerts).prefix(auxiliaryLimit))
        dnsAnswers = Array((batch.dnsAnswers + dnsAnswers).prefix(auxiliaryLimit))
        let queuedTouches = touchOrder.compactMap { touches[$0] }
        touches.removeAll()
        touchOrder.removeAll()
        for touch in batch.touches + queuedTouches { add(touch: touch) }
        let queuedSources = sourceOrder.compactMap { sources[$0] }
        sources.removeAll()
        sourceOrder.removeAll()
        for source in batch.sources + queuedSources { add(source: source) }
    }

    /// Forgets a deleted app: its inventory entries, drafts, alerts and touches are dropped, and queued
    /// rows, chains and sources lose their link to it (they are still written, without an app).
    mutating func purge(appID: AppID) {
        for key in order where requests[key]?.appID == appID {
            requests[key]?.appID = nil
            requests[key]?.isNew = false
        }
        chains = chains.map { $0.appID == appID ? ChainWrite(chain: $0.chain, appID: nil, deviceID: $0.deviceID) : $0 }
        newHosts.removeAll { $0.appID == appID }
        drafts.removeAll { $0.appID == appID }
        alerts.removeAll { $0.appID == appID }
        touchOrder.removeAll { key in
            guard touches[key]?.appID == appID else { return false }
            touches[key] = nil
            return true
        }
        for key in sourceOrder where sources[key]?.appID == appID { sources[key]?.appID = nil }
    }
}
