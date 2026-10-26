import AppKit
import SwiftUI

/// Menu bar commands: File, View (page shortcuts) and Capture.
struct TidemarkCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            CommandsWindowButton(title: tr("New Site Probe", "Commands"), key: "n", modifiers: [.command, .shift]) {
                Self.newSiteProbe(model)
            }
            CommandsWindowButton(title: tr("Monitor an App…", "Commands"), key: "m", modifiers: [.command, .shift]) {
                model.nav.openAddApp()
            }
        }
        CommandGroup(before: .sidebar) {
            CommandsWindowButton(title: tr("Requests", "Commands"), key: "1") { model.nav.open(.requests) }
            CommandsWindowButton(title: tr("Notifications", "Commands"), key: "2") { model.nav.open(.notifications) }
            CommandsWindowButton(title: tr("Domains & IPs", "Commands"), key: "3") { model.nav.open(.inventory) }
            CommandsWindowButton(title: tr("Site Probe", "Commands"), key: "4") { model.nav.open(.probe) }
            CommandsWindowButton(title: tr("Egress IP", "Commands"), key: "5") { model.nav.open(.egress) }
            Divider()
        }
        CommandMenu(tr("Capture", "Commands")) {
            CommandsWindowButton(
                title: model.live.recording ? tr("Pause Recording…", "Commands") : tr("Resume Recording…", "Commands"),
                key: "r", modifiers: [.command, .shift]
            ) {
                model.nav.confirmRecordingToggle = true
            }
            Button(tr("Reconnect to Surge", "Commands")) { model.capture.reconnect() }
        }
    }

    /// Like the page's New Probe button: an empty URL bar and no saved session selected. A running probe
    /// is left alone; the page then shows it.
    @MainActor
    static func newSiteProbe(_ model: AppModel, web: ProbeWebSession = .shared) {
        if !model.probe.isRunning, !web.isStarting {
            model.probe.selectedID = nil
            web.urlDraft = ""
        }
        model.nav.open(.probe)
    }
}

/// A menu item that performs `action`, then activates Tidemark and brings the main window forward, reopening it
/// if it was closed: the page, sheet or confirmation it sets up lives there.
private struct CommandsWindowButton: View {
    @Environment(\.openWindow) private var openWindow
    var title: String
    var key: KeyEquivalent
    var modifiers: EventModifiers = .command
    var action: () -> Void

    var body: some View {
        Button(title) {
            action()
            NSApp.activate()
            openWindow(id: WindowID.main)
        }
        .keyboardShortcut(key, modifiers: modifiers)
    }
}
