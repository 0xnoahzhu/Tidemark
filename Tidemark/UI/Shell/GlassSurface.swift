import AppKit
import SwiftUI

/// The design's frosted surfaces and how the "Liquid Glass" preference (Settings › General, 0 = Clear …
/// 100 = Tinted) colors them.
///
/// The page paints each surface with `rgba(--glassRGB, max(floor, --glassA))` over a backdrop blur, where
/// `--glassA = .16 + .76·g`: the floor keeps text legible at the Clear end, and each surface has its own. Tidemark
/// lays the same color at the same opacity over the system's Liquid Glass, which provides the blur.
///
/// The main window's sidebar is not one of them: a color laid over its full-height system glass would flatten it,
/// so the same color tints that glass itself instead (`SidebarGlassTint`).
enum GlassSurface {
    /// The menu bar panel: `max(.85, glassA)`. The page's panel is at least .6 over a backdrop blur; over the
    /// system's Liquid Glass and a dark desktop, .6 leaves its gray labels hard to read in light mode.
    case panel
    /// The sidebar's Mac menu: `max(.88, glassA)`.
    case menu
    /// The pause / resume recording dialog: `max(.6, glassA)`.
    case dialog
    /// The Stop monitoring / Monitor again dialog: `max(.85, glassA)`.
    case appDialog
    /// The Settings window: `max(.72, glassA)`.
    case settings

    /// The opacity the surface never goes below.
    var floor: Double {
        switch self {
        case .panel: 0.85
        case .menu: 0.88
        case .dialog: 0.6
        case .appDialog: 0.85
        case .settings: 0.72
        }
    }

    /// The design's `--glassA` for a preference of 0…100: `.16 + .76·g`.
    static func glassAlpha(preference: Double) -> Double {
        0.16 + 0.76 * min(1, max(0, preference / 100))
    }

    /// Opacity of `color` on this surface for a preference of 0…100.
    func opacity(preference: Double) -> Double {
        max(floor, Self.glassAlpha(preference: preference))
    }

    /// This surface's tint, laid over the system glass.
    func tint(preference: Double) -> Color {
        Self.color.opacity(opacity(preference: preference))
    }

    /// The design's `--glassRGB`: 242,242,246 in light mode, 40,40,44 in dark mode.
    static let color = Color.dynamic(
        light: NSColor(srgbRed: 242 / 255, green: 242 / 255, blue: 246 / 255, alpha: 1),
        dark: NSColor(srgbRed: 40 / 255, green: 40 / 255, blue: 44 / 255, alpha: 1)
    )
}
