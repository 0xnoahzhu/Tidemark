import AppKit
import SwiftUI

/// Page of one monitored app: header, stats and the Requests / Domains & IPs / Process Tree tabs.
///
/// The app's tile, name and bundle path live in the window toolbar (title, subtitle and a leading tile);
/// the tab switch is the toolbar's trailing item. The page also presents the "Stop monitoring" and
/// "Delete" confirmations whenever `Navigation.confirmMonitoringToggle` / `confirmDeleteApp` name this app.
struct AppDetailView: View {
    @Environment(AppModel.self) private var model
    var appID: AppID

    /// Counters this page read from the database for its own scope, tagged with the app and scope they
    /// were read for. Used when the page's scope differs from the sidebar's (the app is not on the selected
    /// Mac) and until the capture engine publishes the app's counters in `CatalogState`.
    @State private var loadedStats: LoadedStats?
    @State private var actionError: (any Error)?

    var body: some View {
        if let app = model.catalog.app(appID) {
            page(app)
        } else {
            EmptyState(systemImage: "app.dashed",
                       title: tr("This app is no longer monitored", "AppDetail"),
                       message: tr("It was deleted, or another Mac removed it from the database.", "AppDetail"))
        }
    }

    // MARK: Page

    @ViewBuilder
    private func page(_ app: MonitoredApp) -> some View {
        @Bindable var nav = model.nav
        let absent = isAbsent(app)
        let statsKey = StatsKey(appID: app.id, scope: statsScope(absent: absent))
        let stats = Self.displayedStats(catalog: model.catalog.stats[app.id],
                                        loaded: loadedStats?.key == statsKey ? loadedStats?.stats : nil,
                                        pageScope: statsKey.scope, sidebarScope: model.devices.scope)

        VStack(spacing: 0) {
            if absent { absentBanner(app) }
            statsStrip(app, stats: stats, absent: absent)
            installsRow(app)
            switch nav.appTab {
            case .requests:
                AppDetailRequestsTab(app: app, storedCount: stats.requests, absent: absent)
            case .inventory:
                AppDetailInventoryTab(app: app, absent: absent)
            case .tree:
                AppDetailProcessTreeTab(app: app, absent: absent)
            }
        }
        .background(Theme.bg)
        .navigationTitle(app.name)
        .navigationSubtitle(app.path)
        .toolbar {
            ToolbarItem(placement: .navigation) {
                AppTile(app: app, size: 26, dimmed: app.isArchived)
                    .padding(.horizontal, 2)
            }
            .sharedBackgroundVisibility(.hidden)

            ToolbarItem(placement: .primaryAction) {
                Picker(tr("View", "AppDetail"), selection: $nav.appTab) {
                    Text(tr("All Requests", "AppDetail")).tag(AppTab.requests)
                    Text(tr("Domains & IPs", "AppDetail")).tag(AppTab.inventory)
                    Text(tr("Process Tree", "AppDetail")).tag(AppTab.tree)
                }
                .pickerStyle(.tabs)
                .labelsHidden()
                .fixedSize()
            }
        }
        .task(id: statsKey) {
            await refreshStats(statsKey)
        }
        .confirmationDialog(monitoringTitle(app), isPresented: monitoringDialog(app), titleVisibility: .visible) {
            let monitoring = model.catalog.isMonitoring(app.id)
            Button(monitoring ? tr("Stop Monitoring", "AppDetail") : tr("Start Monitoring", "AppDetail"),
                   role: monitoring ? .destructive : nil) {
                model.capture.setMonitoring(app.id, enabled: !monitoring)
            }
            Button(tr("Cancel", "AppDetail"), role: .cancel) {}
        } message: {
            Text(monitoringMessage(app))
        }
        .confirmationDialog(trf("Delete %@?", "AppDetail", app.name), isPresented: deleteDialog(app), titleVisibility: .visible) {
            Button(tr("Delete", "AppDetail"), role: .destructive) { delete(app) }
            Button(tr("Cancel", "AppDetail"), role: .cancel) {}
        } message: {
            Text(trf("This removes %1$@'s domain and IP lists, its alerts and its settings. Its %2$@ requests stay in the global request log, because every request is recorded anyway.",
                     "AppDetail", app.name, Fmt.count(stats.requests)))
        }
        .dialogIcon(dialogIconImage(app))
        .alert(error: $actionError) {
            Button(tr("OK", "AppDetail")) {}
        }
    }

    // MARK: Absent banner

    /// The app's bundle path does not exist on the Mac the page is scoped to.
    private func isAbsent(_ app: MonitoredApp) -> Bool {
        model.catalog.isInstalled(app.id, on: model.devices.contextDeviceID) == false
    }

