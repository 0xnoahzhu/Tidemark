import AppKit
import Foundation
import System
import Testing
@testable import Tidemark

@MainActor
@Suite(.serialized)
struct UIChromeTests {
    // MARK: Menu bar glyph

    @Test func glyphStatePriority() {
        let connected = LinkStatus.connected(detail: "")
        #expect(MenuBarGlyph.state(recording: true, surge: connected, unreadAlerts: 0) == .normal)
        #expect(MenuBarGlyph.state(recording: true, surge: connected, unreadAlerts: 3) == .alert)
        #expect(MenuBarGlyph.state(recording: true, surge: .failed(message: "x"), unreadAlerts: 3) == .offline)
        #expect(MenuBarGlyph.state(recording: true, surge: .connecting, unreadAlerts: 0) == .offline)
        #expect(MenuBarGlyph.state(recording: false, surge: .failed(message: "x"), unreadAlerts: 3) == .paused)
    }

    @Test func glyphIsAnEighteenPointTemplate() throws {
        for state in MenuBarGlyph.State.allCases {
            let image = MenuBarGlyph.image(for: state)
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 18, height: 18))
        }
        let normal = try alphaCoverage(MenuBarGlyph.image(for: .normal))
        let paused = try alphaCoverage(MenuBarGlyph.image(for: .paused))
        let alert = try alphaCoverage(MenuBarGlyph.image(for: .alert))
        let offline = try alphaCoverage(MenuBarGlyph.image(for: .offline))
        #expect(normal > 0)
        // Paused is the same shape at 40 % opacity.
        #expect(abs(paused / normal - 0.4) < 0.03)
        // The filled marker covers more than the ring and its dot.
        #expect(alert > normal)
        #expect(offline != paused)
    }

    /// Sum of alpha over a 2x rendering, in pixels.
    private func alphaCoverage(_ image: NSImage) throws -> Double {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 36, pixelsHigh: 36, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        var total = 0.0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                total += Double(rep.colorAt(x: x, y: y)?.alphaComponent ?? 0)
            }
        }
        return total
    }

    // MARK: Dock

    @Test func dockBadgeLabel() {
        #expect(DockIconUpdater.badgeLabel(unread: 0) == nil)
        #expect(DockIconUpdater.badgeLabel(unread: -1) == nil)
        #expect(DockIconUpdater.badgeLabel(unread: 7) == "7")
        #expect(DockIconUpdater.badgeLabel(unread: 1000) == "999+")
    }

    @Test func brandIconVariantsDiffer() throws {
        let light = try #require(DockIconUpdater.brandIcon(dark: false, pixels: 64))
        let dark = try #require(DockIconUpdater.brandIcon(dark: true, pixels: 64))
        let lightRep = try #require(light.representations.first as? NSBitmapImageRep)
        let darkRep = try #require(dark.representations.first as? NSBitmapImageRep)
        // Upper middle of the icon: the sky is light in one variant and dark in the other.
        let a = try #require(lightRep.colorAt(x: 32, y: 18)?.usingColorSpace(.deviceRGB))
        let b = try #require(darkRep.colorAt(x: 32, y: 18)?.usingColorSpace(.deviceRGB))
        #expect(a.brightnessComponent > b.brightnessComponent + 0.2)
        #expect(DockIconUpdater.isDark(try #require(NSAppearance(named: .darkAqua))))
        #expect(!DockIconUpdater.isDark(try #require(NSAppearance(named: .aqua))))
    }

    /// The Dock follows the system: the app's effective appearance while it follows the system too, the
    /// global interface style while Settings › Appearance forces Light or Dark.
    @Test func dockIconFollowsTheSystemAppearance() throws {
        let light = try #require(NSAppearance(named: .aqua))
        let dark = try #require(NSAppearance(named: .darkAqua))
        #expect(DockIconUpdater.systemIsDark(appOverride: nil, effective: dark, interfaceStyle: nil))
        #expect(!DockIconUpdater.systemIsDark(appOverride: nil, effective: light, interfaceStyle: "Dark"))
        // Forced Dark inside Tidemark on a light system keeps the light Dock icon, and the reverse.
        #expect(!DockIconUpdater.systemIsDark(appOverride: dark, effective: dark, interfaceStyle: nil))
        #expect(DockIconUpdater.systemIsDark(appOverride: light, effective: light, interfaceStyle: "Dark"))
    }

    // MARK: Menu bar panel

    @Test func menuBarPanelMatchesTheDesignWidth() {
        #expect(MenuBarPanel.width == 320)
    }

    // MARK: Settings chrome

    @Test func settingsWindowMatchesTheDesignWidth() {
        #expect(SettingsLayout.width == 660)
    }

    /// Each tab icon is a full-color 26 pt tile in the design's color with a white glyph on it, centered on the
    /// toolbar's 32 pt canvas.
    @Test func settingsTabIconsAreColoredTiles() throws {
        for tab in SettingsTab.allCases {
            let image = SettingsTabIcon.image(tab)
            #expect(!image.isTemplate)
            #expect(image.size == NSSize(width: 32, height: 32))
            let rep = try render(image, pixels: 64)
            // Near the left edge, halfway down: the tile color (rendered the same way), no glyph.
            let color = SettingsTabIcon.tileColor(tab)
            let swatch = try render(NSImage(size: image.size, flipped: false) { rect in
                color.setFill()
                rect.fill()
                return true
            }, pixels: 64)
            // 2 pt inside the tile's left edge (3 pt canvas margin), halfway down.
            let tile = try #require(rep.colorAt(x: 10, y: 32))
            let expected = try #require(swatch.colorAt(x: 10, y: 32))
            #expect(abs(tile.redComponent - expected.redComponent) < 0.02, "\(tab) tile red")
            #expect(abs(tile.greenComponent - expected.greenComponent) < 0.02, "\(tab) tile green")
            #expect(abs(tile.blueComponent - expected.blueComponent) < 0.02, "\(tab) tile blue")
            // The margin and the tile's rounded corners are transparent.
            #expect((rep.colorAt(x: 2, y: 32)?.alphaComponent ?? 1) < 0.1, "\(tab) margin")
            #expect((rep.colorAt(x: 7, y: 7)?.alphaComponent ?? 1) < 0.5, "\(tab) corner")
            // Some pixels are white: the glyph.
            var white = 0
            for x in 0..<rep.pixelsWide {
                for y in 0..<rep.pixelsHigh {
                    if let c = rep.colorAt(x: x, y: y), c.redComponent > 0.95, c.greenComponent > 0.95, c.blueComponent > 0.95 {
                        white += 1
                    }
                }
            }
            #expect(white > 20, "\(tab) glyph")
        }
        withLanguage(.chinese) {
            #expect(SettingsTabIcon.title(.database) == "数据库")
            #expect(SettingsTabIcon.title(.surge) == "Surge")
        }
    }

    private func render(_ image: NSImage, pixels: Int) throws -> NSBitmapImageRep {
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8, samplesPerPixel: 4,
                                                hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = image.size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(origin: .zero, size: image.size))
        NSGraphicsContext.restoreGraphicsState()
        return rep
    }

    /// One status line, rebuilt in the current language, local or remote.
    @Test func surgeStatusLine() {
        withLanguage(.english) {
            #expect(SettingsSurgePane.connectedText(remote: false) == "Found · controller connected · streaming")
            #expect(SettingsSurgePane.connectedText(remote: true) == "Remote · controller connected · streaming")
        }
        withLanguage(.chinese) {
            #expect(SettingsSurgePane.connectedText(remote: false) == "已找到 · 控制器已连接 · 正在订阅")
            #expect(SettingsSurgePane.connectedText(remote: true) == "远程 · 控制器已连接 · 正在订阅")
        }
    }

    @Test func surgeCLIPathProblems() {
        withLanguage(.english) {
            #expect(SettingsSurgePane.message(for: .missing) == "No file at this path.")
            #expect(SettingsSurgePane.message(for: .inaccessible(.permissionDenied)).hasPrefix("This path cannot be read: "))
            #expect(!SettingsSurgePane.message(for: .inaccessible(.permissionDenied)).contains("%@"))
        }
        withLanguage(.chinese) {
            #expect(SettingsSurgePane.message(for: .missing) == "此路径下没有文件。")
            #expect(SettingsSurgePane.message(for: .notAFile) == "此路径是文件夹，不是 surge-cli 可执行文件。")
            #expect(SettingsSurgePane.message(for: .notExecutable) == "此文件不可执行。")
            #expect(SettingsSurgePane.message(for: .inaccessible(.permissionDenied)).hasPrefix("无法读取此路径："))
        }
    }

    @Test func ipInfoServiceNames() {
        withLanguage(.english) {
            #expect(SettingsGeneralPane.ipInfoServiceName(.proxycheck) == "proxycheck.io")
            #expect(SettingsGeneralPane.ipInfoServiceName(.off) == "Off")
        }
        withLanguage(.chinese) {
            #expect(SettingsGeneralPane.ipInfoServiceName(.proxycheck) == "proxycheck.io")
            #expect(SettingsGeneralPane.ipInfoServiceName(.off) == "关闭")
        }
    }

    @Test func explainHostsNoteGivesTheReason() {
        withLanguage(.english) {
            #expect(SettingsNotificationsPane.explainHostsNote(available: true, reason: nil).contains("generated on this Mac"))
            #expect(SettingsNotificationsPane.explainHostsNote(available: false, reason: "Model is downloading") == "Model is downloading")
            #expect(SettingsNotificationsPane.explainHostsNote(available: false, reason: nil) == "Apple Intelligence is unavailable on this Mac.")
        }
    }

    // MARK: Commands

    /// File › New Site Probe starts from an empty URL bar with no saved session selected, unless a probe runs.
    @Test func newSiteProbeCommandResetsThePage() {
        let (defaults, suite) = Self.scratchDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(preferences: Preferences(defaults: defaults))
        let web = ProbeWebSession()
        model.probe.selectedID = UUID()
        web.urlDraft = "https://example.com"
        model.nav.open(.requests)
        TidemarkCommands.newSiteProbe(model, web: web)
        #expect(model.probe.selectedID == nil)
        #expect(web.urlDraft.isEmpty)
        #expect(model.nav.page == .probe)
    }

    /// A private defaults suite; remove it with `removePersistentDomain(forName:)` when done.
    static func scratchDefaults() -> (UserDefaults, String) {
        let name = "tidemark-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: Settings helpers

    @Test func mutePatterns() {
        #expect(SettingsMutePattern.normalize("  API.Example.com ") == "api.example.com")
        #expect(SettingsMutePattern.normalize("*.apple.com") == "*.apple.com")
        #expect(SettingsMutePattern.normalize("https://linear.app/team/issue") == "linear.app")
        #expect(SettingsMutePattern.normalize("104.16.98.215") == "104.16.98.215")
        #expect(SettingsMutePattern.normalize("2001:db8::1") == "2001:db8::1")
        #expect(SettingsMutePattern.normalize("example.com.") == "example.com")
        #expect(SettingsMutePattern.normalize("localhost") == "localhost")
        #expect(SettingsMutePattern.normalize("") == nil)
        #expect(SettingsMutePattern.normalize("raycast") == nil)
        #expect(SettingsMutePattern.normalize("two words.com") == nil)
        #expect(SettingsMutePattern.normalize("*.*.example.com") == nil)
        #expect(SettingsMutePattern.normalize("a..b") == nil)
    }

    @Test func databaseURLKeepsThePasswordOut() {
        let split = SettingsDatabaseURL.split("postgresql://tide:s%40cret@127.0.0.1:5432/tidemark")
        #expect(split.url == "postgresql://tide@127.0.0.1:5432/tidemark")
        #expect(split.password == "s@cret")
        let plain = SettingsDatabaseURL.split("postgresql://localhost:5432/tidemark")
        #expect(plain.url == "postgresql://localhost:5432/tidemark")
        #expect(plain.password == nil)
    }

    @Test func databaseFormatting() {
        withLanguage(.english) {
            #expect(SettingsDatabaseFormat.seconds(1) == "1")
            #expect(SettingsDatabaseFormat.seconds(0.5) == "0.5")
            #expect(SettingsDatabaseFormat.batchLabel(.init(rows: 200, interval: 1)) == "200 · 1 s")
            #expect(SettingsDatabaseFormat.retentionLabel(0) == "Forever")
            #expect(SettingsDatabaseFormat.retentionLabel(365) == "1 year")
            #expect(SettingsDatabaseFormat.retentionLabel(1) == "1 day")
            #expect(SettingsDatabaseFormat.retentionLabel(30) == "30 days")
            #expect(SettingsDatabaseFormat.milliseconds(.milliseconds(2)) == 2)
        }
        withLanguage(.chinese) {
            #expect(SettingsDatabaseFormat.batchLabel(.init(rows: 200, interval: 1)) == "200 · 1 秒")
            #expect(SettingsDatabaseFormat.retentionLabel(90) == "90 天")
        }
    }

    @Test func addAppLabels() {
        withLanguage(.english) {
            #expect(AddAppCandidates.backfillLabel(0) == "Nothing recorded yet")
            #expect(AddAppCandidates.backfillLabel(1) == "1 past request")
            #expect(AddAppCandidates.backfillLabel(3204) == "3,204 past requests")
        }
        withLanguage(.chinese) {
            #expect(AddAppCandidates.backfillLabel(3204) == "3,204 条历史请求")
        }
        #expect(AddAppCandidates.normalized("/Applications/Slack.app/") == "/Applications/Slack.app")
        #expect(AddAppCandidates.normalized("/") == "/")
        let finder = AddAppCandidates.candidate(path: "/System/Library/CoreServices/Finder.app", pastRequests: 2)
        #expect(finder.name == "Finder")
        #expect(finder.bundleID == "com.apple.finder")
    }

    // MARK: Localization

    /// Every `tr`/`trf`/`trn` key used by the menu bar, settings, sheets and commands has a zh-Hans translation.
    @Test func everyChromeStringIsTranslated() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sources = ["Tidemark/UI/MenuBar", "Tidemark/UI/Settings", "Tidemark/UI/Sheets", "Tidemark/App/TidemarkCommands.swift"]
        let tables: Set<String> = ["MenuBar", "Settings", "Sheets", "Commands"]
        let bundle = try #require(Bundle.main.path(forResource: "zh-Hans", ofType: "lproj").flatMap(Bundle.init(path:)))
        let sameInBothLanguages: Set<String> = ["Liquid Glass"]

        var checked = 0
        for path in sources {
            for file in swiftFiles(at: root.appending(path: path)) {
                let source = try String(contentsOf: file, encoding: .utf8)
                for (key, table) in Self.localizationKeys(in: source) where tables.contains(table) {
                    let translated = bundle.localizedString(forKey: key, value: "\u{0}", table: table)
                    #expect(translated != "\u{0}", "Missing zh-Hans translation for \"\(key)\" in \(table)")
                    if !sameInBothLanguages.contains(key) {
                        #expect(translated != key, "Untranslated \"\(key)\" in \(table)")
                    }
                    checked += 1
                }
            }
        }
        #expect(checked > 100)
    }

    private func swiftFiles(at url: URL) -> [URL] {
        if url.pathExtension == "swift" { return [url] }
        let items = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return items.filter { $0.pathExtension == "swift" }
    }

    /// `(key, table)` pairs of `tr("…", "T")`, `trf("…", "T", …)` and both keys of `trn("…", "…", n, "T")`.
    static func localizationKeys(in source: String) -> [(String, String)] {
        let string = #""((?:[^"\\]|\\.)*)""#
        var result: [(String, String)] = []
        let single = try! Regex(#"\btrf?\(\s*"# + string + #"\s*,\s*"# + string)
        for match in source.matches(of: single) {
            if let key = match.output[1].substring, let table = match.output[2].substring {
                result.append((String(key).replacingOccurrences(of: "\\\"", with: "\""), String(table)))
            }
        }
        let plural = try! Regex(#"\btrn\(\s*"# + string + #"\s*,\s*"# + string + #"\s*,\s*[^,]+?,\s*"# + string)
        for match in source.matches(of: plural) {
            if let one = match.output[1].substring, let other = match.output[2].substring, let table = match.output[3].substring {
                result.append((String(one), String(table)))
                result.append((String(other), String(table)))
            }
        }
        return result
    }

    private func withLanguage(_ language: Preferences.Language, _ body: () -> Void) {
        let saved = Localizer.shared.preference
        Localizer.shared.preference = language
        body()
        Localizer.shared.preference = saved
    }
}
