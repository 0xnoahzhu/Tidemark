import SwiftUI

/// Notifications page: first contact with a new domain or IP by a monitored app, grouped by day.
struct NotificationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var nav = model.nav
        let items = NotificationsPresentation.filter(model.alerts.items, by: nav.alertFilter)
        let groups = NotificationsPresentation.group(items)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 6.px) {
                if !groups.today.isEmpty {
                    NotificationsSectionHeader(title: tr("Today", "Notifications"))
                        .padding(.top, 12.px)
                    ForEach(groups.today) { alert in
                        NotificationCard(alert: alert, isToday: true)
                    }
                }
                if !groups.earlier.isEmpty {
                    NotificationsSectionHeader(title: tr("Earlier", "Notifications"))
                        .padding(.top, groups.today.isEmpty ? 12.px : 14.px)
                    ForEach(groups.earlier) { alert in
                        NotificationCard(alert: alert, isToday: false)
                    }
                }
            }
            .padding(.horizontal, 20.px)
            .padding(.top, 4.px)
            .padding(.bottom, 20.px)
            .animation(.smooth(duration: 0.25), value: items.map(\.id))
        }
        // Cards scroll out under the toolbar's hard edge, as the Requests table does, not visibly under the title.
        .scrollEdgeEffectStyle(.hard, for: .top)
        .background(Theme.bg3)
        .overlay {
            if items.isEmpty {
                Text(tr("Nothing here. New domains and IPs show up the first time they're seen.", "Notifications"))
                    .font(.design(13))
                    .foregroundStyle(Theme.ink2)
                    .multilineTextAlignment(.center)
                    .padding(40.px)
            }
        }
        .pageToolbar(tr("Notifications", "Notifications"), subtitle: tr("First contact with a new domain or IP by a monitored app", "Notifications")) {
            NotificationsToolbar(model: model)
        }
    }
}

/// The design's All / Unread switch and "Mark All as Read".
private struct NotificationsToolbar: ToolbarContent {
    /// Passed in rather than read from the environment, as toolbar items can be re-hosted in the overflow menu.
    var model: AppModel

    var body: some ToolbarContent {
        @Bindable var nav = model.nav
        ToolbarItem(placement: .primaryAction) {
            // Only Unread has a count: the page keeps the newest 200 notifications, not all of them.
            DesignSegmentedControl(tr("Show", "Notifications"), selection: $nav.alertFilter, size: .compact(), segments: [
                .init(.all, tr("All", "Notifications"), systemImage: "tray.full"),
                .init(.unread, tr("Unread", "Notifications"), systemImage: "envelope.badge", count: model.alerts.unreadCount),
            ])
        }
        .sharedBackgroundVisibility(.hidden)
        .visibilityPriority(.high)

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.capture.markAllAlertsRead(appID: nil) }
            } label: {
                // The system's toolbar button, with the design's label.
                Text(tr("Mark All as Read", "Notifications"))
                    .font(.design(12, .medium))
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
            .padding(.horizontal, 2.px)
            .padding(.bottom, 2.px)
            .accessibilityAddTraits(.isHeader)
    }
}
