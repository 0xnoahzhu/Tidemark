import AppKit
import SwiftUI

/// Policy capsule (`Proxy › HK-01`, `DIRECT`, `AI › US-West`) tinted by policy group.
struct PolicyChip: View {
    var policyPath: [String]
    var maxWidth: CGFloat? = nil

    var body: some View {
        if policyPath.isEmpty {
            // Surge reports the policy only after the connection is set up.
            Text("—").font(.design(11)).foregroundStyle(Theme.ink3)
        } else {
            chip
        }
    }

    /// The group hops stay readable; when space runs out the final policy is shortened from its start
    /// (`AI › …RackNerd-Hysteria2`), so both the group and the end of the policy name remain visible.
    private var chip: some View {
        let tint = Theme.tint(Theme.policyHue(policyPath))
        return HStack(spacing: 0) {
            if policyPath.count > 1 {
                Text(policyPath.dropLast().joined(separator: " › ") + " › ")
                    .lineLimit(1)
                    .layoutPriority(1)
            }
            Text(policyPath.last ?? "")
                .lineLimit(1)
                .truncationMode(.head)
        }
        .font(.design(11, .medium))
        .padding(.horizontal, 6.px)
        .frame(height: 18.px)
        .background(tint.background, in: RoundedRectangle(cornerRadius: 5.px, style: .continuous))
        .foregroundStyle(tint.foreground)
        .frame(maxWidth: maxWidth, alignment: .leading)
        .fixedSize(horizontal: maxWidth == nil, vertical: true)
        .help(policyPath.joined(separator: " › "))
    }
}

/// Small uppercase badges used in tables: NEW, NEW SITE, BY IP, Running, Exited, This Mac…
struct TagBadge: View {
    enum Style {
        /// Amber `NEW` / `NEW SITE`.
        case new
        /// Neutral grey (`BY IP`, `Exited`, `Domain`).
        case neutral
        /// Green (`Running`, `200 OK`).
        case ok
        /// Red (`Failed`).
        case bad
        /// Accent tint (`This Mac`).
        case accent
        /// Any hue tint (`IP` type chip).
        case hue(Double)
    }

    var text: String
    var style: Style = .neutral
    var mono = false

    var body: some View {
        let (bg, fg) = colors
        Text(text)
            .font(mono ? Theme.mono(9.5, weight: .bold) : .design(9.5, .bold))
            .lineLimit(1)
            .padding(.horizontal, 5.px)
            .frame(height: 15.px)
            .background(bg, in: RoundedRectangle(cornerRadius: 4.px, style: .continuous))
            .foregroundStyle(fg)
            .fixedSize()
    }

    private var colors: (Color, Color) {
        switch style {
        case .new: (Theme.newBadge, Theme.newBadgeInk)
        case .neutral: (Theme.fill2, Theme.ink2)
        case .ok: Theme.tint(150)
        case .bad: Theme.tint(27)
        case .accent: (Theme.accentTint, Theme.accentInk)
        case .hue(let h): Theme.tint(h)
        }
    }
}

/// Device badge in table rows (`MBP`, `mini`).
struct DeviceBadge: View {
    var shortName: String
    var hue: Double

    var body: some View {
        Text(shortName)
            .font(.design(9, .bold))
            .padding(.horizontal, 4.px)
            .frame(height: 14.px)
            .background(Theme.deviceColor(hue: hue), in: RoundedRectangle(cornerRadius: 3.5.px, style: .continuous))
            .foregroundStyle(.white)
            .fixedSize()
    }
}

/// Capsule counter: red for unread alerts, amber for new hosts.
struct CountBadge: View {
    enum Style { case unread, new }
    var count: Int
    var style: Style = .unread

    var body: some View {
        Text("\(count)")
            .font(.design(10, .bold))
            .monospacedDigit()
            .padding(.horizontal, 5.px)
            .frame(minWidth: 18.px, minHeight: 16.px)
            .background(style == .unread ? Theme.unreadBadge : Theme.newBadge, in: Capsule())
            .foregroundStyle(style == .unread ? Color.white : Theme.newBadgeInk)
            .fixedSize()
    }
}

/// Status dot, optionally pulsing (recording indicator, Surge / PostgreSQL health).
///
/// The pulse (opacity 1 → 0.3 and back, 0.7 s each way) runs in Core Animation on the dot's own layer: as a SwiftUI
/// animation it would update the page around the dot on the main thread every frame for as long as it is shown.
/// Callers pass `pulsing: false` under Reduce Motion or reduced resource usage, for a still dot.
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6.px
    var pulsing = false

    var body: some View {
        if pulsing {
            StatusDotPulse(color: color)
                .frame(width: size, height: size)
                // The AppKit view takes no clicks; this shape gives a click on the dot to the button around it, as
                // the SwiftUI circle did.
                .contentShape(Circle())
        } else {
            Circle()
                .fill(color)
                .frame(width: size, height: size)
        }
    }
}

/// The pulsing dot: an AppKit view that draws the dot and pulses its layer.
private struct StatusDotPulse: NSViewRepresentable {
    var color: Color

    func makeNSView(context: Context) -> StatusDotPulseView { StatusDotPulseView() }

    func updateNSView(_ view: StatusDotPulseView, context: Context) {
        view.color = color
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: StatusDotPulseView, context: Context) -> CGSize? {
        CGSize(width: proposal.width ?? 0, height: proposal.height ?? 0)
    }
}

/// Draws a filled circle in `color` (redrawn when the appearance changes, so dynamic colors follow it) and pulses
/// its layer's opacity with a repeating `CABasicAnimation`, which the render server runs. It takes no clicks itself.
final class StatusDotPulseView: NSView {
    static let animationKey = "pulse"

    var color: Color = .clear {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    required init?(coder: NSCoder) { nil }

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        NSColor(color).setFill()
        NSBezierPath(ovalIn: bounds).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let layer, layer.animation(forKey: Self.animationKey) == nil else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.7
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(pulse, forKey: Self.animationKey)
    }
}
