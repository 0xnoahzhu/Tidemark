import SwiftUI

/// White rounded card with a hairline border (Egress page, settings groups, inspector blocks).
struct Card<Content: View>: View {
    var padding: CGFloat = 16.px
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12.px, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12.px, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

/// Uppercase grey section label (`PROCESS CHAIN`, `CONNECTION`, `TODAY`).
struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.design(10.5, .semibold))
            .tracking(0.4 * UIScale.factor)
            .foregroundStyle(Theme.ink2)
    }
}

/// `Label      value` row of the inspector and egress cards.
struct KeyValueRow<Value: View>: View {
    var label: String
    /// The label column's width in points; callers pass design px (`70.px`).
    var labelWidth: CGFloat = 76.px
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8.px) {
            Text(label)
                .font(.design(12))
                .foregroundStyle(Theme.ink2)
                .frame(width: labelWidth, alignment: .leading)
            value
                .font(.design(12))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(minHeight: 20.px)
    }
}

extension KeyValueRow where Value == Text {
    init(_ label: String, _ value: String, mono: Bool = false, labelWidth: CGFloat = 76.px) {
        self.label = label
        self.labelWidth = labelWidth
        self.value = Text(value).font(mono ? Theme.mono(12) : .design(12))
    }
}

/// A page's title and subtitle at the design's sizes: 15 px bold, slightly tightened, over 11 px in the secondary
/// ink. Pages draw it in the window toolbar (`pageToolbar(_:subtitle:items:)`), whose own title the system keeps
/// at its fixed size whatever the scale. Like the system's title, it greys out while its window is inactive.
struct PageTitle: View {
    /// The UI scale and line height the title block is drawn at. A toolbar item is 36 pt tall at most, whatever the
    /// scale, so the block grows only as far as that holds it, as the toolbar's segmented control does: at the UI
    /// scale with a line height of 1.2 (tighter than the page's 1.35) while it fits, then with the line height
    /// tightening to 1.1, then no further.
    struct Metrics: Equatable {
        var factor: CGFloat
        var lineHeight: CGFloat

        init(factor: CGFloat = UIScale.factor) {
            // What the 15 and 11 px lines may take of the item: all but the 1 px between them (1.5 pt at most) and
            // the half point each line may round up to.
            let room = UIScale.toolbarItemHeight - 1.5 - 2 * 0.5
            lineHeight = min(max(room / (26 * factor), 1.1), 1.2)
            self.factor = min(factor, room / (26 * lineHeight))
        }
    }

    /// The narrowest the page toolbar shortens the block to, in px: every page's name, and the start of its subtitle.
    static let minimumWidth: CGFloat = 128

    var title: String
    var subtitle: String?
    /// Draws the subtitle in the monospaced font (an app's path).
    var monospacedSubtitle = false
    var metrics = Metrics()

    @Environment(\.appearsActive) private var appearsActive

    var body: some View {
        let factor = metrics.factor
        VStack(alignment: .leading, spacing: UIScale.length(1, factor: factor)) {
            Text(title)
                .font(.system(size: 15 * factor, weight: .bold))
                .tracking(-0.15 * factor)
                .foregroundStyle(appearsActive ? Theme.ink : Theme.ink3)
            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.system(size: 11 * factor, design: monospacedSubtitle ? .monospaced : .default))
                    .foregroundStyle(appearsActive ? Theme.ink2 : Theme.ink3)
                    .truncationMode(monospacedSubtitle ? .middle : .tail)
            }
        }
        .lineLimit(1)
        .lineHeight(.multiple(factor: metrics.lineHeight))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

extension View {
    /// The page's toolbar: its title and subtitle at the leading end, drawn by the page at the design's size in
    /// place of the system's title, and `items` at the trailing end. The window keeps the title and subtitle as its
    /// own, which the Window menu, Mission Control and VoiceOver read.
    func pageToolbar<Items: ToolbarContent>(
        _ title: String,
        subtitle: String,
        monospacedSubtitle: Bool = false,
        @ToolbarContentBuilder items: () -> Items
    ) -> some View {
        // Where the system drew its title.
        pageToolbar(title, subtitle: subtitle, monospacedSubtitle: monospacedSubtitle, inset: 11.5, leading: EmptyView(), items: items())
    }

    /// `pageToolbar(_:subtitle:items:)` with `leading` (an app's tile) before the title.
    func pageToolbar<Leading: View, Items: ToolbarContent>(
        _ title: String,
        subtitle: String,
        monospacedSubtitle: Bool = false,
        @ViewBuilder leading: () -> Leading,
        @ToolbarContentBuilder items: () -> Items
    ) -> some View {
        pageToolbar(title, subtitle: subtitle, monospacedSubtitle: monospacedSubtitle, inset: 2, leading: leading(), items: items())
    }

    /// The page toolbar with the title block `inset` px from the toolbar's leading items.
    private func pageToolbar<Leading: View, Items: ToolbarContent>(
        _ title: String,
        subtitle: String,
        monospacedSubtitle: Bool,
        inset: CGFloat,
        leading: Leading,
        items: Items
    ) -> some View {
        navigationTitle(title)
            .navigationSubtitle(subtitle)
            .toolbar(removing: .title)
            .toolbar {
                ToolbarItem(placement: .navigation) {
                    let metrics = PageTitle.Metrics()
                    HStack(spacing: 10.px) {
                        leading
                        // In a narrow window the title gives way before the page's items, as the system's did: the
                        // subtitle shortens first, then the title, down to room for a page's name and the start of
                        // its subtitle. Below that the toolbar moves items to its overflow menu.
                        PageTitle(title: title, subtitle: subtitle, monospacedSubtitle: monospacedSubtitle, metrics: metrics)
                            .frame(minWidth: UIScale.length(PageTitle.minimumWidth, factor: metrics.factor), alignment: .leading)
                    }
                    .padding(.leading, inset.px)
                    .padding(.trailing, 2.px)
                    .toolbarItemCompressible()
                }
                // Text on the toolbar itself, as the system's title, rather than in a glass bubble.
                .sharedBackgroundVisibility(.hidden)

                // What the system's title took: the room between the title and the page's items. It has to be in the
                // same toolbar as the items; on its own the items would follow the title.
                ToolbarSpacer(.flexible)

                items
            }
    }
}

/// Page header used by every main-window page: title + subtitle on the left, accessories on the right.
struct PageHeader<Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 10.px) {
            PageTitle(title: title, subtitle: subtitle)
            Spacer(minLength: 12.px)
            accessory
        }
        .padding(.horizontal, 20.px)
        .frame(height: 52.px)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String?) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Centered placeholder for empty lists.
struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
        .foregroundStyle(Theme.ink2)
    }
}
