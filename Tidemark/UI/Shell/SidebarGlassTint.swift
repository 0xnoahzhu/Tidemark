import AppKit
import SwiftUI

/// Tints the split view's own sidebar glass toward the design's glass color as Settings › General › Liquid Glass
/// moves toward Tinted.
///
/// The page lays `rgba(--glassRGB, max(.42, --glassA))` over a blur for its sidebar. A color laid over the sidebar
/// column in SwiftUI would cover the system's glass, so the color goes on the glass itself, as the
/// `NSGlassEffectView.tintColor` of the sidebar glass that holds the rows, and the system keeps drawing the material,
/// its edges and its inactive state. The untinted system glass stands for the Clear end: there it is left exactly
/// as the system draws it, and above it the tint takes the page's `--glassA` (no floor: the system glass keeps the
/// rows legible on its own).
///
/// Measured on macOS 27.0.1: in an active window the tinted glass shows the color at that alpha (at Tinted, 242,242,246
/// in light mode and 42,42,46 in dark mode, the page's sidebar); in an inactive window the system draws tinted glass
/// desaturated and nearer mid-gray, as it does any tinted glass. The tint stays through appearance changes, key and
/// main changes and hiding and showing the sidebar.
struct SidebarGlassTint: NSViewRepresentable {
    var preference: Double

    /// The tint's alpha for a preference of 0…100: none at the Clear end, the design's `--glassA` above it.
    static func alpha(preference: Double) -> Double? {
        preference > 0 ? GlassSurface.glassAlpha(preference: preference) : nil
    }

    func makeNSView(context: Context) -> SidebarGlassTintAnchor {
        SidebarGlassTintAnchor()
    }

    func updateNSView(_ anchor: SidebarGlassTintAnchor, context: Context) {
        anchor.apply(alpha: Self.alpha(preference: preference))
    }

    static func dismantleNSView(_ anchor: SidebarGlassTintAnchor, coordinator: ()) {
        anchor.restore()
    }
}

/// The invisible marker behind the sidebar's rows; it tints the nearest `NSGlassEffectView` among its ancestors.
final class SidebarGlassTintAnchor: NSView {
    private var alpha: Double?
    private weak var glass: NSGlassEffectView?
    /// The glass's own tint, put back at the Clear end and when the sidebar goes away.
    private var systemTint: NSColor?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { apply(alpha: alpha) }
    }

    /// Tints the enclosing glass with the design's glass color at `alpha`, or gives it back its own tint for `nil`.
    func apply(alpha: Double?) {
        let target = enclosingGlass()
        guard target !== glass || alpha != self.alpha else { return }
        self.alpha = alpha
        guard let target else { return }
        if target !== glass {
            restore()
            glass = target
            systemTint = target.tintColor
        }
        target.tintColor = alpha.map { NSColor(GlassSurface.color).withAlphaComponent($0) } ?? systemTint
    }

    /// Gives the glass back its own tint.
    func restore() {
        glass?.tintColor = systemTint
        glass = nil
    }

    private func enclosingGlass() -> NSGlassEffectView? {
        var view = superview
        while let current = view {
            if let glass = current as? NSGlassEffectView { return glass }
            view = current.superview
        }
        return nil
    }
}
