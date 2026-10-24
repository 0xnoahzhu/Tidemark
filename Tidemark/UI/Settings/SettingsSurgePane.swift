import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Settings › Surge: the surge-cli executable, the event subscription, reconnecting and a remote Surge.
struct SettingsSurgePane: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    @State private var remoteDraft = ""
    @State private var tagDraft = ""
    @State private var passwordDraft = ""
    @State private var hasStoredPassword = false
    @State private var applied = false

    /// The command Tidemark keeps running, shown in the Subscription block.
    static let subscriptionCommand = "$ surge-cli --raw watch request request-update real-time-speed environment reload shutdown"

    var body: some View {
        Form {
            Section {
                HStack(spacing: 8) {
                    Text(model.preferences.surgeCLIPath)
                        .font(Theme.mono(11.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(model.preferences.surgeCLIPath)
                    Button(tr("Choose…", "Settings"), action: chooseCLI)
                }
                status
            } header: {
                Text(tr("surge-cli location", "Settings"))
            }

            Section {
                Text(Self.subscriptionCommand)
                    .font(Theme.mono(12))
                    .foregroundStyle(Color(oklch: 0.88, 0.08, 165))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(oklch: 0.2, 0.01, 250), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                SettingsNote(text: tr("Each event arrives as one line of JSON. Tidemark reads the process, its parent, host, remote IP, policy and rule, then writes the row. If the stream drops, it reconnects and carries on.", "Settings"))
                Toggle(tr("Reconnect automatically", "Settings"), isOn: reconnectBinding)
            } header: {
                Text(tr("Subscription", "Settings"))
            }

            Section {
                LabeledContent(tr("Host and port", "Settings")) {
                    TextField(text: $remoteDraft, prompt: Text(tr("Optional, same as --remote host:port", "Settings"))) {
                        Text(tr("Host and port", "Settings"))
                    }
                    .labelsHidden()
                    .multilineTextAlignment(.trailing)
                    .font(Theme.mono(12))
                    .autocorrectionDisabled()
                    .onSubmit(apply)
                }
                SecureField(text: $passwordDraft, prompt: Text(hasStoredPassword ? tr("Saved in the Keychain", "Settings") : tr("Controller password", "Settings"))) {
                    Text(tr("Password", "Settings"))
                }
                .onSubmit(apply)
                TextField(text: $tagDraft, prompt: Text(tr("Mac mini (Office)", "Settings"))) {
                    Text(tr("Tag requests as", "Settings"))
                    Text(tr("The device name stored with every request from the remote Surge", "Settings"))
                }
                .onSubmit(apply)
                HStack {
                    if applied {
                        Label(tr("Reconnecting with the new settings", "Settings"), systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.ink2)
                            .transition(.opacity)
                    }
                    Spacer()
                    Button(tr("Apply", "Settings"), action: apply)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!hasChanges)
                }
            } header: {
                Text(tr("Remote Surge", "Settings"))
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 600)
        .onAppear(perform: load)
    }

    // MARK: Status

    @ViewBuilder
    private var status: some View {
        let path = model.preferences.surgeCLIPath
        if model.preferences.surgeRemote.isEmpty, !FileManager.default.isExecutableFile(atPath: path) {
            SettingsStatusLine(tone: .failed, text: tr("surge-cli was not found at this path", "Settings"))
        } else {
            switch model.live.surge {
            case .connected:
                SettingsStatusLine(tone: .ok, text: tr("Found · controller connected · streaming", "Settings"), detail: model.live.surgeDetail)
            case .connecting:
                SettingsStatusLine(tone: .pending, text: tr("Connecting…", "Settings"))
            case .failed(let message):
                SettingsStatusLine(tone: .failed, text: message)
            case .paused:
                SettingsStatusLine(tone: .neutral, text: tr("Recording is paused", "Settings"), detail: model.live.surgeDetail)
            case .idle:
                SettingsStatusLine(tone: .neutral, text: tr("Not connected", "Settings"))
            }
        }
    }

    // MARK: Actions

    private var reconnectBinding: Binding<Bool> {
        Binding(get: { model.preferences.surgeReconnect }, set: { model.preferences.surgeReconnect = $0 })
    }

    private var hasChanges: Bool {
        remoteDraft.trimmingCharacters(in: .whitespaces) != model.preferences.surgeRemote
            || tagDraft.trimmingCharacters(in: .whitespaces) != model.preferences.surgeRemoteTag
            || !passwordDraft.isEmpty
    }

    private func load() {
        remoteDraft = model.preferences.surgeRemote
        tagDraft = model.preferences.surgeRemoteTag
        hasStoredPassword = Keychain.read(account: Keychain.surgeRemoteAccount)?.isEmpty == false
    }

    private func apply() {
        guard hasChanges else { return }
        model.preferences.surgeRemote = remoteDraft.trimmingCharacters(in: .whitespaces)
        model.preferences.surgeRemoteTag = tagDraft.trimmingCharacters(in: .whitespaces)
        if !passwordDraft.isEmpty {
            Keychain.write(passwordDraft, account: Keychain.surgeRemoteAccount)
            passwordDraft = ""
            hasStoredPassword = true
        }
        model.capture.reconnect()
        withAnimation { applied = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            withAnimation { applied = false }
        }
    }

    private func chooseCLI() {
        let panel = NSOpenPanel()
        panel.title = tr("Choose surge-cli", "Settings")
        panel.prompt = tr("Choose", "Settings")
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = true
        panel.allowedContentTypes = [.unixExecutable, .executable]
        let current = URL(fileURLWithPath: model.preferences.surgeCLIPath)
        panel.directoryURL = current.deletingLastPathComponent()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.preferences.surgeCLIPath = url.path
        model.capture.reconnect()
    }
}
