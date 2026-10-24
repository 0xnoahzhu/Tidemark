import Foundation
import os

/// The server refused a statement (`DatabaseError.query`): retrying the same data fails again.
struct CaptureWriteRejection: Error {
    var message: String
}

/// Every item of a batch was refused one by one: the server, not the data, is the problem (the work is
/// kept for later, like for an unreachable server).
struct CaptureServerRejection: Error, LocalizedError {
    var message: String
    var errorDescription: String? { "PostgreSQL refused every write: \(message)" }
}

/// Flushing, spool replay and the files kept beside the spool.
///
/// Errors are classified: an unreachable server, a timeout or a cancellation keeps everything (rows go to
/// the spool, the rest back into the buffer) and takes the pipeline offline; a rejected statement is
/// retried item by item, links to rows another Mac may have deleted (app, probe session) are dropped,
/// and only what the server still refuses is set aside — so one bad item never blocks the queue.
extension CapturePipeline {
    /// One round of writes: the due batch, the oldest spool segment, then (with the spool drained) the
    /// first-contact work saved by an earlier run. Closing rows of ended sessions runs beside it
    /// (`startMaintenanceIfDue`).
    func writeCycle(now: Date) async {
        defer {
            isFlushing = false
            flushStartedAt = nil
        }
        if online, buffer.shouldFlush(now: now) { await flushBatch(now: now, budget: flushBudget) }
        if online, !spool.isEmpty { await replayOldestSegment(now: now) }
        guard online, spool.isEmpty else { return }
        restoreAuxiliaryIfNeeded()
        if shouldSaveSnapshot(now: now) { saveSnapshot(now: now) }
    }

