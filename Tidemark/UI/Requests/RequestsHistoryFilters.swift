import SwiftUI

/// The Status menu's choices: Surge's states, and the requests whose connection ended with an error (Surge marks
/// resets and broken pipes completed, so no state finds them).
enum RequestsStatusChoice: Hashable {
    case state(StatusFilter)
    case endedWithError

    static let states: [RequestsStatusChoice] = StatusFilter.allCases.map { .state($0) }

    /// The choice History's query holds, written back as its status and error filter.
    @MainActor
    static func binding(_ nav: Navigation) -> Binding<RequestsStatusChoice> {
        Binding {
            nav.history.endedWithError ? .endedWithError : .state(nav.history.status)
        } set: { choice in
            switch choice {
            case .state(let status):
                nav.history.status = status
                nav.history.endedWithError = false
            case .endedWithError:
                nav.history.status = .any
                nav.history.endedWithError = true
            }
        }
    }
}

/// `Host api2.cursor.sh ✕` or `IP 104.18.19.125 ✕`: the exact host or IP History shows, on the accent tint, removed
/// by its button; `Until Oct 24 14:21:25 ✕` for where History opened on one request ends.
struct RequestsHostChip: View {
    /// `Host`, or `IP` for the requests that reached an address.
    var title: String
    var host: String
    var help: String
    /// The remove button's help, "Show every host" when nil.
    var removeHelp: String? = nil
    var remove: () -> Void

    var body: some View {
        HStack(spacing: 5.px) {
            Text(title)
                .foregroundStyle(Theme.accentInk.opacity(0.75))
            Text(host)
                .lineLimit(1)
                .truncationMode(.middle)
            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.design(9, .bold))
                    .frame(width: 16.px, height: 16.px)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .help(removeHelp ?? tr("Show every host", "Requests"))
            .accessibilityLabel(trf("Remove the filter for %@", "Requests", host))
        }
        .font(.design(12))
        .foregroundStyle(Theme.accentInk)
        .padding(.leading, 10.px)
        .padding(.trailing, 5.px)
        .frame(height: 26.px)
        .frame(maxWidth: 260.px)
        .background(Theme.accentTint, in: RoundedRectangle(cornerRadius: 7.px, style: .continuous))
        .fixedSize(horizontal: false, vertical: true)
        .help(help)
    }
}

/// Lays the filter bar's items out left to right, wrapping onto another line when they do not fit; the items marked
/// `Trailing` sit at the end of the last line, as after a spacer, or on a line of their own.
struct RequestsFilterBarLayout: Layout {
    /// Marks the row count and its progress indicator.
    struct Trailing: LayoutValueKey {
        static let defaultValue = false
    }

    var spacing: CGFloat
    var rowSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let frames = frames(for: subviews, width: width)
        let height = frames.map(\.maxY).max() ?? 0
        return CGSize(width: width.isFinite ? width : frames.map(\.maxX).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, frame) in zip(subviews, frames(for: subviews, width: bounds.width)) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), proposal: ProposedViewSize(frame.size))
        }
    }

    /// Each subview's frame: leading items in rows that wrap, each row centered vertically; the trailing items after
    /// them, right-aligned on the last row where they fit.
    private func frames(for subviews: Subviews, width: CGFloat) -> [CGRect] {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let isTrailing = subviews.map { $0[Trailing.self] }
        // Each row's item indices, leading items first.
        var rows: [[Int]] = [[]]
        var x: CGFloat = 0
        for index in subviews.indices where !isTrailing[index] {
            let item = min(sizes[index].width, width)
            if x > 0, x + item > width {
                rows.append([])
                x = 0
            }
            rows[rows.count - 1].append(index)
            x += item + spacing
        }
        let trailing = subviews.indices.filter { isTrailing[$0] && sizes[$0].width > 0 }
        let trailingWidth = trailing.map { sizes[$0].width }.reduce(0, +) + spacing * CGFloat(max(0, trailing.count - 1))
        if !trailing.isEmpty, x > 0, x + trailingWidth > width {
            rows.append([])
        }
        rows[rows.count - 1] += trailing

        var frames = Array(repeating: CGRect.zero, count: subviews.count)
        var y: CGFloat = 0
        for row in rows {
            let height = row.map { sizes[$0].height }.max() ?? 0
            var leadingX: CGFloat = 0
            // With no width to fit (an ideal size), the trailing items follow the others.
            var trailingX = width.isFinite ? width - trailingWidth : 0
            for index in row {
                let size = CGSize(width: min(sizes[index].width, width), height: sizes[index].height)
                let origin: CGFloat
                if isTrailing[index] {
                    origin = max(leadingX, trailingX)
                    trailingX = origin + size.width + spacing
                } else {
                    origin = leadingX
                    leadingX += size.width + spacing
                }
                frames[index] = CGRect(x: origin, y: y + (height - size.height) / 2, width: size.width, height: size.height)
            }
            y += height + (row.isEmpty ? 0 : rowSpacing)
        }
        return frames
    }
}
