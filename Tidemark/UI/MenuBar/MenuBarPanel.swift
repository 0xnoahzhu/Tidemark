import AppKit
import SwiftUI

/// Content of the menu bar panel: recording switch, today's counters, the current egress IP, the latest
/// first-contact alerts and the Open Window / Settings… / Quit footer.
///
/// Hosted by `StatusItemController` in a Liquid Glass panel, over which it lays the design's panel glass color
/// (`GlassSurface.panel`, which follows Settings › General › Liquid Glass), so its text stays legible over any
/// desktop. Every action calls `onDismiss` first so the panel closes before the main window or Settings come
/// forward.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Closes the panel (ends the status item's expanded-interface session).
    var onDismiss: @MainActor () -> Void = {}

    /// The design's 320 px, which `StatusItemController` also sizes the panel's window and glass to.
    static let width = 320.px
    static let cornerRadius = 16.px

    var body: some View {
        VStack(alignment: .leading, spacing: 10.px) {
            header
            HStack(spacing: 8.px) {
                MenuBarStatTile(title: tr("Today", "MenuBar"), value: Fmt.count(model.live.todayCount))
                MenuBarStatTile(title: tr("Right now", "MenuBar"), value: Fmt.rate(model.live.rate))
            }
            egressRow
            latest
            footer
        }
        .padding(12.px)
        .frame(width: Self.width)
        .foregroundStyle(Theme.ink)
        .background(
            GlassSurface.panel.tint(preference: model.preferences.glass),
            in: RoundedRectangle(cornerRadius: Self.cornerRadius, style: .continuous)
        )
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10.px) {
            // The asset keeps the system icon margin; drawn a quarter larger, its tile fills the design's 36 px.
            let tile = 36.px, drawn = tile * 1.25
            Image("BrandIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: drawn, height: drawn)
                .padding(-(drawn - tile) / 2)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1.px) {
                Text(verbatim: "Tidemark")
                    .font(.design(13, .bold))
                Text(statusLine)
                    .font(.design(11.5))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8.px)
            Toggle(isOn: recordingBinding) {
                Text(tr("Recording", "MenuBar"))
            }
            .toggleStyle(.switch)
            // The system's switch, which does not follow the UI scale: a size larger from 1.2 on, near the
            // design's 34 × 20 px there.
            .controlSize(UIScale.factor >= 1.2 ? .regular : .small)
            .labelsHidden()
            .tint(Theme.accent)
            .help(model.live.recording ? tr("Pause recording…", "MenuBar") : tr("Resume recording…", "MenuBar"))
        }
    }

    private var statusLine: String {
        guard model.live.recording else { return tr("Paused", "MenuBar") }
        switch model.live.surge {
        case .connected, .paused:
            return trf("Recording · %@", "MenuBar", Fmt.rate(model.live.rate))
        case .idle, .connecting:
            return tr("Connecting to Surge…", "MenuBar")
        case .failed:
            return tr("Surge is not connected", "MenuBar")
        }
    }

    /// The switch never flips by itself: it asks for confirmation in the main window.
    private var recordingBinding: Binding<Bool> {
        Binding(
            get: { model.live.recording },
            set: { _ in
                model.nav.confirmRecordingToggle = true
                showMainWindow()
            }
        )
    }

    // MARK: Egress

    private var egressRow: some View {
        HStack(spacing: 8.px) {
            Text(tr("Egress", "MenuBar"))
                .foregroundStyle(Theme.ink2)
                .fixedSize()
            if let current = model.egress.current {
                MenuBarEgressValue(ip: current.ip ?? "—", policyPath: current.policyPath)
                    .layoutPriority(1)
            } else {
                Text(model.egress.isChecking ? tr("Checking…", "MenuBar") : "—")
                    .foregroundStyle(Theme.ink3)
                Spacer(minLength: 0)
            }
        }
        .font(.design(12))
        .padding(.horizontal, 10.px)
        .padding(.vertical, 6.px)
        // One line normally; a long IPv6 address puts the policy chip on a second line.
        .frame(minHeight: 32.px)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10.px, style: .continuous))
    }

    // MARK: Latest alerts

    /// The `LATEST` title and the three newest alerts, spaced like every other part of the panel.
    @ViewBuilder
    private var latest: some View {
        Text(tr("Latest", "MenuBar").uppercased(with: localizer.locale))
            .font(.design(10.5, .semibold))
            .tracking(0.6 * UIScale.factor)
            .foregroundStyle(Theme.ink2)
            .padding(.horizontal, 2.px)
            .padding(.top, 2.px)
        let items = Array(model.alerts.items.prefix(3))
        if items.isEmpty {
            Text(tr("Nothing here. New domains and IPs show up the first time they're seen.", "MenuBar"))
                .font(.design(11.5))
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2.px)
        } else {
            ForEach(items) { alert in
                MenuBarAlertRow(alert: alert) { open(alert) }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 6.px) {
            Button(tr("Open Window", "MenuBar")) {
                showMainWindow()
            }
            .buttonStyle(DesignButtonStyle(fillsWidth: true))
            Button(tr("Settings…", "MenuBar")) {
                onDismiss()
                DockPresence.willShowWindow()
                NSApp.activate()
                openSettings()
            }
            Button {
                onDismiss()
                AppDelegate.requestQuit()
            } label: {
                Text(tr("Quit", "MenuBar")).foregroundStyle(Theme.ink2)
            }
        }
        .buttonStyle(DesignButtonStyle())
        .padding(.top, 8.px)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    // MARK: Actions

    private func showMainWindow() {
        onDismiss()
        DockPresence.willShowWindow()
        NSApp.activate()
        openWindow(id: WindowID.main)
    }

    private func open(_ alert: AlertItem) {
        if alert.isUnread {
            let id = alert.id
            Task { await model.capture.markAlertsRead([id]) }
        }
        // Highlight the new host in the app's Domains & IPs tab, like a notification card's View.
        model.nav.appSelectedHost = alert.kind == .domain ? alert.value : nil
        model.nav.open(.app(alert.appID), tab: .inventory)
        showMainWindow()
    }
}

