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
        // The unit tests run inside this app (TEST_HOST); they must never start capture against the real
        // Surge and database.
        guard !Self.isTestHost else { return }
        AppBootstrap.start(model)
    }

    static var isTestHost: Bool { ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil }

    /// Capture keeps running from the menu bar when the window closes.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Set by a quit that needs no confirmation (`requestQuit(confirmed: true)`).
    private static var quitConfirmed = false

    /// Quits from a run-loop block rather than from the caller's job. `applicationShouldTerminate` defers
    /// to a main-actor task, which cannot run while `terminate` is nested inside another main-queue job
    /// (for example a `Task` on the main actor), so calling `terminate` directly from there would hang.
    /// `confirmed` skips the "Quit Tidemark?" dialog, for a quit nobody asked for at the keyboard.
    static func requestQuit(confirmed: Bool = false) {
        RunLoop.main.perform {
            MainActor.assumeIsolated {
                if confirmed { quitConfirmed = true }
                NSApp.terminate(nil)
            }
        }
    }

    /// Asks before quitting, because nothing is recorded while Tidemark is not running, then defers quitting until
    /// buffered rows are written, so the last batch is not lost. A logout, restart or shutdown quits without asking,
    /// so Tidemark never holds them up.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        let reason = NSAppleEventManager.shared().currentAppleEvent?.attributeDescriptor(forKeyword: AEKeyword(kAEQuitReason))?.enumCodeValue
        if !Self.isTestHost, !Self.quitConfirmed, !Self.isSystemQuit(reason: reason), !Self.confirmQuit() {
            return .terminateCancel
        }
        terminating = true
        Task { @MainActor [model] in
            await AppBootstrap.stop(model)
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Whether the quit Apple event's reason (`kAEQuitReason`) is the system logging out, restarting or shutting down.
    nonisolated static func isSystemQuit(reason: OSType?) -> Bool {
        guard let reason else { return false }
        let system = [kAELogOut, kAEReallyLogOut, kAEShowRestartDialog, kAEShowShutdownDialog, kAERestart, kAEShutDown]
        return system.map { OSType($0) }.contains(reason)
    }

    /// "Quit Tidemark?": Cancel is the default and Escape's button, so only a click on Quit quits.
    private static func confirmQuit() -> Bool {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = tr("Quit Tidemark?", "Shell")
        alert.informativeText = tr("While Tidemark isn't running, requests Surge handles aren't saved to PostgreSQL and no new-site alerts fire.", "Shell")
        let cancel = alert.addButton(withTitle: tr("Cancel", "Shell"))
        cancel.keyEquivalent = "\r"
        let quit = alert.addButton(withTitle: tr("Quit", "Shell"))
        quit.keyEquivalent = ""
        quit.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
