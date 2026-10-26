import SwiftUI
import UniformTypeIdentifiers

/// Global Domains & IPs page, deduplicated across every app and probe.
///
/// A table lists each domain and IP once, newest first, with the processes (and probes) that reached it;
/// "Group by site" folds domains into their registrable domain and IPs into their network. The lists come from
/// `AppModel.inventory`, which outlives the page, and the rows are built as they scroll into view, so switching
/// between All, Domains and IPs, grouping and coming back to the page only lay out the rows on screen.
struct InventoryView: View {
    @Environment(AppModel.self) private var model

    @State private var exportDocument: AnalyzeCSVDocument?
    @State private var isExporting = false
    @State private var exportError: (any Error)?

    var body: some View {
        @Bindable var nav = model.nav
        let key = InventoryCache.Key(search: nav.inventorySearch.trimmingCharacters(in: .whitespaces), scope: model.devices.scope)
        let snapshot = model.inventory.snapshot(for: key)
        let visible = snapshot?.entries(nav.inventoryKind) ?? []

        content(snapshot: snapshot, visible: visible, key: key)
            .pageToolbar(tr("Domains & IPs", "Inventory"), subtitle: subtitle(snapshot)) {
                // The switches keep the standard priority, the page title's: above it, the toolbar would drop the title
                // in a narrow window instead of shortening it.
                ToolbarItem(placement: .primaryAction) {
                    // No counts: the subtitle beside it gives them, and at the default window width they would cut it.
                    DesignSegmentedControl(tr("Kind", "Inventory"), selection: $nav.inventoryKind, size: .compact(), segments: [
                        .init(nil, tr("All", "Inventory"), systemImage: "list.bullet"),
                        .init(.domain, tr("Domains", "Inventory"), systemImage: "globe"),
                        .init(.ip, tr("IPs", "Inventory"), systemImage: "number"),
                    ])
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $nav.inventoryGrouped) {
                        Text(tr("Group by site", "Inventory")).font(.design(12, .medium))
                    }
                    .toggleStyle(.button)
                    .help(tr("Fold domains into their site and IPs into their network", "Inventory"))
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                // The design's order: the search field before Export CSV (`searchable` would put it last).
                ToolbarItem(placement: .primaryAction) {
                    ToolbarSearchField(text: $nav.inventorySearch, prompt: tr("Search", "Inventory"))
                        .frame(width: 170.px)
                }
                // The last item to overflow: the field has no usable form in the overflow menu.
                .visibilityPriority(Self.searchPriority)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                // The first item to overflow, before the switches that change what the page shows: the overflow menu's
                // item exports as the button does.
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        exportDocument = AnalyzeCSVDocument(text: AnalyzeCSV.inventory(visible))
                        isExporting = true
                    } label: {
                        Text(tr("Export CSV", "Inventory")).font(.design(12, .medium))
                    }
                    .disabled(visible.isEmpty)
                }
                .visibilityPriority(.low)
            }
            .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .commaSeparatedText,
                          defaultFilename: tr("Domains and IPs", "Inventory"),
                          onCompletion: { result in
                              if case .failure(let error) = result { exportError = error }
                          })
            .alert(error: $exportError) {
                Button(tr("OK", "Inventory")) {}
            }
            .task(id: key) {
                await load(key)
            }
    }

    @ViewBuilder
    private func content(snapshot: InventoryCache.Snapshot?, visible: [InventoryEntry], key: InventoryCache.Key) -> some View {
        if snapshot == nil {
            // Only the first visit waits for the database; later visits show the cached list at once.
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if visible.isEmpty {
            if key.search.isEmpty {
                EmptyState(systemImage: "network",
                           title: tr("No domains or IPs yet", "Inventory"),
                           message: tr("Every domain and IP that Surge sees shows up here once, whichever app or probe reached it.", "Inventory"))
            } else {
                // Not `ContentUnavailableView.search`: the message says what the search looks at.
                EmptyState(systemImage: "magnifyingglass",
                           title: trf("No domains or IPs match “%@”", "Inventory", key.search),
                           message: tr("The search looks at each domain or IP and the apps and probes that reached it.", "Inventory"))
            }
        } else {
            let groups = model.nav.inventoryGrouped
                ? model.inventory.groups(for: key, kind: model.nav.inventoryKind, unknownNetwork: tr("Unknown network", "Inventory"),
                                         site: { model.classifier.site(for: $0) })
                : nil
            InventoryList(model: model, entries: visible, groups: groups)
        }
    }

    private static let searchPriority = ToolbarItemVisibilityPriority(higherThan: .high)

    private func subtitle(_ snapshot: InventoryCache.Snapshot?) -> String {
        let domains = snapshot?.domainCount ?? 0
        return trf("%1$@ · %2$@, deduplicated across every app and probe", "Inventory",
                   trn("%lld domain", "%lld domains", domains, "Inventory"),
                   trn("%lld IP", "%lld IPs", (snapshot?.all.count ?? 0) - domains, "Inventory"))
    }

    // MARK: Loading

    private func load(_ key: InventoryCache.Key) async {
        await model.inventory.keepCurrent(key) { source in
            try await model.database.inventory(kind: nil, search: source.search, scope: source.scope)
        }
    }
}

