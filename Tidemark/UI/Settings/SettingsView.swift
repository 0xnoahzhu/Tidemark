import SwiftUI

/// The Settings window: General, Surge, Database and Notifications tabs.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    var body: some View {
        @Bindable var nav = model.nav
        TabView(selection: $nav.settingsTab) {
            Tab(tr("General", "Settings"), systemImage: "gearshape", value: SettingsTab.general) {
                SettingsGeneralPane()
            }
            Tab(String("Surge"), systemImage: "chart.bar.fill", value: SettingsTab.surge) {
                SettingsSurgePane()
            }
            Tab(tr("Database", "Settings"), systemImage: "cylinder.split.1x2", value: SettingsTab.database) {
                SettingsDatabasePane()
            }
            Tab(tr("Notifications", "Settings"), systemImage: "bell.badge", value: SettingsTab.notifications) {
                SettingsNotificationsPane()
            }
        }
        .tabViewStyle(.automatic)
        .environment(\.locale, localizer.locale)
    }
}

// MARK: - Shared pieces

/// Fixed pane width; each pane picks its own height so the window resizes between tabs.
enum SettingsLayout {
    static let width: CGFloat = 620
}

/// `● Connected · PostgreSQL 18.3 · 2 ms` status line under a connection field.
struct SettingsStatusLine: View {
    enum Tone { case ok, pending, failed, neutral }

    var tone: Tone
    var text: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .foregroundStyle(tone == .failed ? Theme.failed : Theme.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(2)
                }
            }
        }
        .font(.system(size: 12))
    }

    private var color: Color {
        switch tone {
        case .ok: Theme.live
        case .pending: Theme.warning
        case .failed: Theme.failed
        case .neutral: Theme.ink3
        }
    }
}

/// Secondary explanation under a group (`Every row is tagged with the Mac it came from…`).
struct SettingsNote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.ink2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
