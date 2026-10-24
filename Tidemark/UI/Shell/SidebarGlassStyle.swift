import AppKit
import SwiftUI

/// Maps the "Liquid Glass" preference (Settings › General, 0 = Clear … 100 = Tinted) onto the sidebar.
///
/// The prototype paints the sidebar with `rgba(glassRGB, max(.42, .16 + .76·g))` over a `14 + 26·g` px blur.
/// On macOS 27 the split view sidebar already floats as system Liquid Glass, so the low end keeps that glass
/// clear and the high end lays an increasingly opaque tint of the glass color over it, which is how the
/// system's own Clear ↔ Tinted appearance setting reads. Controls placed on the sidebar use `glass`, which
/// moves from `Glass.clear` to a tinted `Glass.regular` along the same scale.
struct SidebarGlassStyle: Equatable {
    /// Normalized preference, 0…1.
    var amount: Double

    init(preference: Double) {
        amount = min(1, max(0, preference / 100))
    }

    /// The prototype's background alpha, `max(.42, .16 + .76·g)`.
    var designOpacity: Double { max(0.42, 0.16 + 0.76 * amount) }

    /// The prototype's backdrop blur in points, `14 + 26·g`.
    var designBlur: Double { 14 + 26 * amount }

    /// Below this amount the sidebar keeps the system's clear glass untouched.
    static let clearThreshold = 0.2

    var isClear: Bool { amount < Self.clearThreshold }

    /// Opacity of the tint wash laid over the system sidebar glass.
    ///
    /// The system glass already contributes roughly the prototype's minimum (.42), so only the part of the
    /// design opacity above that floor is added, rescaled so 100 reaches a frosted but still translucent sidebar.
    var washOpacity: Double {
        guard !isClear else { return 0 }
        let floor = 0.42
        let excess = max(0, (0.16 + 0.76 * amount) - floor)
        return min(0.62, excess / (0.92 - floor) * 0.62)
    }

    /// Strength of the tint handed to `Glass.tint(_:)` for glass controls on the sidebar.
    var glassTintOpacity: Double { isClear ? 0 : 0.16 + 0.6 * amount }

    /// Glass for controls drawn on the sidebar (Mac picker, status footer).
    var glass: Glass {
        isClear ? .clear : .regular.tint(Self.glassColor.opacity(glassTintOpacity))
    }

    /// The prototype's `--glassRGB`: 242,242,246 in light mode, 40,40,44 in dark mode.
    static let glassColor = Color.dynamic(
        light: NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 246 / 255, alpha: 1),
        dark: NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 44 / 255, alpha: 1)
    )
}
