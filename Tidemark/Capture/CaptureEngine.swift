import AppKit
import Foundation
import Observation
import os

/// Records every request Surge handles into PostgreSQL, rolls requests up to monitored apps and alerts on
/// first contact. Implements `CaptureActions` for the UI.
///
/// The engine owns the connection lifecycles (Surge stream with reconnect and backfill, PostgreSQL with
/// reconnect and spool replay), the periodic jobs (stats, devices, retention, polling other Macs) and
/// the main-actor state. Request processing happens off the main actor in `CapturePipeline`; the engine
/// drains its coalesced changes four times a second.
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
    /// Builds a client when the surge-cli path or the remote controller changes. When nil the engine keeps
    /// its client and only restarts the stream.
    var makeSurgeClient: ((SurgeEndpoint) -> any SurgeClient)?
    /// Builds a database when the connection URL changes. When nil the engine reconnects its instance.
    var makeDatabase: ((Preferences) -> any TidemarkDatabase)?

    static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "capture")

    private var started = false
    private var jobs: [String: Task<Void, Never>] = [:]
    private var streamTask: Task<Void, Never>?
    private var databaseTask: Task<Void, Never>?
    private var pipelineTask: Task<Void, Never>?
    private var scopeObservation: ObservationTracking.Token?
    private var preferencesObservation: ObservationTracking.Token?
    private var workspaceTokens: [NotificationCenter.ObservationToken] = []

    private var rateMeter = CaptureRateMeter()
    private var surgeStartTime: Double?
    private var observedScope: DeviceScope = .all
    private var observedPreferences: PreferenceValues?
    private var todayStart = Calendar.current.startOfDay(for: .now)
    private var totalBase: Int64 = 0
    private var writtenSinceEstimate: Int64 = 0
    private var lastAlertID: Int64 = 0
    private var liveCursor = Date.now.addingTimeInterval(-60)

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
        spool: CaptureSpool? = nil
    ) {
        self.model = model
        self.surge = surge
        self.database = database
        self.processes = processes
        self.classifier = classifier
        self.probeRegistry = probeRegistry
        let preferences = model.preferences
        pipeline = CapturePipeline(
            settings: Self.settings(preferences, surge: surge),
            database: database,
            surge: surge,
            processes: processes,
            classifier: classifier,
            probes: probeRegistry,
            spool: spool ?? CaptureSpool(limit: preferences.spoolLimit)
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

    // MARK: Lifecycle

    /// Connects PostgreSQL (migrating it) and loads the shared state, then subscribes to Surge and starts
    /// the periodic jobs. Recording always starts on.
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
            self.startStream()
            if !connected { self.scheduleDatabaseReconnect() }
        }
    }

    /// Stops every job and writes what is buffered. The final flush is shielded from cancellation so a
    /// terminating app still gets its rows out (or onto the spool).
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
            await pipeline.flushAll()
        }
        pipelineTask?.cancel()
    }

    // MARK: PostgreSQL

    /// One connection attempt: connect, migrate, ping, register this Mac and load the shared state.
    @discardableResult
    func connectDatabase() async -> Bool {
        model.live.database = .connecting
        do {
            try await database.connect()
            try await database.migrate()
            let ping = try await database.ping()
            model.live.lastRoundTrip = ping.roundTrip
            model.live.serverVersion = ping.serverVersion
            model.live.database = .connected(detail: "PostgreSQL \(ping.serverVersion)")
        } catch {
            model.live.database = .failed(message: Self.message(for: error))
            await pipeline.setDatabaseOnline(false)
            return false
        }
        await loadSharedState()
        await pipeline.setDatabaseOnline(true)
        return true
    }

    /// Retries the connection with exponential backoff (1 s … 60 s) until it succeeds.
    func scheduleDatabaseReconnect() {
        databaseTask?.cancel()
        databaseTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                attempt += 1
                try? await Task.sleep(for: .seconds(Self.backoff(attempt)))
                guard !Task.isCancelled, let self else { return }
                if await self.connectDatabase() { return }
            }
        }
    }

    private func reconnectDatabase(replacing: Bool) {
        databaseTask?.cancel()
        databaseTask = Task { [weak self] in
            guard let self else { return }
            if replacing, let make = self.makeDatabase {
                let database = make(self.model.preferences)
                self.database = database
                self.model.database = database
                await self.pipeline.setServices(surge: self.surge, database: database)
            }
            await self.pipeline.setDatabaseOnline(false)
            if !(await self.connectDatabase()) { self.scheduleDatabaseReconnect() }
        }
    }

    /// Devices, apps, installs, mutes, inventory, alerts, probe sessions and counters.
    private func loadSharedState() async {
        await registerDevices()
        do {
            let apps = try await database.apps()
            model.catalog.apps = apps
            await pushApps()
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
        if let newest = try? await database.alerts(filter: .all, appID: nil, scope: .all, limit: 1).first {
            lastAlertID = max(lastAlertID, newest.id)
        }
        await reloadScoped()
        if let sessions = try? await database.probeSessions(limit: 100) {
            model.probe.sessions = sessions
            if model.probe.selectedID == nil { model.probe.selectedID = sessions.first?.id }
        }
        await refreshTotal()
        await refreshToday()
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
        streamTask = Task { [weak self] in await self?.runStream() }
    }

    private func runStream() async {
        var attempt = 0
        while !Task.isCancelled {
            model.live.surge = .connecting
            do {
                let status = try await surge.status()
                let startTime = status.startTime ?? 0
                if let previous = surgeStartTime, abs(previous - startTime) > 0.001 { egress?.note(.surgeRestarted) }
                surgeStartTime = startTime
                await pipeline.beginSession(Int64((startTime * 1000).rounded()))
                let stream = surge.events()
                model.live.surge = .connected(detail: tr("watching requests", "Capture"))
                model.live.surgeDetail = surge.endpoint.remote == nil
                    ? tr("Found · controller connected · streaming", "Capture")
                    : tr("Remote · controller connected · streaming", "Capture")
                attempt = 0
                let backfill = Task { [surge, pipeline] in
                    if let recent = try? await surge.recentRequests() { await pipeline.ingestBackfill(recent) }
                }
                defer { backfill.cancel() }
                try await pipeline.consume(stream)
                if Task.isCancelled { return }
                model.live.surge = .failed(message: tr("Surge stopped streaming", "Capture"))
            } catch {
                if Task.isCancelled { return }
                model.live.surge = .failed(message: Self.message(for: error))
                model.live.surgeDetail = Self.message(for: error)
            }
            guard model.preferences.surgeReconnect else { return }
            attempt += 1
            try? await Task.sleep(for: .seconds(Self.backoff(attempt)))
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
            debounce("surge-settings", .milliseconds(1500)) { await $0.applySurgeSettings() }
        } else if old.remoteTag != new.remoteTag {
            debounce("remote-tag", .milliseconds(1500)) { await $0.registerDevices() }
        }
        if old.databaseURL != new.databaseURL {
            debounce("database-url", .milliseconds(1500)) { $0.reconnectDatabase(replacing: true) }
        }
        if old.batchRows != new.batchRows || old.batchInterval != new.batchInterval {
            let settings = Self.settings(model.preferences, surge: surge)
            Task { await pipeline.update(settings: settings) }
        }
        if old.spoolLimit != new.spoolLimit {
            let limit = new.spoolLimit
            Task { await pipeline.setSpoolLimit(limit) }
        }
        if !old.systemNotifications, new.systemNotifications {
            Task { await notifier.requestAuthorizationIfNeeded() }
        }
    }

    /// A new surge-cli path or remote controller: rebuild the client, switch the device rows are written
    /// under, and restart the stream.
    private func applySurgeSettings() async {
        if let make = makeSurgeClient {
            let client = make(model.preferences.surgeEndpoint)
            surge = client
            model.surge = client
            await pipeline.setServices(surge: client, database: database)
        }
        await pipeline.update(settings: Self.settings(model.preferences, surge: surge))
        surgeStartTime = nil
        await registerDevices()
        startStream()
    }

    // MARK: Jobs

    private func startJobs() {
        every("ui", .milliseconds(250)) { await $0.drainPipeline() }
        every("other-macs-rows", .seconds(2), delay: .seconds(2)) { await $0.pollOtherMacRows() }
        every("other-macs-alerts", .seconds(10), delay: .seconds(10)) { await $0.pollOtherMacAlerts() }
        every("ping", .seconds(15), delay: .seconds(15)) { await $0.ping() }
        every("stats", .seconds(15), delay: .seconds(15)) { await $0.refreshStats() }
        every("devices", .seconds(30), delay: .seconds(30)) { engine in
            await engine.refreshDevices()
            await engine.refreshToday()
        }
        every("dns", .seconds(30), delay: .seconds(5)) { await $0.pipeline.refreshDNSCache() }
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
        if let written = update.lastWriteAt, live.lastWriteAt != written { live.lastWriteAt = written }
        if live.bufferedRows != update.bufferedRows { live.bufferedRows = update.bufferedRows }
        if let speed = update.speed {
            live.downloadSpeed = speed.in
            live.uploadSpeed = speed.out
        }

        if !update.alerts.isEmpty { receive(update.alerts, fromOtherMac: false) }
        if !update.inventoryChanged.isEmpty {
            debounce("stats-after-inventory", .seconds(2)) { await $0.refreshStats() }
        }
        for signal in update.signals {
            switch signal {
            case .environmentChanged: egress?.note(.policyChanged)
            case .reload: egress?.note(.profileReloaded)
            case .shutdown: live.surge = .failed(message: tr("Surge is shutting down", "Capture"))
            }
        }
        if let failure = update.databaseFailure {
            live.database = .failed(message: failure)
            scheduleDatabaseReconnect()
        }
    }

    /// New alerts: into the Notifications list (when the scope shows their Mac) and as system notifications.
    private func receive(_ alerts: [AlertItem], fromOtherMac: Bool) {
        let preferences = model.preferences
        for alert in alerts.sorted(by: { $0.id < $1.id }) {
            if model.devices.scope.includes(alert.deviceID), !model.alerts.items.contains(where: { $0.id == alert.id }) {
                model.alerts.items.insert(alert, at: 0)
                if alert.isUnread { model.alerts.unreadCount += 1 }
            }
            guard preferences.systemNotifications, !fromOtherMac || preferences.notifyOtherMacs else { continue }
            guard alert.kind == .domain ? preferences.notifyNewDomain : preferences.notifyNewIP else { continue }
            let appName = model.catalog.app(alert.appID)?.name ?? tr("Unknown app", "Capture")
            let deviceName = fromOtherMac ? model.devices.device(alert.deviceID)?.name : nil
            notifier.post(alert, appName: appName, deviceName: deviceName, groupBursts: preferences.groupBursts)
        }
        if model.alerts.items.count > 500 { model.alerts.items.removeLast(model.alerts.items.count - 500) }
    }

    /// "View" on a notification: the app's Domains & IPs tab, alerts marked read.
    private func openAlerts(appID: AppID, ids: [Int64]) {
        model.nav.open(.app(appID), tab: .inventory)
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

    private func refreshDevices() async {
        guard databaseReady, let devices = try? await database.devices() else { return }
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

    /// Rows other Macs wrote, merged into the live table while the scope includes them.
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
        guard let rows = try? await database.requestsWritten(after: liveCursor, excluding: me, limit: 300), !rows.isEmpty else { return }
        liveCursor = rows.compactMap(\.writtenAt).max() ?? liveCursor
        model.live.upsert(rows.filter { scope.includes($0.deviceID) })
    }

    /// Alerts other Macs wrote since the last poll.
    private func pollOtherMacAlerts() async {
        guard databaseReady, let alerts = try? await database.alerts(after: lastAlertID, excluding: recordingDeviceID), !alerts.isEmpty else { return }
        lastAlertID = max(lastAlertID, alerts.map(\.id).max() ?? lastAlertID)
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
        if let deleted = try? await database.deleteRequests(olderThan: cutoff), deleted > 0 {
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

    static func message(for error: any Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
