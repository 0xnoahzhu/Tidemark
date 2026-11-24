import Foundation
import Testing
@testable import Tidemark

@MainActor
struct AppUpdaterTests {
    /// A found version shows until it is installed, skipped or no longer offered; a downloaded one installs once, from
    /// Install and Relaunch.
    @Test func followsWhatSparkleReports() {
        let updater = AppUpdater()
        #expect(updater.newVersion == nil && !updater.isReadyToInstall)

        updater.found("1.1.0")
        #expect(updater.newVersion == "1.1.0" && !updater.isReadyToInstall)

        var installs = 0
        updater.ready("1.1.0") { installs += 1 }
        #expect(updater.isReadyToInstall)
        updater.installAndRelaunch()
        updater.installAndRelaunch()
        #expect(installs == 1, "the downloaded version installs once")

        // A newer version than the downloaded one waits for its own download.
        updater.ready("1.1.0") { installs += 1 }
        updater.found("1.2.0")
        #expect(updater.newVersion == "1.2.0" && !updater.isReadyToInstall)
        updater.installAndRelaunch()
        #expect(installs == 1)

        updater.foundNothing()
        #expect(updater.newVersion == nil && !updater.isReadyToInstall)
    }

    @Test func describesTheUpdateInSettings() {
        Localizer.shared.override = "en"
        let updater = AppUpdater()
        #expect(SettingsGeneralPane.updateNote(updater, versionAndBuild: "Version 1.0.0 (21)") == "This build does not update itself.")
        updater.isAvailable = true
        #expect(SettingsGeneralPane.updateNote(updater, versionAndBuild: "Version 1.0.0 (21)") == "Version 1.0.0 (21)")
        updater.found("1.1.0")
        #expect(SettingsGeneralPane.updateNote(updater, versionAndBuild: "") == "Version 1.1.0 is available.")
        updater.ready("1.1.0") {}
        #expect(SettingsGeneralPane.updateNote(updater, versionAndBuild: "") == "Version 1.1.0 is ready to install.")
    }
}
