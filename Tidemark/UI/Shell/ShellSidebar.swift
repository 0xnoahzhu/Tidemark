import SwiftUI

/// The main window's Liquid Glass sidebar: Mac menu, Capture and Analyze destinations, monitored and
/// archived apps, and the Surge / PostgreSQL status footer.
///
/// Laid out like the page rather than as a system sidebar list: 30 pt rows one point apart, and the selected
/// row on the accent wash with its text in ink. The Mac menu and the footer stay put while the rows scroll.
///
/// The column itself is the system's: nothing is painted behind the rows, so the split view's own sidebar glass,
/// which holds the traffic lights, shows as in any other macOS 27 window (full height, edge to edge). Settings ›
/// General › Liquid Glass tints that glass itself (`SidebarGlassTint`), leaving it untouched at the Clear end.
struct ShellSidebar: View {
    @Environment(AppModel.self) private var model
    @SceneStorage("sidebar.archivedExpanded") private var archivedExpanded = true

    var body: some View {
        VStack(spacing: 0) {
            SidebarMacPicker()
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                // The open Mac menu lies over the rows below.
                .zIndex(1)

            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    rows
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 10)
            }
            // No line or fade at either end: the page draws only the footer's own top border.
            .scrollEdgeEffectHidden(true, for: .all)

            SidebarFooter()
                .overlay(alignment: .top) {
                    Rectangle().fill(Theme.line).frame(height: 0.5)
                }
        }
        .foregroundStyle(Theme.ink)
        .background { SidebarGlassTint(preference: model.preferences.glass) }
        .animation(.smooth(duration: 0.25), value: model.catalog.apps.map(\.id))
    }

    @ViewBuilder
    private var rows: some View {
        SidebarSectionHeader(title: tr("Capture", "Sidebar"), top: 4)
        SidebarRow(page: .requests) {
            SidebarGlyph(symbol: "line.3.horizontal", tint: Theme.tileRequests, scale: 0.5)
            SidebarRowTitle(tr("Requests", "Sidebar"))
            Text(Fmt.rate(model.live.recording ? model.live.rate : 0))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.inkGlass)
                .contentTransition(.numericText())
        }
        SidebarRow(page: .notifications) {
            SidebarGlyph(symbol: "circle.fill", tint: Theme.tileNotifications, scale: 0.36)
            SidebarRowTitle(tr("Notifications", "Sidebar"))
            if model.alerts.unreadCount > 0 {
                CountBadge(count: model.alerts.unreadCount, style: .unread)
            }
        }

        SidebarSectionHeader(title: tr("Analyze", "Sidebar"))
        SidebarRow(page: .inventory) {
            SidebarGlyph(symbol: "circle", tint: Theme.tileInventory, scale: 0.52)
            SidebarRowTitle(tr("Domains & IPs", "Sidebar"))
        }
        SidebarRow(page: .probe) {
            SidebarGlyph(symbol: "diamond.fill", tint: Theme.tileProbe, scale: 0.42)
            SidebarRowTitle(tr("Site Probe", "Sidebar"))
        }
        SidebarRow(page: .egress) {
            SidebarGlyph(symbol: "triangle.fill", tint: Theme.tileEgress, scale: 0.42)
            SidebarRowTitle(tr("Egress IP", "Sidebar"))
        }

        SidebarMonitoredHeader()
        ForEach(model.catalog.active) { app in
            SidebarAppRow(app: app)
        }

        let archived = model.catalog.archived
        if !archived.isEmpty {
            SidebarArchivedHeader(count: archived.count, isExpanded: $archivedExpanded)
            if archivedExpanded {
                ForEach(archived) { app in
                    SidebarArchivedRow(app: app)
                }
            }
        }
    }
}

/// Section title in the page's sidebar style (11 pt semibold, glass ink), 14 pt below the rows above it.
private struct SidebarSectionHeader: View {
    var title: String
    var top: CGFloat = 14

