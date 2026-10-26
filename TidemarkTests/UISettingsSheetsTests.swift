import AppKit
import SwiftUI
import Testing
@testable import Tidemark

/// The Monitor an App sheet at the UI scale.
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
}
