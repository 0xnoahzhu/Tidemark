import Foundation
import Observation

/// Live capture state shown in the sidebar footer, the Requests page and the menu bar.
/// Written by the capture engine on the main actor.
@MainActor
@Observable
final class LiveState {
    var surge: LinkStatus = .idle
    var database: LinkStatus = .idle

    /// Recording on/off (pausing stops writes and alerts; it resumes on next launch).
    var recording: Bool = true

    /// Newest first. This Mac's requests from the Surge stream merged with rows other Macs wrote.
    var rows: [RequestRecord] = []
    /// Maximum rows kept in `rows`.
    let rowLimit = 600

    /// Requests per second over the last ~10 s.
    var rate: Double = 0
    /// Requests per second, one sample per second, newest last (48 samples).
    var rateHistory: [Double] = Array(repeating: 0, count: 48)
    /// Surge throughput in bytes per second.
    var downloadSpeed: Int64 = 0
    var uploadSpeed: Int64 = 0

    /// Requests started today on this Mac.
    var todayCount: Int64 = 0
    /// Rows in `requests` (estimate + rows written since).
    var totalRows: Int64 = 0
    var writtenThisSession: Int64 = 0
    /// Rows waiting in the write buffer or the on-disk spool.
    var bufferedRows: Int = 0
    var lastRoundTrip: Duration?
    var serverVersion: String = ""
    var lastWriteAt: Date?

    /// Inserts or replaces rows (matched by key), keeping them ordered newest first by start time and
    /// trimming to `rowLimit`. Rows that started earlier than the newest one (long-lived connections,
    /// other Macs' rows arriving late) are placed at their position instead of on top.
    func upsert(_ incoming: [RequestRecord]) {
        guard !incoming.isEmpty else { return }
        var index: [RequestKey: Int] = [:]
        for (i, r) in rows.enumerated() { index[r.key] = i }
        var fresh: [RequestRecord] = []
        for r in incoming {
            if let i = index[r.key] { rows[i] = r } else { fresh.append(r) }
        }
        guard !fresh.isEmpty else { return }
        for record in fresh.sorted(by: { $0.startedAt > $1.startedAt }) {
            // First position whose row started before `record` (rows are newest first).
            var low = 0, high = rows.count
            while low < high {
                let mid = (low + high) / 2
                if rows[mid].startedAt >= record.startedAt { low = mid + 1 } else { high = mid }
            }
            rows.insert(record, at: low)
        }
        if rows.count > rowLimit { rows.removeLast(rows.count - rowLimit) }
    }

    func clear() { rows.removeAll() }
}
