import AppKit
import Observation

/// Keeps the Dock tile in step with Tidemark's state while Tidemark is in the Dock (`DockPresence`): the light or
/// dark BrandIcon for the system's appearance (the Dock follows System Settings, not Settings › Appearance inside
/// Tidemark), and a badge with the number of unread first-contact alerts. Out of the Dock it follows nothing.
@MainActor
final class DockIconUpdater {
    /// Posted by the system when Light / Dark changes in System Settings.
    static let systemThemeChanged = Notification.Name("AppleInterfaceThemeChangedNotification")

    private let model: AppModel
    private var appearanceObservation: NSKeyValueObservation?
    private var themeObserver: (any NSObjectProtocol)?
    private var stateObservation: ObservationTracking.Token?
    private var isDark: Bool?
    private var darkIcon: NSImage?

    init(model: AppModel) {
        self.model = model
    }

    /// Starts following the appearance and the unread count. Call once the Dock tile is up: it is new each time
    /// Tidemark enters the Dock, so the icon and the badge are written to it again.
    func start() {
        guard stateObservation == nil else { return }
        isDark = nil
        // The app's effective appearance tracks the system while Settings › Appearance is System; the theme
        // notification covers system changes while the app forces Light or Dark.
        appearanceObservation = NSApp.observe(\.effectiveAppearance, options: [.initial, .new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.applySystemAppearance() }
        }
        themeObserver = DistributedNotificationCenter.default().addObserver(forName: Self.systemThemeChanged, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applySystemAppearance() }
        }
        let alerts = model.alerts
        stateObservation = withContinuousObservation(options: [.didSet]) { _ in
            let label = Self.badgeLabel(unread: alerts.unreadCount)
            if NSApp.dockTile.badgeLabel != label { NSApp.dockTile.badgeLabel = label }
        }
    }

    /// Stops following them once Tidemark has left the Dock, and clears the icon and the badge, so the next tile
    /// gets both written afresh.
    func stop() {
        guard stateObservation != nil else { return }
        appearanceObservation?.invalidate()
        appearanceObservation = nil
        if let themeObserver { DistributedNotificationCenter.default().removeObserver(themeObserver) }
        themeObserver = nil
        stateObservation = nil
        isDark = nil
        NSApp.dockTile.badgeLabel = nil
        NSApp.applicationIconImage = nil
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Whether the system (and so the Dock) is dark. While the app follows the system its effective
    /// appearance is the answer; when the app forces Light or Dark, the global `AppleInterfaceStyle`
    /// default (`Dark`, or absent for Light) still tells the system's choice.
    static func systemIsDark(appOverride: NSAppearance?, effective: NSAppearance, interfaceStyle: String?) -> Bool {
        guard appOverride != nil else { return isDark(effective) }
        return interfaceStyle?.caseInsensitiveCompare("Dark") == .orderedSame
    }

    private func applySystemAppearance() {
        let dark = Self.systemIsDark(
            appOverride: NSApp.appearance,
            effective: NSApp.effectiveAppearance,
            interfaceStyle: UserDefaults.standard.string(forKey: "AppleInterfaceStyle")
        )
        applyIcon(dark: dark)
    }

    /// The Dock badge text for an unread count: nil when nothing is unread, `999+` past three digits.
    static func badgeLabel(unread: Int) -> String? {
        guard unread > 0 else { return nil }
        return unread > 999 ? "999+" : String(unread)
    }

    private func applyIcon(dark: Bool) {
        guard dark != isDark else { return }
        isDark = dark
        if dark, darkIcon == nil { darkIcon = Self.brandIcon(dark: true) }
        // The light variant is the bundle icon; restoring it keeps the system's own icon treatments.
        NSApp.applicationIconImage = dark ? darkIcon : nil
    }

    /// Renders one appearance variant of the `BrandIcon` asset into a fixed bitmap.
    static func brandIcon(dark: Bool, pixels: Int = 1024) -> NSImage? {
        guard let source = NSImage(named: "BrandIcon"),
              let appearance = NSAppearance(named: dark ? .darkAqua : .aqua),
              let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels, bitsPerSample: 8,
                                         samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                                         bytesPerRow: 0, bitsPerPixel: 0),
              let context = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = context
        context.imageInterpolation = .high
        // The bitmap context draws in pixels; the rep is sized in points (2x) afterwards.
        appearance.performAsCurrentDrawingAppearance {
            source.draw(in: NSRect(x: 0, y: 0, width: pixels, height: pixels), from: .zero, operation: .copy, fraction: 1)
        }
        NSGraphicsContext.restoreGraphicsState()
        let size = NSSize(width: pixels / 2, height: pixels / 2)
        rep.size = size
        let image = NSImage(size: size)
        image.addRepresentation(rep)
        return image
    }
}
