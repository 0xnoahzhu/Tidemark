#if DEBUG
import AppKit
import SwiftUI

/// Debug-only walk through every screen with real data, rendering each window offscreen to PNG.
///
/// Rendering uses `cacheDisplay`, so it works without Screen Recording access and while the screen is
/// locked (Liquid Glass materials are not captured). Launch a Debug build with:
/// * `-TidemarkDebugTour <directory>` — where the PNGs go; the app quits when the tour ends;
/// * `-TidemarkDebugMonitor "/Applications/A.app,/Applications/B.app"` — monitor these apps first;
/// * `-TidemarkDebugProbe <url>` — also run a real site probe of `url`;
/// * `-TidemarkDebugLanguages en,zh` / `-TidemarkDebugAppearances light,dark` — variants to capture.
@MainActor
enum DebugTour {
    static func runIfRequested(_ model: AppModel) {
        let defaults = UserDefaults.standard
        guard let directory = defaults.string(forKey: "TidemarkDebugTour") else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        Task(name: "debug-tour") {
            await run(model, directory: url)
            AppDelegate.requestQuit()
        }
    }

    private static func run(_ model: AppModel, directory: URL) async {
        let defaults = UserDefaults.standard
        await waitUntil(seconds: 25) { model.live.database.isHealthy && model.live.rows.count > 5 }
        log("database=\(model.live.database) surge=\(model.live.surge) rows=\(model.live.rows.count)")

        for path in (defaults.string(forKey: "TidemarkDebugMonitor") ?? "").split(separator: ",").map(String.init) where !path.isEmpty {
            guard !model.catalog.apps.contains(where: { $0.path == path }) else { continue }
            do {
                let app = try await model.capture.monitorApp(path: path, includeChildren: true, alertOnDomain: true, alertOnIP: true, backfill: true)
                log("monitoring \(app.name)")
            } catch {
                log("monitor \(path) failed: \(error)")
            }
        }
        await pause(4)

        let languages = (defaults.string(forKey: "TidemarkDebugLanguages") ?? "en").split(separator: ",").map(String.init)
        let appearances = (defaults.string(forKey: "TidemarkDebugAppearances") ?? "light").split(separator: ",").map(String.init)
        for language in languages {
            Localizer.shared.override = language == "zh" ? "zh-Hans" : "en"
            for appearance in appearances {
                NSApp.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
                await tour(model, into: directory, prefix: "\(language)-\(appearance)")
            }
        }

        if let probeURL = defaults.string(forKey: "TidemarkDebugProbe") {
            Localizer.shared.override = "en"
            NSApp.appearance = NSAppearance(named: .aqua)
            await probe(model, url: probeURL, into: directory)
        }
        log("tour finished")
    }

