import AppKit
import SwiftUI

/// The main window's Liquid Glass sidebar: Mac menu, Capture and Analyze destinations, monitored and
/// archived apps, and the Surge / PostgreSQL status footer.
struct ShellSidebar: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("sidebar.archivedExpanded") private var archivedExpanded = false

    var body: some View {
        let nav = model.nav
        let glass = SidebarGlassStyle(preference: model.preferences.glass)
        List(selection: Binding(get: { nav.page }, set: { if let page = $0 { nav.page = page } })) {
            Section {
                SidebarDestinationRow(title: tr("Requests", "Sidebar"), symbol: "line.3.horizontal", tint: Theme.tileRequests) {
                    Text(Fmt.rate(model.live.recording ? model.live.rate : 0))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.inkGlass)
                        .contentTransition(.numericText())
                }
                .tag(Page.requests)

                SidebarDestinationRow(title: tr("Notifications", "Sidebar"), symbol: "circle.fill", tint: Theme.tileNotifications, symbolScale: 0.36) {
                    if model.alerts.unreadCount > 0 {
                        CountBadge(count: model.alerts.unreadCount, style: .unread)
                    }
                }
                .tag(Page.notifications)
            } header: {
                SidebarSectionHeader(title: tr("Capture", "Sidebar"))
            }

            Section {
                SidebarDestinationRow(title: tr("Domains & IPs", "Sidebar"), symbol: "circle", tint: Theme.tileInventory, symbolScale: 0.52) { EmptyView() }
                    .tag(Page.inventory)
                SidebarDestinationRow(title: tr("Site Probe", "Sidebar"), symbol: "diamond.fill", tint: Theme.tileProbe, symbolScale: 0.42) { EmptyView() }
                    .tag(Page.probe)
                SidebarDestinationRow(title: tr("Egress IP", "Sidebar"), symbol: "triangle.fill", tint: Theme.tileEgress, symbolScale: 0.42) { EmptyView() }
                    .tag(Page.egress)
            } header: {
                SidebarSectionHeader(title: tr("Analyze", "Sidebar"))
            }

            Section {
                ForEach(model.catalog.active) { app in
                    SidebarAppRow(app: app)
                        .tag(Page.app(app.id))
                }
            } header: {
                HStack(spacing: 4) {
                    SidebarSectionHeader(title: tr("Monitored Apps", "Sidebar"))
                    Spacer(minLength: 0)
                    Button {
                        nav.openAddApp()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(width: 20, height: 20)
                            .contentShape(.rect(cornerRadius: 6))
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(Theme.inkGlass)
                    .help(tr("Monitor an App…", "Sidebar"))
                    .accessibilityLabel(tr("Monitor an App…", "Sidebar"))
                }
            }

            let archived = model.catalog.archived
            if !archived.isEmpty {
                Section(isExpanded: $archivedExpanded) {
                    ForEach(archived) { app in
                        SidebarArchivedRow(app: app)
                            .tag(Page.app(app.id))
                    }
                } header: {
                    HStack(spacing: 5) {
                        SidebarSectionHeader(title: tr("Archived", "Sidebar"))
                        Text(String(archived.count))
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.inkGlass)
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .background { SidebarGlassWash(style: glass) }
        .safeAreaBar(edge: .top) {
            SidebarMacPicker()
                .padding(.horizontal, 10)
                .padding(.bottom, 6)
        }
        .safeAreaBar(edge: .bottom) {
            SidebarFooter()
        }
        .animation(.smooth(duration: 0.25), value: model.catalog.apps.map(\.id))
    }
}

/// A tint of the prototype's glass color laid over the system sidebar glass; empty at the Clear end.
private struct SidebarGlassWash: View {
    var style: SidebarGlassStyle

    var body: some View {
        Rectangle()
            .fill(SidebarGlassStyle.glassColor.opacity(style.washOpacity))
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .animation(.easeInOut(duration: 0.2), value: style.washOpacity)
    }
}

/// Section title in the prototype's sidebar style (11 pt semibold, glass ink).
private struct SidebarSectionHeader: View {
    var title: String

    var body: some View {
        Text(title)
            .font(Theme.sectionLabel)
            .foregroundStyle(Theme.inkGlass)
    }
}

/// A page destination: colored glyph tile, title and a trailing accessory.
private struct SidebarDestinationRow<Accessory: View>: View {
    var title: String
    var symbol: String
    var tint: Color
    var symbolScale: CGFloat = 0.5
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(spacing: 9) {
            SidebarGlyph(symbol: symbol, tint: tint, scale: symbolScale)
            Text(title)
                .lineLimit(1)
            Spacer(minLength: 4)
            accessory
        }
        .frame(minHeight: 26)
    }
}

/// `GlyphTile` with a per-symbol scale, so the dot / ring / diamond / triangle glyphs match the prototype.
private struct SidebarGlyph: View {
    var symbol: String
    var tint: Color
    var scale: CGFloat

    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint)
            .frame(width: 20, height: 20)
            .overlay {
                Image(systemName: symbol)
                    .font(.system(size: 20 * scale, weight: .bold))
                    .foregroundStyle(.white)
            }
            .accessibilityHidden(true)
    }
}

