import AppKit
import SwiftUI

/// The one factor every design length and type size is drawn at.
///
/// The design is measured in CSS px; the app draws each px as `factor` points, so the whole UI grows or shrinks
/// together. Lengths are rounded to half a point, which stays on the pixel grid at 2x; type sizes are not rounded.
/// The factor is resolved once, before the first window, and never changes while the app runs, so AppKit code,
/// static widths and SwiftUI views all see the same number. Hairlines, opacities and system chrome do not scale.
enum UIScale {
    /// The factor the app ships with.
    static let standard: CGFloat = 1.0
    /// The factors the app can be drawn at.
    static let range: ClosedRange<CGFloat> = 1.0...1.5
    /// The main window's minimum content size in design px; a factor whose scaled minimum does not fit the screen is
    /// lowered.
    static let minimumWindow = CGSize(width: 1000, height: 640)
    /// What the window adds above its content, in points at every factor: the toolbar's band.
    static let windowChromeHeight: CGFloat = 52
    /// The tallest toolbar item, in points at every factor: the glass capsule an item sits in.
    static let toolbarItemHeight: CGFloat = 36

    /// The factor in use: `standard`, or in Debug builds the `-TidemarkUIScale 1.3` launch argument, clamped to
    /// `range` and lowered to fit the main screen.
    static let factor: CGFloat = resolve(requested: requestedFactor, visibleSize: launchScreenSize)

    /// The main screen's visible size when the factor was resolved; nil if that was off the main thread or without a
    /// screen, when the factor is not fitted to the screen.
    static let launchScreenSize: CGSize? = mainScreenVisibleSize

    /// Resolves `factor` on the main thread, where the screen is known, so the clamp to the screen always applies.
    /// The app calls it before it builds its first window; every later read gets the same value.
    @MainActor
    static func resolveAtLaunch() {
        _ = factor
    }

    /// The main window's minimum content size in points: `minimumWindow` at the factor, never larger than the screen
    /// leaves below the toolbar.
    static let minimumWindowSize = minimumWindowSize(factor: factor, visibleSize: launchScreenSize)

    /// `minimumWindow` at `factor`, cut to `visibleSize` less the toolbar where the screen is smaller: a screen too
    /// small even at the lowest factor, which `resolve` never goes below, or the half point a rounded length can add.
    static func minimumWindowSize(factor: CGFloat, visibleSize: CGSize?) -> CGSize {
        var size = CGSize(width: length(minimumWindow.width, factor: factor), height: length(minimumWindow.height, factor: factor))
        if let visibleSize, visibleSize.width > 0, visibleSize.height > windowChromeHeight {
            size.width = min(size.width, visibleSize.width)
            size.height = min(size.height, visibleSize.height - windowChromeHeight)
        }
        return size
    }

    /// `px` design px in points at the current factor.
    static func length(_ px: CGFloat) -> CGFloat {
        length(px, factor: factor)
    }

    /// `px` design px in points at `factor`, rounded to half a point.
    static func length(_ px: CGFloat, factor: CGFloat) -> CGFloat {
        (px * factor * 2).rounded() / 2
    }

    /// The factor for a `requested` one (nil for `standard`) on a screen whose visible frame is `visibleSize` (nil
    /// when unknown): within `range`, and no larger than lets the scaled minimum window, with its toolbar, fit the
    /// screen.
    static func resolve(requested: CGFloat?, visibleSize: CGSize?) -> CGFloat {
        var result = min(max(requested ?? standard, range.lowerBound), range.upperBound)
        if let visibleSize, visibleSize.width > 0, visibleSize.height > windowChromeHeight {
            let fitting = min(visibleSize.width / minimumWindow.width, (visibleSize.height - windowChromeHeight) / minimumWindow.height)
            result = max(range.lowerBound, min(result, fitting))
        }
        return result
    }

    private static var requestedFactor: CGFloat? {
        #if DEBUG
        let value = UserDefaults.standard.double(forKey: "TidemarkUIScale")
        return value > 0 ? CGFloat(value) : nil
        #else
        return nil
        #endif
    }

    /// The main screen's visible frame, read on the main thread (where the first window asks for the factor).
    private static var mainScreenVisibleSize: CGSize? {
        guard Thread.isMainThread else { return nil }
        return MainActor.assumeIsolated { NSScreen.main?.visibleFrame.size }
    }
}

extension Int {
    /// This many design px in points: `14.px`.
    var px: CGFloat { UIScale.length(CGFloat(self)) }
}

extension Double {
    /// This many design px in points: `12.5.px`.
    var px: CGFloat { UIScale.length(CGFloat(self)) }
}

extension CGFloat {
    /// This many design px in points.
    var px: CGFloat { UIScale.length(self) }
}

extension Font {
    /// The system font at a design size in px: `.design(12, .semibold)`.
    static func design(_ px: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: px * UIScale.factor, weight: weight)
    }

    /// The monospaced system font at a design size in px.
    static func designMono(_ px: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: px * UIScale.factor, weight: weight, design: .monospaced)
    }
}

extension NSFont {
    /// The system font at a design size in px, for AppKit views and text measurement.
    static func design(_ px: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .systemFont(ofSize: px * UIScale.factor, weight: weight)
    }

    /// The monospaced system font at a design size in px.
    static func designMono(_ px: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        .monospacedSystemFont(ofSize: px * UIScale.factor, weight: weight)
    }
}
