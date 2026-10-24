import AppKit
import Foundation
import os

extension CaptureEngine: CaptureActions {
    // MARK: Recording

    func setRecording(_ on: Bool) {
        model.live.recording = on
        Task { await pipeline.setRecording(on) }
    }

    func reconnect() {
        startStream()
        scheduleDatabaseReconnectNow()
    }

    private func scheduleDatabaseReconnectNow() {
        Task {
            if !(await connectDatabase()) { scheduleDatabaseReconnect() }
        }
    }

    // MARK: Apps

    func monitorApp(path: String, includeChildren: Bool, alertOnDomain: Bool, alertOnIP: Bool, backfill: Bool) async throws -> MonitoredApp {
        let bundlePath = Self.normalizedBundlePath(path)
        if var existing = model.catalog.apps.first(where: { $0.path == bundlePath }) {
            if existing.isArchived {
                existing.archivedAt = nil
                try await updateApp(existing)
            }
            return existing
        }
        let identity = Self.bundleIdentity(at: bundlePath)
        let app = MonitoredApp(
            id: UUID(), name: identity.name, path: bundlePath, bundleID: identity.bundleID,
            tileLetter: identity.letter, tileHue: CaptureDeviceInfo.tileHue(for: identity.bundleID ?? bundlePath),
            includeChildren: includeChildren, alertRule: alertOnDomain ? .anyHost : .off, alertNewIP: alertOnIP,
            archivedAt: nil, createdAt: .now
        )
        try await database.insertApp(app)
        model.catalog.apps.append(app)
        await pushApps()

        let installed = FileManager.default.fileExists(atPath: bundlePath)
        if (try? await database.setInstalled(appID: app.id, deviceID: thisDeviceID, installed: installed)) != nil {
            model.catalog.installs[app.id, default: [:]][thisDeviceID] = installed
        }
        if backfill {
            do {
                let rows = try await database.backfill(appID: app.id, bundlePath: bundlePath)
                Self.log.info("Backfilled \(rows) requests for \(app.name, privacy: .public)")
            } catch {
                Self.log.error("Backfill failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        try? await pipeline.loadKnownHosts()
        await refreshCatalog()
        return app
    }

    func updateApp(_ app: MonitoredApp) async throws {
        try await database.updateApp(app)
        if let index = model.catalog.apps.firstIndex(where: { $0.id == app.id }) {
            model.catalog.apps[index] = app
        } else {
            model.catalog.apps.append(app)
        }
        await pushApps()
        await refreshStats()
    }

    func archiveApp(_ id: AppID) async throws {
        guard var app = model.catalog.app(id) else { return }
        app.archivedAt = .now
        model.catalog.paused.remove(id)
        try await updateApp(app)
    }

    func restoreApp(_ id: AppID) async throws {
        guard var app = model.catalog.app(id) else { return }
        app.archivedAt = nil
        try await updateApp(app)
    }

    func deleteApp(_ id: AppID) async throws {
        try await database.deleteApp(id)
        model.catalog.apps.removeAll { $0.id == id }
        model.catalog.stats[id] = nil
        model.catalog.installs[id] = nil
        model.catalog.paused.remove(id)
        model.alerts.items.removeAll { $0.appID == id }
        if let unread = try? await database.unreadAlertCount(scope: model.devices.scope) { model.alerts.unreadCount = unread }
        await pipeline.forgetApp(id)
        await pushApps()
        if model.nav.page == .app(id) { model.nav.open(.requests) }
    }

    func setMonitoring(_ id: AppID, enabled: Bool) {
        if enabled { model.catalog.paused.remove(id) } else { model.catalog.paused.insert(id) }
        Task { await pushApps() }
    }

    func monitorCandidates() async -> [AppCandidate] {
        let monitored = Set(model.catalog.apps.map(\.path))
        let own = Self.normalizedBundlePath(Bundle.main.bundleURL.path(percentEncoded: false))
        var seen: Set<String> = []
        var found: [(name: String, path: String, bundleID: String?)] = []
        for running in NSWorkspace.shared.runningApplications where running.activationPolicy == .regular {
            guard let url = running.bundleURL else { continue }
            let path = Self.normalizedBundlePath(url.path(percentEncoded: false))
            guard path != own, !monitored.contains(path), seen.insert(path).inserted else { continue }
            let name = running.localizedName ?? url.deletingPathExtension().lastPathComponent
            found.append((name, path, running.bundleIdentifier))
        }
        let database = self.database
        let paths = found.map(\.path)
        let counts = await withTaskGroup(of: (String, Int64).self) { group in
            for path in paths {
                group.addTask { (path, (try? await database.countRequests(inBundle: path)) ?? 0) }
            }
            var result: [String: Int64] = [:]
            for await (path, count) in group { result[path] = count }
            return result
        }
        return found
            .map { AppCandidate(name: $0.name, path: $0.path, bundleID: $0.bundleID, pastRequests: counts[$0.path] ?? 0) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: Alerts

    func markAlertsRead(_ ids: [Int64]) async {
        guard !ids.isEmpty else { return }
        let wanted = Set(ids)
        let now = Date.now
        var changed = 0
        for index in model.alerts.items.indices where wanted.contains(model.alerts.items[index].id) && model.alerts.items[index].isUnread {
            model.alerts.items[index].readAt = now
            changed += 1
        }
        model.alerts.unreadCount = max(0, model.alerts.unreadCount - changed)
        do {
            try await database.markAlertsRead(ids)
        } catch {
            Self.log.error("Marking alerts read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func markAllAlertsRead(appID: AppID?) async {
        let now = Date.now
        for index in model.alerts.items.indices where model.alerts.items[index].isUnread && (appID == nil || model.alerts.items[index].appID == appID) {
            model.alerts.items[index].readAt = now
        }
        do {
            try await database.markAllAlertsRead(appID: appID, scope: model.devices.scope)
            model.alerts.unreadCount = try await database.unreadAlertCount(scope: model.devices.scope)
        } catch {
            if appID == nil { model.alerts.unreadCount = 0 }
            Self.log.error("Marking all alerts read failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func mute(_ pattern: String, dismissingAlert: Int64?) async {
        let pattern = pattern.trimmingCharacters(in: .whitespaces).lowercased()
        guard !pattern.isEmpty else { return }
        if !model.alerts.mutes.contains(pattern) { model.alerts.mutes.append(pattern) }
        await pipeline.setMutes(model.alerts.mutes)
        do {
            try await database.addMute(pattern)
        } catch {
            Self.log.error("Adding mute failed: \(error.localizedDescription, privacy: .public)")
        }
        guard let id = dismissingAlert else { return }
        if let index = model.alerts.items.firstIndex(where: { $0.id == id }) {
            if model.alerts.items[index].isUnread { model.alerts.unreadCount = max(0, model.alerts.unreadCount - 1) }
            model.alerts.items.remove(at: index)
        }
        try? await database.deleteAlert(id)
    }

    func unmute(_ pattern: String) async {
        model.alerts.mutes.removeAll { $0 == pattern }
        await pipeline.setMutes(model.alerts.mutes)
        do {
            try await database.removeMute(pattern)
        } catch {
            Self.log.error("Removing mute failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: Devices and database

    func renameThisMac(_ name: String) async {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let id = thisDeviceID
        let product = CaptureDeviceInfo.productName()
        if let index = model.devices.devices.firstIndex(where: { $0.id == id }) {
            model.devices.devices[index].name = name
            model.devices.devices[index].shortName = CaptureDeviceInfo.shortName(name: name, product: product)
        }
        do {
            try await database.renameDevice(id, name: name)
            if let device = model.devices.thisDevice { try await database.upsertDevice(device) }
        } catch {
            Self.log.error("Renaming this Mac failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func testDatabaseConnection() async -> Result<String, Error> {
        do {
            if !model.live.database.isHealthy { try await database.connect() }
            let result = try await database.ping()
            let ms = Self.milliseconds(result.roundTrip)
            return .success(trf("Connected · PostgreSQL %@ · %lld ms", "Capture", result.serverVersion, Int(ms.rounded())))
        } catch {
            return .failure(error)
        }
    }

    // MARK: Helpers

    /// Apps, installs and stats after a mutation.
    func refreshCatalog() async {
        if let apps = try? await database.apps() {
            model.catalog.apps = apps
            await pushApps()
        }
        if let installs = try? await database.installs() { model.catalog.installs = installs }
        await refreshStats()
    }

    static func milliseconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15
    }

    /// `/Applications/Cursor.app` (no trailing slash, standardized).
    static func normalizedBundlePath(_ path: String) -> String {
        var result = (path as NSString).standardizingPath
        while result.count > 1, result.hasSuffix("/") { result.removeLast() }
        return result
    }

    /// Display name (`CFBundleDisplayName`, else `CFBundleName`, else the file name), bundle ID and tile letter.
    static func bundleIdentity(at path: String) -> (name: String, bundleID: String?, letter: String) {
        let bundle = Bundle(path: path)
        let info = bundle?.localizedInfoDictionary ?? [:]
        let base = bundle?.infoDictionary ?? [:]
        let fileName = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        let candidates = [info["CFBundleDisplayName"], base["CFBundleDisplayName"], info["CFBundleName"], base["CFBundleName"]]
        let name = candidates.lazy.compactMap { $0 as? String }.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? fileName
        let letter = name.first(where: \.isLetter).map { String($0).uppercased() } ?? String(name.prefix(1)).uppercased()
        return (name, bundle?.bundleIdentifier, letter.isEmpty ? "A" : letter)
    }
}
