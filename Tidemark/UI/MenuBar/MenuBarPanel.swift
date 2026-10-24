import AppKit
import SwiftUI

/// Content of the menu bar panel: recording switch, today's counters, the current egress IP, the latest
/// first-contact alerts and the Open Window / Settings… / Quit footer.
///
/// Hosted by `StatusItemController` in a Liquid Glass panel. Every action calls `onDismiss` first so the
/// panel closes before the main window or Settings come forward.
struct MenuBarPanel: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    /// Closes the panel (ends the status item's expanded-interface session).
    var onDismiss: @MainActor () -> Void = {}

    static let width: CGFloat = 320

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
            HStack(spacing: 8) {
                MenuBarStatTile(title: tr("Today", "MenuBar"), value: Fmt.count(model.live.todayCount))
                MenuBarStatTile(title: tr("Right now", "MenuBar"), value: Fmt.rate(model.live.rate))
            }
            egressRow
            latest
            footer
        }
        .padding(12)
        .frame(width: Self.width)
        .foregroundStyle(Theme.ink)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 10) {
            Image("BrandIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 34, height: 34)
                .padding(-3)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Tidemark")
                    .font(.system(size: 13, weight: .bold))
                Text(statusLine)
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 8)
            Toggle(isOn: recordingBinding) {
                Text(tr("Recording", "MenuBar"))
            }
            .toggleStyle(.switch)
            .controlSize(.small)
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
        HStack(spacing: 8) {
            Text(tr("Egress", "MenuBar"))
                .foregroundStyle(Theme.ink2)
            if let current = model.egress.current {
                // The IP is the row's value: it keeps its full width and the policy chip gives way.
                Text(current.ip ?? "—")
                    .font(Theme.mono(12, weight: .semibold))
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                    .textSelection(.enabled)
                Spacer(minLength: 6)
                MenuBarPolicyChip(policyPath: current.policyPath)
            } else {
                Text(model.egress.isChecking ? tr("Checking…", "MenuBar") : "—")
                    .foregroundStyle(Theme.ink3)
                Spacer(minLength: 0)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 10)
        .frame(height: 32)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Latest alerts

    private var latest: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(tr("Latest", "MenuBar").uppercased(with: localizer.locale))
                .font(.system(size: 10.5, weight: .semibold))
                .tracking(0.6)
                .foregroundStyle(Theme.ink2)
                .padding(.horizontal, 2)
                .padding(.top, 2)
                .padding(.bottom, 2)
            let items = Array(model.alerts.items.prefix(3))
            if items.isEmpty {
                Text(tr("Nothing here. New domains and IPs show up the first time they're seen.", "MenuBar"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .padding(.vertical, 4)
            } else {
                ForEach(items) { alert in
                    MenuBarAlertRow(alert: alert) { open(alert) }
                }
            }
        }
    }

    // MARK: Footer

    private var footer: some View {
        GlassEffectContainer {
            HStack(spacing: 6) {
                Button {
                    showMainWindow()
                } label: {
                    Text(tr("Open Window", "MenuBar")).frame(maxWidth: .infinity)
                }
                Button(tr("Settings…", "MenuBar")) {
                    onDismiss()
                    NSApp.activate()
                    openSettings()
                }
                Button(tr("Quit", "MenuBar")) {
                    onDismiss()
                    AppDelegate.requestQuit()
                }
                .foregroundStyle(Theme.ink2)
            }
            .buttonStyle(.glass)
            .font(.system(size: 12, weight: .medium))
        }
        .padding(.top, 8)
        .overlay(alignment: .top) {
            Rectangle().fill(Theme.line).frame(height: 0.5)
        }
    }

    // MARK: Actions

    private func showMainWindow() {
        onDismiss()
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
        VStack(alignment: .leading, spacing: 1) {
            Text(title)
                .font(.system(size: 10.5))
                .foregroundStyle(Theme.ink2)
            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityElement(children: .combine)
    }
}

/// The leaf policy of the current egress (`HK-01`), tinted like its policy group.
private struct MenuBarPolicyChip: View {
    var policyPath: [String]

    var body: some View {
        let tint = Theme.tint(Theme.policyHue(policyPath))
        Text(policyPath.last ?? "—")
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(tint.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(tint.foreground)
            .help(policyPath.joined(separator: " › "))
    }
}

/// One of the three newest alerts: app tile, the new host / site / IP, `Docker · com.docker.backend`, time.
private struct MenuBarAlertRow: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer
    var alert: AlertItem
    var action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                AppTile(identity: identity, size: 22)
                VStack(alignment: .leading, spacing: 0) {
                    Text(value)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(identity.name + " · " + alert.processName)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                Text(time)
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
                    .monospacedDigit()
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 3)
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            .background(hovering ? Theme.fill : .clear, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, -2)
        .onHover { hovering = $0 }
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
