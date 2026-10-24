import AppKit
import SwiftUI

/// The menu bar glyph (the "dots" variant of the design's `MenuGlyph`): a dashed threshold, a rising
/// line of dots and a marker circle, drawn as an 18 × 18 pt template image.
enum MenuBarGlyph {
    enum State: String, CaseIterable, Sendable {
        /// Recording, Surge connected, nothing unread.
        case normal
        /// Recording is paused (40 % opacity).
        case paused
        /// Unread first-contact alerts (the marker circle is filled).
        case alert
        /// Surge is not connected (40 % opacity with a diagonal strike).
        case offline
    }

    static let size = NSSize(width: 18, height: 18)

    /// Picks the state shown in the menu bar. Paused wins over offline, offline over alert.
    static func state(recording: Bool, surge: LinkStatus, unreadAlerts: Int) -> State {
        if !recording { return .paused }
        if !surge.isHealthy { return .offline }
        if unreadAlerts > 0 { return .alert }
        return .normal
    }

    @MainActor
    static func state(for model: AppModel) -> State {
        state(recording: model.live.recording, surge: model.live.surge, unreadAlerts: model.alerts.unreadCount)
    }

    /// Template image for `state`; AppKit tints it for the menu bar's appearance.
    @MainActor
    static func image(for state: State) -> NSImage {
        if let cached = cache[state] { return cached }
        let image = NSImage(size: size, flipped: true) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            draw(state, in: rect, context: context)
            return true
        }
        image.isTemplate = true
        cache[state] = image
        return image
    }

    @MainActor private static var cache: [State: NSImage] = [:]

    /// Draws the glyph into a flipped (y-down) context, using percentages of the design's 100 × 100 box.
    private static func draw(_ state: State, in rect: CGRect, context: CGContext) {
        let w = rect.width, h = rect.height
        func box(_ x: Double, _ y: Double, _ bw: Double, _ bh: Double) -> CGRect {
            CGRect(x: rect.minX + w * x / 100, y: rect.minY + h * y / 100, width: w * bw / 100, height: h * bh / 100)
        }

        context.saveGState()
        context.setAlpha(state == .paused || state == .offline ? 0.4 : 1)
        context.beginTransparencyLayer(auxiliaryInfo: nil)
        context.setFillColor(NSColor.black.cgColor)

        // Dashed threshold line.
        for x in [4.0, 19, 34] {
            let pill = box(x, 27.5, 9, 7)
            context.addPath(CGPath(roundedRect: pill, cornerWidth: pill.height / 2, cornerHeight: pill.height / 2, transform: nil))
        }
        // Rising line of samples.
        for (x, y) in [(5.5, 71.5), (23.5, 65.5), (41.5, 47.5), (81.5, 40.5)] {
            context.addEllipse(in: box(x, y, 13, 13))
        }
        context.fillPath()

        // Marker: a ring with a center dot, or a filled circle when something new arrived.
        let marker = box(50, 13, 36, 36)
        if state == .alert {
            context.fillEllipse(in: marker)
        } else {
            let ring = CGMutablePath()
            ring.addEllipse(in: marker)
            ring.addEllipse(in: marker.insetBy(dx: w * 0.08, dy: h * 0.08))
            context.addPath(ring)
            context.fillPath(using: .evenOdd)
            context.fillEllipse(in: box(61.5, 24.5, 13, 13))
        }

        if state == .offline {
            // A bar from bottom-left to top-right across the whole glyph.
            let center = CGPoint(x: rect.midX, y: rect.midY)
            let bar = box(-4, 45.5, 108, 9)
            var transform = CGAffineTransform(translationX: center.x, y: center.y)
                .rotated(by: -35 * .pi / 180)
                .translatedBy(x: -center.x, y: -center.y)
            context.addPath(CGPath(roundedRect: bar, cornerWidth: bar.height / 2, cornerHeight: bar.height / 2, transform: &transform))
            context.fillPath()
        }

        context.endTransparencyLayer()
        context.restoreGState()
    }
}

/// SwiftUI rendering of the menu bar glyph for the current model state (used by `MenuBarExtra` hosts and previews).
struct MenuBarLabel: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Image(nsImage: MenuBarGlyph.image(for: MenuBarGlyph.state(for: model)))
            .accessibilityLabel(MenuBarStatusText.accessibilityLabel(for: MenuBarGlyph.state(for: model), unread: model.alerts.unreadCount))
    }
}

/// Short state descriptions shared by the status item tooltip, its accessibility label and the panel header.
@MainActor
enum MenuBarStatusText {
    static func accessibilityLabel(for state: MenuBarGlyph.State, unread: Int) -> String {
        switch state {
        case .normal: "Tidemark · " + tr("Recording", "MenuBar")
        case .paused: "Tidemark · " + tr("Paused", "MenuBar")
        case .offline: "Tidemark · " + tr("Surge is not connected", "MenuBar")
        case .alert: "Tidemark · " + trn("%lld new alert", "%lld new alerts", unread, "MenuBar")
        }
    }
}
