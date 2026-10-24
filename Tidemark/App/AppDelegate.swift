import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()
    private var terminating = false

    /// App Intents resolve `@Dependency AppModel`; register it before the system can run an intent or
    /// entity query that launched Tidemark.
    func applicationWillFinishLaunching(_ notification: Notification) {
        TidemarkIntents.register(model: model)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppBootstrap.start(model)
    }

    /// Capture keeps running from the menu bar when the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quits from a run-loop block rather than from the caller's job. `applicationShouldTerminate` defers
    /// to a main-actor task, which cannot run while `terminate` is nested inside another main-queue job
    /// (for example a `Task` on the main actor), so calling `terminate` directly from there would hang.
    static func requestQuit() {
        RunLoop.main.perform {
            MainActor.assumeIsolated { NSApp.terminate(nil) }
        }
    }

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
