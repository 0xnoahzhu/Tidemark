import AppKit
import SwiftUI

/// Converts the design's OKLCH colors to sRGB, so tokens match the prototype exactly.
enum OKLCH {
    /// sRGB components (0…1, clamped) for an OKLCH color. `hue` is in degrees.
    static func srgb(l: Double, c: Double, h: Double) -> (r: Double, g: Double, b: Double) {
        let hr = h * .pi / 180
        let a = c * cos(hr), b = c * sin(hr)
        let l_ = l + 0.3963377774 * a + 0.2158037573 * b
        let m_ = l - 0.1055613458 * a - 0.0638541728 * b
        let s_ = l - 0.0894841775 * a - 1.2914855480 * b
        let L = l_ * l_ * l_, M = m_ * m_ * m_, S = s_ * s_ * s_
        let rl = 4.0767416621 * L - 3.3077115913 * M + 0.2309699292 * S
        let gl = -1.2684380046 * L + 2.6097574011 * M - 0.3413193965 * S
        let bl = -0.0041960863 * L - 0.7034186147 * M + 1.7076147010 * S
        func encode(_ x: Double) -> Double {
            let v = x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
            return min(1, max(0, v))
        }
        return (encode(rl), encode(gl), encode(bl))
    }

    static func nsColor(_ l: Double, _ c: Double, _ h: Double, alpha: Double = 1) -> NSColor {
        let (r, g, b) = srgb(l: l, c: c, h: h)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: alpha)
    }
}

extension Color {
    /// `oklch(l c h / alpha)` from the design.
    init(oklch l: Double, _ c: Double, _ h: Double, alpha: Double = 1) {
        let (r, g, b) = OKLCH.srgb(l: l, c: c, h: h)
        self.init(.sRGB, red: r, green: g, blue: b, opacity: alpha)
    }

    /// `#rrggbb`
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  opacity: alpha)
    }

    /// A color that resolves differently in light and dark appearance.
    static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: .dynamic(light: light, dark: dark))
    }
}

extension NSColor {
    /// A color that resolves differently in light and dark appearance.
    static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .vibrantDark, .accessibilityHighContrastDarkAqua]) != nil ? dark : light
        }
    }

    convenience init(hex: UInt32, alpha: Double = 1) {
        self.init(srgbRed: Double((hex >> 16) & 0xff) / 255,
                  green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255,
                  alpha: alpha)
    }

    static func white(_ alpha: Double) -> NSColor { NSColor(srgbRed: 1, green: 1, blue: 1, alpha: alpha) }
    static func black(_ alpha: Double) -> NSColor { NSColor(srgbRed: 0, green: 0, blue: 0, alpha: alpha) }
}
