import AppKit
import SwiftUI
import Testing
@testable import Tidemark

/// Design px become points through one factor: lengths rounded to half a point, fonts unrounded.
struct UIScaleTests {
    @Test func lengthsRoundToHalfAPoint() {
        #expect(UIScale.length(13, factor: 1.3) == 17)     // 16.9
        #expect(UIScale.length(11, factor: 1.3) == 14.5)   // 14.3
        #expect(UIScale.length(28, factor: 1.2) == 33.5)   // 33.6
        #expect(UIScale.length(10, factor: 1.25) == 12.5)
        #expect(UIScale.length(0.2, factor: 1) == 0)
        // Quarter points round away from zero, the same for negative lengths (negative padding).
        #expect(UIScale.length(10.25, factor: 1) == 10.5)
        #expect(UIScale.length(-10.25, factor: 1) == -10.5)
        #expect(UIScale.length(-4.5, factor: 1.4) == -6.5) // -6.3
    }

    @Test func standardFactorKeepsHalfPointLengths() {
        for px: CGFloat in [0, 0.5, 1, 6, 10.5, 14, 30, 320, 1248] {
            #expect(UIScale.length(px, factor: 1) == px)
        }
    }

    @Test func requestedFactorIsClampedToTheRange() {
        let roomy = CGSize(width: 2560, height: 1415)
        #expect(UIScale.resolve(requested: nil, visibleSize: roomy) == UIScale.standard)
        #expect(UIScale.resolve(requested: 1.3, visibleSize: roomy) == 1.3)
        #expect(UIScale.resolve(requested: 2, visibleSize: roomy) == UIScale.range.upperBound)
        #expect(UIScale.resolve(requested: 0.8, visibleSize: roomy) == UIScale.range.lowerBound)
        #expect(UIScale.resolve(requested: 1.4, visibleSize: nil) == 1.4)
    }

    @Test func factorIsLoweredSoTheMinimumWindowFits() {
        // A 14" MacBook Pro: 1470 × 923 visible, less the 52 pt toolbar, so at most 871 / 640 ≈ 1.36.
        let laptop = UIScale.resolve(requested: 1.5, visibleSize: CGSize(width: 1470, height: 923))
        #expect(abs(laptop - 871.0 / 640) < 0.0001)
        #expect(UIScale.resolve(requested: 1.3, visibleSize: CGSize(width: 1470, height: 923)) == 1.3)
        // Width binds: 1200 / 1000.
        #expect(UIScale.resolve(requested: 1.4, visibleSize: CGSize(width: 1200, height: 1000)) == 1.2)
        // Never below the range, even when the unscaled window does not fit.
        #expect(UIScale.resolve(requested: 1.3, visibleSize: CGSize(width: 900, height: 600)) == UIScale.range.lowerBound)
    }

    /// The tests (and their expectations written in `.px`) run at the shipping factor.
    @Test func testHostRunsAtTheStandardFactor() {
        #expect(UIScale.factor == UIScale.standard)
    }

    @Test func pxOfEveryNumberTypeUsesTheFactor() {
        let factor = UIScale.factor
        #expect(14.px == UIScale.length(14, factor: factor))
        #expect(12.5.px == UIScale.length(12.5, factor: factor))
        #expect(CGFloat(10.5).px == UIScale.length(10.5, factor: factor))
        #expect((-4).px == -UIScale.length(4, factor: factor))
    }

    @Test func fontsScaleWithoutRounding() {
        let factor = UIScale.factor
        #expect(Font.design(11.5) == .system(size: 11.5 * factor, weight: .regular))
        #expect(Font.designMono(10.5, .medium) == .system(size: 10.5 * factor, weight: .medium, design: .monospaced))
        #expect(Theme.mono(11) == .designMono(11))
        #expect(NSFont.design(12.5, .semibold).pointSize == 12.5 * factor)
        #expect(NSFont.designMono(11).pointSize == 11 * factor)
    }
}

/// What the factor gives the main window.
struct UIScaleWindowTests {
    /// The app resolves the factor on the main thread before its first window, so the screen clamp applies.
    @Test func factorIsResolvedWithTheScreenAtLaunch() {
        #expect(UIScale.launchScreenSize != nil)
        #expect(UIScale.minimumWindowSize == UIScale.minimumWindowSize(factor: UIScale.factor, visibleSize: UIScale.launchScreenSize))
    }

    @Test func minimumWindowScalesAndFitsTheScreen() {
        let roomy = CGSize(width: 2560, height: 1415)
        #expect(UIScale.minimumWindowSize(factor: 1, visibleSize: roomy) == CGSize(width: 1000, height: 640))
        #expect(UIScale.minimumWindowSize(factor: 1.3, visibleSize: roomy) == CGSize(width: 1300, height: 832))
        #expect(UIScale.minimumWindowSize(factor: 1.4, visibleSize: nil) == CGSize(width: 1400, height: 896))
        // The highest factor a 14" MacBook Pro allows rounds to a length no larger than its screen.
        let laptop = CGSize(width: 1470, height: 923)
        let fitted = UIScale.minimumWindowSize(factor: UIScale.resolve(requested: 1.5, visibleSize: laptop), visibleSize: laptop)
        #expect(fitted.width <= laptop.width && fitted.height <= laptop.height)
        #expect(fitted.height + UIScale.windowChromeHeight <= laptop.height)
        // A screen smaller than the unscaled window gets a window as large as the screen.
        #expect(UIScale.minimumWindowSize(factor: 1, visibleSize: CGSize(width: 900, height: 600)) == CGSize(width: 900, height: 548))
    }
}
