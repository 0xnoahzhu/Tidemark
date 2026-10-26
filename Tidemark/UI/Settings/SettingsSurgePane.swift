import AppKit
import SwiftUI
import System
import UniformTypeIdentifiers

/// Settings › Surge: the surge-cli executable and the event subscription.
struct SettingsSurgePane: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    /// The subscription as the design shows it.
    static let subscriptionCommand = "$ surge-cli --raw watch request"

    var body: some View {
        SettingsPage {
            SettingsGroup(title: tr("surge-cli location", "Settings")) {
                HStack(spacing: 8.px) {
                    Text(model.preferences.surgeCLIPath)
                        .font(Theme.mono(11.5))
                        .lineLimit(1)
                        .truncationMode(.head)
                        .textSelection(.enabled)
                        .help(model.preferences.surgeCLIPath)
                        .settingsField()
                    // As tall as the field beside it.
                    Button(tr("Choose…", "Settings"), action: chooseCLI)
                        .buttonStyle(DesignButtonStyle(height: 30))
                        .fixedSize()
                }
                status
            }

            SettingsGroup(title: tr("Subscription", "Settings")) {
                Text(verbatim: Self.subscriptionCommand)
                    .font(Theme.mono(12))
                    .foregroundStyle(Color(oklch: 0.88, 0.08, 165))
                    .textSelection(.enabled)
                    .padding(.horizontal, 12.px)
                    .padding(.vertical, 10.px)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(oklch: 0.2, 0.01, 250), in: RoundedRectangle(cornerRadius: 9.px, style: .continuous))
                SettingsNote(text: tr("Each event arrives as one line of JSON. Tidemark reads the process, its parent, host, remote IP, policy and rule, then writes the row. If the stream drops, it reconnects and carries on.", "Settings"))
            }
        }
    }

    // MARK: Status

    /// One line, built from state at render time so it follows the language.
    @ViewBuilder
    private var status: some View {
        if let problem = SurgeCLIPathProblem(checking: model.preferences.surgeCLIPath) {
            SettingsStatusLine(tone: .failed, text: Self.message(for: problem))
        } else {
            switch model.live.surge {
            case .connected:
                SettingsStatusLine(tone: .ok, text: Self.connectedText)
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

    /// `Found · controller connected · streaming`
    static var connectedText: String {
        tr("Found · controller connected · streaming", "Settings")
    }

    /// Why surge-cli cannot run from the chosen path, in the app's language.
    static func message(for problem: SurgeCLIPathProblem) -> String {
        switch problem {
        case .inaccessible(let errno): trf(problem.message, "SurgeCLI", errno.description)
        case .missing, .notAFile, .notExecutable: tr(problem.message, "SurgeCLI")
        }
    }

    // MARK: Actions

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