/// Filtering and ordering behind the Domains & IPs table (pure, so it can be tested).
enum InventoryPresentation {
    /// The entries of `kind` (all when nil), newest first seen first, then by name: the database's order.
    static func visible(_ entries: [InventoryEntry], kind: HostKind?) -> [InventoryEntry] {
        entries.filter { kind == nil || $0.kind == kind }.sorted { a, b in
            a.firstSeen != b.firstSeen ? a.firstSeen > b.firstSeen : a.value < b.value
        }
    }
}

// MARK: - List

/// The Domains & IPs table: a pinned header and lazily built rows in one scroll view, laid out like the native
/// table it replaced: the inset style's header, row padding and alternating rounded rows, continued below the last
/// row; columns sized and resized as the native table sizes them, whose header dividers can be dragged, scrolling
/// sideways when they do not fit. Flat and grouped rows share the scroll view, so grouping only swaps the rows.
private struct InventoryList: View {
    let model: AppModel
    var entries: [InventoryEntry]
    /// The site and network groups when grouped by site; nil for the flat list.
    var groups: [InventoryGroup]?

    @State private var position = ScrollPosition(edge: .top)
    @State private var scrolled = InventoryScrollGeometry()
    /// The columns' widths once they differ from those a new table gives them at the list's width (after the window
    /// was resized or a divider dragged, or in a window too narrow for every column); nil until then.
    @State private var widths: InventoryColumnWidths?
    /// The width a legacy vertical scroller takes from the list, which the scroll view's container still includes.
    @State private var scrollerWidth: CGFloat = 0

    private var columns: [InventoryColumnsLayout.Column] {
        groups == nil ? InventoryColumnsLayout.entryColumns : InventoryColumnsLayout.groupColumns
    }

