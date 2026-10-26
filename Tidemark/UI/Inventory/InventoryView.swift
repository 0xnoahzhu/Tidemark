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
            .navigationTitle(tr("Domains & IPs", "Inventory"))
            .navigationSubtitle(subtitle(snapshot))
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    DesignSegmentedControl(tr("Kind", "Inventory"), selection: $nav.inventoryKind,
                                           size: .regular(horizontalPadding: 11), segments: [
                        (nil, tr("All", "Inventory")),
                        (.domain, tr("Domains", "Inventory")),
                        (.ip, tr("IPs", "Inventory")),
                    ])
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Toggle(tr("Group by site", "Inventory"), isOn: $nav.inventoryGrouped)
                        .toggleStyle(.button)
                        .help(tr("Fold domains into their site and IPs into their network", "Inventory"))
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                // The design's order: the search field before Export CSV (`searchable` would put it last).
                ToolbarItem(placement: .primaryAction) {
                    ToolbarSearchField(text: $nav.inventorySearch, prompt: tr("Search", "Inventory"))
                        .frame(width: 170)
                }
                // The last item to overflow: the field has no usable form in the overflow menu.
                .visibilityPriority(.high)
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button(tr("Export CSV", "Inventory")) {
                        exportDocument = AnalyzeCSVDocument(text: AnalyzeCSV.inventory(visible))
                        isExporting = true
                    }
                    .disabled(visible.isEmpty)
                }
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
                // Not `ContentUnavailableView.search`, whose text follows the system language rather than
                // Settings › Language.
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
/// table it replaced (the inset style's header, row padding and alternating rounded rows). Flat and grouped
/// rows share the scroll view, so grouping only swaps the rows.
private struct InventoryList: View {
    let model: AppModel
    var entries: [InventoryEntry]
    /// The site and network groups when grouped by site; nil for the flat list.
    var groups: [InventoryGroup]?

    @State private var position = ScrollPosition(edge: .top)
    @State private var scrolled = InventoryScrollGeometry()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                if let groups {
                    Section {
                        InventoryTableMetrics.topInset
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            InventoryGroupRow(model: model, group: group, striped: index % 2 == 1)
                        }
                    } header: {
                        InventoryHeaderRow(columns: InventoryColumnsLayout.groupColumns, titles: [
                            (tr("Site or network", "Inventory"), .leading),
                            (tr("Seen by", "Inventory"), .leading),
                            (tr("Requests", "Inventory"), .trailing),
                        ])
                    }
                } else {
                    Section {
                        InventoryTableMetrics.topInset
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            InventoryEntryRow(model: model, entry: entry, striped: index % 2 == 1)
                        }
                    } header: {
                        InventoryHeaderRow(columns: InventoryColumnsLayout.entryColumns, titles: [
                            (tr("Name", "Inventory"), .leading),
                            (tr("Type", "Inventory"), .leading),
                            (tr("Seen by · process path", "Inventory"), .leading),
                            (tr("First seen", "Inventory"), .leading),
                            (tr("Last seen", "Inventory"), .leading),
                            (tr("Requests", "Inventory"), .trailing),
                        ])
                    }
                }
            }
            .padding(.bottom, InventoryTableMetrics.verticalInset)
        }
        .scrollPosition($position)
        .onScrollGeometryChange(for: ScrollGeometry.self, of: { $0 }) { _, geometry in
            scrolled.geometry = geometry
        }
        .background(InventoryTableMetrics.background)
        // A new table, like the one grouping used to build, starts at the top.
        .onChange(of: groups == nil) { position.scrollTo(edge: .top) }
        // Like the native table, the list takes focus from Tab and a click, and Home, End, Page Up and Page Down
        // scroll it.
        .focusable(interactions: .edit)
        .focusEffectDisabled()
        .onKeyPress(keys: [.home, .end, .pageUp, .pageDown]) { press in
            scroll(press.key)
        }
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
            let page = max(0, visible - InventoryTableMetrics.headerHeight - 10)
            let top = geometry.contentOffset.y + geometry.contentInsets.top
            let target = top + (key == .pageDown ? page : -page)
            position.scrollTo(y: min(max(0, target), max(0, geometry.contentSize.height - visible)))
        }
        return .handled
    }
}

