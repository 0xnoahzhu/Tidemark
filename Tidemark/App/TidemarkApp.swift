import SwiftUI

@main
struct TidemarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let model = delegate.model

        Window("Tidemark", id: WindowID.main) {
            MainWindowView()
                .environment(model)
                .environment(Localizer.shared)
        }
        .defaultSize(width: 1248, height: 812)
        .windowToolbarStyle(.unified)
        .commands { TidemarkCommands(model: model) }

        Window("Site Probe", id: WindowID.probeBrowser) {
            ProbeBrowserWindow()
                .environment(model)
                .environment(Localizer.shared)
        }
        .defaultSize(width: 1280, height: 860)
        .windowResizability(.contentSize)

        MenuBarExtra {
            MenuBarPanel()
                .environment(model)
                .environment(Localizer.shared)
        } label: {
            MenuBarLabel()
                .environment(model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environment(model)
                .environment(Localizer.shared)
        }
    }
}

/// Scene identifiers for `openWindow(id:)`.
enum WindowID {
    static let main = "main"
    static let probeBrowser = "probe-browser"
}
