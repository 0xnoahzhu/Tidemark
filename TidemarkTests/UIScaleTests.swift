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

    @Test func savedFrameIsReplacedOnlyAfterTheFactorChanged() {
        // Versions before the UI scale stored nothing and drew at 1.0.
        #expect(!MainWindowFrame.needsReset(stored: nil, factor: 1))
        #expect(MainWindowFrame.needsReset(stored: nil, factor: 1.3))
        #expect(!MainWindowFrame.needsReset(stored: 1.3, factor: 1.3))
        #expect(MainWindowFrame.needsReset(stored: 1.3, factor: 1.2))
        #expect(MainWindowFrame.needsReset(stored: 1, factor: 1.4))
    }

    @Test func defaultSizeIsTheDesignsWindowWithinTheScreen() {
        let size = MainWindowFrame.defaultSize
        #expect(size.width == min(1248.px, UIScale.launchScreenSize?.width ?? .infinity))
        #expect(size.height == min(812.px, UIScale.launchScreenSize?.height ?? .infinity))
    }

    @Test func savedLayoutKeysAreTheMainWindows() {
        #expect(MainWindowFrame.isSavedLayout("NSWindow Frame main"))
        #expect(MainWindowFrame.isSavedLayout("NSSplitView Subview Frames main, SidebarNavigationSplitView"))
        #expect(!MainWindowFrame.isSavedLayout("NSWindow Frame probe-browser"))
        #expect(!MainWindowFrame.isSavedLayout("NSWindow Frame com_apple_SwiftUI_Settings_window"))
        #expect(!MainWindowFrame.isSavedLayout("window.mainScale"))
    }

    /// A layout saved at another factor is forgotten once; the next one is kept.
    @Test func savedLayoutIsForgottenOnceAfterTheFactorChanged() {
        let defaults = TestDefaults()
        let suite = defaults.make()
        let frame = "40 80 1564 812 0 0 2560 1410 "
        suite.set(frame, forKey: "NSWindow Frame main")
        suite.set(["0, 0, 244, 812, NO, NO"], forKey: "NSSplitView Subview Frames main, SidebarNavigationSplitView")
        suite.set(frame, forKey: "NSWindow Frame probe-browser")
        suite.set(Double(UIScale.factor) + 0.3, forKey: MainWindowFrame.defaultsKey)

        MainWindowFrame.resetIfScaleChanged(defaults: suite)
        #expect(suite.object(forKey: "NSWindow Frame main") == nil)
        #expect(suite.object(forKey: "NSSplitView Subview Frames main, SidebarNavigationSplitView") == nil)
        #expect(suite.string(forKey: "NSWindow Frame probe-browser") == frame)
        #expect(suite.double(forKey: MainWindowFrame.defaultsKey) == Double(UIScale.factor))

        suite.set(frame, forKey: "NSWindow Frame main")
        MainWindowFrame.resetIfScaleChanged(defaults: suite)
        #expect(suite.string(forKey: "NSWindow Frame main") == frame)
    }
}

/// The design's sizes as the views draw them.
@MainActor
struct UIScaleDrawingTests {
    private static func fittingHeight(_ view: some View) -> CGFloat {
        NSHostingView(rootView: view).fittingSize.height
    }

    /// `line-height: 1.35` is a multiple of the font's size, as in CSS, so a single line is taller than SF's own
    /// (about 1.19 of the size) too.
    @Test func lineHeightIsAMultipleOfTheFontSize() {
        let natural = Self.fittingHeight(Text(verbatim: "Requests").font(.design(13)))
        let design = Self.fittingHeight(Text(verbatim: "Requests").font(.design(13)).lineHeight(Theme.lineHeight))
        #expect(design == (13 * UIScale.factor * 1.35).rounded(.up))
        #expect(design > natural)
        let twoLines = Self.fittingHeight(Text(verbatim: "One\nTwo").font(.design(12)).lineHeight(Theme.noteLineHeight))
        #expect(abs(twoLines - 2 * 12 * UIScale.factor * 1.5) <= 1)
    }

    /// Buttons and fields keep the design's heights whatever the line height around them.
    @Test func controlsHaveTheDesignsHeights() {
        let button = Button("Copy as JSON") {}.buttonStyle(DesignButtonStyle())
        #expect(Self.fittingHeight(button) == 28.px)
        #expect(Self.fittingHeight(button.lineHeight(Theme.lineHeight)) == 28.px)
        #expect(Self.fittingHeight(Button("Pause") {}.buttonStyle(DesignButtonStyle(kind: .destructive, height: 30))) == 30.px)
        let field = TextField("Find a Mac", text: .constant("")).designField(height: 26).lineHeight(Theme.lineHeight)
        #expect(Self.fittingHeight(field) == 26.px)
        #expect(Self.fittingHeight(FilterField(prompt: "Search", text: .constant(""), width: 190)) == 28.px)
    }

    /// The title block fits the toolbar's 52 pt band, which does not grow with the UI scale, at every factor.
    @Test func pageTitleFitsTheToolbarAtEveryFactor() {
        let lines: CGFloat = 15 + 11
        let drawn = Self.fittingHeight(PageTitle(title: "Requests", subtitle: "Every request Surge sees"))
        #expect(abs(drawn - (lines * 1.2 * UIScale.factor + 1.px)) <= 1.5)
        let largest = UIScale.range.upperBound
        #expect(lines * 1.2 * largest + UIScale.length(1, factor: largest) <= 52)
    }

    /// A page draws its title in the toolbar, and the window keeps it as its title for the Window menu, Mission
    /// Control and VoiceOver.
    @Test func pageToolbarKeepsTheWindowTitle() async throws {
        let page = Color.clear
            .frame(width: 600, height: 300)
            .pageToolbar("Requests", subtitle: "Every request Surge sees") {
                ToolbarItem(placement: .primaryAction) { Text(verbatim: "Item") }
            }
        let host = NSHostingView(rootView: page)
        host.sceneBridgingOptions = [.toolbars, .title]
        // Never ordered in.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 400), styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        window.contentView = host

        let deadline = ContinuousClock.now + .seconds(5)
        while window.title != "Requests" || window.toolbar == nil, ContinuousClock.now < deadline {
            window.layoutIfNeeded()
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(window.title == "Requests")
        #expect(window.subtitle == "Every request Surge sees")
        let items = try #require(window.toolbar?.items)
        #expect(items.count >= 3, "the title, the room after it and the page's item")
    }
}
