import SwiftUI
import UniformTypeIdentifiers

/// Global Domains & IPs page, deduplicated across every app and probe.
///
/// A table lists each domain and IP once, newest first, with the processes (and probes) that reached it;
/// "Group by site" folds domains into their registrable domain and IPs into their network.
struct InventoryView: View {
    @Environment(AppModel.self) private var model

    @State private var entries: [InventoryEntry] = []
    /// `entries` filtered by kind and in the table's order, and their site / network groups. Recomputed only
    /// when the entries, the kind or the grouping change.
    @State private var visible: [InventoryEntry] = []
    @State private var groups: [InventoryGroup] = []
    @State private var domainCount = 0
    @State private var loaded = false
    @State private var exportDocument: AnalyzeCSVDocument?
    @State private var isExporting = false
    @State private var exportError: (any Error)?

    var body: some View {
        @Bindable var nav = model.nav

        content
            .navigationTitle(tr("Domains & IPs", "Inventory"))
            .navigationSubtitle(subtitle)
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
            .task(id: QueryKey(search: nav.inventorySearch.trimmingCharacters(in: .whitespaces), scope: model.devices.scope)) {
                await refresh()
            }
            .onChange(of: PresentationKey(kind: nav.inventoryKind, grouped: nav.inventoryGrouped,
                                          language: Localizer.shared.languageCode), initial: true) {
                recompute()
            }
    }

    @ViewBuilder
    private var content: some View {
        if loaded && visible.isEmpty {
            let search = model.nav.inventorySearch.trimmingCharacters(in: .whitespaces)
            if search.isEmpty {
                EmptyState(systemImage: "network",
                           title: tr("No domains or IPs yet", "Inventory"),
                           message: tr("Every domain and IP that Surge sees shows up here once, whichever app or probe reached it.", "Inventory"))
            } else {
                // Not `ContentUnavailableView.search`, whose text follows the system language rather than
                // Settings › Language.
                EmptyState(systemImage: "magnifyingglass",
                           title: trf("No domains or IPs match “%@”", "Inventory", search),
                           message: tr("The search looks at each domain or IP and the apps and probes that reached it.", "Inventory"))
            }
        } else if model.nav.inventoryGrouped {
            groupedTable
        } else {
            flatTable
        }
    }

    private var subtitle: String {
        trf("%1$@ · %2$@, deduplicated across every app and probe", "Inventory",
            trn("%lld domain", "%lld domains", domainCount, "Inventory"),
            trn("%lld IP", "%lld IPs", entries.count - domainCount, "Inventory"))
    }

    private struct PresentationKey: Hashable {
        var kind: HostKind?
        var grouped: Bool
        var language: String
    }

    /// Filters, orders and groups `entries` for the tables.
    private func recompute() {
        visible = InventoryPresentation.visible(entries, kind: model.nav.inventoryKind)
        groups = model.nav.inventoryGrouped
            ? InventoryGroup.make(visible, site: { model.classifier.site(for: $0) }, unknownNetwork: tr("Unknown network", "Inventory"))
            : []
        domainCount = entries.reduce(0) { $0 + ($1.kind == .domain ? 1 : 0) }
    }

    // MARK: Flat table

    private var flatTable: some View {
        // As in the design, the headers do not sort: the rows keep the newest first.
        Table(visible) {
            TableColumn(tr("Name", "Inventory")) { entry in
                Text(entry.value)
                    .font(entry.kind == .ip ? Theme.mono(12, weight: .medium) : .system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.geo?.display ?? entry.value)
            }
            .width(min: 150, ideal: 270)

            TableColumn(tr("Type", "Inventory")) { entry in
                InventoryKindChip(kind: entry.kind)
            }
            .width(58)

            // The path column takes the spare width (2fr in the design); the date and count columns are capped
            // so the table's uniform column resizing cannot widen them instead.
            TableColumn(tr("Seen by · process path", "Inventory")) { entry in
                InventorySourcesList(model: model, sources: entry.sources)
            }
            .width(min: 240, ideal: 480)

            TableColumn(tr("First seen", "Inventory")) { entry in
                Text(AnalyzeFormat.seen(entry.firstSeen)).foregroundStyle(Theme.ink2)
            }
            .width(min: 108, ideal: 112, max: 120)

            TableColumn(tr("Last seen", "Inventory")) { entry in
                Text(AnalyzeFormat.seen(entry.lastSeen, timeOnlyToday: true)).foregroundStyle(Theme.ink2)
            }
            .width(min: 108, ideal: 112, max: 120)

            TableColumn(tr("Requests", "Inventory")) { entry in
                Text(Fmt.count(entry.requestCount))
                    .font(Theme.mono(11))
            }
            .width(min: 60, ideal: 70, max: 84)
            .alignment(.trailing)
        }
        .font(.system(size: 12))
    }

    // MARK: Grouped table

    private var groupedTable: some View {
        Table(groups) {
            TableColumn(tr("Site or network", "Inventory")) { group in
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
            }
            .width(min: 260, ideal: 560)

            TableColumn(tr("Seen by", "Inventory")) { group in
                HStack(spacing: -4) {
                    ForEach(Array(group.sources.prefix(5).enumerated()), id: \.offset) { _, source in
                        InventorySourceTile(model: model, source: source, size: 18)
                            .padding(1.5)
                            .background(Theme.bg, in: RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                            .help(InventorySourcesList.displayTitle(source))
                    }
                }
            }
            .width(min: 110, ideal: 140, max: 180)

            TableColumn(tr("Requests", "Inventory")) { group in
                Text(Fmt.count(group.requests))
                    .font(Theme.mono(11))
            }
            .width(min: 60, ideal: 70, max: 90)
            .alignment(.trailing)
        }
        .font(.system(size: 12))
    }

    // MARK: Loading

    private struct QueryKey: Hashable {
        var search: String
        var scope: DeviceScope
    }

    private func refresh() async {
        // Debounce typing in the search field.
        if loaded {
            try? await Task.sleep(for: .milliseconds(300))
        }
        while !Task.isCancelled {
            let search = model.nav.inventorySearch.trimmingCharacters(in: .whitespaces)
            if let fresh = try? await model.database.inventory(kind: nil, search: search, scope: model.devices.scope),
               !Task.isCancelled, fresh != entries {
                entries = fresh
                recompute()
            }
            loaded = true
            try? await Task.sleep(for: .seconds(30))
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
/// Rendered inside `Table` cells, which do not receive custom environment objects on macOS 27, so the
/// model is passed explicitly.
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
