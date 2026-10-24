import AppKit
import CryptoKit
import Foundation
import Observation
import os

/// Records every request Surge handles into PostgreSQL, rolls requests up to monitored apps and alerts on
/// first contact. Implements `CaptureActions` for the UI.
///
/// The engine owns the connection lifecycles (Surge stream with reconnect, backfill, session tracking and a
/// liveness watchdog; PostgreSQL with reconnect and spool replay), the periodic jobs (stats, devices,
/// retention, shared state, polling other Macs) and the main-actor state. Request processing happens off
/// the main actor in `CapturePipeline`; the engine drains its coalesced changes four times a second.
@MainActor
final class CaptureEngine {
    let model: AppModel
    let processes: any ProcessInspecting
    let classifier: any SiteClassifying
    /// Shared with `ProbeController` so Surge records of probe connections can be matched.
    let probeRegistry: ProbeRegistry
    let pipeline: CapturePipeline
    let notifier = CaptureNotifier()

    private(set) var surge: any SurgeClient
    private(set) var database: any TidemarkDatabase

    /// Receives Surge signals (policy switches, reloads, restarts, wake) to schedule egress checks.
    weak var egress: EgressMonitor?
    /// Builds a client when the surge-cli path, the remote controller or its password changes. When nil the
    /// engine keeps its client and only restarts the stream.
    var makeSurgeClient: ((SurgeEndpoint) -> any SurgeClient)?
    /// Builds a database for a connection URL (password included). Used when the URL or the Keychain
    /// password changes, and for testing new settings. When nil the engine reconnects its instance.
    var makeDatabase: ((String) -> any TidemarkDatabase)?
    /// Called on the main actor after the engine switched to a new database (services that read it follow).
    var databaseChanged: ((any TidemarkDatabase) -> Void)?
    /// Releases a database the engine no longer uses (closes its connection pool).
    var retireDatabase: (@Sendable (any TidemarkDatabase) async -> Void)?
    /// The PostgreSQL URL (Keychain password included) the settings describe. Read only when `makeDatabase`
    /// is set; tests replace it so they never touch the Keychain.
    var settingsDatabaseURL: @MainActor () -> String

