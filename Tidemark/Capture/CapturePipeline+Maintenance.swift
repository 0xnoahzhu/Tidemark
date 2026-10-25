import Foundation
import os

/// Closing rows Surge will never update again: rows left active by earlier Surge sessions
/// (`closeActiveRequests`) and rows of a session that `dump active` no longer lists (`closeVanishedRequests`).
///
/// These statements may scan many rows, so they run beside the writes, one round at a time, with their own
/// long budget. A failure never takes capture offline: it is logged and the close is tried again after
/// `maintenanceRetryInterval`, or as soon as the next reconnect brings PostgreSQL back.
extension CapturePipeline {
    /// A close as scheduled, and as it runs (with every request still active in memory kept).
    typealias VanishedRun = (scheduled: VanishedClose, effective: VanishedClose)

    /// Starts a maintenance round when one is due: PostgreSQL reachable, the spool replayed, no round running,
    /// and a close whose rows are no longer waiting to be written (a later write of such a row would insert it
    /// active again, and the merge never reopens a closed row). Returns the round's task.
    func startMaintenanceIfDue(now: Date) -> Task<Void, Never>? {
        guard online, spool.isEmpty, maintenanceTask == nil, now >= maintenanceRetryAt,
              !sessionCloses.isEmpty || !vanishedCloses.isEmpty else { return nil }
        let queued = buffer.queuedRequests + (inFlightBatch?.requests ?? [])
        let sessions = sessionCloses.filter { device, close in
            !queued.contains { $0.key.deviceID == device && $0.key.session < close.before }
        }
        let vanished = vanishedCloses.filter { close in
            !queued.contains { row in
                row.key.deviceID == close.deviceID && row.key.session == close.session && row.state == .active
                    && row.startedAt < close.startedBefore && !close.keeping.contains(row.key.surgeID) && !isKnownActive(row.key)
            }
        }
        guard !sessions.isEmpty || !vanished.isEmpty else { return nil }
        let runs = vanished.map { ($0, keepingKnownActive($0)) }
        let task = Task { await self.runMaintenance(sessions: sessions, vanished: runs) }
        maintenanceTask = task
        return task
    }

    /// The request is one of the current session's and this pipeline still holds it as active.
    private func isKnownActive(_ key: RequestKey) -> Bool {
        key.deviceID == settings.deviceID && key.session == session && entries[key.surgeID]?.record.state == .active
    }

    /// A close of the current session also keeps every request this pipeline still holds as active: the stream
    /// reported those after the listing, or the listing missed them.
    private func keepingKnownActive(_ close: VanishedClose) -> VanishedClose {
        guard close.deviceID == settings.deviceID, close.session == session else { return close }
        var close = close
        for (id, entry) in entries where entry.record.state == .active { close.keeping.insert(id) }
        return close
    }

    private func runMaintenance(sessions: [DeviceID: SessionClose], vanished: [VanishedRun]) async {
        defer { maintenanceTask = nil }
        let database = self.database
        let budget = maintenanceBudget
        for (device, close) in sessions {
            do {
                let closed = try await CaptureTimeout.unstructured(budget) {
                    try await database.closeActiveRequests(deviceID: device, before: close.before, at: close.at)
                }
                if closed > 0 { Self.log.info("Closed \(closed) requests left active by an earlier Surge session") }
            } catch {
                guard dropsFailedMaintenance(error, label: "Closing earlier sessions' requests") else { return }
            }
            if sessionCloses[device] == close { sessionCloses[device] = nil }
        }
        for run in vanished {
            let close = run.effective
            do {
                // An empty listing next to many rows it would end is likelier a listing that failed.
                var vanishing: Int64 = 0
                if close.emptyListing {
                    vanishing = try await CaptureTimeout.unstructured(budget) {
                        try await database.countVanishedRequests(deviceID: close.deviceID, session: close.session,
                                                                 keeping: Array(close.keeping), startedBefore: close.startedBefore)
                    }
                }
                if vanishing > emptyListingLimit {
                    Self.log.error("Not closing \(vanishing) active requests: dump active listed none of them")
                } else {
                    let closed = try await CaptureTimeout.unstructured(budget) {
                        try await database.closeVanishedRequests(deviceID: close.deviceID, session: close.session, keeping: Array(close.keeping),
                                                                 startedBefore: close.startedBefore, at: close.at)
                    }
                    if closed > 0 { Self.log.info("Closed \(closed) requests that ended while Tidemark was not watching") }
                }
            } catch {
                guard dropsFailedMaintenance(error, label: "Closing ended requests") else { return }
            }
            vanishedCloses.removeAll { $0 == run.scheduled }
        }
    }

    /// Logs a failed maintenance statement. A refused statement fails the same way again, so it is dropped
    /// (`true`: carry on); anything else (unreachable, timed out) stops the round and is retried later.
    private func dropsFailedMaintenance(_ error: any Error, label: String) -> Bool {
        if case DatabaseError.query(let message) = error {
            Self.log.error("\(label, privacy: .public) was refused: \(message, privacy: .public)")
            return true
        }
        Self.log.error("\(label, privacy: .public) failed; trying again later: \(error.localizedDescription, privacy: .public)")
        maintenanceRetryAt = Date.now.addingTimeInterval(maintenanceRetryInterval)
        return false
    }
}
