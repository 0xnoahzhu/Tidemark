import AppKit
import SwiftUI
import System
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

    /// One line, built from state at render time so it follows the language and the connected endpoint.
    @ViewBuilder
    private var status: some View {
        // A remote Surge is also reached through the local surge-cli (`--remote`).
        if let problem = SurgeCLIPathProblem(checking: model.preferences.surgeCLIPath) {
            SettingsStatusLine(tone: .failed, text: Self.message(for: problem))
        } else {
            switch model.live.surge {
            case .connected:
                SettingsStatusLine(tone: .ok, text: Self.connectedText(remote: model.surge.endpoint.remote != nil))
            case .connecting:
                SettingsStatusLine(tone: .pending, text: tr("Connecting…", "Settings"))
            case .failed(let error):
                SettingsStatusLine(tone: .failed, text: CaptureEngine.message(for: error))
            case .paused:
                SettingsStatusLine(tone: .neutral, text: tr("Recording is paused", "Settings"))
            case .idle:
                SettingsStatusLine(tone: .neutral, text: tr("Not connected", "Settings"))
            }
        }
    }

    /// `Found · controller connected · streaming`, or the remote variant.
    static func connectedText(remote: Bool) -> String {
        remote
            ? tr("Remote · controller connected · streaming", "Settings")
            : tr("Found · controller connected · streaming", "Settings")
    }

    /// Why surge-cli cannot run from the chosen path, in the app's language.
    static func message(for problem: SurgeCLIPathProblem) -> String {
        switch problem {
        case .inaccessible(let errno): trf(problem.message, "SurgeCLI", errno.description)
        case .missing, .notAFile, .notExecutable: tr(problem.message, "SurgeCLI")
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

    /// Saves the remote settings (the password to the Keychain) and only then reconnects, so the engine
    /// rebuilds its Surge client from what was just saved.
    private func apply() {
        guard hasChanges else { return }
        model.preferences.surgeRemote = remoteDraft.trimmingCharacters(in: .whitespaces)
        model.preferences.surgeRemoteTag = tagDraft.trimmingCharacters(in: .whitespaces)
        if !passwordDraft.isEmpty {
            Keychain.write(passwordDraft, account: Keychain.surgeRemoteAccount)
            passwordDraft = ""
            hasStoredPassword = true
        }
        remoteDraft = model.preferences.surgeRemote
        tagDraft = model.preferences.surgeRemoteTag
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
        guard panel.runModal() == .OK, let url = panel.url, url.path != model.preferences.surgeCLIPath else { return }
        model.preferences.surgeCLIPath = url.path
        model.capture.reconnect()
    }
}
