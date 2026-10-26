import AppKit
import Foundation
import SwiftUI
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
        #expect(MenuBarGlyph.state(recording: true, surge: .failed(CaptureSurgeFailure.stoppedStreaming), unreadAlerts: 3) == .offline)
        #expect(MenuBarGlyph.state(recording: true, surge: .connecting, unreadAlerts: 0) == .offline)
        #expect(MenuBarGlyph.state(recording: false, surge: .failed(CaptureSurgeFailure.stoppedStreaming), unreadAlerts: 3) == .paused)
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

    /// The egress IP and its policy chip stay inside the room the 320 pt panel leaves next to the "Egress"
    /// label, even for a full-length IPv6 address and a long policy name: IPv4 and short IPv6 addresses share
    /// one line with the chip, a full-length IPv6 address moves the chip to a second line.
    @Test func egressValueNeverRunsPastThePanel() {
        let available = CGSize(width: 230, height: 200)
        let policy = ["AI", "AT&T-RackNerd-Hysteria2"]
        func size(_ ip: String) -> CGSize {
            NSHostingController(rootView: MenuBarEgressValue(ip: ip, policyPath: policy)).sizeThatFits(in: available)
        }
        for ip in ["2001:0db8:85a3:0000:0000:8a2e:0370:7334", "2a01:4f8:c17:1234::1", "255.255.255.255", "—"] {
            #expect(size(ip).width <= available.width, "\(ip)")
        }
        let oneLine = size("255.255.255.255").height
        #expect(oneLine < 24)
        #expect(size("2a01:4f8:c17:1234::1").height == oneLine)
        #expect(size("2001:0db8:85a3:0000:0000:8a2e:0370:7334").height > oneLine + 10)
    }

    // MARK: Settings chrome

    /// 660 × 590 with the toolbar, as in the design: the panes leave room for the toolbar a preference-style
    /// window with labelled 32 pt tab icons has (measured on a window that is never shown).
    @Test func settingsWindowMatchesTheDesignSize() {
        #expect(SettingsLayout.width == 660)
        #expect(SettingsLayout.paneHeight + SettingsLayout.toolbarHeight == 590)

        @MainActor final class Tabs: NSObject, NSToolbarDelegate {
            let ids = SettingsTab.allCases.map { NSToolbarItem.Identifier(String(describing: $0)) }
            func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
            func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
            func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { ids }
            func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                         willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
                let item = NSToolbarItem(itemIdentifier: id)
                item.label = id.rawValue
                item.image = SettingsTabIcon.image(.general)
                return item
            }
        }
        let tabs = Tabs()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: SettingsLayout.width, height: SettingsLayout.paneHeight),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let toolbar = NSToolbar(identifier: "settings-size-test")
        toolbar.delegate = tabs
        window.toolbar = toolbar
        window.toolbarStyle = .preference
        #expect(window.frame.height - window.contentLayoutRect.height == SettingsLayout.toolbarHeight)
        withExtendedLifetime(tabs) {}
    }

    /// The window's glass is at least 72 % opaque, as in the design, and follows the Liquid Glass slider above that.
    @Test func settingsGlassFollowsTheSlider() {
        #expect(SettingsWindowGlass.opacity(0) == 0.72)
        #expect(SettingsWindowGlass.opacity(40) == 0.72)
        #expect(abs(SettingsWindowGlass.opacity(80) - 0.768) < 1e-9)
        #expect(abs(SettingsWindowGlass.opacity(100) - 0.92) < 1e-9)
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

    /// One status line, rebuilt in the current language.
    @Test func surgeStatusLine() {
        withLanguage(.english) {
            #expect(SettingsSurgePane.connectedText == "Found · controller connected · streaming")
        }
        withLanguage(.chinese) {
            #expect(SettingsSurgePane.connectedText == "已找到 · 控制器已连接 · 正在订阅")
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

    // MARK: Commands

    /// File › New Site Probe starts from an empty URL bar with no saved session selected, unless a probe runs.
    @Test func newSiteProbeCommandResetsThePage() {
        let (defaults, suite) = Self.scratchDefaults()
        defer { TestDefaults.remove(suite) }
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

    /// A private defaults suite; remove it with `TestDefaults.remove(_:)` when done.
    static func scratchDefaults() -> (UserDefaults, String) {
        let name = "tidemark-tests-\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    // MARK: Settings helpers

    /// The URL field is saved as typed, password included, and the preference keeps it that way. Capture connects
    /// to it unless `TIDEMARK_DATABASE_URL` overrides it.
    @Test func databaseURLIsKeptWithItsPassword() {
        let (defaults, suite) = Self.scratchDefaults()
        defer { TestDefaults.remove(suite) }
        let preferences = Preferences(defaults: defaults)
        preferences.databaseURL = "postgres://tide:s%40cret@db.example:5455/tidemark"
        #expect(defaults.string(forKey: "db.url") == "postgres://tide:s%40cret@db.example:5455/tidemark")
        #expect(Preferences(defaults: defaults).databaseURL == "postgres://tide:s%40cret@db.example:5455/tidemark")
        if ProcessInfo.processInfo.environment["TIDEMARK_DATABASE_URL"]?.isEmpty ?? true {
            #expect(preferences.connectionURL == preferences.databaseURL)
        }
    }

    /// The field shows the saved password as a mask, and the mask left in place (or what is left of it) keeps it,
    /// whatever else changed.
    @Test func databaseURLMasksThePassword() throws {
        let saved = "postgresql://tide:s%40cret@127.0.0.1:5432/tidemark"
        let masked = SettingsDatabaseURL.masked(saved)
        #expect(masked == "postgresql://tide:••••••••@127.0.0.1:5432/tidemark")
        #expect(SettingsDatabaseURL.unmasked(masked, saved: saved) == saved)
        #expect(SettingsDatabaseURL.unmasked("postgresql://tide:••••••••@10.1.2.52:5455/tidemark", saved: saved)
                == "postgresql://tide:s%40cret@10.1.2.52:5455/tidemark")
        #expect(SettingsDatabaseURL.unmasked("postgres://tide:•••@127.0.0.1:5432/tidemark", saved: saved)
                == "postgres://tide:s%40cret@127.0.0.1:5432/tidemark", "an edited mask")
        #expect(SettingsDatabaseURL.masked("POSTGRES://tide:pw@h/db") == "POSTGRES://tide:••••••••@h/db", "schemes ignore case")
        // Only the password's own place is masked: the same text anywhere else stays, and is saved as it was.
        let echoed = "postgres://tide:tidemark@h/tidemark?application_name=tidemark"
        #expect(SettingsDatabaseURL.masked(echoed) == "postgres://tide:••••••••@h/tidemark?application_name=tidemark")
        #expect(SettingsDatabaseURL.unmasked("postgres://tide:••••••••@h2/tidemark?application_name=tidemark", saved: echoed)
                == "postgres://tide:tidemark@h2/tidemark?application_name=tidemark")

        // A typed password, or none, is saved as typed.
        #expect(SettingsDatabaseURL.unmasked("postgres://tide:new@h/db", saved: saved) == "postgres://tide:new@h/db")
        #expect(SettingsDatabaseURL.unmasked("postgres://tide@h/db", saved: saved) == "postgres://tide@h/db")
        #expect(SettingsDatabaseURL.masked("postgres://tide@h/db") == "postgres://tide@h/db")
        // A mask with no saved password to stand for is dropped.
        #expect(SettingsDatabaseURL.unmasked("postgres://tide:••••••••@h/db", saved: "postgres://tide@h/db") == "postgres://tide@h/db")

        // A password holding an "@" is masked whole and comes back the same.
        let at = "postgres://tide:se@cret@h/db"
        #expect(SettingsDatabaseURL.masked(at) == "postgres://tide:••••••••@h/db")
        let restored = try #require(SettingsDatabaseURL.unmasked(SettingsDatabaseURL.masked(at), saved: at))
        #expect(try PostgresConnectionURL(restored).password == "se@cret")

        // The field left as shown gives back the saved URL exactly, whatever its encoding, so nothing is saved and
        // nothing reconnects; an edit elsewhere keeps the password's own encoding.
        for unedited in ["postgres://tide:a%21b@h/db", at, "postgres://tide:pw@h/my db?password=a=b"] {
            #expect(SettingsDatabaseURL.unmasked(SettingsDatabaseURL.masked(unedited), saved: unedited) == unedited, "\(unedited)")
        }
        #expect(SettingsDatabaseURL.unmasked("postgres://tide:••••••••@h2/db", saved: "postgres://tide:a%21b@h/db") == "postgres://tide:a%21b@h2/db")
        #expect(SettingsDatabaseURL.unmasked("postgres://h2/db?password=••••••••", saved: "postgres://h/db?password=a%21b")
                == "postgres://h2/db?password=a%21b")

        // Without a user name the mask still round-trips.
        let userless = "postgresql://:pw@localhost:5432/tidemark"
        #expect(SettingsDatabaseURL.masked(userless) == "postgresql://:••••••••@localhost:5432/tidemark")
        #expect(SettingsDatabaseURL.unmasked(SettingsDatabaseURL.masked(userless), saved: userless) == userless)
        #expect(SettingsDatabaseURL.unmasked("postgresql://:••••••••@localhost:5432/tidemark", saved: "postgresql://localhost:5432/tidemark")
                == "postgresql://localhost:5432/tidemark")
    }

    /// libpq's `password` parameter is masked where it is too, and the other parameters keep their encoding.
    @Test func databaseURLMasksAPasswordParameter() throws {
        let saved = "postgres://tide@127.0.0.1:5432/tidemark?password=s%26cret&sslmode=require"
        let masked = SettingsDatabaseURL.masked(saved)
        #expect(masked == "postgres://tide@127.0.0.1:5432/tidemark?password=••••••••&sslmode=require")
        #expect(SettingsDatabaseURL.unmasked(masked, saved: saved) == saved)
        #expect(SettingsDatabaseURL.masked("postgres://h/db?PASSWORD=a&password=b") == "postgres://h/db?PASSWORD=••••••••&password=••••••••")

        let encoded = "postgres://h/d?sslrootcert=/a%20b/c+d.pem&password=x"
        #expect(SettingsDatabaseURL.masked(encoded) == "postgres://h/d?sslrootcert=/a%20b/c+d.pem&password=••••••••")
        #expect(SettingsDatabaseURL.unmasked(SettingsDatabaseURL.masked(encoded), saved: encoded) == encoded)
        let userInfo = "postgres://tide:s%40cret@h/d?sslrootcert=/a%20b/c+d.pem"
        #expect(SettingsDatabaseURL.unmasked(SettingsDatabaseURL.masked(userInfo), saved: userInfo) == userInfo)

        // Each mask stands for the saved password of its own place, or the other one, encoded for where it is.
        let both = "postgres://me:mine@h/db?password=other"
        #expect(SettingsDatabaseURL.masked(both) == "postgres://me:••••••••@h/db?password=••••••••")
        #expect(SettingsDatabaseURL.unmasked(SettingsDatabaseURL.masked(both), saved: both) == both)
        // A password typed in one place replaces the saved one, as it would be used: the mask in the other is dropped.
        let typedParameter = try #require(SettingsDatabaseURL.unmasked("postgres://tide:••••••••@h/db?password=new", saved: both))
        #expect(typedParameter == "postgres://tide@h/db?password=new")
        #expect(try PostgresConnectionURL(typedParameter).password == "new")
        #expect(SettingsDatabaseURL.unmasked("postgres://me:new@h/db?password=••••••••", saved: both) == "postgres://me:new@h/db")
        #expect(SettingsDatabaseURL.unmasked("postgres://h/db?password=••••••••&password=new", saved: both) == "postgres://h/db?password=new")
        let moved = try #require(SettingsDatabaseURL.unmasked("postgres://tide@h/db?password=••••••••", saved: "postgres://tide:a&b=c@h/db"))
        #expect(try PostgresConnectionURL(moved).password == "a&b=c")
        let movedBack = try #require(SettingsDatabaseURL.unmasked("postgres://tide:••••••••@h/db", saved: "postgres://tide@h/db?password=x%2Fy%3Az"))
        #expect(try PostgresConnectionURL(movedBack).password == "x/y:z")
        #expect(SettingsDatabaseURL.unmasked("postgres://h/db?password=••••••••&sslmode=require", saved: "postgres://h/db")
                == "postgres://h/db?sslmode=require")
    }

    /// libpq's `sslpassword`, the client key's passphrase, is masked too, and its mask stands only for the saved one.
    @Test func databaseURLMasksTheSSLPassword() {
        let saved = "postgres://tide:pw@h/db?sslpassword=k%26p&sslmode=require"
        #expect(SettingsDatabaseURL.masked(saved) == "postgres://tide:••••••••@h/db?sslpassword=••••••••&sslmode=require")
        #expect(SettingsDatabaseURL.unmasked("postgres://tide:••••••••@h2/db?sslpassword=••••••••&sslmode=require", saved: saved)
                == "postgres://tide:pw@h2/db?sslpassword=k%26p&sslmode=require")
        #expect(SettingsDatabaseURL.unmasked("postgres://tide:••••••••@h/db?SSLPASSWORD=•••", saved: "postgres://tide:pw@h/db")
                == "postgres://tide:pw@h/db", "never the password")
        #expect(SettingsDatabaseURL.unmasked("postgres://tide:••••••••@h/db?sslpassword=new", saved: saved)
                == "postgres://tide:pw@h/db?sslpassword=new", "a typed passphrase keeps the saved password")
        #expect(SettingsDatabaseURL.unmasked("postgres://tide:new@h/db?sslpassword=••••••••", saved: saved)
                == "postgres://tide:new@h/db?sslpassword=k%26p", "a typed password keeps the saved passphrase")
    }

    /// Text that is not a PostgreSQL URL is never saved: it may hold a password the field cannot find.
    @Test func databaseURLRefusesOtherText() {
        for text in ["tide:secret@127.0.0.1:5432/tidemark", "127.0.0.1:5432/tidemark", "host=db password=secret dbname=tidemark",
                     "http://tide:secret@db/tidemark", "not a url", ""] {
            #expect(SettingsDatabaseURL.unmasked(text, saved: "postgres://tide:pw@h/db") == nil, "\(text)")
        }
        #expect(SettingsDatabaseURL.masked("tide@127.0.0.1:5432/tidemark") == "tide@127.0.0.1:5432/tidemark")
    }

    @Test func databaseFormatting() {
        withLanguage(.english) {
            #expect(SettingsDatabaseFormat.seconds(1) == "1")
            #expect(SettingsDatabaseFormat.seconds(0.5) == "0.5")
            #expect(SettingsDatabaseFormat.batchLabel(.init(rows: 200, interval: 1)) == "200 · 1 s")
            #expect(SettingsDatabaseFormat.batchNote(.init(rows: 200, interval: 1)) == "Every 200 rows or 1 second, whichever comes first")
            #expect(SettingsDatabaseFormat.batchNote(.init(rows: 100, interval: 0.5)) == "Every 100 rows or 0.5 seconds, whichever comes first")
            #expect(SettingsDatabaseFormat.milliseconds(.milliseconds(2)) == 2)
        }
        withLanguage(.chinese) {
            #expect(SettingsDatabaseFormat.batchLabel(.init(rows: 200, interval: 1)) == "200 · 1 秒")
            #expect(SettingsDatabaseFormat.batchNote(.init(rows: 200, interval: 1)) == "每 200 行或每 1 秒写一次，先到为准")
        }
    }

    /// The Language pop-up offers English and 简体中文; following the system shows the language in use.
    @Test func languagePopUpShowsTheLanguageInUse() {
        #expect(SettingsGeneralPane.shownLanguage(.system, isChinese: false) == .english)
        #expect(SettingsGeneralPane.shownLanguage(.system, isChinese: true) == .chinese)
        #expect(SettingsGeneralPane.shownLanguage(.english, isChinese: true) == .english)
        #expect(SettingsGeneralPane.shownLanguage(.chinese, isChinese: false) == .chinese)
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
        let finderPath = "/System/Library/CoreServices/Finder.app"
        let finder = AddAppCandidates.candidate(path: finderPath, pastRequests: 2)
        // Finder's display name, the one the Requests table and the sidebar use ("访达" on a Chinese system).
        #expect(finder.name == AppNaming.displayName(forBundlePath: finderPath))
        #expect(!finder.name.isEmpty && !finder.name.hasSuffix(".app"))
        #expect(finder.bundleID == "com.apple.finder")
        #expect(finder.pastRequests == 2)
    }

    /// Running apps are listed under their bundle's display name, not the process's ("Code" for Visual Studio
    /// Code), and sorted by it.
    @Test func addAppCandidatesUseTheBundleDisplayName() {
        let running = [
            AppCandidate(name: "Code", path: "/Applications/Visual Studio Code (Tidemark Test).app", bundleID: "com.microsoft.VSCode", pastRequests: 12),
            AppCandidate(name: "Zed", path: "/Applications/Alpha Editor (Tidemark Test).app", bundleID: nil, pastRequests: 0),
        ]
        let named = AddAppCandidates.named(running)
        #expect(named.map(\.name) == ["Alpha Editor (Tidemark Test)", "Visual Studio Code (Tidemark Test)"])
        #expect(named.map(\.pastRequests) == [0, 12])
        #expect(named.last?.bundleID == "com.microsoft.VSCode")
        #expect(named.first?.path == "/Applications/Alpha Editor (Tidemark Test).app")
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
