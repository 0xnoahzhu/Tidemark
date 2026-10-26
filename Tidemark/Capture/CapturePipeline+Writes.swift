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
            inFlightBatch = batch
            try await writeDNSAnswers(&batch, deadline: deadline)
            inFlightBatch = batch
            try await writeProxyErrors(&batch, deadline: deadline)
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
        } catch let rejection as CaptureWriteRejection {
            let refused = try await writeRowsIndividually(rows, refusal: rejection.message, now: now, deadline: deadline)
            spool.quarantine(refused)
        }
        batch.requests = []
    }

    /// After a refused batch of rows: writes it in halves and splits only the halves the server refuses
    /// again, so a bad row costs a few statements rather than one per row of the batch. A single refused row
    /// is retried without its app and probe links (they may point at rows another Mac deleted). Returns the
    /// rows still refused. When every row is refused and no other statement of this flush succeeded, the
    /// server is at fault: that throws, and the rows are kept for later.
    private func writeRowsIndividually(_ rows: [RequestRecord], refusal: String, now: Date, deadline: ContinuousClock.Instant) async throws
        -> [RequestRecord] {
        let (refused, deeper) = try await bisectRefused(rows, now: now, deadline: deadline)
        let message = deeper.isEmpty ? refusal : deeper
        if !refused.isEmpty, refused.count == rows.count, rows.count > 1, !writesSucceeded {
            throw CaptureServerRejection(message: message)
        }
        if !refused.isEmpty { Self.log.error("PostgreSQL refused \(refused.count) request rows: \(message, privacy: .public)") }
        return refused
    }

    /// `rows` were refused together: their halves are tried apart (recursively), down to single rows.
    private func bisectRefused(_ rows: [RequestRecord], now: Date, deadline: ContinuousClock.Instant) async throws
        -> (refused: [RequestRecord], message: String) {
        let database = self.database
        guard rows.count > 1 else {
            guard let row = rows.first else { return ([], "") }
            guard row.appID != nil || row.probeSessionID != nil else { return ([row], "") }
            var unlinked = row
            unlinked.appID = nil
            unlinked.probeSessionID = nil
            unlinked.isNew = false
            do {
                let result = try await write(until: deadline) { [unlinked] in try await database.upsertRequestsCountingInserts([unlinked]) }
                didWrite([unlinked], ids: result.ids, inserted: result.inserted, now: now)
                return ([], "")
            } catch let rejection as CaptureWriteRejection {
                return ([row], rejection.message)
            }
        }
        var refused: [RequestRecord] = []
        var message = ""
        let middle = rows.count / 2
        for half in [Array(rows[..<middle]), Array(rows[middle...])] {
            do {
                let result = try await write(until: deadline) { try await database.upsertRequestsCountingInserts(half) }
                didWrite(half, ids: result.ids, inserted: result.inserted, now: now)
            } catch let rejection as CaptureWriteRejection {
                let deeper = try await bisectRefused(half, now: now, deadline: deadline)
                refused += deeper.refused
                message = deeper.message.isEmpty ? rejection.message : deeper.message
            }
        }
        return (refused, message)
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

    private func writeDNSAnswers(_ batch: inout CaptureWriteBuffer.Batch, deadline: ContinuousClock.Instant) async throws {
        guard !batch.dnsAnswers.isEmpty else { return }
        let answers = batch.dnsAnswers
        let database = self.database
        do {
            try await write(until: deadline) { try await database.saveDNSAnswers(answers) }
        } catch is CaptureWriteRejection {
            _ = try await individually(answers, label: "DNS answers") { answer in
                try await write(until: deadline) { try await database.saveDNSAnswers([answer]) }
            }
        }
        batch.dnsAnswers = []
    }

    private func writeProxyErrors(_ batch: inout CaptureWriteBuffer.Batch, deadline: ContinuousClock.Instant) async throws {
        guard !batch.proxyErrors.isEmpty else { return }
        let errors = batch.proxyErrors
        let database = self.database
        do {
            try await write(until: deadline) { try await database.saveProxyErrors(errors) }
        } catch is CaptureWriteRejection {
            _ = try await individually(errors, label: "proxy errors") { error in
                try await write(until: deadline) { try await database.saveProxyErrors([error]) }
            }
        }
        batch.proxyErrors = []
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
            let rows = ownedByThisDevice(CaptureSpool.decode(segment.lines[start..<min(start + chunkSize, segment.lines.count)]))
            start += chunkSize
            guard !rows.isEmpty else { continue }
            let deadline = ContinuousClock.now.advanced(by: writeTimeout)
            do {
                do {
                    let result = try await write(until: deadline) { try await database.upsertRequestsCountingInserts(rows) }
                    didWrite(rows, ids: result.ids, inserted: result.inserted, now: now)
                } catch let rejection as CaptureWriteRejection {
                    let refused = try await writeRowsIndividually(rows, refusal: rejection.message, now: now,
                                                                  deadline: .now.advanced(by: writeTimeout * 4))
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

    /// Rows kept on disk are this Mac's own (`settings.deviceID`), whatever ID they were spooled under: an earlier ID
    /// of this Mac (`DeviceIdentity`) may have been merged away meanwhile, and a row of a device that no longer exists
    /// is refused (`requests.device_id` references `devices`), so the spool would never drain. A row whose key now
    /// matches a stored row merges into it like any rewrite. The earlier ID itself is this Mac's too, so whatever else
    /// it wrote is merged into this Mac's ID (`scheduleEarlierDeviceIDs`).
    func ownedByThisDevice(_ rows: [RequestRecord]) -> [RequestRecord] {
        let device = settings.deviceID
        guard rows.contains(where: { $0.key.deviceID != device }) else { return rows }
        scheduleEarlierDeviceIDs(Set(rows.map(\.key.deviceID)))
        return rows.map { row in
            var row = row
            row.key.deviceID = device
            return row
        }
    }

    /// IDs found in the spool or in `auxiliary.json` other than this Mac's: earlier IDs of this Mac, merged into its
    /// current one.
    func scheduleEarlierDeviceIDs(_ ids: Set<DeviceID>) {
        for id in ids where id != settings.deviceID && !settledDevices.contains(id) && deviceMerges[id] == nil {
            Self.log.info("Found work saved under an earlier ID of this Mac: written under its current ID, and the earlier ID is merged into it")
            scheduleDeviceMerge(from: id, into: settings.deviceID)
        }
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

    /// First-contact work saved when an earlier run quit offline goes back into the queue (once per launch), as this
    /// Mac's own like the spool's rows (`ownedByThisDevice`).
    func restoreAuxiliaryIfNeeded() {
        guard !auxiliaryRestored else { return }
        auxiliaryRestored = true
        guard let saved = sidecar.takeAuxiliary() else { return }
        scheduleEarlierDeviceIDs(saved.deviceIDs)
        buffer.restore(saved.recorded(as: settings.deviceID))
    }

    func shouldSaveSnapshot(now: Date) -> Bool {
        guard knownLoaded else { return false }
        guard let last = lastSnapshotAt else { return true }
        return now.timeIntervalSince(last) >= snapshotInterval
    }

    /// Saves apps and the inventory index for a launch without the database.
    func saveSnapshot(now: Date) {
        guard knownLoaded, !allApps.isEmpty || known.count > 0 else { return }
        lastSnapshotAt = now
        sidecar.saveSnapshot(CaptureStateSnapshot(savedAt: now, apps: allApps, known: known.exported))
    }
}

extension CaptureWriteBuffer.Batch {
    /// Every device this work names.
    var deviceIDs: Set<DeviceID> {
        var ids = Set(chains.compactMap(\.deviceID))
        ids.formUnion(newHosts.compactMap(\.firstDeviceID))
        ids.formUnion(drafts.map(\.requestKey.deviceID))
        ids.formUnion(touches.compactMap(\.firstDeviceID))
        ids.formUnion(sources.map(\.deviceID))
        ids.formUnion(alerts.map(\.deviceID))
        ids.formUnion(dnsAnswers.map(\.deviceID))
        ids.formUnion(proxyErrors.map(\.deviceID))
        return ids
    }

    /// The same work as `device`'s: its process chains, host sources, alerts, DNS answers and proxy errors, the requests
    /// its alert drafts belong to and the first Mac of its inventory entries (see `CapturePipeline.ownedByThisDevice`).
    func recorded(as device: DeviceID) -> Self {
        var batch = self
        for index in batch.chains.indices { batch.chains[index].deviceID = device }
        for index in batch.newHosts.indices where batch.newHosts[index].firstDeviceID != nil { batch.newHosts[index].firstDeviceID = device }
        for index in batch.drafts.indices { batch.drafts[index].requestKey.deviceID = device }
        for index in batch.touches.indices where batch.touches[index].firstDeviceID != nil { batch.touches[index].firstDeviceID = device }
        for index in batch.sources.indices { batch.sources[index].deviceID = device }
        for index in batch.alerts.indices { batch.alerts[index].deviceID = device }
        for index in batch.dnsAnswers.indices { batch.dnsAnswers[index].deviceID = device }
        for index in batch.proxyErrors.indices { batch.proxyErrors[index].deviceID = device }
        return batch
    }
}