/// `Today 128,513` / `Right now 2.8/s` tile.
private struct MenuBarStatTile: View {
    var title: String
    var value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 1.px) {
            Text(title)
                .font(.design(10.5))
                .foregroundStyle(Theme.ink2)
            Text(value)
                .font(.design(17, .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10.px)
        .padding(.vertical, 9.px)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10.px, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The current egress IP and its policy, inside the egress row.
///
/// The IP is the row's value. When it fits at full size next to a readable chip (every IPv4 address and most
/// IPv6 ones do), both share one line and the chip shortens first. A longer IPv6 address takes the whole line,
/// scaling down a little and then shortening in the middle, and the chip moves below it, so the row never runs
/// past the panel.
struct MenuBarEgressValue: View {
    var ip: String
    var policyPath: [String]

    /// Room the chip asks for when deciding whether the IP and the chip share a line.
    static let chipRoom = 56.px

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12.px) {
                ipText.fixedSize()
                MenuBarPolicyChip(policyPath: policyPath)
                    .frame(minWidth: 0, idealWidth: Self.chipRoom, maxWidth: .infinity, alignment: .trailing)
            }
            VStack(alignment: .trailing, spacing: 4.px) {
                ipText
                    .minimumScaleFactor(0.75)
                    .truncationMode(.middle)
                MenuBarPolicyChip(policyPath: policyPath)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var ipText: some View {
        Text(ip)
            .font(Theme.mono(12, weight: .semibold))
            .lineLimit(1)
            .textSelection(.enabled)
    }
}

/// The leaf policy of the current egress (`HK-01`), tinted like its policy group. Like every policy chip, a
/// shortened name keeps its end (`…RackNerd-Hysteria2`).
private struct MenuBarPolicyChip: View {
    var policyPath: [String]

    var body: some View {
        let tint = Theme.tint(Theme.policyHue(policyPath))
        Text(policyPath.last ?? "—")
            .font(.design(11, .medium))
            .lineLimit(1)
            .truncationMode(.head)
            .padding(.horizontal, 7.px)
            .padding(.vertical, 1.px)
            .background(tint.background, in: RoundedRectangle(cornerRadius: 5.px, style: .continuous))
            .foregroundStyle(tint.foreground)
    }
}

/// One of the three newest alerts: app tile, the new host / site / IP, `Docker · com.docker.backend`, time.
private struct MenuBarAlertRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer
    var alert: AlertItem
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9.px) {
                AppTile(identity: identity, size: 22.px)
                VStack(alignment: .leading, spacing: 2.px) {
                    Text(value)
                        .font(.design(12, .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text([identity.name, alert.knownProcessName].compactMap { $0 }.joined(separator: " · "))
                        .font(.design(10.5))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 6.px)
                Text(time)
                    .font(.design(10.5))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
            }
            .padding(.horizontal, 2.px)
            .padding(.vertical, 3.px)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint(tr("Shows this app's domains and IPs", "MenuBar"))
    }

    private var identity: AppIdentity {
        if let app = model.catalog.app(alert.appID) {
            return AppIdentity(name: app.name, bundlePath: app.path, letter: app.tileLetter, hue: app.tileHue, isMonitored: true, appID: app.id)
        }
        return AppIdentity(name: "?", bundlePath: nil, letter: "?", hue: nil, isMonitored: false, appID: alert.appID)
    }

    private var value: String {
        alert.scope == .site ? (alert.site ?? alert.value) : alert.value
    }

    private var time: String {
        Calendar.current.isDateInToday(alert.createdAt)
            ? Fmt.hm(alert.createdAt)
            : Fmt.monthDay(alert.createdAt, locale: localizer.locale)
    }
}
