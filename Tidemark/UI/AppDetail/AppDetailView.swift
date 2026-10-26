import AppKit
import SwiftUI

/// Page of one monitored app: header, stats and the Requests / Domains & IPs / Process Tree tabs.
///
/// The app's tile, name and bundle path live in the window toolbar (title, subtitle and a leading tile);
/// the tab switch is the toolbar's trailing item. The page also presents the "Delete" sheet whenever
/// `Navigation.confirmDeleteApp` names this app; the main window asks before monitoring stops or restarts.
///
/// The page stays when another app is opened, so the window's toolbar items are updated rather than rebuilt;
/// the stats strip, the Installed on row and the tab below them start afresh for every app. Its body reads
/// nothing that changes while the page is shown (counters, the Macs' activity, the selected tab): the views that
/// show those read them, so a change doesn't make the toolbar re-evaluate.
struct AppDetailView: View {
    @Environment(AppModel.self) private var model
    var appID: AppID
    /// What the app pages' tabs showed last, kept by the main window.
    var cache: AppDetailCache

    @State private var counters = AppDetailCounters()
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
        let absent = isAbsent(app)
        let statsKey = AppDetailCounters.Key(appID: app.id, scope: absent ? .all : model.devices.scope)

        VStack(spacing: 0) {
            if absent { AppDetailAbsentBanner(app: app) }
            // A new strip for every app, so its Monitoring switch doesn't slide from one app's state to the next's.
            AppDetailStatsStrip(app: app, absent: absent, counters: counters, perform: perform)
                .id(app.id)
            AppDetailInstallsRow(app: app)
                .id(app.id)
            AppDetailTabContent(app: app, absent: absent, counters: counters, cache: cache)
                .id(app.id)
        }
        .background(Theme.bg)
        .pageToolbar(app.name, subtitle: app.path, monospacedSubtitle: true) {
            AppTile(app: app, size: 26.px, dimmed: app.isArchived)
        } items: {
            ToolbarItem(placement: .primaryAction) {
                AppDetailTabSwitch(model: model, app: app, absent: absent, counters: counters)
            }
            .sharedBackgroundVisibility(.hidden)
        }
        .task(id: statsKey) {
            await refreshStats(statsKey)
        }
        .sheet(isPresented: deleteDialog(app)) {
            AppDetailDeleteSheet(model: model, app: app, absent: absent, counters: counters) { delete(app) }
        }
        .alert(error: $actionError) {
            Button(tr("OK", "AppDetail")) {}
        }
    }

    /// The app's bundle path does not exist on the Mac the page is scoped to.
    private func isAbsent(_ app: MonitoredApp) -> Bool {
        model.catalog.isInstalled(app.id, on: model.devices.contextDeviceID) == false
    }

    // MARK: Dialogs

    private func deleteDialog(_ app: MonitoredApp) -> Binding<Bool> {
        Binding(
            get: { model.nav.confirmDeleteApp == app.id },
            set: { if !$0, model.nav.confirmDeleteApp == app.id { model.nav.confirmDeleteApp = nil } }
        )
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

    /// The capture engine keeps `CatalogState.stats` for the sidebar's scope, so they only describe the page
    /// when its scope is the sidebar's; otherwise (or until they arrive) the page's own query is shown.
    static func displayedStats(catalog: AppStats?, loaded: AppStats?, pageScope: DeviceScope, sidebarScope: DeviceScope) -> AppStats {
        if pageScope == sidebarScope, let catalog { return catalog }
        return loaded ?? AppStats()
    }

    /// Polls the counters for the page's scope, skipping the query while the catalog already has them.
    private func refreshStats(_ key: AppDetailCounters.Key) async {
        while !Task.isCancelled {
            if key.scope != model.devices.scope || model.catalog.stats[key.appID] == nil {
                if let stats = try? await model.database.appStats(key.appID, scope: key.scope), !Task.isCancelled {
                    counters.loaded = AppDetailCounters.Loaded(key: key, stats: stats)
                }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

/// The All Requests / Domains & IPs / Process Tree switch with the stats strip's counts, in a view of its own so the
/// counters' updates redraw only the switch, not the page. (A toolbar item gets the model passed in.)
private struct AppDetailTabSwitch: View {
    var model: AppModel
    var app: MonitoredApp
    var absent: Bool
    var counters: AppDetailCounters

    var body: some View {
        @Bindable var nav = model.nav
        let stats = counters.stats(for: app, absent: absent, model: model)
        DesignSegmentedControl(tr("View", "AppDetail"), selection: $nav.appTab, size: .compact(), segments: [
            .init(.requests, tr("All Requests", "AppDetail"), systemImage: "list.bullet.rectangle", count: Int(stats.requests)),
            .init(.inventory, tr("Domains & IPs", "AppDetail"), systemImage: "globe", count: stats.domains + stats.ips),
            .init(.tree, tr("Process Tree", "AppDetail"), systemImage: "point.3.connected.trianglepath.dotted", count: stats.processes),
        ])
    }
}

/// Counters an app's page read from the database for its own scope, tagged with the app and scope they were
/// read for. Used when the page's scope differs from the sidebar's (the app is not on the selected Mac) and
/// until the capture engine publishes the app's counters in `CatalogState`.
@MainActor
@Observable
final class AppDetailCounters {
    struct Key: Hashable {
        var appID: AppID
        var scope: DeviceScope
    }

    struct Loaded: Equatable {
        var key: Key
        var stats: AppStats
    }

    var loaded: Loaded?

    /// The counters the page shows for `app`.
    func stats(for app: MonitoredApp, absent: Bool, model: AppModel) -> AppStats {
        let scope = absent ? DeviceScope.all : model.devices.scope
        let key = Key(appID: app.id, scope: scope)
        return AppDetailView.displayedStats(catalog: model.catalog.stats[app.id],
                                            loaded: loaded?.key == key ? loaded?.stats : nil,
                                            pageScope: scope, sidebarScope: model.devices.scope)
    }
}

/// The selected tab of an app's page, in a view of its own so a tab switch (or typing in a tab's search field)
/// doesn't re-run the page's body, which owns the window toolbar.
private struct AppDetailTabContent: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp
    var absent: Bool
    var counters: AppDetailCounters
    var cache: AppDetailCache

    var body: some View {
        let scope = absent ? DeviceScope.all : model.devices.scope
        switch model.nav.appTab {
        case .requests:
            AppDetailRequestsTab(app: app, absent: absent, counters: counters)
        case .inventory:
            AppDetailInventoryTab(app: app, scope: scope, search: model.nav.appInventorySearch, cache: cache)
        case .tree:
            AppDetailProcessTreeTab(app: app, scope: scope, cache: cache)
        }
    }
}

// MARK: - Absent banner

/// "/Applications/Cursor.app is not on Mac mini (Office)": the app's bundle path does not exist on the Mac the
/// page is scoped to.
private struct AppDetailAbsentBanner: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp

    var body: some View {
        let context = model.devices.contextDeviceID
        let others = model.devices.devices
            .filter { $0.id != context && $0.isOnline && model.catalog.isInstalled(app.id, on: $0.id) == true }
            .map(\.name)
        HStack(spacing: 10.px) {
            Circle().fill(Color(oklch: 0.72, 0.15, 70)).frame(width: 7.px, height: 7.px)
            Text(trf("%1$@ is not on %2$@", "AppDetail", app.path, AppDetailContext.macName(model)))
                .fontWeight(.semibold)
                .layoutPriority(1)
            if !others.isEmpty {
                Text(trf("Not monitored there. Showing live data from %@.", "AppDetail", others.joined(separator: " · ")))
                    .foregroundStyle(Theme.ink2)
            }
            Spacer(minLength: 0)
        }
        .font(.design(12))
        .lineLimit(1)
        .padding(.horizontal, 20.px)
        .padding(.vertical, 9.px)
        .background(Color(oklch: 0.8, 0.14, 75, alpha: 0.16))
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }
}

/// The Mac an app's page is scoped to.
private enum AppDetailContext {
    @MainActor
    static func macName(_ model: AppModel) -> String {
        model.devices.device(model.devices.contextDeviceID)?.name ?? tr("this Mac", "AppDetail")
    }
}

// MARK: - Stats strip

/// The app's counters, with its Monitoring switch and Archive button (or, archived, Restore and Delete). In a window
/// too narrow for the whole strip, the note beside the controls shortens; the counters, the switch and the buttons keep
/// their size.
private struct AppDetailStatsStrip: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp
    var absent: Bool
    var counters: AppDetailCounters
    var perform: (@escaping @MainActor () async throws -> Void) -> Void

    var body: some View {
        let stats = counters.stats(for: app, absent: absent, model: model)
        HStack(spacing: 28.px) {
            stat(tr("Domains", "AppDetail"), Fmt.count(stats.domains))
            stat(tr("IPs", "AppDetail"), Fmt.count(stats.ips))
            stat(tr("Requests", "AppDetail"), Fmt.count(stats.requests))
            stat(tr("Processes", "AppDetail"), Fmt.count(stats.processes))
            if stats.newDomainsIn24h > 0 {
                AnalyzePill(text: trn("%lld new domain in 24 h", "%lld new domains in 24 h", stats.newDomainsIn24h, "AppDetail"))
            }
            Spacer(minLength: 12.px)
            if app.isArchived {
                archivedControls
            } else {
                activeControls
            }
        }
        .padding(.horizontal, 20.px)
        .padding(.vertical, 14.px)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 1.px) {
            Text(label).font(.design(11)).foregroundStyle(Theme.ink2)
            Text(value)
                .font(.design(21, .semibold))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .contentTransition(.numericText())
        }
        .fixedSize()
    }

    private var archivedControls: some View {
        let note = tr("Not monitoring · history kept in the database", "AppDetail")
        return HStack(spacing: 10.px) {
            Text(tr("ARCHIVED", "AppDetail"))
                .font(.design(11, .bold))
                .tracking(0.44 * UIScale.factor)
                .padding(.horizontal, 7.px)
                .padding(.vertical, 2.px)
                .background(Theme.fill2, in: RoundedRectangle(cornerRadius: 5.px, style: .continuous))
                .foregroundStyle(Theme.ink2)
                .fixedSize()
            Text(note)
                .font(.design(12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .help(note)
            Button(tr("Restore", "AppDetail")) { perform { try await model.capture.restoreApp(app.id) } }
                .fixedSize()
            Button(role: .destructive) {
                model.nav.confirmDeleteApp = app.id
            } label: {
                // Red on the fill, as the design's: the label's color comes before the style's ink.
                Text(tr("Delete…", "AppDetail")).foregroundStyle(Color(oklch: 0.58, 0.19, 27))
            }
            .fixedSize()
        }
        .buttonStyle(Self.buttonStyle)
    }

    /// Archive, Restore and Delete…: the design's 26 px buttons on the fill.
    private static let buttonStyle = DesignButtonStyle(height: 26, cornerRadius: 7, horizontalPadding: 10)

    private var activeControls: some View {
        HStack(spacing: 16.px) {
            if absent {
                let note = trf("Not monitored on %@", "AppDetail", AppDetailContext.macName(model))
                HStack(spacing: 7.px) {
                    Toggle(tr("Monitoring", "AppDetail"), isOn: .constant(false))
                        .labelsHidden()
                        .disabled(true)
                        .fixedSize()
                    Text(note)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .help(note)
                }
            } else {
                HStack(spacing: 7.px) {
                    Toggle(tr("Monitoring", "AppDetail"), isOn: monitoringSwitch)
                        .labelsHidden()
                    Text(tr("Monitoring", "AppDetail"))
                }
                .fixedSize()
            }
            Button(tr("Archive", "AppDetail")) { perform { try await model.capture.archiveApp(app.id) } }
                .buttonStyle(Self.buttonStyle)
                .fixedSize()
        }
        .toggleStyle(.switch)
        // The system draws the switch, which only grows a control size at a time: one step up once the page is
        // drawn larger.
        .controlSize(UIScale.factor >= 1.2 ? .regular : .small)
        .font(.design(12))
    }

    /// The switch never flips by itself: it asks for confirmation first, like the design's dialog.
    private var monitoringSwitch: Binding<Bool> {
        Binding(
            get: { model.catalog.isMonitoring(app.id) },
            set: { _ in model.nav.confirmMonitoringToggle = app.id }
        )
    }
}

// MARK: - Installed on

/// "Installed on" and a chip per Mac saying what the app's path is there, wrapping onto more rows when the page is
/// too narrow for them all.
private struct AppDetailInstallsRow: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp

    var body: some View {
        let devices = model.devices.devices
        if !devices.isEmpty {
            AppDetailInstallsLayout {
                Text(tr("Installed on", "AppDetail")).foregroundStyle(Theme.ink2)
                ForEach(devices) { device in
                    installChip(device)
                }
            }
            .font(.design(11.5))
            .lineLimit(1)
            .padding(.horizontal, 20.px)
            .padding(.vertical, 8.px)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        }
    }

    private func installChip(_ device: Device) -> some View {
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
        return HStack(spacing: 5.px) {
            Circle().fill(Theme.deviceColor(hue: device.hue)).frame(width: 7.px, height: 7.px)
            Text(device.name).foregroundStyle(Theme.ink)
            Text(state).foregroundStyle(Theme.ink3)
        }
        .padding(.horizontal, 9.px)
        .padding(.vertical, 2.px)
        .background(Theme.fill, in: Capsule())
        .opacity(installed == false ? 0.55 : 1)
    }
}

/// Lays out the Installed on row like the design's `flex-wrap`: the label and the chips in a row, 8 px apart, and
/// what does not fit on a row starts the next, 8 px below, each row's items centered on it. A chip wider than the
/// whole row gets the row's width.
struct AppDetailInstallsLayout: Layout {
    var spacing: CGFloat = 8.px

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = Self.frames(for: subviews.map { $0.sizeThatFits(.unspecified) }, width: proposal.width ?? .infinity, spacing: spacing)
        return CGSize(width: proposal.width ?? frames.map(\.maxX).max() ?? 0, height: frames.map(\.maxY).max() ?? 0)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = Self.frames(for: subviews.map { $0.sizeThatFits(.unspecified) }, width: bounds.width, spacing: spacing)
        for (subview, frame) in zip(subviews, frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// The frames of items of `sizes` in rows `width` wide.
    static func frames(for sizes: [CGSize], width: CGFloat, spacing: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var rowStart = 0, y: CGFloat = 0, x: CGFloat = 0, rowHeight: CGFloat = 0
        func centerRow() {
            for index in rowStart..<frames.count { frames[index].origin.y = y + (rowHeight - frames[index].height) / 2 }
        }
        for size in sizes {
            let itemWidth = min(size.width, width)
            if x > 0, x + itemWidth > width {
                centerRow()
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
                rowStart = frames.count
            }
            frames.append(CGRect(x: x, y: y, width: itemWidth, height: size.height))
            x += itemWidth + spacing
            rowHeight = max(rowHeight, size.height)
        }
        centerRow()
        return frames
    }
}

// MARK: - Delete sheet

/// The delete sheet with the app's current request count. (A sheet gets the model passed in.)
private struct AppDetailDeleteSheet: View {
    var model: AppModel
    var app: MonitoredApp
    var absent: Bool
    var counters: AppDetailCounters
    var onDelete: () -> Void

    var body: some View {
        AppDeleteConfirmation(app: app, requests: counters.stats(for: app, absent: absent, model: model).requests, onDelete: onDelete)
    }
}
