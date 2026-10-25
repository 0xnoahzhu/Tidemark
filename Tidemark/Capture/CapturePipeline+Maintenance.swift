import Foundation
import os

/// Merging the earlier IDs of this Mac into its current one (`mergeDevice`), and closing rows Surge will never update
/// again: rows left active by earlier Surge sessions (`closeActiveRequests`) and rows of a session that `dump active`
/// no longer lists (`closeVanishedRequests`).
///
/// These statements may scan many rows, so they run beside the writes, one round at a time, with their own
/// long budget. A failure never takes capture offline: it is logged and the work is tried again later. A close is
/// tried again after `maintenanceRetryInterval`, or as soon as the next reconnect brings PostgreSQL back; merging has
/// its own retry time and backoff, so it never holds up the closes.
extension CapturePipeline {
    /// A close as scheduled, and as it runs (with every request still active in memory kept).
    typealias VanishedRun = (scheduled: VanishedClose, effective: VanishedClose)

    /// Schedules merging the rows an earlier ID of this Mac (`legacy`, see `DeviceIdentity`) wrote into `into`. It runs
    /// as maintenance once PostgreSQL is reachable, the spool is replayed and `deviceMergeDelay` passed since this
    /// launch first reached PostgreSQL, and only while nothing wrote under `legacy` since then. A merge that succeeded
    /// is reported in `mergedDevices`; one that failed is tried again later. An ID already merged or left alone in
    /// this launch is not scheduled again.
    func scheduleDeviceMerge(from legacy: DeviceID, into: DeviceID) {
        guard legacy != into, !settledDevices.contains(legacy), deviceMerges[legacy] == nil else { return }
        deviceMerges[legacy] = into
    }

    /// Starts a maintenance round when one is due: PostgreSQL reachable, the spool replayed, no round running, and
    /// a close whose rows are no longer waiting to be written (a later write of such a row would insert it active
    /// again, and the merge never reopens a closed row), or merging earlier IDs of this Mac (`deviceMergesDue`).
    /// Returns the round's task.
    func startMaintenanceIfDue(now: Date) -> Task<Void, Never>? {
        guard online else { return nil }
        if writingSince == nil { writingSince = now }
        guard spool.isEmpty, maintenanceTask == nil else { return nil }
        var sessions: [DeviceID: SessionClose] = [:]
        var vanished: [VanishedClose] = []
        if now >= maintenanceRetryAt, !sessionCloses.isEmpty || !vanishedCloses.isEmpty {
            let queued = buffer.queuedRequests + (inFlightBatch?.requests ?? [])
            sessions = sessionCloses.filter { device, close in
                !queued.contains { $0.key.deviceID == device && $0.key.session < close.before }
            }
            vanished = vanishedCloses.filter { close in
                !queued.contains { row in
                    row.key.deviceID == close.deviceID && row.key.session == close.session && row.state == .active
                        && row.startedAt < close.startedBefore && !close.keeping.contains(row.key.surgeID) && !isKnownActive(row.key)
                }
            }
        }
        let merging = deviceMergesDue(now: now)
        guard merging || !sessions.isEmpty || !vanished.isEmpty else { return nil }
        let runs = vanished.map { ($0, keepingKnownActive($0)) }
        let task = Task { await self.runMaintenance(sessions: sessions, vanished: runs, merging: merging, now: now) }
        maintenanceTask = task
        return task
    }