    private func contextMacName() -> String {
        model.devices.device(model.devices.contextDeviceID)?.name ?? tr("this Mac", "AppDetail")
    }

    private func absentBanner(_ app: MonitoredApp) -> some View {
        let context = model.devices.contextDeviceID
        let others = model.devices.devices
            .filter { $0.id != context && $0.isOnline && model.catalog.isInstalled(app.id, on: $0.id) == true }
            .map(\.name)
        return HStack(spacing: 10) {
            Circle().fill(Color(oklch: 0.72, 0.15, 70)).frame(width: 7, height: 7)
            Text(trf("%1$@ is not on %2$@", "AppDetail", app.path, contextMacName()))
                .fontWeight(.semibold)
                .layoutPriority(1)
            if !others.isEmpty {
                Text(trf("Not monitored there. Showing live data from %@.", "AppDetail", others.joined(separator: " · ")))
                    .foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 12))
        .lineLimit(1)
        .padding(.horizontal, 20)
        .padding(.vertical, 9)
        .background(Color(oklch: 0.8, 0.14, 75, alpha: 0.16))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    // MARK: Stats strip

    private func statsStrip(_ app: MonitoredApp, stats: AppStats, absent: Bool) -> some View {
        HStack(spacing: 28) {
            stat(tr("Domains", "AppDetail"), Fmt.count(stats.domains))
            stat(tr("IPs", "AppDetail"), Fmt.count(stats.ips))
            stat(tr("Requests", "AppDetail"), Fmt.count(stats.requests))
            stat(tr("Processes", "AppDetail"), Fmt.count(stats.processes))
            if stats.newDomainsIn24h > 0 {
                AnalyzePill(text: trn("%lld new domain in 24 h", "%lld new domains in 24 h", stats.newDomainsIn24h, "AppDetail"))
            }
            Spacer(minLength: 12)
            if app.isArchived {
                archivedControls(app)
            } else {
                activeControls(app, absent: absent)
            }
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.system(size: 11)).foregroundStyle(Theme.ink2)
            Text(value)
                .font(.system(size: 21, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
        }
        .fixedSize()
    }

    private func archivedControls(_ app: MonitoredApp) -> some View {
        HStack(spacing: 10) {
            Text(tr("ARCHIVED", "AppDetail"))
                .font(.system(size: 11, weight: .bold))
                .tracking(0.44)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(Theme.fill2, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .foregroundStyle(Theme.ink2)
            Text(tr("Not monitoring · history kept in the database", "AppDetail"))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            Button(tr("Restore", "AppDetail")) { perform { try await model.capture.restoreApp(app.id) } }
            Button(tr("Delete…", "AppDetail"), role: .destructive) { model.nav.confirmDeleteApp = app.id }
        }
        .buttonStyle(.bordered)
        .fixedSize()
    }

    private func activeControls(_ app: MonitoredApp, absent: Bool) -> some View {
        HStack(spacing: 16) {
            if absent {
                HStack(spacing: 7) {
                    Toggle(tr("Monitoring", "AppDetail"), isOn: .constant(false))
                        .labelsHidden()
                        .disabled(true)
                    Text(trf("Not monitored on %@", "AppDetail", contextMacName()))
                        .foregroundStyle(Theme.ink3)
                }
            } else {
                HStack(spacing: 7) {
                    Toggle(tr("Monitoring", "AppDetail"), isOn: monitoringSwitch(app))
                        .labelsHidden()
                    Text(tr("Monitoring", "AppDetail"))
                }
            }
            Button(tr("Archive", "AppDetail")) { perform { try await model.capture.archiveApp(app.id) } }
                .buttonStyle(.bordered)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
        .font(.system(size: 12))
        .fixedSize()
    }

    /// The switch never flips by itself: it asks for confirmation first, like the design's dialog.
    private func monitoringSwitch(_ app: MonitoredApp) -> Binding<Bool> {
        Binding(
            get: { model.catalog.isMonitoring(app.id) },
            set: { _ in model.nav.confirmMonitoringToggle = app.id }
        )
    }

    // MARK: Installed on

    @ViewBuilder
    private func installsRow(_ app: MonitoredApp) -> some View {
        let devices = model.devices.devices
        if !devices.isEmpty {
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Text(tr("Installed on", "AppDetail")).foregroundStyle(Theme.ink2)
                    ForEach(devices) { device in
                        installChip(app, device: device)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 8)
            }
            .scrollIndicators(.never)
            .font(.system(size: 11.5))
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        }
    }

    private func installChip(_ app: MonitoredApp, device: Device) -> some View {
        let installed = model.catalog.isInstalled(app.id, on: device.id)
        let state: String = if installed == false {
            tr("Path not found", "AppDetail")
        } else if installed == nil {
            tr("Not reported", "AppDetail")
        } else if !device.isOnline && device.id != model.devices.thisDeviceID {
            tr("Offline", "AppDetail")
        } else if app.isArchived {
            tr("Archived", "AppDetail")
        } else if device.id == model.devices.thisDeviceID && model.catalog.paused.contains(app.id) {
            tr("Paused", "AppDetail")
        } else {
            tr("Monitoring", "AppDetail")
        }
        return HStack(spacing: 5) {
            Circle().fill(Theme.deviceColor(hue: device.hue)).frame(width: 7, height: 7)
            Text(device.name).foregroundStyle(Theme.ink)
            Text(state).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 2)
        .background(Theme.fill, in: Capsule())
        .opacity(installed == false ? 0.55 : 1)
        .fixedSize()
    }

    // MARK: Dialogs

    private func monitoringDialog(_ app: MonitoredApp) -> Binding<Bool> {
        Binding(
            get: { model.nav.confirmMonitoringToggle == app.id },
            set: { if !$0, model.nav.confirmMonitoringToggle == app.id { model.nav.confirmMonitoringToggle = nil } }
        )
    }

    private func deleteDialog(_ app: MonitoredApp) -> Binding<Bool> {
        Binding(
            get: { model.nav.confirmDeleteApp == app.id },
            set: { if !$0, model.nav.confirmDeleteApp == app.id { model.nav.confirmDeleteApp = nil } }
        )
    }

    private func monitoringTitle(_ app: MonitoredApp) -> String {
        model.catalog.isMonitoring(app.id)
            ? trf("Stop monitoring %@?", "AppDetail", app.name)
            : trf("Monitor %@ again?", "AppDetail", app.name)
    }

    private func monitoringMessage(_ app: MonitoredApp) -> String {
        model.catalog.isMonitoring(app.id)
            ? trf("Its requests are still recorded in the global log, but they won't be added to %@'s domain and IP lists or trigger alerts. Monitoring turns back on the next time Tidemark starts.", "AppDetail", app.name)
            : trf("New domains and IPs from %@ and everything it launches will be added to its lists and alert again.", "AppDetail", app.name)
    }

    /// The app's icon (or its letter tile) for the confirmation dialogs; rendered only while one is up.
    private func dialogIconImage(_ app: MonitoredApp) -> Image? {
        guard model.nav.confirmDeleteApp == app.id || model.nav.confirmMonitoringToggle == app.id else { return nil }
        if let icon = AppIconCache.shared.icon(for: app.path) { return Image(nsImage: icon) }
        let renderer = ImageRenderer(content: LetterTile(letter: app.tileLetter, color: Theme.tileColor(hue: app.tileHue), size: 64))
        renderer.scale = 2
        return renderer.nsImage.map { Image(nsImage: $0) }
    }

    // MARK: Actions

    private func delete(_ app: MonitoredApp) {
        perform {
            try await model.capture.deleteApp(app.id)
            model.nav.open(.requests)
        }
    }

    private func perform(_ action: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await action() } catch { actionError = error }
        }
    }

    // MARK: Stats loading

    private struct StatsKey: Hashable {
        var appID: AppID
        var scope: DeviceScope
    }

    private struct LoadedStats {
        var key: StatsKey
        var stats: AppStats
    }

    /// When the app is not on the selected Mac, the page shows what the other Macs recorded.
    private func statsScope(absent: Bool) -> DeviceScope {
        absent ? .all : model.devices.scope
    }

    /// The capture engine keeps `CatalogState.stats` for the sidebar's scope, so they only describe the page
    /// when its scope is the sidebar's; otherwise (or until they arrive) the page's own query is shown.
    static func displayedStats(catalog: AppStats?, loaded: AppStats?, pageScope: DeviceScope, sidebarScope: DeviceScope) -> AppStats {
        if pageScope == sidebarScope, let catalog { return catalog }
        return loaded ?? AppStats()
    }

    /// Polls the counters for the page's scope, skipping the query while the catalog already has them.
    private func refreshStats(_ key: StatsKey) async {
        while !Task.isCancelled {
            if key.scope != model.devices.scope || model.catalog.stats[key.appID] == nil {
                if let stats = try? await model.database.appStats(key.appID, scope: key.scope), !Task.isCancelled {
                    loadedStats = LoadedStats(key: key, stats: stats)
                }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}