/// The list's last scroll geometry, for the page keys; a reference, so scrolling does not update the view.
@MainActor
private final class InventoryScrollGeometry {
    var geometry: ScrollGeometry?
}

/// The native inset table's measurements and colors, which the list reproduces.
private enum InventoryTableMetrics {
    static let columnSpacing: CGFloat = 17
    static let horizontalPadding: CGFloat = 16
    static let verticalInset: CGFloat = 5
    static let headerHeight: CGFloat = 28
    static let rowPadding: CGFloat = 4

    static let background = Color(nsColor: .controlBackgroundColor)
    static let headerText = Color(nsColor: .headerTextColor)
    static let stripe = Color(nsColor: NSColor.alternatingContentBackgroundColors[1])
    static let headerSeparator = Color.dynamic(light: .black(0.1), dark: .white(0.16))
    static let headerLine = Color.dynamic(light: .black(0.1), dark: .white(0.115))

    /// The space between the header and the first row.
    static var topInset: some View { Color.clear.frame(height: verticalInset) }
}

/// Column titles with the native header's separators and bottom line.
private struct InventoryHeaderRow: View {
    var columns: [InventoryColumnsLayout.Column]
    var titles: [(title: String, alignment: Alignment)]

    var body: some View {
        InventoryColumnsLayout(columns: columns) {
            ForEach(Array(titles.enumerated()), id: \.offset) { index, column in
                Group {
                    if column.alignment == .trailing {
                        // Whole, as the native header draws a right-aligned title in a narrow column.
                        Text(column.title).fixedSize().padding(.trailing, 2)
                    } else {
                        Text(column.title).lineLimit(1).padding(.leading, 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: column.alignment)
                .overlay(alignment: .trailing) {
                    // Between the columns, not after the last one.
                    if index < titles.count - 1 {
                        Rectangle()
                            .fill(InventoryTableMetrics.headerSeparator)
                            .frame(width: 1, height: 15)
                            .offset(x: InventoryTableMetrics.columnSpacing / 2 + 0.5)
                    }
                }
            }
        }
        .font(.system(size: 12))
        .foregroundStyle(InventoryTableMetrics.headerText)
        .padding(.horizontal, InventoryTableMetrics.horizontalPadding)
        // The titles are centered above the bottom line, which the native header draws from 27 pt down.
        .frame(height: InventoryTableMetrics.headerHeight - 1)
        .padding(.bottom, 1)
        .background(InventoryTableMetrics.background)
        .overlay(alignment: .bottom) {
            Rectangle().fill(InventoryTableMetrics.headerLine).frame(height: 1.5).offset(y: 0.5)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }
}

/// The alternate rows' rounded background, inset like the native table's.
private struct InventoryRowStripe: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(InventoryTableMetrics.stripe)
            .padding(.leading, 10)
            .padding(.trailing, 10.5)
    }
}

/// A domain or IP of the flat list.
private struct InventoryEntryRow: View {
    let model: AppModel
    var entry: InventoryEntry
    var striped: Bool

    var body: some View {
        InventoryColumnsLayout(columns: InventoryColumnsLayout.entryColumns) {
            Text(entry.value)
                .font(entry.kind == .ip ? Theme.mono(12, weight: .medium) : .system(size: 12, weight: .medium))
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
        .font(.system(size: 12))
        .padding(.vertical, InventoryTableMetrics.rowPadding)
        .padding(.horizontal, InventoryTableMetrics.horizontalPadding)
        .background { if striped { InventoryRowStripe() } }
        .accessibilityElement(children: .combine)
    }
}

/// A site or network of the grouped list.
private struct InventoryGroupRow: View {
    let model: AppModel
    var group: InventoryGroup
    var striped: Bool

