import SwiftUI

/// Notifications page: first contact with a new domain or IP by a monitored app, grouped by day.
struct NotificationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var nav = model.nav
        let items = NotificationsPresentation.filter(model.alerts.items, by: nav.alertFilter)
        let groups = NotificationsPresentation.group(items)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6) {
                if !groups.today.isEmpty {
                    NotificationsSectionHeader(title: tr("Today", "Notifications"))
                        .padding(.top, 12)
                    ForEach(groups.today) { alert in
                        NotificationCard(alert: alert, isToday: true)
                    }
                }
                if !groups.earlier.isEmpty {
                    NotificationsSectionHeader(title: tr("Earlier", "Notifications"))
                        .padding(.top, groups.today.isEmpty ? 12 : 14)
                    ForEach(groups.earlier) { alert in
                        NotificationCard(alert: alert, isToday: false)
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 4)
            .padding(.bottom, 20)
            .animation(.smooth(duration: 0.25), value: items.map(\.id))
        }
        .scrollEdgeEffectStyle(.soft, for: .top)
        .background(Theme.bg3)
        .overlay {
            if items.isEmpty {
                Text(tr("Nothing here. New domains and IPs show up the first time they're seen.", "Notifications"))
                    .font(.system(size: 13))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .padding(40)
            }
        }
        .navigationTitle(tr("Notifications", "Notifications"))
        .navigationSubtitle(tr("First contact with a new domain or IP by a monitored app", "Notifications"))
        .toolbar { NotificationsToolbar(model: model) }
    }
}

/// The design's All / Unread switch and "Mark All as Read".
private struct NotificationsToolbar: ToolbarContent {
    /// Passed in rather than read from the environment, as toolbar items can be re-hosted in the overflow menu.
    var model: AppModel

    var body: some ToolbarContent {
        @Bindable var nav = model.nav
        ToolbarItem(placement: .primaryAction) {
            Picker(tr("Show", "Notifications"), selection: $nav.alertFilter) {
                Text(tr("All", "Notifications")).tag(AlertFilter.all)
                Text(tr("Unread", "Notifications")).tag(AlertFilter.unread)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
        }
        .visibilityPriority(.high)

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button(tr("Mark All as Read", "Notifications")) {
                Task { await model.capture.markAllAlertsRead(appID: nil) }
            }
            .disabled(model.alerts.unreadCount == 0 && !model.alerts.items.contains(where: \.isUnread))
        }
    }
}

/// `TODAY` / `EARLIER`
private struct NotificationsSectionHeader: View {
    var title: String

    var body: some View {
        SectionLabel(text: title)
            .padding(.horizontal, 2)
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
    }
}
