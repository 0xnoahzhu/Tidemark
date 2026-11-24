import AppKit
import Observation
import Sparkle

/// Updates Tidemark from its GitHub releases with Sparkle: a daily check of the newest release's `appcast.xml`, and
/// Check for Updates… in the app menu.
///
/// Only a Release build that carries Sparkle's EdDSA public key (`SPARKLE_PUBLIC_ED_KEY`) updates itself: a Debug build
/// would replace the copy in DerivedData, and without the key Sparkle cannot verify an update.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Whether this build updates itself (Check for Updates… is in the app menu).
    private(set) var isAvailable = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private let delegate = AppUpdaterDelegate()

    func start() {
        #if !DEBUG
        guard controller == nil, !AppDelegate.isTestHost, Self.hasPublicKey(Bundle.main) else { return }
        controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: delegate)
        isAvailable = true
        #endif
    }

    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    nonisolated static func hasPublicKey(_ bundle: Bundle) -> Bool {
        let key = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return !key.isEmpty
    }
}

/// Lets Sparkle's relaunch past the "Quit Tidemark?" dialog, and shows a found update without pulling Tidemark (a menu
/// bar app) in front of the app in use.
private final class AppUpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Sparkle calls it on the main thread, right before it quits Tidemark.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { AppDelegate.confirmNextQuit() }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
