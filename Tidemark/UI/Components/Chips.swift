import SwiftUI

/// Policy capsule (`Proxy › HK-01`, `DIRECT`, `AI › US-West`) tinted by policy group.
struct PolicyChip: View {
    var policyPath: [String]
    var maxWidth: CGFloat? = nil

    var body: some View {
        if policyPath.isEmpty {
            // Surge reports the policy only after the connection is set up.
            Text("—").font(.system(size: 11)).foregroundStyle(Theme.ink3)
        } else {
            chip
        }
    }

    private var chip: some View {
        let tint = Theme.tint(Theme.policyHue(policyPath))
        return Text(policyPath.joined(separator: " › "))
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .truncationMode(policyPath.count > 1 ? .middle : .tail)
            .padding(.horizontal, 6)
            .frame(height: 18)
            .background(tint.background, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
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
            .font(mono ? Theme.mono(9.5, weight: .bold) : .system(size: 9.5, weight: .bold))
            .lineLimit(1)
            .padding(.horizontal, 5)
            .frame(height: 15)
            .background(bg, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 4)
            .frame(height: 14)
            .background(Theme.deviceColor(hue: hue), in: RoundedRectangle(cornerRadius: 3.5, style: .continuous))
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
            .font(.system(size: 10, weight: .bold))
            .monospacedDigit()
            .padding(.horizontal, 5)
            .frame(minWidth: 18, minHeight: 16)
            .background(style == .unread ? Theme.unreadBadge : Theme.newBadge, in: Capsule())
            .foregroundStyle(style == .unread ? Color.white : Theme.newBadgeInk)
            .fixedSize()
    }
}

/// Status dot, optionally pulsing (recording indicator, Surge / PostgreSQL health).
struct StatusDot: View {
    var color: Color
    var size: CGFloat = 6
    var pulsing = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: size, height: size)
            .phaseAnimator(pulsing ? [1.0, 0.3] : [1.0]) { dot, opacity in
                dot.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.7) }
    }
}
