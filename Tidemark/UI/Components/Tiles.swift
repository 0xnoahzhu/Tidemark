import AppKit
import SwiftUI

/// App tile: the real app icon when the bundle exists on this Mac, otherwise the design's letter tile.
struct AppTile: View {
    var identity: AppIdentity
    var size: CGFloat = 20
    /// Greys the tile out (archived app, or not installed on the selected Mac).
    var dimmed = false

    var body: some View {
        Group {
            if let icon = AppIconCache.shared.icon(for: identity.bundlePath) {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: size, height: size)
            } else {
                LetterTile(letter: identity.letter, color: Theme.tileColor(hue: identity.hue), size: size)
            }
        }
        .saturation(dimmed ? 0 : 1)
        .opacity(dimmed ? 0.5 : 1)
        .accessibilityLabel(identity.name)
    }
}

extension AppTile {
    init(app: MonitoredApp, size: CGFloat = 20, dimmed: Bool = false) {
        self.init(identity: AppIdentity(name: app.name, bundlePath: app.path, letter: app.tileLetter, hue: app.tileHue, isMonitored: true, appID: app.id), size: size, dimmed: dimmed)
    }
}

/// Rounded square with a single white letter (`C` for Cursor).
struct LetterTile: View {
    var letter: String
    var color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Text(letter.prefix(1).uppercased())
                    .font(.system(size: size * 0.52, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}

/// Sidebar destination glyph: an SF Symbol on a colored rounded square.
struct GlyphTile: View {
    var systemName: String
    var color: Color
    var size: CGFloat = 20

    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.3, style: .continuous)
            .fill(color)
            .frame(width: size, height: size)
            .overlay {
                Image(systemName: systemName)
                    .font(.system(size: size * 0.5, weight: .bold))
                    .foregroundStyle(.white)
            }
    }
}

/// Caches app icons by bundle path; returns nil when the bundle is not on this Mac.
@MainActor
final class AppIconCache {
    static let shared = AppIconCache()
    private var cache: [String: NSImage] = [:]
    private var missing: Set<String> = []

    func icon(for bundlePath: String?) -> NSImage? {
        guard let raw = bundlePath, !raw.isEmpty else { return nil }
        let path = raw.hasSuffix("/") ? String(raw.dropLast()) : raw
        if let hit = cache[path] { return hit }
        if missing.contains(path) { return nil }
        guard path.hasSuffix(".app"), FileManager.default.fileExists(atPath: path) else {
            missing.insert(path)
            return nil
        }
        let image = NSWorkspace.shared.icon(forFile: path)
        cache[path] = image
        return image
    }
}
