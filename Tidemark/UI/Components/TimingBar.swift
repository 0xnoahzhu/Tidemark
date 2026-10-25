import SwiftUI

/// Segmented timing bar: 8 pt with a legend in the inspector's TIMING, 7 pt without one in an App page's
/// expanded request row.
struct TimingBar: View {
    var phases: [TimingPhase]
    var barHeight: CGFloat = 8
    var showsLegend = true

    static func color(_ kind: TimingPhase.Kind) -> Color {
        switch kind {
        case .dns: Color(oklch: 0.72, 0.11, 200)
        case .connect: Color(oklch: 0.66, 0.12, 245)
        case .tls: Color(oklch: 0.64, 0.13, 295)
        case .transfer: Color(oklch: 0.68, 0.13, 150)
        }
    }

    var total: TimeInterval { phases.reduce(0) { $0 + $1.duration } }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            GeometryReader { geo in
                HStack(spacing: 1) {
                    ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                        Rectangle()
                            .fill(Self.color(phase.kind))
                            .frame(width: max(2, geo.size.width * phase.duration / max(total, 0.001)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
            .frame(height: barHeight)

            if showsLegend {
                TimingLegendLayout {
                    ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                        HStack(spacing: 5) {
                            RoundedRectangle(cornerRadius: 2).fill(Self.color(phase.kind)).frame(width: 7, height: 7)
                            Text(phase.kind.rawValue).foregroundStyle(Theme.ink2)
                            Text(Fmt.ms(phase.duration * 1000)).font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                        }
                        .font(.system(size: 11))
                        .fixedSize()
                    }
                }
            }
        }
    }
}

/// The legend's `● Label 12 ms` items in rows that wrap like text (the design's `flex-wrap`, 12 pt apart
/// and 4 pt between rows), so an item never breaks inside.
private struct TimingLegendLayout: Layout {
    var spacing: CGFloat = 12
    var rowSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = frames(for: subviews, width: proposal.width ?? .infinity)
        let width = frames.map(\.maxX).max() ?? 0
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: proposal.width ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        var frames: [CGRect] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                x = 0
                y += rowHeight + rowSpacing
                rowHeight = 0
            }
            frames.append(CGRect(origin: CGPoint(x: x, y: y), size: size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return frames
    }
}