    var body: some View {
        let explicit = widths?.widths
        let tableWidth = widths?.tableWidth ?? 0
        // The native table rounds and insets its rows only while its columns fit the list.
        let inset = !(widths?.overflows ?? false)
        let leavesRoom = widths?.leavesRoom ?? false
        ScrollView([.vertical, .horizontal]) {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                if let groups {
                    Section {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            InventoryGroupRow(model: model, group: group, widths: explicit, striped: index % 2 == 1, insetStripe: inset)
                        }
                        InventoryEmptyRows(first: groups.count, pitch: InventoryTableMetrics.groupRowHeight, inset: inset)
                    } header: {
                        InventoryHeaderRow(columns: InventoryColumnsLayout.groupColumns, widths: explicit, leavesRoom: leavesRoom, titles: [
                            (tr("Site or network", "Inventory"), .leading),
                            (tr("Seen by", "Inventory"), .leading),
                            (tr("Requests", "Inventory"), .trailing),
                        ], resize: resize)
                    }
                } else {
                    Section {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            InventoryEntryRow(model: model, entry: entry, widths: explicit, striped: index % 2 == 1, insetStripe: inset)
                        }
                        InventoryEmptyRows(first: entries.count, pitch: InventoryTableMetrics.rowHeight, inset: inset)
                    } header: {
                        InventoryHeaderRow(columns: InventoryColumnsLayout.entryColumns, widths: explicit, leavesRoom: leavesRoom, titles: [
                            (tr("Name", "Inventory"), .leading),
                            (tr("Type", "Inventory"), .leading),
                            (tr("Seen by · process path", "Inventory"), .leading),
                            (tr("First seen", "Inventory"), .leading),
                            (tr("Last seen", "Inventory"), .leading),
                            (tr("Requests", "Inventory"), .trailing),
                        ], resize: resize)
                    }
                }
            }
            // As wide as the list, or as the columns when they do not fit it (then the list scrolls sideways).
            .containerRelativeFrame(.horizontal) { visible, _ in max(visible - scrollerWidth, tableWidth) }
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
            scrolled.geometry = geometry
        }
        .onScrollGeometryChange(for: InventoryTableMetrics.ListWidth.self, of: { InventoryTableMetrics.ListWidth($0) }) { old, new in
            scrollerWidth = new.scroller
            resized(to: new.visible, scrollerOnly: new.container == old.container)
        }
        // Plugging in a mouse or changing Show scroll bars switches between legacy and overlay scrollers.
        .onReceive(NotificationCenter.default.publisher(for: NSScroller.preferredScrollerStyleDidChangeNotification)) { _ in
            guard let geometry = scrolled.geometry else { return }
            let width = InventoryTableMetrics.ListWidth(geometry)
            scrollerWidth = width.scroller
            resized(to: width.visible, scrollerOnly: true)
        }
        .background(InventoryTableMetrics.background)
        // A new table, like the one grouping used to build, starts at the top with its columns as a new table's.
        .onChange(of: groups == nil) {
            widths = scrolled.visibleWidth.flatMap { newTableWidths(visible: $0) }
            position.scrollTo(edge: .top)
        }
        // Like the native table, the list takes focus from Tab and a click, and Home, End, Page Up and Page Down
        // scroll it.
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .onKeyPress(keys: [.home, .end, .pageUp, .pageDown]) { press in
            scroll(press.key)
        }
    }

    /// A new table's widths at the list's `visible` width when the rows cannot lay them out themselves (they do not
    /// fit, so the table is wider than the list); nil otherwise.
    private func newTableWidths(visible: CGFloat) -> InventoryColumnWidths? {
        let created = InventoryColumnWidths(columns: columns, space: InventoryTableMetrics.columnSpace(visible, columns: columns.count))
        return created.overflows ? created : nil
    }

    /// The list is `visible` points wide now: a new list takes a new table's widths, and a resized one fits its
    /// columns to the new width as the native table does. A legacy scroller that shows or hides (`scrollerOnly`, as
    /// the rows outgrow the list or fit it again) is no resize: a new table's columns stay a new table's at the width
    /// it leaves, and only columns already resized or dragged are fitted to it.
    private func resized(to visible: CGFloat, scrollerOnly: Bool = false) {
        guard visible > 0 else { return }
        defer { scrolled.visibleWidth = visible }
        guard let old = scrolled.visibleWidth, old != visible else {
            if scrolled.visibleWidth == nil, let created = newTableWidths(visible: visible) { widths = created }
            return
        }
        if scrollerOnly, widths == newTableWidths(visible: old) {
            let created = newTableWidths(visible: visible)
            if created != widths { widths = created }
            return
        }
        let space = InventoryTableMetrics.columnSpace(visible, columns: columns.count)
        var resized = widths ?? InventoryColumnWidths(columns: columns, space: InventoryTableMetrics.columnSpace(old, columns: columns.count))
        resized.resize(to: space)
        // Columns a new table would have at this width are left to the rows.
        let next: InventoryColumnWidths? = resized.widths == InventoryColumnWidths(columns: columns, space: space).widths && !resized.overflows ? nil : resized
        if next != widths { widths = next }
    }

    /// Follows a drag of the divider after `column` by `offset` (nil when it ends) from the widths it started with.
    private func resize(column: Int, offset: CGFloat?) {
        guard let offset else {
            scrolled.dragStart = nil
            return
        }
        guard let visible = scrolled.visibleWidth else { return }
        let start = scrolled.dragStart
            ?? widths
            ?? InventoryColumnWidths(columns: columns, space: InventoryTableMetrics.columnSpace(visible, columns: columns.count))
        scrolled.dragStart = start
        let dragged = start.dragging(column: column, by: offset)
        if dragged != widths { widths = dragged }
    }

    private func scroll(_ key: KeyEquivalent) -> KeyPress.Result {
        switch key {
        case .home:
            position.scrollTo(edge: .top)
        case .end:
            position.scrollTo(edge: .bottom)
        default:
            guard let geometry = scrolled.geometry else { return .ignored }
            // The container is what shows between the toolbar and the bottom edge; a page is what of it shows below
            // the header, less a little, which stays in view.
            let visible = geometry.containerSize.height
            let page = max(0, visible - InventoryTableMetrics.headerHeight - 10.px)
            let top = geometry.contentOffset.y + geometry.contentInsets.top
            let target = top + (key == .pageDown ? page : -page)
            // Where the list is scrolled sideways stays as it is.
            position.scrollTo(x: geometry.contentOffset.x + geometry.contentInsets.leading,
                              y: min(max(0, target), max(0, geometry.contentSize.height - visible)))
        }
        return .handled
    }
}

/// The list's last scroll geometry and width, for the page keys and the column widths, and the widths a divider
/// drag started from; a reference, so scrolling does not update the view.
@MainActor
private final class InventoryScrollGeometry {
    var geometry: ScrollGeometry?
    var visibleWidth: CGFloat?
    var dragStart: InventoryColumnWidths?
}

/// The table's measurements, the design's in px, with the native inset table's colors and rounded stripes, which the
/// list reproduces.
private enum InventoryTableMetrics {
    static let columnSpacing = columnSpacing(factor: UIScale.factor)
    static let horizontalPadding = horizontalPadding(factor: UIScale.factor)
    static let headerHeight = 28.px
    static let rowPadding = 4.px
    /// A single-line row's height, the design's minimum; the empty rows below a flat list's last one are as tall.
    static let rowHeight = 30.px
    /// A site or network row's height: its two lines and the padding around them (the design's 49.7 px); the empty
    /// rows below the grouped list's last one are as tall.
    static let groupRowHeight = 50.px
    /// The alternate rows' rounded stripe: its insets from the list's leading and trailing edges, which keep the text
    /// 6 and 5.5 px inside it as the native table's rows do, and its radius.
    static let stripeLeadingInset = 8.px
    static let stripeTrailingInset = 8.5.px
    static let stripeRadius = 6.px