    private static func tour(_ model: AppModel, into directory: URL, prefix: String) async {
        let nav = model.nav
        func shot(_ name: String, _ action: () -> Void) async {
            action()
            await pause(2.5)
            snapshotMain(to: directory.appendingPathComponent("\(prefix)-\(name).png"))
        }

        await shot("01-requests-live") { nav.selectedRequest = nil; nav.requestsLive = true; nav.open(.requests) }
        let monitored = model.live.rows.first { $0.appID != nil && $0.chain.count > 1 } ?? model.live.rows.first { $0.appID != nil }
        nav.selectedRequest = (monitored ?? model.live.rows.first(where: { $0.chain.count > 1 }) ?? model.live.rows.first)?.key
        await pause(3)
        await shot("02-requests-inspector") {}
        await shot("03-requests-history") { nav.selectedRequest = nil; nav.requestsLive = false }
        nav.requestsLive = true
        await shot("04-notifications") { nav.open(.notifications) }
        await shot("05-inventory") { nav.open(.inventory) }
        await shot("06-site-probe") { nav.open(.probe) }
        await shot("07-egress") { nav.open(.egress) }
        for (index, app) in model.catalog.active.prefix(3).enumerated() {
            let slug = "08\(Character(UnicodeScalar(97 + index)!))-app-\(app.name.lowercased().replacingOccurrences(of: " ", with: "-"))"
            await shot("\(slug)-requests") { nav.open(.app(app.id), tab: .requests) }
            await shot("\(slug)-inventory") { nav.open(.app(app.id), tab: .inventory) }
            await shot("\(slug)-tree") { nav.open(.app(app.id), tab: .tree) }
        }

        nav.open(.requests)
        nav.openAddApp()
        await pause(3)
        snapshotSheet(to: directory.appendingPathComponent("\(prefix)-09-add-app-sheet.png"))
        nav.showAddApp = false
        await pause(1)

        nav.confirmRecordingToggle = true
        await pause(1.5)
        snapshotMain(to: directory.appendingPathComponent("\(prefix)-10-pause-dialog.png"))
        nav.confirmRecordingToggle = false
        await pause(1)

        StatusItemController.debugShowPanel()
        await pause(2)
        if let panel = StatusItemController.debugPanelWindow {
            snapshot(panel, to: directory.appendingPathComponent("\(prefix)-11-menubar-panel.png"))
        }
        StatusItemController.debugClosePanel()

        openSettings()
        await pause(2)
        for tab in SettingsTab.allCases {
            nav.settingsTab = tab
            await pause(2)
            if let window = settingsWindow() {
                snapshot(window, to: directory.appendingPathComponent("\(prefix)-12-settings-\(tab.rawValue).png"))
            }
        }
        settingsWindow()?.close()
        await pause(1)
    }

    private static func probe(_ model: AppModel, url: String, into directory: URL) async {
        let session = ProbeWebSession.shared
        let ownWindow = model.preferences.probeOwnWindow
        model.preferences.probeOwnWindow = false
        defer { model.preferences.probeOwnWindow = ownWindow }
        model.nav.open(.probe)
        session.urlDraft = url
        do {
            try await session.start(model: model)
        } catch {
            log("probe failed: \(error)")
            return
        }
        await pause(4)
        snapshotMain(to: directory.appendingPathComponent("en-light-13-probe-running.png"))
        await pause(10)
        snapshotMain(to: directory.appendingPathComponent("en-light-14-probe-recording.png"))
        await session.stop(model: model)
        await pause(3)
        snapshotMain(to: directory.appendingPathComponent("en-light-15-probe-completed.png"))
        log("probe hosts=\(model.probe.sessions.first?.hosts.count ?? 0)")
    }

    // MARK: Windows

    private static var mainWindow: NSWindow? {
        NSApp.windows.first { $0.identifier?.rawValue.hasPrefix(WindowID.main) == true && $0.isVisible }
    }

    private static func settingsWindow() -> NSWindow? {
        NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue.localizedCaseInsensitiveContains("settings") == true }
            ?? NSApp.windows.first { $0.isVisible && $0.styleMask.contains(.titled) && $0 !== mainWindow && !$0.isSheet && $0.contentView != nil && $0.frame.width < 1000 }
    }

    private static func openSettings() {
        for item in NSApp.mainMenu?.items.first?.submenu?.items ?? [] where item.keyEquivalent == "," {
            if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
            return
        }
    }

    private static func snapshotMain(to url: URL) {
        guard let window = mainWindow else { log("no main window for \(url.lastPathComponent)"); return }
        snapshot(window, to: url)
    }

    private static func snapshotSheet(to url: URL) {
        guard let sheet = mainWindow?.attachedSheet ?? NSApp.windows.first(where: { $0.isSheet && $0.isVisible }) else {
            log("no sheet for \(url.lastPathComponent)")
            return
        }
        snapshot(sheet, to: url)
    }

    private static func snapshot(_ window: NSWindow, to url: URL) {
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Helpers

    private static func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * 1000)))
    }

    private static func waitUntil(seconds: Double, _ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        while !condition(), ContinuousClock.now < deadline { await pause(0.5) }
    }

    private static func log(_ message: String) {
        FileHandle.standardError.write(Data("[tour] \(message)\n".utf8))
    }
}
#endif
