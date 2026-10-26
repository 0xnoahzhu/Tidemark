import SwiftUI

@main
struct TidemarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    init() {
        TableRowHeightDefaults.register()
        UIScale.resolveAtLaunch()
    }

    var body: some Scene {
        let model = delegate.model

        // Each window's root sets the design's line height, so every text, sheet and dialog in it has it.
        Window("Tidemark", id: WindowID.main) {
            MainWindowView()
                .lineHeight(Theme.lineHeight)
                .environment(model)
                .environment(Localizer.shared)
                .modifier(TidemarkIntentsWindowBridge())
        }
        .defaultSize(width: 1248, height: 812)
        .windowToolbarStyle(.unified)
        .commands { TidemarkCommands(model: model) }

        Window(Text(verbatim: tr("Site Probe", "SiteProbe")), id: WindowID.probeBrowser) {
            ProbeBrowserWindow()
                .lineHeight(Theme.lineHeight)
                .environment(model)
                .environment(Localizer.shared)
        }
        .defaultSize(width: 1280, height: 860)
        .windowResizability(.contentSize)

        // The menu bar item is AppKit-owned (`StatusItemController`) to use the macOS 27 status item
        // expanded-interface session; the composition root installs it.

        Settings {
            SettingsView()
                .lineHeight(Theme.lineHeight)
                .environment(model)
                .environment(Localizer.shared)
                .modifier(TidemarkIntentsWindowBridge())
        }
    }
}

/// Scene identifiers for `openWindow(id:)`.
enum WindowID {
    static let main = "main"
    static let probeBrowser = "probe-browser"
}
