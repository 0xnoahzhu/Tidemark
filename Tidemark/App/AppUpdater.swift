import AppKit
import Observation
import Sparkle

/// Updates Tidemark from its GitHub releases with Sparkle.
///
/// With automatic updates on (Settings › General, on by default), Sparkle checks the newest release's `appcast.xml` once
/// a day and downloads a new version by itself; it installs when Tidemark quits, or at once from Install and Relaunch.
/// A newer version is shown as a dot on the sidebar's Settings button and in Settings › General. Check for Updates… (app
/// menu, Settings › General) shows Sparkle's own window.
///
/// Only a Release build that carries Sparkle's EdDSA public key (`SPARKLE_PUBLIC_ED_KEY`) updates itself: a Debug build
/// would replace the copy in DerivedData, and without the key Sparkle cannot verify an update.
@MainActor
@Observable
final class AppUpdater {
    static let shared = AppUpdater()

    /// Whether this build updates itself (Check for Updates… is in the app menu). Set by `start()`; tests set it.
    var isAvailable = false
    /// Whether Sparkle checks once a day and downloads a new version by itself. Sparkle keeps the choice in Tidemark's
    /// defaults.
    private(set) var updatesAutomatically = false
    /// The newer version the last check found (`1.1.0`), until it is installed, skipped or no longer offered.
    private(set) var newVersion: String?
    /// The new version is downloaded and installs when Tidemark quits; `installAndRelaunch()` installs it now.
    private(set) var isReadyToInstall = false

    @ObservationIgnored private var controller: SPUStandardUpdaterController?
    @ObservationIgnored private lazy var delegate = AppUpdaterDelegate(updater: self)
    @ObservationIgnored private var installNow: (() -> Void)?

    func start() {
        #if !DEBUG
        guard controller == nil, !AppDelegate.isTestHost, Self.hasPublicKey(Bundle.main) else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: delegate, userDriverDelegate: delegate)
        self.controller = controller
        // One switch covers both: a check that finds a version also downloads it (1.0.0 kept them apart).
        let updater = controller.updater
        if updater.automaticallyChecksForUpdates != updater.automaticallyDownloadsUpdates {
            updater.automaticallyDownloadsUpdates = updater.automaticallyChecksForUpdates
        }
        updatesAutomatically = updater.automaticallyChecksForUpdates
        isAvailable = true
        #endif
    }

    /// Sparkle's window: checking, then the new version with its notes and Install, or "You're up to date".
    func checkForUpdates() {
        controller?.checkForUpdates(nil)
    }

    /// Installs a downloaded version now and relaunches Tidemark; without one, checks as `checkForUpdates()` does.
    func installAndRelaunch() {
        if let installNow {
            self.installNow = nil
            installNow()
        } else {
            checkForUpdates()
        }
    }

    func setUpdatesAutomatically(_ on: Bool) {
        guard let updater = controller?.updater else { return }
        updater.automaticallyChecksForUpdates = on
        updater.automaticallyDownloadsUpdates = on
        updatesAutomatically = updater.automaticallyChecksForUpdates
    }

    nonisolated static func hasPublicKey(_ bundle: Bundle) -> Bool {
        let key = (bundle.object(forInfoDictionaryKey: "SUPublicEDKey") as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
        return !key.isEmpty
    }

    // MARK: Sparkle's reports (internal for tests)

    func found(_ version: String) {
        if newVersion != version {
            newVersion = version
            isReadyToInstall = false
            installNow = nil
        }
    }

    func foundNothing() {
        newVersion = nil
        isReadyToInstall = false
        installNow = nil
    }

    func ready(_ version: String, install: @escaping () -> Void) {
        newVersion = version
        isReadyToInstall = true
        installNow = install
    }
}

/// Passes Sparkle's reports to `AppUpdater`, lets its relaunch past the "Quit Tidemark?" dialog, and shows a found
/// update without pulling Tidemark (a menu bar app) in front of the app in use. Sparkle calls it on the main thread.
private final class AppUpdaterDelegate: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    private unowned let updater: AppUpdater

    init(updater: AppUpdater) {
        self.updater = updater
    }

    nonisolated func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        let version = item.displayVersionString
        MainActor.assumeIsolated { self.updater.found(version) }
    }

    nonisolated func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { self.updater.foundNothing() }
    }

    nonisolated func updater(_ updater: SPUUpdater, userDidMake choice: SPUUserUpdateChoice, forUpdate updateItem: SUAppcastItem,
                             state: SPUUserUpdateState) {
        guard choice == .skip else { return }
        MainActor.assumeIsolated { self.updater.foundNothing() }
    }

    /// A downloaded update: Tidemark offers Install and Relaunch (Settings › General) instead of Sparkle's window, and
    /// Sparkle installs it when Tidemark quits.
    nonisolated func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem,
                             immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        let version = item.displayVersionString
        // Sparkle hands it over and later expects it called on the main thread, where AppUpdater calls it.
        nonisolated(unsafe) let install = immediateInstallHandler
        MainActor.assumeIsolated { self.updater.ready(version, install: install) }
        return true
    }

    /// Right before Sparkle quits Tidemark to install.
    nonisolated func updaterWillRelaunchApplication(_ updater: SPUUpdater) {
        MainActor.assumeIsolated { AppDelegate.confirmNextQuit() }
    }

    nonisolated var supportsGentleScheduledUpdateReminders: Bool { true }
}
