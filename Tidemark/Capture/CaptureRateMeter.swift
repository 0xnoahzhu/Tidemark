import Foundation

/// Requests-per-second statistics: one sample per second (the newest `historyLength` kept) and the
/// average rate over the last `window` seconds.
struct CaptureRateMeter {
    let historyLength: Int
    let window: Int
    private(set) var history: [Double]
    private var second: Int64?
    private var count = 0

    init(historyLength: Int = 48, window: Int = 10) {
        self.historyLength = historyLength
        self.window = window
        history = Array(repeating: 0, count: historyLength)
    }

    /// New requests per second over the last `window` completed seconds.
    var rate: Double {
        let recent = history.suffix(window)
        return recent.isEmpty ? 0 : recent.reduce(0, +) / Double(recent.count)
    }

    /// No request in the open second or in any kept one.
    var isIdle: Bool { count == 0 && !history.contains { $0 > 0 } }

    /// Adds `newRequests` seen at `now`, closing any seconds that elapsed.
    mutating func record(_ newRequests: Int, now: Date) {
        advance(to: now)
        count += newRequests
    }

    /// Closes elapsed seconds; idle seconds count as zero. Returns `true` when samples were added.
    @discardableResult
    mutating func advance(to now: Date) -> Bool {
        let current = Int64(now.timeIntervalSince1970.rounded(.down))
        guard let open = second else {
            second = current
            return false
        }
        guard current > open else { return false }
        let elapsed = Int(min(Int64(historyLength), current - open))
        history.append(Double(count))
        if elapsed > 1 { history.append(contentsOf: Array(repeating: 0, count: elapsed - 1)) }
        if history.count > historyLength { history.removeFirst(history.count - historyLength) }
        count = 0
        second = current
        return true
    }
}

/// A `CaptureRateMeter` for each app with recent requests: the new requests per second from the app and the processes
/// it launched, over the same seconds as the overall rate. An app's meter is dropped once it has been idle for the whole
/// window and created again with its next request.
struct CaptureAppRateMeters {
    let window: Int
    private var meters: [AppID: CaptureRateMeter] = [:]

    init(window: Int = 10) {
        self.window = window
    }

    /// Each app's rate over the last `window` completed seconds; apps without one are left out.
    var rates: [AppID: Double] {
        meters.compactMapValues { $0.rate > 0 ? $0.rate : nil }
    }

    /// Adds each app's `newRequests` seen at `now`, closing any seconds that elapsed for every app.
    mutating func record(_ newRequests: [AppID: Int], now: Date) {
        for appID in newRequests.keys where meters[appID] == nil {
            meters[appID] = CaptureRateMeter(historyLength: window, window: window)
        }
        for appID in Array(meters.keys) {
            meters[appID]?.record(newRequests[appID] ?? 0, now: now)
            if meters[appID]?.isIdle == true { meters[appID] = nil }
        }
    }
}