    var body: some View {
        Text(title)
            .font(Theme.sectionLabel)
            .foregroundStyle(Theme.inkGlass)
            .padding(EdgeInsets(top: top, leading: 8, bottom: 4, trailing: 8))
            .accessibilityAddTraits(.isHeader)
    }
}

/// `Monitored Apps` and its `+` button, which opens Monitor an App.
private struct SidebarMonitoredHeader: View {
    @Environment(AppModel.self) private var model
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            Text(tr("Monitored Apps", "Sidebar"))
                .font(Theme.sectionLabel)
                .foregroundStyle(Theme.inkGlass)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityAddTraits(.isHeader)
            Button {
                model.nav.openAddApp()
            } label: {
                Image(systemName: "plus")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.inkGlass)
                    .frame(width: 20, height: 20)
                    .background(isHovering ? Theme.fill2 : .clear, in: .rect(cornerRadius: 6, style: .continuous))
                    .contentShape(.rect(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .onHover { isHovering = $0 }
            .help(tr("Monitor an App…", "Sidebar"))
            .accessibilityLabel(tr("Monitor an App…", "Sidebar"))
        }
        .padding(EdgeInsets(top: 14, leading: 8, bottom: 4, trailing: 2))
    }
}

/// `› Archived 1`: the archived apps' section title, which shows or hides them. Open by default, as in the page.
private struct SidebarArchivedHeader: View {
    var count: Int
    @Binding var isExpanded: Bool

    var body: some View {
        Button {
            withAnimation(.smooth(duration: 0.2)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 8, weight: .bold))
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: 8)
                Text(tr("Archived", "Sidebar"))
                    .font(Theme.sectionLabel)
                Text(String(count))
                    .font(.system(size: 11, weight: .medium))
            }
            .foregroundStyle(Theme.inkGlass)
            .padding(EdgeInsets(top: 12, leading: 8, bottom: 4, trailing: 8))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// One destination: a 30 pt row that opens `page`, on the accent wash while it is the page shown.
private struct SidebarRow<Content: View>: View {
    @Environment(AppModel.self) private var model
    var page: Page
    @ViewBuilder var content: Content

    var body: some View {
        let selected = model.nav.page == page
        Button {
            model.nav.page = page
        } label: {
            HStack(spacing: 9) {
                content
            }
            .font(.system(size: 13))
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 30, maxHeight: 30, alignment: .leading)
            .background(selected ? Theme.accentTint : .clear, in: .rect(cornerRadius: 8, style: .continuous))
            .contentShape(.rect(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A row's title, taking the room its trailing counters leave.
private struct SidebarRowTitle: View {
    var title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// `GlyphTile` with a per-symbol scale, so the dot / ring / diamond / triangle glyphs match the page.
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

/// A monitored app: tile, name, "Not on this Mac" when absent on the selected Mac (the whole row dimmed, its path
/// in the tooltip), and the 24 h NEW count.
private struct SidebarAppRow: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp

    var body: some View {
        let context = model.devices.contextDeviceID
        let absent = model.catalog.isInstalled(app.id, on: context) == false
        let newCount = model.catalog.stats[app.id]?.newIn24h ?? 0
        SidebarRow(page: .app(app.id)) {
            AppTile(app: app, size: 20)
                .saturation(absent ? 0 : 1)
            SidebarRowTitle(app.name)
            if absent {
                Text(absentShortLabel(context: context))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.inkGlass)
                    .lineLimit(1)
                    .fixedSize()
            }
            if newCount > 0 {
                CountBadge(count: newCount, style: .new)
            }
        }
        .opacity(absent ? 0.5 : 1)
        .help(absent ? absentLongLabel(context: context) : "")
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
    var app: MonitoredApp

    var body: some View {
        SidebarRow(page: .app(app.id)) {
            AppTile(app: app, size: 20, dimmed: true)
            SidebarRowTitle(app.name)
                .foregroundStyle(Theme.inkGlass)
        }
    }
}
