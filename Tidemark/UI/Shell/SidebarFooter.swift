import SwiftUI

/// Bottom of the sidebar: Surge and PostgreSQL health, and the Settings button.
struct SidebarFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let live = model.live
        HStack(alignment: .bottom, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                SidebarStatusLine(
                    name: "Surge",
                    status: live.surge,
                    detail: SidebarStatusText.surge(live.surge),
                    monospacedDetail: false
                )
                SidebarStatusLine(
                    name: "PostgreSQL",
                    status: live.database,
                    detail: SidebarStatusText.database(live.database, totalRows: live.totalRows),
                    monospacedDetail: live.database.isHealthy
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.inkGlass)
                    .frame(width: 26, height: 26)
                    .contentShape(.rect(cornerRadius: 7))
            }
            .buttonStyle(.borderless)
            .help(tr("Settings…", "Sidebar"))
            .accessibilityLabel(tr("Settings…", "Sidebar"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// `● Surge watching requests` with the dot colored by link health and, while the link is down, the error as
/// help text.
private struct SidebarStatusLine: View {
    var name: String
    var status: LinkStatus
    var detail: String
    var monospacedDetail: Bool

    var body: some View {
        HStack(spacing: 6) {
            StatusDot(color: SidebarStatusText.color(status), size: 6, pulsing: status == .connecting)
            Text(name)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(monospacedDetail ? Theme.mono(11) : .system(size: 11))
                .foregroundStyle(Theme.inkGlass)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .help(SidebarStatusText.help(status) ?? "")
        .accessibilityElement(children: .combine)
    }
}

/// Wording and colors of the footer status lines.
enum SidebarStatusText {
    static func color(_ status: LinkStatus) -> Color {
        switch status {
        case .connected: Theme.live
        case .connecting: Theme.warning
        case .failed: Theme.failed
        case .idle, .paused: Theme.ink3
        }
    }

    @MainActor
    static func surge(_ status: LinkStatus) -> String {
        switch status {
        case .connected: tr("watching requests", "Sidebar")
        case .connecting: tr("connecting…", "Sidebar")
        case .failed: tr("not connected", "Sidebar")
        case .paused: tr("paused", "Sidebar")
        case .idle: tr("not started", "Sidebar")
        }
    }

    @MainActor
    static func database(_ status: LinkStatus, totalRows: Int64) -> String {
        switch status {
        case .connected: trf("%@ rows", "Sidebar", Fmt.count(totalRows))
        case .connecting: tr("connecting…", "Sidebar")
        case .failed: tr("not connected", "Sidebar")
        case .paused: tr("paused", "Sidebar")
        case .idle: tr("not started", "Sidebar")
        }
    }

    /// The failure (in the current UI language) for the line's tooltip. A healthy line has none, as in the page.
    @MainActor
    static func help(_ status: LinkStatus) -> String? {
        guard case .failed(let error) = status else { return nil }
        return CaptureEngine.message(for: error)
    }
}