    /// Merging is due once `deviceMergeDelay` passed since this launch first reached PostgreSQL, and after its retry
    /// time: an ID is scheduled, or it is time to look for more (`deviceLookInterval`).
    private func deviceMergesDue(now: Date) -> Bool {
        guard !deviceMergesStopped, let writingSince, now >= writingSince.addingTimeInterval(deviceMergeDelay),
              now >= deviceMergeRetryAt else { return false }
        return !deviceMerges.isEmpty || (!settings.isRemote && now >= nextDeviceLookAt)
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

    private func runMaintenance(sessions: [DeviceID: SessionClose], vanished: [VanishedRun], merging: Bool, now: Date) async {
        defer { maintenanceTask = nil }
        await close(sessions: sessions, vanished: vanished)
        if merging { await mergeEarlierDeviceIDs(now: now) }
    }

    /// Closes rows of ended sessions and rows that ended unseen; stops at a failure that is worth trying again.
    private func close(sessions: [DeviceID: SessionClose], vanished: [VanishedRun]) async {
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

    /// Looks for earlier IDs of this Mac when it is time (`devicesSharingHistory`: the Macs that recorded its Surge
    /// sessions or its processes), then merges every scheduled one, provided nothing wrote under it since this launch
    /// first reached PostgreSQL. An ID something still writes under, or a remote Surge, is left alone until the next
    /// launch. Requests a merge moved that earlier Surge sessions left active are closed like this Mac's own, by a
    /// close scheduled for the next round; and since their sessions and processes may lead to further IDs, the next
    /// round looks again.
    ///
    /// A failure is retried later with a growing pause (`deviceMergeRetryAt`), and given up until the next launch once
    /// the server refused it `deviceMergeRefusalLimit` times in a row: a merge resumes where it stopped, and nothing
    /// is lost while it waits.
    private func mergeEarlierDeviceIDs(now: Date) async {
        let database = self.database
        let device = settings.deviceID
        let idle = Duration.seconds(max(deviceMergeDelay, now.timeIntervalSince(writingSince ?? now)))
        do {
            if !settings.isRemote, now >= nextDeviceLookAt {
                let sessions = session > 0 ? [session] : []
                let found = try await CaptureTimeout.unstructured(maintenanceBudget) {
                    try await database.devicesSharingHistory(with: device, sessions: sessions)
                }
                nextDeviceLookAt = now.addingTimeInterval(deviceLookInterval)
                for id in found where !settledDevices.contains(id) && deviceMerges[id] == nil {
                    Self.log.info("Found an earlier ID of this Mac: it recorded this Mac's Surge sessions or processes")
                    deviceMerges[id] = device
                }
            }
            for (from, into) in deviceMerges.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
                let merge = try await CaptureTimeout.unstructured(deviceMergeBudget) {
                    try await database.mergeDevice(from, into: into, idleFor: idle)
                }
                if deviceMerges[from] == into { deviceMerges[from] = nil }
                settledDevices.insert(from)
                switch merge.refusal {
                case nil:
                    if merge.merged {
                        Self.log.info("Merged an earlier ID of this Mac: \(merge.requestsMoved) requests moved, \(merge.duplicatesDropped) duplicates dropped")
                    }
                    pending.mergedDevices.append(from)
                case .stillWriting:
                    Self.log.error("Not merging an earlier ID of this Mac before the next launch: something still writes under it")
                case .remoteSurge:
                    Self.log.error("Not merging a remote Surge into this Mac")
                }
                if merge.requestsMoved > 0 {
                    nextDeviceLookAt = .distantPast
                    if into == settings.deviceID, session > 0, sessionCloses[into] == nil {
                        sessionCloses[into] = SessionClose(before: session, at: Date(timeIntervalSince1970: Double(session) / 1000))
                    }
                }
            }
            deviceMergeFailures = 0
            deviceMergeRefusals = 0
        } catch {
            deviceMergeFailures += 1
            if case DatabaseError.query = error { deviceMergeRefusals += 1 } else { deviceMergeRefusals = 0 }
            if deviceMergeRefusals >= deviceMergeRefusalLimit {
                deviceMergesStopped = true
                let refusals = deviceMergeRefusals
                Self.log.error("Merging an earlier ID of this Mac was refused \(refusals) times; not trying again before the next launch: \(error.localizedDescription, privacy: .public)")
                return
            }
            let pause = min(maintenanceRetryInterval * pow(2, Double(deviceMergeFailures - 1)), deviceMergeMaxRetryInterval)
            deviceMergeRetryAt = now.addingTimeInterval(pause)
            Self.log.error("Merging an earlier ID of this Mac failed; trying again in \(Int(pause)) s: \(error.localizedDescription, privacy: .public)")
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
