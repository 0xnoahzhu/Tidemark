import AppKit
import Foundation
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