    var body: some View {
        InventoryColumnsLayout(columns: InventoryColumnsLayout.groupColumns) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(group.name).font(.system(size: 12.5, weight: .semibold)).lineLimit(1)
                    Text(group.kind == .ip
                         ? trn("%lld IP", "%lld IPs", group.names.count, "Inventory")
                         : trn("%lld host", "%lld hosts", group.names.count, "Inventory"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                }
                Text(group.preview)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
            }
            .padding(.vertical, 4)
            HStack(spacing: -4) {
                ForEach(Array(group.sources.prefix(5).enumerated()), id: \.offset) { _, source in
                    InventorySourceTile(model: model, source: source, size: 18)
                        .padding(1.5)
                        .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                        .help(InventorySourcesList.displayTitle(source))
                }
            }
            Text(Fmt.count(group.requests))
                .font(Theme.mono(11))
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.vertical, InventoryTableMetrics.rowPadding)
        .padding(.horizontal, InventoryTableMetrics.horizontalPadding)
        .background { if striped { InventoryRowStripe() } }
        .accessibilityElement(children: .combine)
    }
}

/// Lays out a row of the Domains & IPs table as the native table did: columns that cap their width keep their
/// minimum, and the others share the rest, each getting its ideal width plus an equal part of the space left over
/// (or minus an equal part of what is missing, down to its minimum). Cells start at their column's leading edge
/// and are centered vertically.
struct InventoryColumnsLayout: Layout {
    struct Column: Hashable, Sendable {
        var ideal: CGFloat
        var min: CGFloat
        var max: CGFloat = .infinity
    }

    /// Name, Type, Seen by · process path, First seen, Last seen, Requests.
    static let entryColumns: [Column] = [
        Column(ideal: 270, min: 150), Column(ideal: 58, min: 58, max: 58), Column(ideal: 480, min: 240),
        Column(ideal: 112, min: 108, max: 120), Column(ideal: 112, min: 108, max: 120), Column(ideal: 70, min: 60, max: 84),
    ]
    /// Site or network, Seen by, Requests.
    static let groupColumns: [Column] = [
        Column(ideal: 560, min: 260), Column(ideal: 140, min: 110, max: 180), Column(ideal: 70, min: 60, max: 90),
    ]

    var columns: [Column]
    var spacing: CGFloat = 17

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? columns.reduce(spacing * CGFloat(max(0, columns.count - 1))) { $0 + $1.ideal }
        let widths = Self.widths(for: columns, spacing: spacing, total: width)
        var height: CGFloat = 0
        for (index, subview) in subviews.enumerated() where index < widths.count {
            height = max(height, subview.sizeThatFits(ProposedViewSize(width: widths[index], height: nil)).height)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let widths = Self.widths(for: columns, spacing: spacing, total: bounds.width)
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

    /// Column widths for a row `total` points wide.
    static func widths(for columns: [Column], spacing: CGFloat, total: CGFloat) -> [CGFloat] {
        var result = columns.map(\.min)
        let shared = columns.indices.filter { columns[$0].max == .infinity }
        let available = total - spacing * CGFloat(max(0, columns.count - 1))
            - columns.indices.filter { !shared.contains($0) }.reduce(CGFloat(0)) { $0 + columns[$1].min }
        let minimums = shared.reduce(CGFloat(0)) { $0 + columns[$1].min }
        guard available > minimums else {
            // Too narrow for every minimum: the shared columns shrink in proportion.
            for index in shared { result[index] = minimums > 0 ? max(0, available) * columns[index].min / minimums : 0 }
            return result
        }
        var pool = shared
        var remaining = available
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
}

/// `Domain` (grey) or `IP` (tinted) type chip.
struct InventoryKindChip: View {
    var kind: HostKind

    var body: some View {
        let tint = Theme.tint(200)
        Text(kind == .ip ? tr("IP", "Inventory") : tr("Domain", "Inventory"))
            .font(.system(size: 10.5, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(kind == .ip ? tint.background : Theme.fill, in: RoundedRectangle(cornerRadius: 4, style: .continuous))
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
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(sources.prefix(6).enumerated()), id: \.offset) { _, source in
                HStack(alignment: .top, spacing: 6) {
                    InventorySourceTile(model: model, source: source, size: 14)
                        .padding(.top, 1)
                    Text(Self.wrappable(Self.displayPath(source)))
                        .font(Theme.mono(10.5))
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(1)
                        .lineLimit(4)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(Self.displayPath(source))
                }
            }
        }
        .padding(.vertical, 3)
    }

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

    var id: String { "\(kind.rawValue):\(name)" }

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
