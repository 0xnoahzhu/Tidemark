import SwiftUI

/// Segmented timing bar with a legend (inspector › TIMING).
struct TimingBar: View {
    var phases: [TimingPhase]

    static func color(_ kind: TimingPhase.Kind) -> Color {
        switch kind {
        case .dns: Color(oklch: 0.72, 0.11, 200)
        case .rule: Color(oklch: 0.7, 0.04, 260)
        case .connect: Color(oklch: 0.66, 0.12, 245)
        case .tls: Color(oklch: 0.64, 0.13, 295)
        case .transfer: Color(oklch: 0.68, 0.13, 150)
        }
    }

    var total: TimeInterval { phases.reduce(0) { $0 + $1.duration } }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            GeometryReader { geo in
                HStack(spacing: 1.5) {
                    ForEach(Array(phases.enumerated()), id: \.offset) { _, phase in
                        Rectangle()
                            .fill(Self.color(phase.kind))
                            .frame(width: max(2, geo.size.width * phase.duration / max(total, 0.001)))
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 3, style: .continuous))
            }
            .frame(height: 6)

            FlowLegend(items: phases.map { (Self.color($0.kind), $0.kind.rawValue, Fmt.ms($0.duration * 1000)) })
        }
    }
}

/// Wrapping legend of `● Label 12 ms` items.
private struct FlowLegend: View {
    var items: [(Color, String, String)]

    var body: some View {
        let columns = [GridItem(.adaptive(minimum: 86), spacing: 6, alignment: .leading)]
        LazyVGrid(columns: columns, alignment: .leading, spacing: 4) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                HStack(spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(item.0).frame(width: 7, height: 7)
                    Text(item.1).foregroundStyle(Theme.ink2)
                    Text(item.2).foregroundStyle(Theme.ink3)
                }
                .font(.system(size: 10.5))
            }
        }
    }
}
