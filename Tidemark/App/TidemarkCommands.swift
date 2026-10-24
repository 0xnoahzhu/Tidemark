import SwiftUI

/// Menu bar commands: File, View (page shortcuts) and Capture.
struct TidemarkCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Site Probe") { model.nav.open(.probe) }
                .keyboardShortcut("n", modifiers: [.command, .shift])
            Button("Monitor an App…") { model.nav.openAddApp() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
        }
        CommandGroup(before: .sidebar) {
            Button("Requests") { model.nav.open(.requests) }.keyboardShortcut("1")
            Button("Notifications") { model.nav.open(.notifications) }.keyboardShortcut("2")
            Button("Domains & IPs") { model.nav.open(.inventory) }.keyboardShortcut("3")
            Button("Site Probe") { model.nav.open(.probe) }.keyboardShortcut("4")
            Button("Egress IP") { model.nav.open(.egress) }.keyboardShortcut("5")
            Divider()
        }
        CommandMenu("Capture") {
            Button(model.live.recording ? "Pause Recording…" : "Resume Recording…") {
                model.nav.confirmRecordingToggle = true
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            Button("Reconnect to Surge") { model.capture.reconnect() }
        }
    }
}
