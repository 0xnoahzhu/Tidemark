import SwiftUI

/// A name and what follows it on one line, such as `githubusercontent.com  2 hosts  NEW SITE` or
/// `183.3.226.35  BY IP  NEW`. The name is whole when it fits. Short of room, what follows it gives way first, one item
/// after another in their order, each taking its narrowest form: nothing for an item that can go (a `ViewThatFits`
/// ending in an empty view), `NEW` for a `ViewThatFits` of `NEW SITE` and `NEW`, its own width for a plain badge. Only
/// then does the name shorten. Subviews are centered vertically, as in an `HStack`.
///
/// Subviews: the name, then what follows it.
struct AppDetailNameLayout: Layout {
    var spacing: CGFloat

    /// Something after the name: its width whole and at its narrowest.
    struct Item: Equatable {
        var ideal: CGFloat
        var narrowest: CGFloat
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let widths = widths(proposal.width, subviews: subviews)
        let height = zip(subviews, widths).map { $0.sizeThatFits(ProposedViewSize(width: $1, height: nil)).height }.max() ?? 0
        return CGSize(width: Self.used(widths, spacing: spacing), height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        for (subview, width) in zip(subviews, widths(bounds.width, subviews: subviews)) {
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: width, height: nil))
            if width > 0 { x += width + spacing }
        }
    }

    private func widths(_ width: CGFloat?, subviews: Subviews) -> [CGFloat] {
        guard let name = subviews.first else { return [] }
        let items = subviews.dropFirst().map { item in
            Item(ideal: item.sizeThatFits(.unspecified).width, narrowest: item.sizeThatFits(ProposedViewSize(width: 0, height: nil)).width)
        }
        return Self.widths(name: name.sizeThatFits(.unspecified).width, items: items, spacing: spacing, width: width ?? .infinity)
    }

    /// The widths of the name (first) and the items after it in a row `width` wide; 0 for an item that gave way
    /// entirely, which takes no spacing either.
    static func widths(name: CGFloat, items: [Item], spacing: CGFloat, width: CGFloat) -> [CGFloat] {
        var widths = items.map(\.ideal)
        func rest() -> CGFloat { used([0] + widths, spacing: spacing) }
        for index in items.indices where name + rest() > width {
            widths[index] = items[index].narrowest
        }
        return [min(name, max(0, width - rest()))] + widths
    }

    /// The width a row of `widths` takes, the name's first.
    private static func used(_ widths: [CGFloat], spacing: CGFloat) -> CGFloat {
        widths.dropFirst().reduce(widths.first ?? 0) { $1 > 0 ? $0 + spacing + $1 : $0 }
    }
}
