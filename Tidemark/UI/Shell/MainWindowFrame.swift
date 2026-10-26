import Foundation

/// The main window's default size, and a one-time return to it after the UI scale changed.
///
/// AppKit restores the window frame and sidebar width it saved, which override the scene's default size and the
/// sidebar's ideal width, so a window last used at another factor would open at its old size in points around
/// content drawn larger or smaller. When the factor differs from the one stored with the frame, the saved frame and
/// split view sizes are forgotten before the window is built, and the window opens at the default size, centered.
/// Versions before the UI scale drew at 1.0, which a missing value stands for.
///
/// The stored factor is the one asked for (`UIScale.requested`), not the one fitted to the screen, so a Mac that
/// launches the app on a screen too small for that factor and then on a larger one keeps its frame both times; AppKit
/// fits a restored frame to the screen it opens on.
enum MainWindowFrame {
    static let defaultsKey = "window.mainScale"
    /// The design's window, in design px.
    static let designSize = CGSize(width: 1248, height: 812)

    /// The default size in points at the UI scale, no larger than the screen.
    static var defaultSize: CGSize {
        var size = CGSize(width: designSize.width.px, height: designSize.height.px)
        if let screen = UIScale.launchScreenSize, screen.width > 0, screen.height > 0 {
            size.width = min(size.width, screen.width)
            size.height = min(size.height, screen.height)
        }
        return size
    }

    /// Whether a window last sized at `stored` (nil when no factor was stored) needs the default frame at `factor`.
    static func needsReset(stored: Double?, factor: CGFloat) -> Bool {
        abs(CGFloat(stored ?? 1) - factor) > 0.001
    }

    /// AppKit's saved layout of the main window: its frame (`NSWindow Frame main`) and the sizes of its split views'
    /// columns (`NSSplitView Subview Frames main, …`).
    static func isSavedLayout(_ key: String) -> Bool {
        key == "NSWindow Frame \(WindowID.main)" || key.hasPrefix("NSSplitView Subview Frames \(WindowID.main),")
    }

    /// Forgets the main window's saved layout if it was saved at another factor, and stores the factor asked for.
    /// The app calls it before it builds its first window.
    static func resetIfScaleChanged(defaults: UserDefaults = .standard) {
        let stored = defaults.object(forKey: defaultsKey) as? Double
        defaults.set(Double(UIScale.requested), forKey: defaultsKey)
        guard needsReset(stored: stored, factor: UIScale.requested) else { return }
        for key in defaults.dictionaryRepresentation().keys where isSavedLayout(key) {
            defaults.removeObject(forKey: key)
        }
    }
}
