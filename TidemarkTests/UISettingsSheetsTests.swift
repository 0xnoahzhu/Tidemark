import AppKit
import SwiftUI
import Testing
@testable import Tidemark

/// The Monitor an App sheet at the UI scale, and the app icons its rows show.
@MainActor
struct UISettingsSheetsTests {
    /// Six candidates show before the list scrolls, in the smallest main window at every factor; a screen that cuts
    /// the minimum window shorter than six need gets five.
    @Test func addAppSheetShowsSixRowsInTheSmallestWindow() {
        for factor: CGFloat in [1, 1.2, 1.3, 1.4, 1.5] {
            let minimum = UIScale.minimumWindowSize(factor: factor, visibleSize: nil).height
            #expect(AddAppSheet.visibleRows(minimumWindowHeight: minimum, factor: factor) == 6, "\(factor)")
        }
        #expect(AddAppSheet.visibleRows(minimumWindowHeight: 480, factor: 1) == 5)
        #expect(AddAppSheet.rowHeight == 47.px)
    }

    /// Everything but the rows stays within the sheet's `chromeHeight`, in English and in Chinese: measured while the
    /// list still looks for running apps, which takes one 36 px line.
    @Test func addAppSheetChromeFitsItsAllowance() {
        let defaults = TestDefaults()
        let model = AppModel(preferences: Preferences(defaults: defaults.make()))
        let saved = Localizer.shared.override
        defer { Localizer.shared.override = saved }
        for language in ["en", "zh-Hans"] {
            Localizer.shared.override = language
            let sheet = AddAppSheet()
                .lineHeight(Theme.lineHeight)
                .environment(model)
                .environment(Localizer.shared)
            let size = NSHostingController(rootView: sheet).sizeThatFits(in: CGSize(width: CGFloat.infinity, height: .infinity))
            #expect(size.width == 520.px, "\(language)")
            #expect(size.height - 36.px <= UIScale.length(AddAppSheet.chromeHeight), "\(language): \(size.height)")
        }
    }

    /// An app reached through a symbolic link (/Applications/Safari.app links into Safari's cryptex) shows the app's
    /// own icon, without the alias badge the link's icon carries.
    @Test func appIconsResolveSymbolicLinks() throws {
        let app = "/System/Applications/Calculator.app"
        let folder = FileManager.default.temporaryDirectory.appending(path: "tidemark-icons-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = folder.appending(path: "Calculator.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: URL(fileURLWithPath: app))

        #expect(AppIconCache.resolved(link.path) == URL(fileURLWithPath: app).resolvingSymlinksInPath().path)
        let icon = try #require(AppIconCache().icon(for: link.path))
        let own = try pixels(NSWorkspace.shared.icon(forFile: app))
        #expect(try differing(pixels(icon), own) == 0)
        // The link's own icon has the badge, so the comparison tells them apart.
        #expect(try differing(pixels(NSWorkspace.shared.icon(forFile: link.path)), own) > 100)
    }

    /// The icon drawn into a 64 × 64 pixel bitmap.
    private func pixels(_ image: NSImage) throws -> [UInt8] {
        let side = 64
        let rep = try #require(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side, bitsPerSample: 8,
                                                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                                bytesPerRow: side * 4, bitsPerPixel: 32))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        image.draw(in: NSRect(x: 0, y: 0, width: side, height: side))
        NSGraphicsContext.restoreGraphicsState()
        let data = try #require(rep.bitmapData)
        return Array(UnsafeBufferPointer(start: data, count: side * side * 4))
    }

    /// Bytes of two bitmaps that differ by more than a rounding error.
    private func differing(_ a: [UInt8], _ b: [UInt8]) -> Int {
        zip(a, b).filter { abs(Int($0) - Int($1)) > 24 }.count
    }
}