    static let background = Color(nsColor: .controlBackgroundColor)
    static let headerText = Color(nsColor: .headerTextColor)
    static let stripe = Color(nsColor: NSColor.alternatingContentBackgroundColors[1])
    static let headerSeparator = Color.dynamic(light: .black(0.1), dark: .white(0.16))
    static let headerLine = Color.dynamic(light: .black(0.1), dark: .white(0.115))

    /// The list's width: its container's, which leaves out the scroll view's insets (such as the sidebar's) but not
    /// a legacy vertical scroller, and the part of it that scroller takes.
    struct ListWidth: Equatable {
        var container: CGFloat
        var scroller: CGFloat

        /// The width the list shows: its container's, less the scroller.
        var visible: CGFloat { container - scroller }

        @MainActor
        init(_ geometry: ScrollGeometry) {
            container = geometry.containerSize.width
            scroller = InventoryTableMetrics.scrollerWidth(geometry)
        }
    }

    /// The width the vertical scroller takes from the list: a legacy (always shown) scroller's while the rows are
    /// taller than the list, which AppKit then shows inside the container; overlay scrollers take none.
    @MainActor
    static func scrollerWidth(_ geometry: ScrollGeometry) -> CGFloat {
        guard NSScroller.preferredScrollerStyle == .legacy, geometry.contentSize.height > geometry.containerSize.height else { return 0 }
        return NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
    }

    // The gap between the columns and the padding at the list's sides at any UI scale: the design's 12 and 14 px.
    static func columnSpacing(factor: CGFloat) -> CGFloat { UIScale.length(12, factor: factor) }
    static func horizontalPadding(factor: CGFloat) -> CGFloat { UIScale.length(14, factor: factor) }

    /// The width `count` columns share in a list `width` points wide: less the padding and the gaps between them.
    static func columnSpace(_ width: CGFloat, columns count: Int) -> CGFloat {
        width - 2 * horizontalPadding - columnSpacing * CGFloat(max(0, count - 1))
    }

    /// The width of a table whose columns take `space`, at the UI scale `factor`.
    static func tableWidth(columnSpace space: CGFloat, columns count: Int, factor: CGFloat) -> CGFloat {
        space + 2 * horizontalPadding(factor: factor) + columnSpacing(factor: factor) * CGFloat(max(0, count - 1))
    }
}

/// Column titles with the native header's separators and bottom line; dragging a separator (or the last column's
/// edge) resizes the column before it, as in the native header.
private struct InventoryHeaderRow: View {
    var columns: [InventoryColumnsLayout.Column]
    var widths: [CGFloat]?
    /// Whether the columns are narrower than the list.
    var leavesRoom: Bool
    var titles: [(title: String, alignment: Alignment)]
    /// Called as the divider after a column is dragged, with the offset from where the drag began, and with nil
    /// when it ends.
    var resize: (_ column: Int, _ offset: CGFloat?) -> Void

    var body: some View {
        InventoryColumnsLayout(columns: columns, widths: widths) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, column in
                Group {
                    if column.alignment == .trailing {
                        // Whole, as the native header draws a right-aligned title in a narrow column.
                        Text(column.title).fixedSize().padding(.trailing, 2.px)
                    } else {
                        Text(column.title).lineLimit(1).padding(.leading, 2.px)
                    }
                }
                .frame(maxWidth: .infinity, alignment: column.alignment)
                .overlay(alignment: .trailing) {
                    // Between the columns, and after the last one only when the columns leave room after it.
                    if index < titles.count - 1 || leavesRoom {
                        Rectangle()
                            .fill(InventoryTableMetrics.headerSeparator)
                            .frame(width: 1, height: 15.px)
                            .offset(x: InventoryTableMetrics.columnSpacing / 2 + 0.5)
                    }
                }
                .overlay(alignment: .trailing) {
                    if columns[index].isResizable {
                        divider(after: index)
                    }
                }
            }
        }
        .font(.design(12))
        .foregroundStyle(InventoryTableMetrics.headerText)
        .padding(.horizontal, InventoryTableMetrics.horizontalPadding)
        // The titles are centered above the bottom line, which the native header draws 1 pt above its bottom.
        .frame(height: InventoryTableMetrics.headerHeight - 1)
        .padding(.bottom, 1)
        .background(InventoryTableMetrics.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(InventoryTableMetrics.headerLine).frame(height: 1.5).offset(y: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    /// The area around the divider after `column` that resizes it.
    private func divider(after column: Int) -> some View {
        Color.clear
            .frame(width: 8.px, height: InventoryTableMetrics.headerHeight)
            .contentShape(Rectangle())
            // Centered on the separator, in the gap between the columns.
            .offset(x: InventoryTableMetrics.columnSpacing / 2 + 8.px / 2)
            .pointerStyle(.columnResize)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .global)
                    .onChanged { resize(column, $0.translation.width) }
                    .onEnded { _ in resize(column, nil) }
            )
            .accessibilityHidden(true)
    }
}

/// The alternate rows' background: rounded and inset like the native table's, or, as the native table draws it
/// while its columns are wider than the list, square across the whole row.
private struct InventoryRowStripe: View {
    var inset: Bool

