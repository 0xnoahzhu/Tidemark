import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var terminating = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppBootstrap.start(model)
    }

    /// Capture keeps running from the menu bar when the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Defers quitting until buffered rows are written, so the last batch is not lost.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        Task { @MainActor [model] in
            await AppBootstrap.stop(model)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