/// A monitored app: tile, name, "Not on this Mac" when absent on the selected Mac, and the 24 h NEW count.
private struct SidebarAppRow: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp

    var body: some View {
        let context = model.devices.contextDeviceID
        let absent = model.catalog.isInstalled(app.id, on: context) == false
        let newCount = model.catalog.stats[app.id]?.newIn24h ?? 0
        HStack(spacing: 9) {
            AppTile(app: app, size: 20, dimmed: absent)
            Text(app.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(absent ? 0.5 : 1)
            Spacer(minLength: 4)
            if absent {
                Text(absentShortLabel(context: context))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.inkGlass)
                    .lineLimit(1)
                    .opacity(0.8)
            }
            if newCount > 0 {
                CountBadge(count: newCount, style: .new)
                    .help(trn("%lld new domain or IP in the last 24 hours", "%lld new domains and IPs in the last 24 hours", newCount, "Sidebar"))
            }
        }
        .frame(minHeight: 26)
        .help(absent ? absentLongLabel(context: context) : app.path)
        .contextMenu { SidebarAppMenu(model: model, app: app) }
    }

    private func absentShortLabel(context: DeviceID) -> String {
        if context == model.devices.thisDeviceID { return tr("Not on this Mac", "Sidebar") }
        return trf("Not on %@", "Sidebar", model.devices.shortName(context))
    }

    private func absentLongLabel(context: DeviceID) -> String {
        let name = model.devices.device(context)?.name ?? model.devices.shortName(context)
        return trf("%1$@ is not on %2$@", "Sidebar", app.path, name)
    }
}

/// An archived app, greyed out.
private struct SidebarArchivedRow: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp

    var body: some View {
        HStack(spacing: 9) {
            AppTile(app: app, size: 20, dimmed: true)
            Text(app.name)
                .lineLimit(1)
                .foregroundStyle(Theme.inkGlass)
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
        .contextMenu { SidebarAppMenu(model: model, app: app) }
    }
}

/// Right-click menu of an app row (menus are built outside the environment chain, so the model is passed in).
private struct SidebarAppMenu: View {
    var model: AppModel
    var app: MonitoredApp

    var body: some View {
        Button(tr("Open", "Sidebar")) { model.nav.open(.app(app.id), tab: .requests) }
        Button(tr("Domains & IPs", "Sidebar")) { model.nav.open(.app(app.id), tab: .inventory) }
        Button(tr("Process Tree", "Sidebar")) { model.nav.open(.app(app.id), tab: .tree) }
        Divider()
        Button(tr("Show in Finder", "Sidebar")) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.path)])
        }
        .disabled(!FileManager.default.fileExists(atPath: app.path))
    }
}