    /// Writes one batch. The caller sets `isFlushing`.
    func flushBatch(now: Date, budget: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: budget)
        writesSucceeded = false
        var batch = buffer.takeAll(now: now)
        prepareRequests(&batch)
        guard !batch.isEmpty else { return }
        // Each step empties its part of `batch` once written; `inFlightBatch` follows, so a quit during a stuck
        // step keeps exactly what is still unwritten.
        inFlightBatch = batch
        defer {
            inFlightBatch = nil
            inFlightHosts = []
        }
        do {
            try await writeChains(&batch, deadline: deadline)
            inFlightBatch = batch
            try await writeRequests(&batch, now: now, deadline: deadline)
            inFlightBatch = batch
            try await writeInventory(&batch, now: now, deadline: deadline)
            inFlightBatch = batch
            try await writeTouches(&batch, deadline: deadline)
            inFlightBatch = batch
            try await writeSources(&batch, deadline: deadline)
            inFlightBatch = batch
            try await writeAlerts(&batch, deadline: deadline)
        } catch {
            spoolRows(batch.requests)
            batch.requests = []
            buffer.restore(batch)
            goOffline(error)
        }
    }

    /// While older rows wait on disk, newer ones queue behind them, except the rows alerts of this batch link
    /// to: those are written now (merges never regress a row, so the older copies replayed later are harmless).
    private func prepareRequests(_ batch: inout CaptureWriteBuffer.Batch) {
        var needed: [RequestKey: RequestRecord] = [:]
        for draft in batch.drafts where draft.requestKey.session == session {
            guard let entry = entries[draft.requestKey.surgeID], entry.record.key == draft.requestKey, entry.record.rowID == nil else { continue }
            needed[draft.requestKey] = entry.record
        }
        if !spool.isEmpty, !batch.requests.isEmpty {
            let later = batch.requests.filter { needed[$0.key] == nil }
            batch.requests.removeAll { needed[$0.key] == nil }
            spoolRows(later)
        }
        let present = Set(batch.requests.map(\.key))
        for (key, record) in needed where !present.contains(key) { batch.requests.append(record) }
    }

    /// One database write, bounded by `writeTimeout` and the flush deadline. A refused statement throws
    /// `CaptureWriteRejection`; anything else (unreachable, timeout, cancelled) means "keep the work for later".
    func write<T: Sendable>(until deadline: ContinuousClock.Instant, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let remaining = ContinuousClock.now.duration(to: deadline)
        guard remaining > .zero else { throw CaptureTimeoutError(seconds: 0) }
        do {
            let value = try await CaptureTimeout.unstructured(min(writeTimeout, remaining), operation)
            writesSucceeded = true
            return value
        } catch DatabaseError.query(let message) {
            throw CaptureWriteRejection(message: message)
        }
    }

    /// After a rejected batch: runs `body` per item. Items the server still refuses are dropped (and
    /// returned). When every item of a multi-item batch is refused and no other statement of this flush
    /// succeeded, the server is at fault: that throws, and the work is kept for later.
    private func individually<Item: Sendable>(_ items: [Item], label: String, _ body: (Item) async throws -> Void) async throws -> [Item] {
        var refused: [Item] = []
        var message = ""
        for item in items {
            do {
                try await body(item)
            } catch let rejection as CaptureWriteRejection {
                refused.append(item)
                message = rejection.message
            }
        }
        if !refused.isEmpty, refused.count == items.count, items.count > 1, !writesSucceeded {
            throw CaptureServerRejection(message: message)
        }
        if !refused.isEmpty { Self.log.error("PostgreSQL refused \(refused.count) \(label, privacy: .public): \(message, privacy: .public)") }
        return refused
    }

    private func writeChains(_ batch: inout CaptureWriteBuffer.Batch, deadline: ContinuousClock.Instant) async throws {
        let database = self.database
        while let chain = batch.chains.first {
            // Chains queued before a switch between local and remote Surge belong to the device they ran on.
            let device = chain.deviceID ?? settings.deviceID
            do {
                _ = try await write(until: deadline) { try await database.upsertProcessChain(deviceID: device, chain: chain.chain, appID: chain.appID) }
            } catch let rejection as CaptureWriteRejection {
                // The app may be gone (deleted here or on another Mac): keep the processes without it.
                if chain.appID != nil {
                    do {
                        _ = try await write(until: deadline) { try await database.upsertProcessChain(deviceID: device, chain: chain.chain, appID: nil) }
                    } catch let again as CaptureWriteRejection {
                        Self.log.error("PostgreSQL refused a process chain: \(again.message, privacy: .public)")
                    }
                } else {
                    Self.log.error("PostgreSQL refused a process chain: \(rejection.message, privacy: .public)")
                }
            }
            batch.chains.removeFirst()
        }
    }

    private func writeRequests(_ batch: inout CaptureWriteBuffer.Batch, now: Date, deadline: ContinuousClock.Instant) async throws {
        guard !batch.requests.isEmpty else { return }
        let rows = batch.requests
        let database = self.database
        do {
            let result = try await write(until: deadline) { try await database.upsertRequestsCountingInserts(rows) }
            didWrite(rows, ids: result.ids, inserted: result.inserted, now: now)
        } catch is CaptureWriteRejection {
            let refused = try await writeRowsIndividually(rows, now: now, deadline: deadline)
            spool.quarantine(refused)
        }
        batch.requests = []
    }

    /// Writes rows one at a time; a refused row is retried without its app and probe links (they may point
    /// at rows another Mac deleted). Returns the rows still refused.
    private func writeRowsIndividually(_ rows: [RequestRecord], now: Date, deadline: ContinuousClock.Instant) async throws -> [RequestRecord] {
        let database = self.database
        return try await individually(rows, label: "request rows") { row in
            do {
                let result = try await write(until: deadline) { try await database.upsertRequestsCountingInserts([row]) }
                didWrite([row], ids: result.ids, inserted: result.inserted, now: now)
            } catch let rejection as CaptureWriteRejection {
                guard row.appID != nil || row.probeSessionID != nil else { throw rejection }
                var unlinked = row
                unlinked.appID = nil
                unlinked.probeSessionID = nil
                unlinked.isNew = false
                let result = try await write(until: deadline) { [unlinked] in try await database.upsertRequestsCountingInserts([unlinked]) }
                didWrite([unlinked], ids: result.ids, inserted: result.inserted, now: now)
            }
        }
    }

    private func writeInventory(_ batch: inout CaptureWriteBuffer.Batch, now: Date, deadline: ContinuousClock.Instant) async throws {
        guard !batch.newHosts.isEmpty else {
            batch.drafts = []
            return
        }
        let hosts = batch.newHosts
        let database = self.database
        inFlightHosts = hosts
        var winners: [AppHost] = []
        var refused = 0
        do {
            winners = try await write(until: deadline) { try await database.insertAppHosts(hosts) }
        } catch is CaptureWriteRejection {
            var won: [AppHost] = []
            refused = try await individually(hosts, label: "inventory entries") { host in
                won += try await write(until: deadline) { try await database.insertAppHosts([host]) }
            }.count
            winners = won
        }
        if winners.count + refused < hosts.count { pending.lostInventoryRace = true }
        batch.alerts.append(contentsOf: confirm(winners: winners, drafts: batch.drafts, now: now))
        batch.newHosts = []
        batch.drafts = []
    }

    private func writeTouches(_ batch: inout CaptureWriteBuffer.Batch, deadline: ContinuousClock.Instant) async throws {
        guard !batch.touches.isEmpty else { return }
        let touches = batch.touches
        let database = self.database
        do {
            try await write(until: deadline) { try await database.touchAppHosts(touches) }
        } catch is CaptureWriteRejection {
            _ = try await individually(touches, label: "inventory touches") { touch in
                try await write(until: deadline) { try await database.touchAppHosts([touch]) }
            }
        }
        batch.touches = []
    }

    private func writeSources(_ batch: inout CaptureWriteBuffer.Batch, deadline: ContinuousClock.Instant) async throws {
        guard !batch.sources.isEmpty else { return }
        let sources = batch.sources
        let database = self.database
        do {
            try await write(until: deadline) { try await database.touchHostSources(sources) }
        } catch is CaptureWriteRejection {
            _ = try await individually(sources, label: "host sources") { source in
                do {
                    try await write(until: deadline) { try await database.touchHostSources([source]) }
                } catch let rejection as CaptureWriteRejection {
                    guard source.appID != nil else { throw rejection }
                    var unlinked = source
                    unlinked.appID = nil
                    try await write(until: deadline) { [unlinked] in try await database.touchHostSources([unlinked]) }
                }
            }
        }
        batch.sources = []
    }

    private func writeAlerts(_ batch: inout CaptureWriteBuffer.Batch, deadline: ContinuousClock.Instant) async throws {
        guard !batch.alerts.isEmpty else { return }
        let alerts = batch.alerts
        let database = self.database
        do {
            let inserted = try await write(until: deadline) { try await database.insertAlerts(alerts) }
            pending.alerts.append(contentsOf: inserted)
        } catch is CaptureWriteRejection {
            var inserted: [AlertItem] = []
            _ = try await individually(alerts, label: "alerts") { alert in
                inserted += try await write(until: deadline) { try await database.insertAlerts([alert]) }
            }
            pending.alerts.append(contentsOf: inserted)
        }
        batch.alerts = []
    }

    /// Stores row IDs and write times back into live rows; counts the rows PostgreSQL inserted.
    func didWrite(_ rows: [RequestRecord], ids: [RequestKey: Int64], inserted: Int, now: Date) {
        for row in rows {
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
        pending.rowsWritten += inserted
        lastWriteAt = now
    }

    /// Turns drafts whose inventory entry won the cross-Mac race into alerts and marks their requests NEW.
    /// An IP alert kept as a fallback fires only when its domain entry lost while the IP entry won.
    func confirm(winners: [AppHost], drafts: [CaptureAlertDraft], now: Date) -> [AlertItem] {
        let won = Set(winners.map { "\($0.appID.uuidString)|\($0.id)" })
        for key in won {
            guard let origin = hostOrigins.removeValue(forKey: key), origin.session == session,
                  var entry = entries[origin.surgeID], entry.record.key == origin, !entry.record.isNew else { continue }
            entry.record.isNew = true
            entry.dirty = true
            entry.urgent = true
            entries[origin.surgeID] = entry
            markChanged(entry.record, fresh: false)
        }
        var alerts: [AlertItem] = []
        var seen: Set<String> = []
        let primaries = drafts.filter { $0.fallbackFor == nil }
        let fallbacks = drafts.filter { draft in
            guard let primary = draft.fallbackFor else { return false }
            return !won.contains("\(draft.appID.uuidString)|\(primary)")
        }
        for draft in primaries + fallbacks {
            let key = "\(draft.appID.uuidString)|\(draft.hostID)"
            guard won.contains(key), seen.insert(key).inserted else { continue }
            var rowID: Int64?
            if draft.requestKey.session == session, let entry = entries[draft.requestKey.surgeID], entry.record.key == draft.requestKey {
                rowID = entry.record.rowID
            }
            // The request's own Mac, also for drafts queued before a switch between local and remote Surge.
            alerts.append(draft.item(deviceID: draft.requestKey.deviceID, requestRowID: rowID, createdAt: now))
        }
        return alerts
    }

    // MARK: Spool

    /// Replays the oldest spool segment, decoding it chunk by chunk. The segment is removed only when every
    /// row was written or set aside; otherwise it stays (replaying it again is harmless: upserts merge).
    func replayOldestSegment(now: Date) async {
        guard let segment = spool.openOldestSegment() else { return }
        writesSucceeded = false
        let chunkSize = max(100, min(1000, settings.batchRows))
        let database = self.database
        var start = 0
        while start < segment.lines.count {
            let rows = CaptureSpool.decode(segment.lines[start..<min(start + chunkSize, segment.lines.count)])
            start += chunkSize
            guard !rows.isEmpty else { continue }
            let deadline = ContinuousClock.now.advanced(by: writeTimeout)
            do {
                do {
                    let result = try await write(until: deadline) { try await database.upsertRequestsCountingInserts(rows) }
                    didWrite(rows, ids: result.ids, inserted: result.inserted, now: now)
                } catch is CaptureWriteRejection {
                    let refused = try await writeRowsIndividually(rows, now: now, deadline: .now.advanced(by: writeTimeout * 4))
                    spool.quarantine(refused)
                }
            } catch {
                goOffline(error)
                return
            }
            guard online else { return }
        }
        spool.removeSegment(segment.id)
    }

    func spoolRows(_ rows: [RequestRecord]) {
        guard !rows.isEmpty else { return }
        do {
            try spool.append(rows)
        } catch {
            Self.log.error("Could not spool \(rows.count) rows: \(error.localizedDescription, privacy: .public)")
        }
    }

    func goOffline(_ error: any Error) {
        guard online else { return }
        online = false
        pending.databaseFailure = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        pending.databaseError = error
        Self.log.error("PostgreSQL write failed: \(error.localizedDescription, privacy: .public)")
    }

    // MARK: Files beside the spool

    /// First-contact work saved when an earlier run quit offline goes back into the queue (once per launch).
    func restoreAuxiliaryIfNeeded() {
        guard !auxiliaryRestored else { return }
        auxiliaryRestored = true
        guard let saved = sidecar.takeAuxiliary() else { return }
        buffer.restore(saved)
    }

    func shouldSaveSnapshot(now: Date) -> Bool {
        guard knownLoaded else { return false }
        guard let last = lastSnapshotAt else { return true }
        return now.timeIntervalSince(last) >= snapshotInterval
    }

    /// Saves apps, mutes and the inventory index for a launch without the database.
    func saveSnapshot(now: Date) {
        guard knownLoaded, !allApps.isEmpty || known.count > 0 else { return }
        lastSnapshotAt = now
        sidecar.saveSnapshot(CaptureStateSnapshot(savedAt: now, apps: allApps, mutes: mutes, known: known.exported))
    }
}
