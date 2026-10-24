import AppKit
import SwiftUI

/// Design tokens of the "Three-pane · Native" direction (`nativeLight` / `nativeDark` in the prototype).
/// Every token adapts to the effective appearance.
enum Theme {
    // Surfaces
    static let bg = Color.dynamic(light: NSColor(hex: 0xffffff), dark: NSColor(hex: 0x1f1f21))
    static let bg2 = Color.dynamic(light: NSColor(hex: 0xf3f3f6), dark: NSColor(hex: 0x29292c))
    static let bg3 = Color.dynamic(light: NSColor(hex: 0xf5f5f7), dark: NSColor(hex: 0x19191b))
    static let card = Color.dynamic(light: NSColor(hex: 0xffffff), dark: NSColor(hex: 0x262629))
    static let zebra = Color.dynamic(light: NSColor(hex: 0xfafafb), dark: .white(0.025))
    /// Background of rows that just arrived / unread notifications.
    static let fresh = Color.dynamic(light: OKLCH.nsColor(0.95, 0.04, 235), dark: OKLCH.nsColor(0.33, 0.06, 245))
    static let segment = Color.dynamic(light: NSColor(hex: 0xffffff), dark: NSColor(hex: 0x5b5b60))

    // Text
    static let ink = Color.dynamic(light: NSColor(hex: 0x1d1d1f), dark: NSColor(hex: 0xf2f2f4))
    static let ink2 = Color.dynamic(light: NSColor(hex: 0x6e6e73), dark: NSColor(hex: 0xa3a3a9))
    static let ink3 = Color.dynamic(light: NSColor(hex: 0xa1a1a6), dark: NSColor(hex: 0x6e6e74))
    /// Secondary text on the glass sidebar.
    static let inkGlass = Color.dynamic(light: NSColor(hex: 0x55555b), dark: NSColor(hex: 0xbabac1))
    static let amberInk = Color.dynamic(light: NSColor(hex: 0x7a4b00), dark: OKLCH.nsColor(0.86, 0.12, 80))

    // Lines and fills
    static let line = Color.dynamic(light: .black(0.09), dark: .white(0.09))
    static let fill = Color.dynamic(light: .black(0.055), dark: .white(0.07))
    static let fill2 = Color.dynamic(light: .black(0.09), dark: .white(0.12))
    /// Track of a switched-off toggle.
    static let off = Color.dynamic(light: .black(0.14), dark: .white(0.18))

    // Accent
    static let accent = Color.dynamic(light: OKLCH.nsColor(0.56, 0.13, 240), dark: OKLCH.nsColor(0.66, 0.14, 245))
    static let accentTint = Color.dynamic(light: OKLCH.nsColor(0.56, 0.13, 240, alpha: 0.13), dark: OKLCH.nsColor(0.66, 0.14, 245, alpha: 0.22))
    static let accentInk = Color.dynamic(light: OKLCH.nsColor(0.45, 0.13, 240), dark: OKLCH.nsColor(0.8, 0.1, 240))
    static let onAccent = Color.white
    static let onAccent2 = Color.white.opacity(0.75)

    // Status
    static let failed = Color(oklch: 0.64, 0.19, 27)
    static let live = Color(hex: 0x30d158)
    static let recording = Color(hex: 0xff453a)
    static let warning = Color(hex: 0xff9f0a)
    static let unreadBadge = Color(oklch: 0.62, 0.2, 27)
    static let newBadge = Color(oklch: 0.8, 0.14, 75)
    static let newBadgeInk = Color(hex: 0x3d2a00)

    // Sidebar glyph tiles
    static let tileRequests = Color(oklch: 0.62, 0.14, 240)
    static let tileNotifications = Color(oklch: 0.62, 0.16, 25)
    static let tileInventory = Color(oklch: 0.62, 0.12, 195)
    static let tileProbe = Color(oklch: 0.6, 0.14, 295)
    static let tileEgress = Color(oklch: 0.62, 0.14, 150)
    /// Tile of processes that are not monitored.
    static let tileNeutral = Color(oklch: 0.7, 0.006, 260)

    /// The design's `tint(h)`: a translucent background and a readable foreground for a hue.
    static func tint(_ hue: Double) -> (background: Color, foreground: Color) {
        (
            Color.dynamic(light: OKLCH.nsColor(0.6, 0.13, hue, alpha: 0.14), dark: OKLCH.nsColor(0.72, 0.12, hue, alpha: 0.2)),
            Color.dynamic(light: OKLCH.nsColor(0.44, 0.12, hue), dark: OKLCH.nsColor(0.84, 0.1, hue))
        )
    }

    /// Hue of a policy chip, as in the design: DIRECT green, REJECT red, AI groups purple, other proxies blue.
    static func policyHue(_ policyPath: [String]) -> Double {
        guard let first = policyPath.first else { return 240 }
        let upper = first.uppercased()
        if upper == "DIRECT" { return 150 }
        if upper.hasPrefix("REJECT") { return 27 }
        if upper.hasPrefix("AI") { return 295 }
        return 240
    }

    /// Fill of an app tile with the given hue (`oklch(0.6 0.15 h)`), or neutral grey.
    static func tileColor(hue: Double?) -> Color {
        guard let hue else { return tileNeutral }
        return Color(oklch: 0.6, 0.15, hue)
    }

    /// Device dot color (`oklch(0.62 0.14 h)`).
    static func deviceColor(hue: Double) -> Color { Color(oklch: 0.62, 0.14, hue) }

    // Typography
    static let body = Font.system(size: 13)
    static let small = Font.system(size: 12)
    static let caption = Font.system(size: 11)
    static let sectionLabel = Font.system(size: 11, weight: .semibold)
    static let title = Font.system(size: 15, weight: .bold)
    static func mono(_ size: CGFloat = 12, weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