    var body: some View {
        if inset {
            RoundedRectangle(cornerRadius: InventoryTableMetrics.stripeRadius, style: .continuous)
                .fill(InventoryTableMetrics.stripe)
                .padding(.leading, InventoryTableMetrics.stripeLeadingInset)
                .padding(.trailing, InventoryTableMetrics.stripeTrailingInset)
        } else {
            Rectangle().fill(InventoryTableMetrics.stripe)
        }
    }
}

/// The empty rows the native table draws below its last one, down to the bottom of the window: alternate rounded
/// rows as tall as the list's rows, whose parity continues the rows'. They hang below the list's end, so they take no
/// room and a long list never scrolls to them.
private struct InventoryEmptyRows: View {
    /// The index the first empty row would have.
    var first: Int
    /// The rows' height.
    var pitch: CGFloat
    /// Rounded and inset rows, as the rows' stripes are.
    var inset: Bool

    var body: some View {
        Color.clear
            .frame(height: 0)
            .overlay(alignment: .top) {
                Canvas { context, size in
                    var index = first % 2 == 1 ? 0 : 1
                    while CGFloat(index) * pitch < size.height {
                        let y = CGFloat(index) * pitch
                        if inset {
                            let leading = InventoryTableMetrics.stripeLeadingInset
                            let width = size.width - leading - InventoryTableMetrics.stripeTrailingInset
                            let rect = CGRect(x: leading, y: y, width: max(0, width), height: pitch)
                            context.fill(RoundedRectangle(cornerRadius: InventoryTableMetrics.stripeRadius, style: .continuous).path(in: rect),
                                         with: .color(InventoryTableMetrics.stripe))
                        } else {
                            context.fill(Path(CGRect(x: 0, y: y, width: size.width, height: pitch)), with: .color(InventoryTableMetrics.stripe))
                        }
                        index += 2
                    }
                }
                .containerRelativeFrame(.vertical, alignment: .top)
                .allowsHitTesting(false)
            }
            .accessibilityHidden(true)
    }
}

/// A domain or IP of the flat list.
private struct InventoryEntryRow: View {
    let model: AppModel
    var entry: InventoryEntry
    var widths: [CGFloat]?
    var striped: Bool
    var insetStripe: Bool

    var body: some View {
        InventoryColumnsLayout(columns: InventoryColumnsLayout.entryColumns, widths: widths) {
            Text(entry.value)
                .font(entry.kind == .ip ? Theme.mono(12, weight: .medium) : .design(12, .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(entry.geo?.display ?? entry.value)
            InventoryKindChip(kind: entry.kind)
            InventorySourcesList(model: model, sources: entry.sources)
            Text(AnalyzeFormat.seen(entry.firstSeen)).foregroundStyle(Theme.ink2)
            Text(AnalyzeFormat.seen(entry.lastSeen, timeOnlyToday: true)).foregroundStyle(Theme.ink2)
            Text(Fmt.count(entry.requestCount))
                .font(Theme.mono(11))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.design(12))
        .padding(.vertical, InventoryTableMetrics.rowPadding)
        .frame(minHeight: InventoryTableMetrics.rowHeight)
        .padding(.horizontal, InventoryTableMetrics.horizontalPadding)
        .background { if striped { InventoryRowStripe(inset: insetStripe) } }
        // One element per row that names each column, as VoiceOver reads a table's row; the name's tooltip (an
        // IP's network) is its help.
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(accessibilityText)
        .accessibilityHint(entry.geo?.display ?? "")
    }

    private var accessibilityText: String {
        trf("Name: %1$@, Type: %2$@, Seen by: %3$@, First seen: %4$@, Last seen: %5$@, Requests: %6$@", "Inventory",
            entry.value, entry.kind == .ip ? tr("IP", "Inventory") : tr("Domain", "Inventory"),
            InventorySourcesList.accessibilityText(entry.sources),
            AnalyzeFormat.seen(entry.firstSeen), AnalyzeFormat.seen(entry.lastSeen, timeOnlyToday: true),
            Fmt.count(entry.requestCount))
    }
}

/// A site or network of the grouped list.
private struct InventoryGroupRow: View {
    let model: AppModel
    var group: InventoryGroup
    var widths: [CGFloat]?
    var striped: Bool
    var insetStripe: Bool

    var body: some View {
        InventoryColumnsLayout(columns: InventoryColumnsLayout.groupColumns, widths: widths) {
            VStack(alignment: .leading, spacing: 2.px) {
                HStack(alignment: .firstTextBaseline, spacing: 8.px) {
                    Text(group.name).font(.design(12.5, .semibold)).lineLimit(1)
                    Text(group.kind == .ip
                         ? trn("%lld IP", "%lld IPs", group.names.count, "Inventory")
                         : trn("%lld host", "%lld hosts", group.names.count, "Inventory"))
                        .font(.design(11))
                        .foregroundStyle(Theme.ink2)
                }
                Text(group.preview)
                    .font(.design(11))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            .padding(.vertical, 4.px)
            HStack(spacing: -4.px) {
                ForEach(Array(group.sources.prefix(5).enumerated()), id: \.offset) { _, source in
                    InventorySourceTile(model: model, source: source, size: 18.px)
                        .padding(1.5.px)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6.5.px, style: .continuous))
                        .help(InventorySourcesList.displayTitle(source))
                }
            }
            Text(Fmt.count(group.requests))
                .font(Theme.mono(11))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.design(12))
        .padding(.vertical, InventoryTableMetrics.rowPadding)
        .frame(minHeight: InventoryTableMetrics.groupRowHeight)
        .padding(.horizontal, InventoryTableMetrics.horizontalPadding)
        .background { if striped { InventoryRowStripe(inset: insetStripe) } }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(.isStaticText)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        trf("Site or network: %1$@, %2$@, %3$@, Seen by: %4$@, Requests: %5$@", "Inventory",
            group.name,
            group.kind == .ip
                ? trn("%lld IP", "%lld IPs", group.names.count, "Inventory")
                : trn("%lld host", "%lld hosts", group.names.count, "Inventory"),
            group.preview,
            group.sources.prefix(5).map(InventorySourcesList.displayTitle).joined(separator: ", "),
            Fmt.count(group.requests))
    }
}

/// Lays out a row of the Domains & IPs table in columns of the given widths or, without them, of the widths a new
/// native table gives its columns in the row's width. Cells start at their column's leading edge and are centered
/// vertically.
struct InventoryColumnsLayout: Layout {
    struct Column: Hashable, Sendable {
        var ideal: CGFloat
        var min: CGFloat
        var max: CGFloat = .infinity

