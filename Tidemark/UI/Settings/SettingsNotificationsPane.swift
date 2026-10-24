import AppKit
import SwiftUI
import UserNotifications

/// Settings › Notifications: macOS notifications, what alerts, bursts and muted hosts.
struct SettingsNotificationsPane: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    @State private var authorization: UNAuthorizationStatus = .notDetermined
    @State private var muteDraft = ""
    @State private var muteProblem: String?

    var body: some View {
        @Bindable var preferences = model.preferences
        Form {
            Section {
                Toggle(isOn: systemBinding) {
                    Text(tr("macOS notifications", "Settings"))
                    Text(tr("Shown the first time a monitored app reaches any new domain or IP.", "Settings"))
                }
                if preferences.systemNotifications, authorization == .denied {
                    HStack(alignment: .firstTextBaseline) {
                        Text(tr("Notifications are turned off for Tidemark in System Settings.", "Settings"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.amberInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(tr("Open System Settings…", "Settings"), action: openNotificationSettings)
                    }
                }
            }

            Section {
                Toggle(isOn: $preferences.notifyNewDomain) {
                    Text(tr("New domain", "Settings"))
                    Text(tr("When a monitored app reaches a host it never has before", "Settings"))
                }
                Toggle(isOn: $preferences.notifyNewIP) {
                    Text(tr("New IP", "Settings"))
                    Text(tr("Noisier, since CDNs rotate addresses", "Settings"))
                }
                Toggle(isOn: $preferences.notifyOtherMacs) {
                    Text(tr("Alerts from other Macs", "Settings"))
                    Text(tr("Also show a system notification when another Mac in this database finds something new", "Settings"))
                }
                Toggle(isOn: $preferences.groupBursts) {
                    Text(tr("Group bursts", "Settings"))
                    Text(tr("One alert per app for anything new within 30 seconds", "Settings"))
                }
                explainHostsToggle
            }
            .disabled(!preferences.systemNotifications)

            Section {
                ForEach(model.alerts.mutes, id: \.self) { pattern in
                    HStack {
                        Text(pattern)
                            .font(Theme.mono(12))
                            .textSelection(.enabled)
                        Spacer()
                        Button(tr("Remove", "Settings")) {
                            Task { await model.capture.unmute(pattern) }
                        }
                        .buttonStyle(.borderless)
                        .foregroundStyle(Theme.accentInk)
                    }
                }
                HStack(spacing: 8) {
                    TextField(text: $muteDraft, prompt: Text(tr("host, IP or *.example.com", "Settings"))) {
                        Text(tr("Mute", "Settings"))
                    }
                    .labelsHidden()
                    .font(Theme.mono(12))
                    .autocorrectionDisabled()
                    .onSubmit(addMute)
                    .onChange(of: muteDraft) { muteProblem = nil }
                    Button(tr("Add", "Settings"), action: addMute)
                        .disabled(muteDraft.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let muteProblem {
                    Text(muteProblem)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.failed)
                }
            } header: {
                Text(tr("Muted hosts", "Settings"))
            } footer: {
                SettingsNote(text: tr("Muted hosts are still recorded. They just don't alert.", "Settings"))
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 650)
        .task { authorization = await Self.authorizationStatus() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { authorization = await Self.authorizationStatus() }
        }
    }

    // MARK: Host insights

    /// Opt-in on-device explanation under new-host notifications. Shown off and disabled, with the reason,
    /// while Apple Intelligence is unavailable.
    private var explainHostsToggle: some View {
        let available = model.insights.isAvailable
        return Toggle(isOn: Binding(
            get: { available && model.preferences.notifyExplainHosts },
            set: { model.preferences.notifyExplainHosts = $0 }
        )) {
            Text(tr("Explain new hosts with Apple Intelligence", "Settings"))
            Text(Self.explainHostsNote(available: available, reason: model.insights.unavailableReason))
        }
        .disabled(!available)
    }

    static func explainHostsNote(available: Bool, reason: String?) -> String {
        guard !available else {
            return tr("Adds a short description of the host, generated on this Mac. It never delays the alert.", "Settings")
        }
        return reason ?? tr("Apple Intelligence is unavailable on this Mac.", "Settings")
    }

    // MARK: System notifications

    private var systemBinding: Binding<Bool> {
        Binding(
            get: { model.preferences.systemNotifications },
            set: { on in
                model.preferences.systemNotifications = on
                guard on else { return }
                Task { @MainActor in
                    if await Self.authorizationStatus() == .notDetermined {
                        _ = await Self.requestAuthorization()
                    }
                    authorization = await Self.authorizationStatus()
                }
            }
        )
    }

    nonisolated private static func authorizationStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    nonisolated private static func requestAuthorization() async -> Bool {
        (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    private func openNotificationSettings() {
        let id = Bundle.main.bundleIdentifier ?? "io.tidemark.Tidemark"
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension?id=\(id)") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Mutes

    private func addMute() {
        guard let pattern = SettingsMutePattern.normalize(muteDraft) else {
            muteProblem = tr("Enter a host name, an IP address or a pattern like *.example.com.", "Settings")
            return
        }
        muteDraft = ""
        guard !model.alerts.mutes.contains(pattern) else { return }
        Task { await model.capture.mute(pattern, dismissingAlert: nil) }
    }
}

/// Validates what the user types into "Muted hosts": a host, an IP, or `*.example.com`.
enum SettingsMutePattern {
    /// Lower-cased pattern, or nil when the input is not a host, IP or `*.` wildcard. A pasted URL yields its host.
    static func normalize(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.contains("://"), let host = URL(string: value)?.host(percentEncoded: false) {
            value = host
        }
        if value.hasSuffix(".") { value.removeLast() }
        guard !value.isEmpty else { return nil }
        if HostName.isIPAddress(value) { return value }
        let name = value.hasPrefix("*.") ? String(value.dropFirst(2)) : value
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 || name == "localhost" else { return nil }
        let valid = labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        }
        return valid ? value : nil
    }
}
