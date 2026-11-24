import SwiftUI

/// Notifications page: first contact with a new domain or IP by a monitored app, grouped by day.
struct NotificationsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var nav = model.nav
        let app = model.catalog.app(nav.alertApp)
        let items = NotificationsPresentation.filter(model.alerts.items, by: nav.alertFilter, app: app?.id)
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
        .background(Theme.bg)
        .overlay {
            if items.isEmpty {
                Text(app.map { trf("Nothing here from %@. Its new domains and IPs show up the first time they're seen.", "Notifications", $0.name) }
                    ?? tr("Nothing here. New domains and IPs show up the first time they're seen.", "Notifications"))
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

/// The app menu, the design's All / Unread switch and "Mark All as Read".
private struct NotificationsToolbar: ToolbarContent {
    /// Passed in rather than read from the environment, as toolbar items can be re-hosted in the overflow menu.
    var model: AppModel

    var body: some ToolbarContent {
        @Bindable var nav = model.nav
        // An app deleted while chosen leaves the page on every app's notifications.
        let app = model.catalog.app(nav.alertApp)
        let appUnread = app.map { app in model.alerts.items.count { $0.appID == app.id && $0.isUnread } }

        ToolbarItem(placement: .primaryAction) {
            NotificationsAppMenu(selection: $nav.alertApp, chosen: app,
                                 apps: NotificationsPresentation.apps(with: model.alerts.items, in: model.catalog.apps))
        }
        .visibilityPriority(.high)

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            // Only Unread has a count: the page keeps the newest 200 notifications, not all of them. One app's count is
            // of those it lists.
            DesignSegmentedControl(tr("Show", "Notifications"), selection: $nav.alertFilter, size: .compact(), segments: [
                .init(.all, tr("All", "Notifications"), systemImage: "tray.full"),
                .init(.unread, tr("Unread", "Notifications"), systemImage: "envelope.badge", count: appUnread ?? model.alerts.unreadCount),
            ])
        }
        .sharedBackgroundVisibility(.hidden)
        .visibilityPriority(.high)

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            Button {
                Task { await model.capture.markAllAlertsRead(appID: app?.id) }
            } label: {
                // The system's toolbar button, with the design's label.
                Text(tr("Mark All as Read", "Notifications"))
                    .font(.design(12, .medium))
            }
            .disabled(appUnread.map { $0 == 0 } ?? (model.alerts.unreadCount == 0 && !model.alerts.items.contains(where: \.isUnread)))
        }
    }
}

/// Which app's notifications the page lists: All Apps, or one of the apps that has some.
private struct NotificationsAppMenu: View {
    @Binding var selection: AppID?
    /// The listed app chosen, or nil for All Apps.
    var chosen: MonitoredApp?
    var apps: [MonitoredApp]

    var body: some View {
        let title = tr("App", "Notifications")
        let label = chosen?.name ?? tr("All Apps", "Notifications")
        Menu {
            Picker(title, selection: $selection) {
                Text(tr("All Apps", "Notifications")).tag(AppID?.none)
                if !apps.isEmpty {
                    Divider()
                    ForEach(apps) { app in
                        Text(app.name).tag(Optional(app.id))
                    }
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            // The system's toolbar menu, with the design's label.
            Text(label)
                .font(.design(12, .medium))
                .lineLimit(1)
        }
        .help(tr("Show the notifications of one app", "Notifications"))
        .accessibilityLabel(title)
        .accessibilityValue(label)
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
