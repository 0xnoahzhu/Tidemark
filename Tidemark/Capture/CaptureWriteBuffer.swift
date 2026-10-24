import Foundation

/// Batches database writes: request rows (coalesced by key), process chains, inventory entries,
/// inventory touches, global host sources and alerts.
///
/// A batch is due every `batchRows` request rows or `batchInterval` seconds, whichever comes first.
/// Auxiliary queues (everything except requests) are capped so a long outage cannot grow memory
/// without bound; requests go to the disk spool instead.
struct CaptureWriteBuffer {
    /// A process chain to upsert, with the app its subtree belongs to.
    struct ChainWrite: Hashable, Sendable {
        var chain: [ProcessLink]
        var appID: AppID?
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

        var isEmpty: Bool {
            chains.isEmpty && requests.isEmpty && newHosts.isEmpty && drafts.isEmpty && touches.isEmpty && sources.isEmpty && alerts.isEmpty
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

    init(batchRows: Int, batchInterval: TimeInterval, auxiliaryLimit: Int = 50_000, now: Date = .now) {
        self.batchRows = max(1, batchRows)
        self.batchInterval = max(0.05, batchInterval)
        self.auxiliaryLimit = auxiliaryLimit
        self.lastFlush = now
    }

    /// Request rows waiting to be written.
    var requestCount: Int { order.count }

    var isEmpty: Bool {
        order.isEmpty && chains.isEmpty && newHosts.isEmpty && drafts.isEmpty && alerts.isEmpty && touches.isEmpty && sources.isEmpty
    }

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

    mutating func add(chain: [ProcessLink], appID: AppID?) {
        guard !chain.isEmpty, chains.count < auxiliaryLimit else { return }
        chains.append(ChainWrite(chain: chain, appID: appID))
    }

    mutating func add(_ contact: CaptureFirstContact) {
        if newHosts.count < auxiliaryLimit { newHosts.append(contentsOf: contact.hosts) }
        if let alert = contact.alert, drafts.count < auxiliaryLimit { drafts.append(alert) }
        for touch in contact.touches { add(touch: touch) }
    }

    mutating func add(alert: AlertItem) {
        guard alerts.count < auxiliaryLimit else { return }
        alerts.append(alert)
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
        var batch = Batch()
        batch.chains = chains
        batch.requests = takeRequests()
        batch.newHosts = newHosts
        batch.drafts = drafts
        batch.alerts = alerts
        batch.touches = touchOrder.compactMap { touches[$0] }
        batch.sources = sourceOrder.compactMap { sources[$0] }
        chains.removeAll()
        newHosts.removeAll()
        drafts.removeAll()
        alerts.removeAll()
        touches.removeAll()
        touchOrder.removeAll()
        sources.removeAll()
        sourceOrder.removeAll()
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

    /// Marks the interval as restarted without taking anything (after spooling).
    mutating func markFlushed(now: Date) { lastFlush = now }

    /// Puts back the parts of a failed batch that are not spooled (everything but requests), ahead of
    /// anything queued since.
    mutating func restore(_ batch: Batch) {
        chains = Array((batch.chains + chains).prefix(auxiliaryLimit))
        newHosts = Array((batch.newHosts + newHosts).prefix(auxiliaryLimit))
        drafts = Array((batch.drafts + drafts).prefix(auxiliaryLimit))
        alerts = Array((batch.alerts + alerts).prefix(auxiliaryLimit))
        let queuedTouches = touchOrder.compactMap { touches[$0] }
        touches.removeAll()
        touchOrder.removeAll()
        for touch in batch.touches + queuedTouches { add(touch: touch) }
        let queuedSources = sourceOrder.compactMap { sources[$0] }
        sources.removeAll()
        sourceOrder.removeAll()
        for source in batch.sources + queuedSources { add(source: source) }
    }
}