        /// Whether its width can change (the Type column's cannot).
        var isResizable: Bool { min < max }

        func clamped(_ width: CGFloat) -> CGFloat { Swift.min(Swift.max(width, min), max) }
    }

    /// Name, Type, Seen by · process path, First seen, Last seen, Requests.
    static let entryColumns = entryColumns(factor: UIScale.factor)
    /// Site or network, Seen by, Requests.
    static let groupColumns = groupColumns(factor: UIScale.factor)

    // The columns above at any UI scale, in design px. Text grows with the scale, and SF a little less than its size,
    // so a width that fits its text in px fits it at every factor: Type its chip, First and Last seen
    // `Yesterday 23:59`, Requests a count of eight digits in 11 px SF Mono, Seen by five tiles.
    static func entryColumns(factor: CGFloat) -> [Column] {
        let px = { UIScale.length($0, factor: factor) }
        return [
            Column(ideal: px(270), min: px(150)), Column(ideal: px(58), min: px(58), max: px(58)), Column(ideal: px(480), min: px(240)),
            Column(ideal: px(112), min: px(108), max: px(120)), Column(ideal: px(112), min: px(108), max: px(120)),
            Column(ideal: px(70), min: px(70), max: px(84)),
        ]
    }

    static func groupColumns(factor: CGFloat) -> [Column] {
        let px = { UIScale.length($0, factor: factor) }
        return [Column(ideal: px(560), min: px(260)), Column(ideal: px(140), min: px(110), max: px(180)), Column(ideal: px(70), min: px(70), max: px(90))]
    }

    var columns: [Column]
    var widths: [CGFloat]?
    var spacing: CGFloat = InventoryTableMetrics.columnSpacing

    private func resolved(_ total: CGFloat) -> [CGFloat] {
        widths ?? Self.widths(for: columns, spacing: spacing, total: total)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? (widths ?? columns.map(\.ideal)).reduce(spacing * CGFloat(max(0, columns.count - 1)), +)
        let widths = resolved(width)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() where index < widths.count {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = resolved(bounds.width)
        var x = bounds.minX
        for (index, subview) in subviews.enumerated() {
            guard index < widths.count else {
                subview.place(at: CGPoint(x: bounds.maxX, y: bounds.midY), anchor: .leading, proposal: .zero)
                continue
            }
            subview.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(width: widths[index], height: nil))
            x += widths[index] + spacing
        }
    }

    /// The widths a new native table gives its columns in a row `total` points wide.
    static func widths(for columns: [Column], spacing: CGFloat, total: CGFloat) -> [CGFloat] {
        InventoryColumnWidths.initial(columns, space: total - spacing * CGFloat(max(0, columns.count - 1)))
    }
}

/// The widths of the Domains & IPs table's columns, kept as the native table kept them.
///
/// A new table caps the columns that have a maximum at their minimum and shares the rest between the others, each
/// taking its ideal width plus an equal part of what is left (or less an equal part of what is missing, down to its
/// minimum); too narrow for every minimum, it keeps the ideal widths and scrolls sideways. As the list is resized,
/// columns that filled it share the difference equally, within their limits. Dragging a divider resizes the column
/// before it, and when the columns filled the list, the ones after it make up the difference from the last one back.
struct InventoryColumnWidths: Equatable {
    typealias Column = InventoryColumnsLayout.Column

