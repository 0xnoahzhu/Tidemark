import AppKit
import SwiftUI

/// The Settings window: General, Surge, Database and Notifications tabs.
struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    var body: some View {
        @Bindable var nav = model.nav
        TabView(selection: $nav.settingsTab) {
            Tab(value: SettingsTab.general) {
                SettingsGeneralPane()
            } label: {
                tabLabel(.general)
            }
            Tab(value: SettingsTab.surge) {
                SettingsSurgePane()
            } label: {
                tabLabel(.surge)
            }
            Tab(value: SettingsTab.database) {
                SettingsDatabasePane()
            } label: {
                tabLabel(.database)
            }
            Tab(value: SettingsTab.notifications) {
                SettingsNotificationsPane()
            } label: {
                tabLabel(.notifications)
            }
        }
        .tabViewStyle(.automatic)
        .environment(\.locale, localizer.locale)
    }

    private func tabLabel(_ tab: SettingsTab) -> some View {
        Label {
            Text(SettingsTabIcon.title(tab))
        } icon: {
            Image(nsImage: SettingsTabIcon.image(tab))
                .renderingMode(.original)
        }
    }
}

// MARK: - Shared pieces

/// Fixed pane width; each pane picks its own height so the window resizes between tabs.
enum SettingsLayout {
    static let width: CGFloat = 660
}

/// The design's Settings tab icons: a 26 pt rounded tile in the tab's color holding a white glyph
/// (a dotted ring for General, rising bars for Surge, stacked rows for Database, a bell for Notifications).
///
/// The Settings toolbar shows tab images at 32 pt, so the tile sits centered on a transparent 32 pt canvas
/// to keep the design's 26 pt size and clear the label.
enum SettingsTabIcon {
    /// Canvas the toolbar displays.
    static let canvas: CGFloat = 32
    /// The tile, as in the design.
    static let side: CGFloat = 26
    static let cornerRadius: CGFloat = 7

    @MainActor
    static func title(_ tab: SettingsTab) -> String {
        switch tab {
        case .general: tr("General", "Settings")
        case .surge: String("Surge")
        case .database: tr("Database", "Settings")
        case .notifications: tr("Notifications", "Settings")
        }
    }

    /// Tile color, `oklch` from the design (Notifications has no design tile; it takes an amber one).
    static func tileColor(_ tab: SettingsTab) -> NSColor {
        switch tab {
        case .general: OKLCH.nsColor(0.55, 0.02, 260)
        case .surge: OKLCH.nsColor(0.6, 0.16, 25)
        case .database: OKLCH.nsColor(0.62, 0.14, 240)
        case .notifications: OKLCH.nsColor(0.68, 0.15, 60)
        }
    }

    /// Full-color (non-template) tile image, drawn at whatever scale it is displayed.
    @MainActor
    static func image(_ tab: SettingsTab) -> NSImage {
        if let cached = cache[tab] { return cached }
        let size = NSSize(width: canvas, height: canvas)
        let image = NSImage(size: size, flipped: true) { rect in
            draw(tab, in: rect)
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = title(tab)
        cache[tab] = image
        return image
    }

    @MainActor private static var cache: [SettingsTab: NSImage] = [:]

    /// Draws into a flipped (y-down) canvas using the design's pixel geometry on a 26 × 26 tile.
    private static func draw(_ tab: SettingsTab, in canvasRect: NSRect) {
        let scale = canvasRect.width / canvas
        let inset = (canvas - side) / 2 * scale
        let rect = canvasRect.insetBy(dx: inset, dy: inset)
        func box(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) -> NSRect {
            NSRect(x: rect.minX + x * scale, y: rect.minY + y * scale, width: w * scale, height: h * scale)
        }
        func pill(_ r: NSRect, opacity: CGFloat = 1) {
            NSColor.white.withAlphaComponent(opacity).setFill()
            let radius = min(2 * scale, min(r.width, r.height) / 2)
            NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
        }

        tileColor(tab).setFill()
        NSBezierPath(roundedRect: rect, xRadius: cornerRadius * scale, yRadius: cornerRadius * scale).fill()

        switch tab {
        case .general:
            // 12 pt ring with a 2.5 pt dotted white border: six dots around a 4.75 pt radius.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let radius = 4.75 * scale, dot = 2.5 * scale
            NSColor.white.setFill()
            for index in 0..<6 {
                let angle = CGFloat(index) * .pi / 3 - .pi / 2
                let x = center.x + radius * cos(angle), y = center.y + radius * sin(angle)
                NSBezierPath(ovalIn: NSRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot)).fill()
            }
        case .surge:
            // Three 3 pt bars (6, 11 and 8 pt tall), 2 pt apart, standing 7 pt above the bottom edge.
            for (index, height) in [CGFloat(6), 11, 8].enumerated() {
                pill(box(6.5 + CGFloat(index) * 5, 19 - height, 3, height))
            }
        case .database:
            // Three 12 × 3 pt rows, 2 pt apart, fading 1 → 0.8 → 0.6.
            for (index, opacity) in [CGFloat(1), 0.8, 0.6].enumerated() {
                pill(box(7, 6.5 + CGFloat(index) * 5, 12, 3), opacity: opacity)
            }
        case .notifications:
            let configuration = NSImage.SymbolConfiguration(pointSize: 13 * scale, weight: .semibold)
                .applying(.init(paletteColors: [.white]))
            if let bell = NSImage(systemSymbolName: "bell.fill", accessibilityDescription: nil)?.withSymbolConfiguration(configuration) {
                let glyph = bell.size
                let target = NSRect(x: rect.midX - glyph.width / 2, y: rect.midY - glyph.height / 2, width: glyph.width, height: glyph.height)
                bell.draw(in: target, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
            }
        }
    }
}

/// `● Connected · PostgreSQL 18.3 · 2 ms` status line under a connection field.
struct SettingsStatusLine: View {
    enum Tone { case ok, pending, failed, neutral }

    var tone: Tone
    var text: String
    var detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            StatusDot(color: color, size: 7, pulsing: tone == .pending)
                .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 1 }
            VStack(alignment: .leading, spacing: 2) {
                Text(text)
                    .foregroundStyle(tone == .failed ? Theme.failed : Theme.ink2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail, !detail.isEmpty {
                    Text(detail)
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(2)
                }
            }
        }
        .font(.system(size: 12))
    }

    private var color: Color {
        switch tone {
        case .ok: Theme.live
        case .pending: Theme.warning
        case .failed: Theme.failed
        case .neutral: Theme.ink3
        }
    }
}

/// Secondary explanation under a group (`Every row is tagged with the Mac it came from…`).
struct SettingsNote: View {
    var text: String

    var body: some View {
        Text(text)
            .font(.system(size: 11.5))
            .foregroundStyle(Theme.ink2)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