    static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "capture")

    /// Nothing from the watch stream for this long (Surge sends a speed event every second) restarts it.
    let streamSilenceLimit: TimeInterval = 15
    /// Explaining a host may delay its notification by at most this much.
    let explanationTimeout: Duration = .milliseconds(1500)
    /// Longest wait for connecting to PostgreSQL or a ping (migrations may take longer and are not bounded).
    let connectTimeout: Duration = .seconds(20)
    /// After this many failed reconnects in a row the client is rebuilt: its pooled connections may be dead.
    let rebuildAfterFailures = 3
    /// Apps another Mac added are evaluated against their inventory once that Mac's backfill has had this long
    /// (counted from the app's creation) to rebuild it.
    let remoteInventoryAllowance: TimeInterval = 90

    private var started = false
    private var jobs: [String: Task<Void, Never>] = [:]
    private var streamTask: Task<Void, Never>?
    private var streamConnectedAt: Date?
    private var databaseTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var surgeSettingsTask: Task<Void, Never>?
    private var scopeObservation: ObservationTracking.Token?
    private var preferencesObservation: ObservationTracking.Token?
    private var workspaceTokens: [NotificationCenter.ObservationToken] = []

    private var rateMeter = CaptureRateMeter()
    private var surgeStartTime: Double?
    private var lastEnvironment: SurgeEnvironment?
    private var observedScope: DeviceScope = .all
    private var observedPreferences: PreferenceValues?
    /// Device the pipeline currently writes under.
    private var appliedRecordingDevice: DeviceID
    /// SHA-256 of the connection URL (password included) the current database was built with; nil when unknown.
    private(set) var databaseFingerprint: String?
    private var reconnectAttempt = 0
    /// Last time a write failed after the connection had been established.
    private var lastWriteFailureAt: Date?
    private var todayStart = Calendar.current.startOfDay(for: .now)
    private var totalBase: Int64 = 0
    private var writtenSinceEstimate: Int64 = 0
    private var lastAlertID: Int64 = 0
    private var notifiedAlerts: Set<Int64> = []
    private var liveCursor = Date.now.addingTimeInterval(-60)
    /// The app list was loaded from PostgreSQL at least once (apps that appear later were added elsewhere).
    private var catalogLoaded = false
    /// Bumped by every local change of the app list: a database read of the apps that started before it is
    /// stale and must not be applied.
    var catalogGeneration = 0

    /// Preferences the engine reacts to.
    private struct PreferenceValues: Equatable {
        var cliPath: String
        var remote: String
        var remoteTag: String
        var databaseURL: String
        var batchRows: Int
        var batchInterval: Double
        var spoolLimit: Int
        var systemNotifications: Bool

        @MainActor init(_ p: Preferences) {
            cliPath = p.surgeCLIPath
            remote = p.surgeRemote.trimmingCharacters(in: .whitespaces)
            remoteTag = p.surgeRemoteTag
            databaseURL = p.databaseURL
            batchRows = p.batchRows
            batchInterval = p.batchInterval
            spoolLimit = p.spoolLimit
            systemNotifications = p.systemNotifications
        }
    }

    init(
        model: AppModel,
        surge: any SurgeClient,
        database: any TidemarkDatabase,
        processes: any ProcessInspecting,
        classifier: any SiteClassifying,
        probeRegistry: ProbeRegistry = ProbeRegistry(),
        spool: CaptureSpool? = nil,
        contactGrace: TimeInterval = 2.5
    ) {
        self.model = model
        self.surge = surge
        self.database = database
        self.processes = processes
        self.classifier = classifier
        self.probeRegistry = probeRegistry
        let preferences = model.preferences
        appliedRecordingDevice = CaptureDeviceInfo.recordingDeviceID(preferences)
        settingsDatabaseURL = { preferences.databaseURLWithPassword }
        pipeline = CapturePipeline(
            settings: Self.settings(preferences, surge: surge),
            database: database,
            surge: surge,
            processes: processes,
            classifier: classifier,
            probes: probeRegistry,
            spool: spool ?? CaptureSpool(limit: preferences.spoolLimit),
            contactGrace: contactGrace
        )
    }

    /// The device rows are written under (this Mac, or the remote Surge's row).
    var recordingDeviceID: DeviceID { CaptureDeviceInfo.recordingDeviceID(model.preferences) }
    var thisDeviceID: DeviceID { model.preferences.thisDeviceID }

    private static func settings(_ preferences: Preferences, surge: any SurgeClient) -> CaptureSettings {
        CaptureSettings(
            deviceID: CaptureDeviceInfo.recordingDeviceID(preferences),
            isRemote: surge.endpoint.remote != nil,
            batchRows: preferences.batchRows,
            batchInterval: preferences.batchInterval,
            ownExecutablePath: Bundle.main.executablePath
        )
    }

    /// Records which connection URL (password included) the current database was built with, so a later
    /// change of the URL or of the Keychain password rebuilds it.
    func adoptDatabaseURL(_ url: String) {
        databaseFingerprint = Self.fingerprint(url)
    }

    static func fingerprint(_ secret: String) -> String {
        SHA256.hash(data: Data(secret.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Surge's `start-time` (seconds) as the session key (milliseconds).
    static func sessionKey(_ startTime: Double) -> Int64 { Int64((startTime * 1000).rounded()) }

    // MARK: Lifecycle

    /// Connects PostgreSQL (migrating it) and loads the shared state, then subscribes to Surge and starts
    /// the periodic jobs. Recording always starts on. Without a database the shared state saved by the
    /// last run is used, so attribution and first contact keep working.
    func start() {
        guard !started else { return }
        started = true
        model.live.recording = true
        notifier.onView = { [weak self] appID, ids in self?.openAlerts(appID: appID, ids: ids) }
        notifier.onMute = { [weak self] pattern, id in
            guard let self else { return }
            Task { await self.mute(pattern, dismissingAlert: id) }
        }
        notifier.install()
        if model.preferences.systemNotifications {
            Task { await notifier.requestAuthorizationIfNeeded() }
        }
        observedPreferences = PreferenceValues(model.preferences)
        observedScope = model.devices.scope
        pipelineTask = Task { [pipeline] in await pipeline.run() }
        startObservers()
        startJobs()
        databaseTask = Task { [weak self] in
            guard let self else { return }
            let connected = await self.connectDatabase()
            if !connected { await self.restoreSavedState() }
            self.startStream()
            if !connected { self.scheduleDatabaseReconnect() }
        }
    }

    /// Stops every job and writes what is buffered. The final flush is shielded from cancellation so a
    /// terminating app still gets its rows out (or onto the spool) within a few seconds.
    func stop() async {
        guard started else { return }
        started = false
        for job in jobs.values { job.cancel() }
        jobs.removeAll()
        streamTask?.cancel()
        databaseTask?.cancel()
        if let token = scopeObservation.take() { token.cancel() }
        if let token = preferencesObservation.take() { token.cancel() }
        for token in workspaceTokens { NSWorkspace.shared.notificationCenter.removeObserver(token) }
        workspaceTokens.removeAll()
        let pipeline = self.pipeline
        // macOS 27: the final flush runs to completion even when the calling task was cancelled.
        await withTaskCancellationShield {
            await pipeline.flushAll(final: true)
        }
        pipelineTask?.cancel()
    }

    // MARK: PostgreSQL

    /// One connection attempt: connect, migrate, ping, register this Mac and load the shared state.
    /// Connecting and the ping are bounded (a pooled connection may be dead); migrations are not, since
    /// building an index on a large table may take minutes. Writes resume before the shared state has loaded,
    /// so a slow read there never keeps capture offline.
    @discardableResult
    func connectDatabase() async -> Bool {
        model.live.database = .connecting
        let database = self.database
        do {
            try await CaptureTimeout.unstructured(connectTimeout) { try await database.connect() }
            try await database.migrate()
            let ping = try await CaptureTimeout.unstructured(connectTimeout) { try await database.ping() }
            model.live.lastRoundTrip = ping.roundTrip
            model.live.serverVersion = ping.serverVersion
            model.live.database = .connected(detail: "PostgreSQL \(ping.serverVersion)")
        } catch {
            model.live.database = .failed(message: Self.message(for: error))
            await pipeline.setDatabaseOnline(false)
            return false
        }
        await pipeline.setDatabaseOnline(true)
        await loadSharedState()
        return true
    }

    /// Retries the connection with exponential backoff (1 s … 60 s) until it succeeds. The backoff keeps
    /// growing across failures until a write succeeds, so a server that accepts connections but refuses
    /// writes is not hammered.
    func scheduleDatabaseReconnect() {
        databaseTask?.cancel()
        databaseTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                guard let self else { return }
                self.reconnectAttempt += 1
                try? await Task.sleep(for: .seconds(Self.backoff(self.reconnectAttempt)))
                guard !Task.isCancelled else { return }
                if await self.connectDatabase() { return }
                failures += 1
                // Statements abandoned on dead sockets may still hold the pool's connections: start afresh.
                if failures % self.rebuildAfterFailures == 0, self.makeDatabase != nil {
                    let url = self.settingsDatabaseURL()
                    await self.replaceDatabase(url: url, fingerprint: Self.fingerprint(url))
                }
            }
        }
    }

    /// Reconnects PostgreSQL; rebuilds the client first when the URL or the Keychain password changed.
    /// Without `force` nothing happens unless something changed.
    func applyDatabaseSettings(force: Bool) {
        let replacement = changedDatabaseURL()
        guard replacement != nil || force else { return }
        reconnectDatabase(replacingWith: replacement)
    }

    /// The settings' URL when it (or its Keychain password) differs from the live connection's.
    func changedDatabaseURL() -> (url: String, fingerprint: String)? {
        guard makeDatabase != nil else { return nil }
        let url = settingsDatabaseURL()
        let fingerprint = Self.fingerprint(url)
        return fingerprint == databaseFingerprint ? nil : (url, fingerprint)
    }

    private func reconnectDatabase(replacingWith replacement: (url: String, fingerprint: String)?) {
        databaseTask?.cancel()
        reconnectAttempt = 0
        databaseTask = Task { [weak self] in
            guard let self else { return }
            // Rows are spooled until the (new) connection is up.
            await self.pipeline.setDatabaseOnline(false)
            if let replacement { await self.replaceDatabase(url: replacement.url, fingerprint: replacement.fingerprint) }
            if !(await self.connectDatabase()) { self.scheduleDatabaseReconnect() }
        }
    }

    /// Switches to a new client for `url` and retires the old one (closing its pools) in the background.
    private func replaceDatabase(url: String, fingerprint: String) async {
        guard let make = makeDatabase else { return }
        let old = database
        let database = make(url)
        self.database = database
        model.database = database
        databaseFingerprint = fingerprint
        databaseChanged?(database)
        await pipeline.setServices(surge: surge, database: database)
        if let retire = retireDatabase { Task.detached { await retire(old) } }
    }

    /// Devices, apps, installs, mutes, inventory, alerts, probe sessions and counters.
    private func loadSharedState() async {
        await registerDevices()
        do {
            let generation = catalogGeneration
            let apps = try await database.apps()
            if generation == catalogGeneration { await applyCatalog(apps) }
        } catch {
            Self.log.error("Loading apps failed: \(error.localizedDescription, privacy: .public)")
        }
        if let installs = try? await database.installs() { model.catalog.installs = installs }
        await updateInstalls(force: true)
        if let mutes = try? await database.mutes() {
            model.alerts.mutes = mutes
            await pipeline.setMutes(mutes)
        }
        do {
            try await pipeline.loadKnownHosts()
        } catch {
            Self.log.error("Loading inventory failed: \(error.localizedDescription, privacy: .public)")
        }
        // The highest ID, not the newest by (client) time: Macs' clocks differ.
        if let recent = try? await database.alerts(filter: .all, appID: nil, scope: .all, limit: 200), let newest = recent.map(\.id).max() {
            lastAlertID = max(lastAlertID, newest)
        }
        await reloadScoped()
        if let sessions = try? await database.probeSessions(limit: 100) {
            model.probe.sessions = sessions
            if model.probe.selectedID == nil { model.probe.selectedID = sessions.first?.id }
        }
        await refreshTotal()
        await refreshToday()
    }

    /// The apps, mutes and inventory saved by the last run, when PostgreSQL is unreachable at launch.
    private func restoreSavedState() async {
        guard model.catalog.apps.isEmpty, let snapshot = await pipeline.restoreSnapshot() else { return }
        Self.log.info("PostgreSQL is unreachable; using the shared state saved \(snapshot.savedAt, privacy: .public)")
        model.catalog.apps = snapshot.apps
        model.alerts.mutes = snapshot.mutes
        await pushApps()
    }

    /// Replaces the app list, purging apps another Mac deleted from everything queued. Apps another Mac added
    /// wait for their inventory, which that Mac's backfill is rebuilding: until it is loaded here, every host
    /// they contact would look new.
    private func applyCatalog(_ apps: [MonitoredApp], now: Date = .now) async {
        let previous = Set(model.catalog.apps.map(\.id))
        let removed = previous.subtracting(apps.map(\.id))
        let added = catalogLoaded ? apps.filter { !previous.contains($0.id) && !$0.isArchived } : []
        catalogLoaded = true
        var loads: [(AppID, Date)] = []
        for app in added {
            // Counted from the app's creation on the other Mac, but never more than `remoteInventoryAllowance`
            // from now (its clock may differ from this Mac's).
            let allowed = app.createdAt.addingTimeInterval(remoteInventoryAllowance)
            let ready = min(max(allowed, now), now.addingTimeInterval(remoteInventoryAllowance))
            await pipeline.awaitInventory(for: app.id, loadingAfter: ready, now: now)
            loads.append((app.id, ready))
        }
        if apps != model.catalog.apps { model.catalog.apps = apps }
        await pushApps()
        for (id, ready) in loads { scheduleInventoryLoad(for: id, at: ready, now: now) }
        for id in removed {
            model.catalog.paused.remove(id)
            model.catalog.stats[id] = nil
            model.catalog.installs[id] = nil
            model.alerts.items.removeAll { $0.appID == id }
            await pipeline.purgeApp(id)
            if model.nav.page == .app(id) { model.nav.open(.requests) }
        }
    }

    /// Upserts this Mac's row (and the remote Surge's row) and loads every device.
    private func registerDevices() async {
        let existing = (try? await database.devices()) ?? []
        let id = thisDeviceID
        let current = existing.first { $0.id == id }
        let product = CaptureDeviceInfo.productName()
        let name = current?.name ?? CaptureDeviceInfo.computerName()
        let device = Device(
            id: id, name: name, model: CaptureDeviceInfo.modelDescription(product: product) ?? current?.model,
            shortName: CaptureDeviceInfo.shortName(name: name, product: product),
            hue: current?.hue ?? CaptureDeviceInfo.hue(for: id), isRemoteSurge: false,
            rowCount: current?.rowCount ?? 0, lastWriteAt: current?.lastWriteAt, createdAt: current?.createdAt ?? .now
        )
        do { try await database.upsertDevice(device) } catch {
            Self.log.error("Registering this Mac failed: \(error.localizedDescription, privacy: .public)")
        }
        if let remote = remoteDevice(existing: existing) { try? await database.upsertDevice(remote) }
        await refreshDevices()
    }

    private func remoteDevice(existing: [Device]) -> Device? {
        let remote = model.preferences.surgeRemote.trimmingCharacters(in: .whitespaces)
        guard !remote.isEmpty else { return nil }
        let id = recordingDeviceID
        let current = existing.first { $0.id == id }
        let tag = model.preferences.surgeRemoteTag.trimmingCharacters(in: .whitespaces)
        let name = tag.isEmpty ? remote : tag
        return Device(
            id: id, name: name, model: "\(remote) · remote Surge gateway", shortName: Device.shortName(for: name),
            hue: current?.hue ?? CaptureDeviceInfo.hue(for: id), isRemoteSurge: true,
            rowCount: current?.rowCount ?? 0, lastWriteAt: current?.lastWriteAt, createdAt: current?.createdAt ?? .now
        )
    }

    // MARK: Surge stream

    /// (Re)starts the subscription.
    func startStream() {
        streamTask?.cancel()
        streamConnectedAt = nil
        streamTask = Task { [weak self] in await self?.runStream() }
    }

    /// Cancels the subscription and waits until it stopped delivering events.
    func stopStream() async {
        let task = streamTask
        streamTask = nil
        streamConnectedAt = nil
        task?.cancel()
        await task?.value
    }

    private func runStream() async {
        var attempt = 0
        while !Task.isCancelled {
            model.live.surge = .connecting
            do {
                let status = try await surge.status()
                if Task.isCancelled { return }
                let startTime = status.startTime ?? 0
                if let previous = surgeStartTime, abs(previous - startTime) > 0.001 {
                    egress?.note(.surgeRestarted)
                    // A restarted engine is compared from scratch, so the restart is not also logged as a policy switch.
                    lastEnvironment = nil
                }
                surgeStartTime = startTime
                let epoch = await pipeline.beginSession(Self.sessionKey(startTime))
                // A replaced run must not touch the state of the run that replaced it.
                if Task.isCancelled { return }
                let stream = surge.events()
                model.live.surge = .connected(detail: tr("watching requests", "Capture"))
                streamConnectedAt = .now
                attempt = 0
                let backfill = Task { [surge, pipeline] in
                    let fetchedAt = Date.now
                    async let recent = try? surge.recentRequests()
                    async let active = try? surge.activeRequests()
                    let (recentRequests, activeRequests) = await (recent, active)
                    guard !Task.isCancelled else { return }
                    await pipeline.ingestBackfill((recentRequests ?? []) + (activeRequests ?? []), epoch: epoch)
                    // Requests that ended while the stream was away get no completion event.
                    if let activeRequests {
                        let ids = Set(activeRequests.map(\.id))
                        await pipeline.reconcileActive(ids, fetchedAt: fetchedAt, epoch: epoch)
                        await pipeline.closeVanished(ids, fetchedAt: fetchedAt, epoch: epoch)
                    }
                }
                defer { backfill.cancel() }
                try await pipeline.consume(stream)
                if Task.isCancelled { return }
                streamConnectedAt = nil
                model.live.surge = .failed(message: tr("Surge stopped streaming", "Capture"))
            } catch {
                if Task.isCancelled { return }
                streamConnectedAt = nil
                model.live.surge = .failed(message: Self.message(for: error))
            }
            guard model.preferences.surgeReconnect else { return }
            attempt += 1
            try? await Task.sleep(for: .seconds(Self.backoff(attempt)))
        }
    }

    /// Re-reads Surge's start time: a restarted engine (that kept the watch alive) restarts the stream so the
    /// new session begins before recycled request IDs are recorded; the same session releases held events.
    func checkSurgeSession() async {
        guard streamTask != nil, streamConnectedAt != nil, let current = surgeStartTime else { return }
        let surge = self.surge
        guard let status = try? await CaptureTimeout.unstructured(.seconds(10), { try await surge.status() }),
              let startTime = status.startTime, streamTask != nil else { return }
        if abs(startTime - current) > 0.001 {
            Self.log.info("Surge's engine restarted; reconnecting the stream")
            startStream()
        } else {
            await pipeline.confirmSession(Self.sessionKey(startTime))
        }
    }

    /// Surge sends a speed event every second while subscribed: silence means the stream is stale.
    func checkStreamLiveness(now: Date = .now) async {
        guard streamTask != nil, let connectedAt = streamConnectedAt, model.live.surge.isHealthy else { return }
        let last = max(await pipeline.lastStreamEventAt ?? connectedAt, connectedAt)
        guard now.timeIntervalSince(last) > streamSilenceLimit, streamConnectedAt == connectedAt else { return }
        Self.log.error("No events from Surge for \(Int(now.timeIntervalSince(last))) s; restarting the stream")
        startStream()
    }

    /// Backstop for missed `environment` events: a changed outbound mode, global policy or group selection
    /// schedules an egress check.
    func pollEnvironment() async {
        guard model.live.surge.isHealthy else { return }
        let surge = self.surge
        guard let environment = try? await CaptureTimeout.unstructured(.seconds(10), { try await surge.environment() }) else { return }
        defer { lastEnvironment = environment }
        if let previous = lastEnvironment, previous != environment {
            egress?.note(.policyChanged)
        }
    }

    // MARK: Observation

    private func startObservers() {
        // macOS 27 continuous observation: re-run whenever a property read inside the closure changes.
        scopeObservation = withContinuousObservation(options: [.didSet]) { [weak self] _ in
            guard let self else { return }
            let scope = self.model.devices.scope
            guard scope != self.observedScope else { return }
            self.observedScope = scope
            Task { await self.reloadScoped() }
        }
        preferencesObservation = withContinuousObservation(options: [.didSet]) { [weak self] _ in
            guard let self else { return }
            let values = PreferenceValues(self.model.preferences)
            guard let old = self.observedPreferences, old != values else { return }
            self.observedPreferences = values
            self.preferencesChanged(from: old, to: values)
        }

        let center = NSWorkspace.shared.notificationCenter
        let workspace = NSWorkspace.shared
        workspaceTokens = [
            center.addObserver(of: workspace, for: .willSleep) { [weak self] _ in
                guard let self else { return }
                Task { await self.pipeline.flushAll() }
            },
            center.addObserver(of: workspace, for: .didWake) { [weak self] _ in
                guard let self else { return }
                self.startStream()
                self.egress?.note(.wake)
            },
            center.addObserver(of: workspace, for: .didLaunchApplication) { [weak self] _ in
                self?.debounce("installs", .seconds(2)) { await $0.updateInstalls(force: false) }
            },
            center.addObserver(of: workspace, for: .didTerminateApplication) { [weak self] _ in
                self?.debounce("installs", .seconds(2)) { await $0.updateInstalls(force: false) }
            },
        ]
    }

    private func preferencesChanged(from old: PreferenceValues, to new: PreferenceValues) {
        if old.cliPath != new.cliPath || old.remote != new.remote {
            debounce("surge-settings", .milliseconds(1500)) { $0.scheduleSurgeSettings(restartStream: false) }
        } else if old.remoteTag != new.remoteTag {
            debounce("remote-tag", .milliseconds(1500)) { await $0.registerDevices() }
        }
        if old.databaseURL != new.databaseURL {
            debounce("database-url", .milliseconds(1500)) { $0.applyDatabaseSettings(force: false) }
        }
        if old.batchRows != new.batchRows || old.batchInterval != new.batchInterval {
            let rows = new.batchRows, interval = new.batchInterval
            Task { await pipeline.setBatching(rows: rows, interval: interval) }
        }
        if old.spoolLimit != new.spoolLimit {
            let limit = new.spoolLimit
            Task { await pipeline.setSpoolLimit(limit) }
        }
        if !old.systemNotifications, new.systemNotifications {
            Task { await notifier.requestAuthorizationIfNeeded() }
        }
    }

    /// Applies Surge settings after any earlier application finished (they must not interleave).
    func scheduleSurgeSettings(restartStream: Bool) {
        let previous = surgeSettingsTask
        surgeSettingsTask = Task { [weak self] in
            await previous?.value
            await self?.applySurgeSettings(restartStream: restartStream)
        }
    }

    /// A new surge-cli path, remote controller or remote password rebuilds the client; a new recording
    /// device (local ↔ remote) switches the rows' device. The old stream is stopped and its requests written
    /// first, so nothing it still delivers lands under the new device. Without changes, `restartStream`
    /// only reconnects the stream.
    private func applySurgeSettings(restartStream: Bool) async {
        let endpoint = model.preferences.surgeEndpoint
        let device = recordingDeviceID
        let clientChanged = makeSurgeClient != nil && endpoint != surge.endpoint
        let deviceChanged = device != appliedRecordingDevice
        guard clientChanged || deviceChanged || restartStream else { return }
        if clientChanged || deviceChanged {
            await stopStream()
            if clientChanged, let make = makeSurgeClient {
                let client = make(endpoint)
                surge = client
                model.surge = client
                lastEnvironment = nil
            }
            appliedRecordingDevice = device
            await registerDevices()
            await pipeline.setServices(surge: surge, database: database)
            await pipeline.update(settings: Self.settings(model.preferences, surge: surge))
            surgeStartTime = nil
        }
        startStream()
    }

    // MARK: Jobs

    private func startJobs() {
        every("ui", .milliseconds(250)) { await $0.drainPipeline() }
        every("watchdog", .seconds(5), delay: .seconds(5)) { await $0.checkStreamLiveness() }
        every("session", .seconds(30), delay: .seconds(30)) { await $0.checkSurgeSession() }
        every("environment", .seconds(60), delay: .seconds(10)) { await $0.pollEnvironment() }
        every("other-macs-rows", .seconds(2), delay: .seconds(2)) { await $0.pollOtherMacRows() }
        every("other-macs-alerts", .seconds(10), delay: .seconds(10)) { await $0.pollOtherMacAlerts() }
        every("ping", .seconds(15), delay: .seconds(15)) { await $0.ping() }
        every("stats", .seconds(15), delay: .seconds(15)) { await $0.refreshStats() }
        every("devices", .seconds(30), delay: .seconds(30)) { engine in
            await engine.refreshDevices()
            await engine.refreshToday()
        }
        every("dns", .seconds(30), delay: .seconds(5)) { await $0.pipeline.refreshDNSCache() }
        every("shared", .seconds(60), delay: .seconds(60)) { await $0.refreshSharedState() }
        every("inventory", .seconds(300), delay: .seconds(300)) { await $0.mergeInventory() }
        every("total", .seconds(60), delay: .seconds(60)) { await $0.refreshTotal() }
        every("installs", .seconds(300), delay: .seconds(300)) { await $0.updateInstalls(force: false) }
        every("retention", .seconds(3600), delay: .seconds(120)) { await $0.applyRetention() }
    }

    private func every(_ name: String, _ interval: Duration, delay: Duration = .zero, _ body: @escaping @MainActor (CaptureEngine) async -> Void) {
        jobs[name]?.cancel()
        jobs[name] = Task { [weak self] in
            if delay > .zero { try? await Task.sleep(for: delay) }
            while !Task.isCancelled {
                guard let self else { return }
                await body(self)
                try? await Task.sleep(for: interval)
            }
        }
    }

    private func debounce(_ name: String, _ delay: Duration, _ body: @escaping @MainActor (CaptureEngine) async -> Void) {
        jobs[name]?.cancel()
        jobs[name] = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self else { return }
            await body(self)
        }
    }

    // MARK: Applying pipeline changes

    private func drainPipeline() async {
        apply(await pipeline.drainUpdate())
    }

    /// Applies one coalesced update to the observable state.
    func apply(_ update: CaptureUIUpdate, now: Date = .now) {
        let live = model.live
        if !update.records.isEmpty {
            // Only rows on screen or brand new ones: old rows updated off-screen must not jump back to the top.
            let visible = Set(live.rows.map(\.key))
            live.upsert(update.records.filter { update.fresh.contains($0.key) || visible.contains($0.key) })
        }

        rateMeter.record(update.newRequests, now: now)
        let rate = (rateMeter.rate * 10).rounded() / 10
        if live.rate != rate { live.rate = rate }
        if live.rateHistory != rateMeter.history { live.rateHistory = rateMeter.history }

        let day = Calendar.current.startOfDay(for: now)
        if day != todayStart {
            todayStart = day
            live.todayCount = 0
        }
        if update.newRequests > 0 { live.todayCount += Int64(update.newRequests) }
        if update.rowsWritten > 0 {
            writtenSinceEstimate += Int64(update.rowsWritten)
            live.writtenThisSession += Int64(update.rowsWritten)
            live.totalRows = totalBase + writtenSinceEstimate
        }
        var wrote = false
        if let written = update.lastWriteAt, live.lastWriteAt != written {
            live.lastWriteAt = written
            wrote = true
            reconnectAttempt = 0
        }
        if wrote || update.rowsWritten > 0 { touchRecordingDevice(lastWriteAt: update.lastWriteAt, inserted: Int64(update.rowsWritten)) }
        if live.bufferedRows != update.bufferedRows { live.bufferedRows = update.bufferedRows }
        if let speed = update.speed {
            live.downloadSpeed = speed.in
            live.uploadSpeed = speed.out
        }

        if !update.alerts.isEmpty { receive(update.alerts, fromOtherMac: false) }
        if !update.inventoryChanged.isEmpty {
            debounce("stats-after-inventory", .seconds(2)) { await $0.refreshStats() }
        }
        if update.lostInventoryRace {
            debounce("inventory-merge", .seconds(5)) { await $0.mergeInventory() }
        }
        for signal in update.signals {
            switch signal {
            case .environmentChanged:
                egress?.note(.policyChanged)
                debounce("environment-snapshot", .seconds(1)) { engine in
                    let surge = engine.surge
                    if let environment = try? await surge.environment() { engine.lastEnvironment = environment }
                }
            case .reload:
                egress?.note(.profileReloaded)
                scheduleSessionCheck()
            case .shutdown:
                live.surge = .failed(message: tr("Surge is shutting down", "Capture"))
            case .sessionCheck:
                scheduleSessionCheck()
            }
        }
        if let failure = update.databaseFailure {
            live.database = .failed(message: update.databaseError.map(Self.message(for:)) ?? failure)
            lastWriteFailureAt = now
            scheduleDatabaseReconnect()
        }
    }

    private func scheduleSessionCheck() {
        debounce("session-check", .milliseconds(300)) { await $0.checkSurgeSession() }
    }

    /// Keeps the recording device's row ("Writing now", row count) current between device refreshes.
    private func touchRecordingDevice(lastWriteAt: Date?, inserted: Int64) {
        let id = recordingDeviceID
        guard let index = model.devices.devices.firstIndex(where: { $0.id == id }) else { return }
        var device = model.devices.devices[index]
        if let lastWriteAt, device.lastWriteAt.map({ $0 < lastWriteAt }) ?? true { device.lastWriteAt = lastWriteAt }
        device.rowCount += inserted
        if device != model.devices.devices[index] { model.devices.devices[index] = device }
    }

    /// New alerts: into the Notifications list (when the scope shows their Mac) and as system notifications.
    /// Alerts from other Macs are skipped when their host is muted or their app is archived (or gone) here.
    private func receive(_ alerts: [AlertItem], fromOtherMac: Bool) {
        let preferences = model.preferences
        for alert in alerts.sorted(by: { $0.id < $1.id }) {
            if fromOtherMac {
                guard let app = model.catalog.app(alert.appID), !app.isArchived else { continue }
                let muted = model.alerts.isMuted(alert.value) || (alert.host.map { model.alerts.isMuted($0) } ?? false)
                guard !muted else { continue }
            }
            if model.devices.scope.includes(alert.deviceID), !model.alerts.items.contains(where: { $0.id == alert.id }) {
                model.alerts.items.insert(alert, at: 0)
                if alert.isUnread { model.alerts.unreadCount += 1 }
            }
            guard preferences.systemNotifications, !fromOtherMac || preferences.notifyOtherMacs else { continue }
            guard alert.kind == .domain ? preferences.notifyNewDomain : preferences.notifyNewIP else { continue }
            guard !fromOtherMac || !model.catalog.paused.contains(alert.appID) else { continue }
            guard notifiedAlerts.insert(alert.id).inserted else { continue }
            if notifiedAlerts.count > 5_000 { notifiedAlerts = [alert.id] }
            let appName = model.catalog.app(alert.appID)?.name ?? tr("Unknown app", "Capture")
            let deviceName = fromOtherMac ? model.devices.device(alert.deviceID)?.name : nil
            notifier.post(alert, appName: appName, deviceName: deviceName, groupBursts: preferences.groupBursts,
                          explanation: explanation(for: alert, appName: appName))
        }
        if model.alerts.items.count > 500 { model.alerts.items.removeLast(model.alerts.items.count - 500) }
    }

    /// With Settings › Notifications › Explain hosts on: a line from the on-device model about the alert's host,
    /// from the cache when possible, never waiting longer than `explanationTimeout`.
    func explanation(for alert: AlertItem, appName: String) -> (@MainActor () async -> String?)? {
        guard model.preferences.notifyExplainHosts else { return nil }
        let host: String
        switch alert.kind {
        case .domain: host = alert.value
        case .ip:
            guard let name = alert.host, !name.isEmpty else { return nil }
            host = name
        }
        let context = HostContext(host: host, appName: appName, processName: alert.processName, port: nil,
                                  ips: alert.ip.map { [$0] } ?? [], geo: alert.geo, policy: nil, firstSeen: alert.createdAt, requestCount: nil)
        let model = self.model
        let timeout = explanationTimeout
        return {
            let insight = await CaptureTimeout.value(within: timeout) { @MainActor () async -> HostInsight? in
                if let cached = await model.insights.cachedInsight(for: host) { return cached }
                guard model.insights.isAvailable else { return nil }
                return try? await model.insights.insight(for: context)
            }
            return insight.flatMap(CaptureAlertText.insightLine)
        }
    }

    /// "View" on a notification: the app's Domains & IPs tab, alerts marked read.
    private func openAlerts(appID: AppID, ids: [Int64]) {
        model.nav.open(.app(appID), tab: .inventory)
        TidemarkIntents.showMainWindow()
        guard !ids.isEmpty else { return }
        Task { await markAlertsRead(ids) }
    }

    // MARK: Periodic refreshes

    private var databaseReady: Bool { model.live.database.isHealthy }

    private func ping() async {
        guard databaseReady else { return }
        do {
            let result = try await database.ping()
            model.live.lastRoundTrip = result.roundTrip
            // A healthy connection with no recent write failure starts the next outage's backoff afresh.
            if lastWriteFailureAt.map({ Date.now.timeIntervalSince($0) > 120 }) ?? true { reconnectAttempt = 0 }
            if model.live.serverVersion != result.serverVersion { model.live.serverVersion = result.serverVersion }
        } catch {
            model.live.database = .failed(message: Self.message(for: error))
            await pipeline.setDatabaseOnline(false)
            scheduleDatabaseReconnect()
        }
    }

    /// Alerts, unread count and app stats for the sidebar scope.
    func reloadScoped() async {
        guard databaseReady else { return }
        let scope = model.devices.scope
        if let items = try? await database.alerts(filter: .all, appID: nil, scope: scope, limit: 200) {
            model.alerts.items = items
        }
        if let unread = try? await database.unreadAlertCount(scope: scope) { model.alerts.unreadCount = unread }
        await refreshStats()
    }

    func refreshStats() async {
        guard databaseReady else { return }
        let scope = model.devices.scope
        var stats: [AppID: AppStats] = [:]
        for app in model.catalog.apps {
            if let value = try? await database.appStats(app.id, scope: scope) { stats[app.id] = value }
        }
        if stats != model.catalog.stats { model.catalog.stats = stats }
    }

    /// Apps and mutes changed on other Macs (added, archived, deleted, muted). A list read while this Mac
    /// changed its apps is dropped (the next refresh reads it again).
    func refreshSharedState() async {
        guard databaseReady else { return }
        let generation = catalogGeneration
        if let apps = try? await database.apps(), generation == catalogGeneration, apps != model.catalog.apps { await applyCatalog(apps) }
        if let mutes = try? await database.mutes(), Set(mutes) != Set(model.alerts.mutes) {
            model.alerts.mutes = mutes
            await pipeline.setMutes(mutes)
        }
    }

    /// Loads the inventory of an app another Mac added once its wait is over (see `applyCatalog`).
    private func scheduleInventoryLoad(for appID: AppID, at date: Date, now: Date) {
        let delay = max(0, date.timeIntervalSince(now))
        debounce("added-app-inventory-\(appID.uuidString)", .seconds(delay)) { engine in
            do {
                try await engine.pipeline.loadKnownHosts()
            } catch {
                Self.log.error("Loading the inventory of apps added on another Mac failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Inventory entries other Macs recorded since the last load.
    private func mergeInventory() async {
        guard databaseReady else { return }
        do {
            try await pipeline.mergeKnownHosts()
        } catch {
            Self.log.error("Refreshing the inventory failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func refreshDevices() async {
        guard databaseReady, var devices = try? await database.devices() else { return }
        // This Mac's own writes are newer than the table's last refresh.
        let id = recordingDeviceID
        if let index = devices.firstIndex(where: { $0.id == id }), let written = model.live.lastWriteAt,
           devices[index].lastWriteAt.map({ $0 < written }) ?? true {
            devices[index].lastWriteAt = written
        }
        if devices != model.devices.devices { model.devices.devices = devices }
    }

    private func refreshToday() async {
        guard databaseReady else { return }
        let start = Calendar.current.startOfDay(for: .now)
        guard let count = try? await database.countRequests(since: start, scope: .device(recordingDeviceID)) else { return }
        // Rows still buffered are not in the count yet; never step backwards within a day.
        model.live.todayCount = start == todayStart ? max(count, model.live.todayCount) : count
        todayStart = start
    }

    private func refreshTotal() async {
        guard databaseReady, let estimate = try? await database.estimatedRequestCount() else { return }
        totalBase = estimate
        writtenSinceEstimate = 0
        model.live.totalRows = estimate
    }

    /// Rows other Macs wrote, merged into the live table while the scope includes them. Polls with a small
    /// overlap: a row committed late can carry an `updated_at` just before the previous cursor.
    private func pollOtherMacRows() async {
        guard databaseReady, model.devices.devices.count > 1 else { return }
        let me = recordingDeviceID
        let scope = model.devices.scope
        let includesOthers: Bool = switch scope {
        case .all: true
        case .device(let id): id != me
        }
        guard includesOthers else {
            liveCursor = .now
            return
        }
        guard let rows = try? await database.requestsWritten(after: liveCursor.addingTimeInterval(-3), excluding: me, limit: 300),
              !rows.isEmpty else { return }
        liveCursor = max(liveCursor, rows.compactMap(\.writtenAt).max() ?? liveCursor)
        model.live.upsert(rows.filter { scope.includes($0.deviceID) })
    }

    /// Alerts other Macs wrote since the last poll. Apps this Mac doesn't know yet are loaded first.
    func pollOtherMacAlerts() async {
        guard databaseReady, let alerts = try? await database.alerts(after: lastAlertID, excluding: recordingDeviceID), !alerts.isEmpty else { return }
        lastAlertID = max(lastAlertID, alerts.map(\.id).max() ?? lastAlertID)
        if alerts.contains(where: { model.catalog.app($0.appID) == nil }) { await refreshSharedState() }
        receive(alerts, fromOtherMac: true)
    }

    /// Reports whether each app's bundle exists on this Mac (`app_installs`).
    func updateInstalls(force: Bool) async {
        guard databaseReady else { return }
        let me = thisDeviceID
        for app in model.catalog.apps {
            let exists = FileManager.default.fileExists(atPath: app.path)
            guard force || model.catalog.installs[app.id]?[me] != exists else { continue }
            do {
                try await database.setInstalled(appID: app.id, deviceID: me, installed: exists)
                model.catalog.installs[app.id, default: [:]][me] = exists
            } catch {
                Self.log.error("Updating install state failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func applyRetention() async {
        let days = model.preferences.retentionDays
        guard databaseReady, days > 0 else { return }
        let cutoff = Date.now.addingTimeInterval(-Double(days) * 86_400)
        if let deleted = try? await database.deleteRequests(olderThan: cutoff, deviceID: recordingDeviceID), deleted > 0 {
            Self.log.info("Retention removed \(deleted) requests")
            await refreshTotal()
        }
    }

    // MARK: Helpers

    /// Sends the app list and session pauses to the pipeline.
    func pushApps() async {
        await pipeline.setApps(model.catalog.apps, paused: model.catalog.paused)
    }

    static func backoff(_ attempt: Int) -> Double {
        min(60, pow(2, Double(max(0, attempt - 1))))
    }

    /// A failure for display (Settings › Database and Surge, the sidebar's status), in the UI language. Details
    /// that come from the server or surge-cli stay as they were reported.
    static func message(for error: any Error) -> String {
        switch error {
        case is CaptureTimeoutError: tr("PostgreSQL did not answer in time", "Capture")
        case let rejection as CaptureServerRejection: trf("PostgreSQL refused every write: %@", "Capture", rejection.message)
        case let failure as CaptureDisplayError: message(for: failure.underlying)
        case let error as DatabaseError:
            switch error {
            case .notConfigured: tr("No PostgreSQL connection is configured.", "Capture")
            case .invalidURL(let url): trf("Invalid PostgreSQL URL: %@", "Capture", url)
            case .unreachable(let reason): trf("PostgreSQL is unreachable: %@", "Capture", reason)
            case .query(let reason): trf("PostgreSQL error: %@", "Capture", reason)
            }
        case let error as SurgeError:
            switch error {
            case .cliNotFound(let path): trf("surge-cli was not found at %@.", "Capture", path)
            case .commandFailed(let command, let reason): trf("surge-cli %1$@ failed: %2$@", "Capture", command, reason)
            case .decoding(let command, let reason): trf("Could not read the output of surge-cli %1$@: %2$@", "Capture", command, reason)
            case .timedOut(let command): trf("surge-cli %@ timed out.", "Capture", command)
            }
        default: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

/// An error whose description is `CaptureEngine.message(for:)` of the error it wraps, written in the UI
/// language when it was created (for views that show `localizedDescription`).
struct CaptureDisplayError: Error, LocalizedError {
    var underlying: any Error
    var message: String

    @MainActor init(_ underlying: any Error) {
        self.underlying = underlying
        message = CaptureEngine.message(for: underlying)
    }

    var errorDescription: String? { message }
}