    let columns: [Column]
    private(set) var widths: [CGFloat]
    /// The width the columns share: the list's, less its padding and the gaps between the columns.
    private(set) var space: CGFloat
    /// The UI scale the table's padding and gaps are drawn at.
    let factor: CGFloat

    /// A new table's widths in `space`.
    init(columns: [Column], space: CGFloat, factor: CGFloat = UIScale.factor) {
        self.columns = columns
        self.space = space
        self.factor = factor
        widths = Self.initial(columns, space: space)
    }

    /// The columns' total width.
    var total: CGFloat { widths.reduce(0, +) }

    /// Whether the columns are wider than the list, which then scrolls sideways.
    var overflows: Bool { total > space + 0.5 }

    /// Whether the columns are narrower than the list, leaving room after the last one.
    var leavesRoom: Bool { total < space - 0.5 }

    /// The table's width: the list's, or the columns' when they are wider.
    var tableWidth: CGFloat {
        InventoryTableMetrics.tableWidth(columnSpace: max(space, total), columns: columns.count, factor: factor)
    }

    static func initial(_ columns: [Column], space: CGFloat) -> [CGFloat] {
        guard columns.reduce(0, { $0 + $1.min }) <= space else { return columns.map(\.ideal) }
        var result = columns.map(\.min)
        let shared = columns.indices.filter { columns[$0].max == .infinity }
        var pool = shared
        var remaining = space - columns.indices.filter { !shared.contains($0) }.reduce(CGFloat(0)) { $0 + columns[$1].min }
        while !pool.isEmpty {
            let delta = (remaining - pool.reduce(CGFloat(0)) { $0 + columns[$1].ideal }) / CGFloat(pool.count)
            let pinned = pool.filter { columns[$0].ideal + delta < columns[$0].min }
            if pinned.isEmpty {
                for index in pool { result[index] = columns[index].ideal + delta }
                break
            }
            for index in pinned { remaining -= columns[index].min }
            pool.removeAll { pinned.contains($0) }
        }
        return result
    }

    /// The list now gives the columns `newSpace`: they are fitted to it when they filled the old width, or when they
    /// would otherwise cross the new edge (from scrolling sideways to leaving room, or the other way); otherwise
    /// they keep their widths.
    mutating func resize(to newSpace: CGFloat) {
        let sum = total
        let filled = abs(sum - space) < 0.5
        let keeps = !filled && ((sum > space && sum > newSpace) || (sum < space && sum < newSpace))
        space = newSpace
        if !keeps { fit(newSpace) }
    }

    /// Shares the difference to `target` equally among the resizable columns, within their limits.
    private mutating func fit(_ target: CGFloat) {
        var pool = columns.indices.filter { columns[$0].isResizable }
        var remaining = target - total
        while abs(remaining) > 0.01, !pool.isEmpty {
            let share = remaining / CGFloat(pool.count)
            var open: [Int] = []
            for index in pool {
                let old = widths[index]
                let width = columns[index].clamped(old + share)
                remaining -= width - old
                widths[index] = width
                if width != (share > 0 ? columns[index].max : columns[index].min) { open.append(index) }
            }
            pool = open
        }
    }

    /// These widths after the divider after `column` was dragged by `offset`.
    func dragging(column: Int, by offset: CGFloat) -> Self {
        var result = self
        let filled = abs(total - space) < 0.5
        let width = columns[column].clamped(widths[column] + offset)
        var remaining = widths[column] - width
        result.widths[column] = width
        guard filled else { return result }
        for index in columns.indices.reversed() where index > column && abs(remaining) > 0.01 {
            let next = columns[index].clamped(result.widths[index] + remaining)
            remaining -= next - result.widths[index]
            result.widths[index] = next
        }
        return result
    }
}

/// `Domain` (grey) or `IP` (tinted) type chip.
struct InventoryKindChip: View {
    var kind: HostKind

    var body: some View {
        let tint = Theme.tint(200)
        Text(kind == .ip ? tr("IP", "Inventory") : tr("Domain", "Inventory"))
            .font(.design(10.5, .semibold))
            .padding(.horizontal, 6.px)
            .padding(.vertical, 1.px)
            .background(kind == .ip ? tint.background : Theme.fill, in: RoundedRectangle(cornerRadius: 4.px, style: .continuous))
            .foregroundStyle(kind == .ip ? tint.foreground : Theme.ink2)
            .fixedSize()
    }
}

/// The first six "seen by" rows, as in the design: a tile (app icon, letter, or the purple probe tile) and the
/// process path.
struct InventorySourcesList: View {
    let model: AppModel
    var sources: [InventorySource]

