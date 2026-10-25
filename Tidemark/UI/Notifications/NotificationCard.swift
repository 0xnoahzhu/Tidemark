import SwiftUI

/// One alert: app tile, NEW chip, headline, `Mac · details`, View, time and the unread dot.
/// Clicking the card marks it read; View also opens the app on its Domains & IPs tab.
struct NotificationCard: View {
    @Environment(AppModel.self) private var model
    var alert: AlertItem
    /// Today's cards show only the time; older ones show the day above it.
    var isToday: Bool

    var body: some View {
        let app = model.catalog.app(alert.appID)
        let appName = app?.name ?? tr("Deleted app", "Notifications")
        HStack(spacing: 12) {
            tile(app: app)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text(tr("New", "Notifications"))
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Theme.tint(75).background, in: .rect(cornerRadius: 4, style: .continuous))
                        .foregroundStyle(Theme.tint(75).foreground)
                    Text(headline(appName: appName))
                        .font(.system(size: 13, weight: alert.isUnread ? .semibold : .medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Text(subtitle)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button(tr("View", "Notifications")) { view() }
                .controlSize(.small)
                .disabled(app == nil)

            timeLabel
                .font(.system(size: 11))
                .foregroundStyle(Theme.ink3)
                .multilineTextAlignment(.trailing)
                .frame(width: isToday ? 40 : 64, alignment: .trailing)

            Circle()
                .fill(alert.isUnread ? Theme.accent : .clear)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(alert.isUnread ? Theme.fresh : Theme.card, in: .rect(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Theme.line, lineWidth: 0.5)
        }
        .contentShape(.rect(cornerRadius: 12))
        .onTapGesture { markRead() }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(alert.isUnread ? tr("Unread", "Notifications") : "")
        .accessibilityAction(named: tr("View", "Notifications")) { view() }
        .accessibilityAction(named: tr("Mark as Read", "Notifications")) { markRead() }
    }

    @ViewBuilder
    private func tile(app: MonitoredApp?) -> some View {
        if let app {
            AppTile(app: app, size: 32)
        } else {
            LetterTile(letter: "?", color: Theme.tileNeutral, size: 32)
        }
    }

    private var timeLabel: Text {
        switch Fmt.seen(alert.createdAt) {
        case .time(let time), .today(let time):
            return Text(time)
        case .yesterday(let time):
            return Text(verbatim: tr("Yesterday", "Notifications") + "\n" + time)
        case .date(let date):
            return Text(verbatim: Fmt.monthDay(date, locale: Localizer.shared.locale) + "\n" + Fmt.hm(date))
        }
    }

    private func headline(appName: String) -> String {
        let headline = NotificationsPresentation.headline(for: alert, appName: appName) { model.classifier.site(for: $0) }
        return switch headline {
        case .newSite(let app, let site): trf("%1$@ reached a new site, %2$@", "Notifications", app, site)
        case .newHost(let app, let host): trf("%1$@ contacted %2$@", "Notifications", app, host)
        case .newIP(let app, let ip): trf("%1$@ connected to %2$@", "Notifications", app, ip)
        case .directIP(let app, let ip): trf("%1$@ connected straight to %2$@", "Notifications", app, ip)
        }
    }

    private var subtitle: String {
        let mac = model.devices.device(alert.deviceID)?.name ?? tr("Unknown Mac", "Notifications")
        let details = NotificationsPresentation.details(for: alert).map { detail in
            switch detail {
            case .firstHost(let host): trf("First host %@", "Notifications", host)
            case .via(let process): trf("via %@", "Notifications", process)
            case .text(let text): text
            case .noHostname: tr("No hostname", "Notifications")
            }
        }
        return ([mac] + details).joined(separator: " · ")
    }

    private func markRead() {
        guard alert.isUnread else { return }
        Task { await model.capture.markAlertsRead([alert.id]) }
    }

    private func view() {
        markRead()
        model.nav.appSelectedHost = alert.kind == .domain ? alert.value : nil
        model.nav.open(.app(alert.appID), tab: .inventory)
    }
}