    var body: some View {
        VStack(alignment: .leading, spacing: 3.px) {
            ForEach(Array(sources.prefix(6).enumerated()), id: \.offset) { _, source in
                HStack(alignment: .top, spacing: 6.px) {
                    InventorySourceTile(model: model, source: source, size: 14.px)
                        .padding(.top, 1.px)
                    Text(Self.wrappable(Self.displayPath(source)))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink2)
                        .lineHeight(Self.pathLineHeight)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Self.displayPath(source))
                }
            }
        }
    }

    /// The design's `line-height: 1.4` for the paths, a little looser than the page's.
    static let pathLineHeight = AttributedString.LineHeight.multiple(factor: 1.4)

    static let probePrefix = "Site probe · "

    /// Lets long paths wrap after each `/` (like the design's `word-break: break-all`) for display only.
    static func wrappable(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "/\u{200B}")
    }

    /// A source whose process Surge never reported (stored with an empty or legacy `unknown` path).
    static func isUnreported(_ source: InventorySource) -> Bool {
        source.path.isEmpty || source.path == "unknown"
    }

    static func isProbe(_ source: InventorySource) -> Bool {
        source.probeSessionID != nil || source.path.hasPrefix(probePrefix) || source.path.hasPrefix("probe:")
    }

    /// The process path, or `Site probe · github.com` in the current language.
    @MainActor
    static func displayPath(_ source: InventorySource) -> String {
        if isUnreported(source) { return tr("Process not reported by Surge", "Inventory") }
        if source.path.hasPrefix(probePrefix) {
            return trf("Site probe · %@", "Inventory", String(source.path.dropFirst(probePrefix.count)))
        }
        if source.path.hasPrefix("probe:") {
            return trf("Site probe · %@", "Inventory", source.title)
        }
        return source.path
    }

    @MainActor
    static func displayTitle(_ source: InventorySource) -> String {
        isProbe(source) ? displayPath(source) : source.title
    }

    /// The sources shown, as VoiceOver reads them: each app's name and process path, or the probe or "not reported".
    @MainActor
    static func accessibilityText(_ sources: [InventorySource]) -> String {
        sources.prefix(6).map { source in
            isProbe(source) || isUnreported(source) ? displayPath(source) : "\(source.title), \(displayPath(source))"
        }.joined(separator: "; ")
    }
}

/// Tile of an inventory source: the monitored app's tile, the bundle's icon, or the purple `P` of a probe.
struct InventorySourceTile: View {
    let model: AppModel
    var source: InventorySource
    var size: CGFloat

    var body: some View {
        if InventorySourcesList.isProbe(source) {
            LetterTile(letter: "P", color: Theme.tileProbe, size: size)
        } else if InventorySourcesList.isUnreported(source) {
            LetterTile(letter: "?", color: Theme.tileNeutral, size: size)
        } else if let app = model.catalog.app(source.appID) {
            AppTile(app: app, size: size)
        } else {
            AppTile(identity: AppIdentity(name: source.title, bundlePath: source.bundlePath,
                                          letter: String(source.title.prefix(1)), hue: nil,
                                          isMonitored: false, appID: nil),
                    size: size)
        }
    }
}

/// A site (domains) or network (IPs) row of the grouped Domains & IPs table.
struct InventoryGroup: Identifiable, Hashable {
    var name: String
    var kind: HostKind
    var names: [String]
    /// Distinct sources by title.
    var sources: [InventorySource]
    var requests: Int64

    /// Never an entry's id: grouping swaps the entries for the groups in the same lazy stack, which draws a group in
    /// the row it kept for the entry with the same id (the site `sentry.io` as the domain `sentry.io`).
    var id: String { "group:\(kind.rawValue):\(name)" }

    /// `a.com  ·  b.com  ·  c.com  ·  d.com  ·  +3`
    var preview: String {
        let head = names.prefix(4).joined(separator: "  ·  ")
        return names.count > 4 ? head + "  ·  +\(names.count - 4)" : head
    }

    /// Groups domains by registrable domain and IPs by network (`AS13335 Cloudflare`), busiest first.
    static func make(_ entries: [InventoryEntry], site: (String) -> String, unknownNetwork: String) -> [InventoryGroup] {
        var groups: [String: InventoryGroup] = [:]
        var sourceTitles: [String: Set<String>] = [:]
        var order: [String] = []
        for entry in entries {
            let name = entry.kind == .ip ? network(entry.geo) ?? unknownNetwork : site(entry.value)
            let key = "\(entry.kind.rawValue):\(name)"
            if groups[key] == nil {
                groups[key] = InventoryGroup(name: name, kind: entry.kind, names: [], sources: [], requests: 0)
                order.append(key)
            }
            groups[key]?.names.append(entry.value)
            groups[key]?.requests += entry.requestCount
            for source in entry.sources where sourceTitles[key, default: []].insert(source.title).inserted {
                groups[key]?.sources.append(source)
            }
        }
        return order.compactMap { groups[$0] }.sorted { a, b in
            a.requests != b.requests ? a.requests > b.requests : a.name < b.name
        }
    }

    /// `AS13335 Cloudflare`, the network half of `GeoInfo.display`.
    static func network(_ geo: GeoInfo?) -> String? {
        guard let geo else { return nil }
        var parts: [String] = []
        if let asn = geo.asn { parts.append("AS\(asn)") }
        if let organization = geo.organization, !organization.isEmpty { parts.append(GeoInfo.shortOrganization(organization)) }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}
