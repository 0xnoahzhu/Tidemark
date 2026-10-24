import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Global Domains & IPs page, deduplicated across every app and probe.
///
/// A sortable table lists each domain and IP once with the processes (and probes) that reached it;
/// "Group by site" folds domains into their registrable domain and IPs into their network.
struct InventoryView: View {
    @Environment(AppModel.self) private var model

    @State private var entries: [InventoryEntry] = []
    @State private var loaded = false
    @State private var sortOrder = [KeyPathComparator(\InventoryEntry.firstSeen, order: .reverse)]
    @State private var selection: Set<InventoryEntry.ID> = []
    @State private var exportDocument: AnalyzeCSVDocument?
    @State private var isExporting = false
    @State private var exportError: (any Error)?

    var body: some View {
        @Bindable var nav = model.nav
        let visible = visibleEntries()

        content(visible)
            .navigationTitle(tr("Domains & IPs", "Inventory"))
            .navigationSubtitle(subtitle)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Picker(tr("Kind", "Inventory"), selection: $nav.inventoryKind) {
                        Text(tr("All", "Inventory")).tag(HostKind?.none)
                        Text(tr("Domains", "Inventory")).tag(HostKind?.some(.domain))
                        Text(tr("IPs", "Inventory")).tag(HostKind?.some(.ip))
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Toggle(isOn: $nav.inventoryGrouped) {
                        Label(tr("Group by site", "Inventory"), systemImage: "square.stack.3d.up")
                            .labelStyle(.titleAndIcon)
                    }
                    .toggleStyle(.button)
                    .help(tr("Fold domains into their site and IPs into their network", "Inventory"))
                }
                ToolbarSpacer(.fixed, placement: .primaryAction)
                ToolbarItem(placement: .primaryAction) {
                    Button(tr("Export CSV", "Inventory")) {
                        exportDocument = AnalyzeCSVDocument(text: AnalyzeCSV.inventory(visible))
                        isExporting = true
                    }
                    .disabled(visible.isEmpty)
                }
            }
            .searchable(text: $nav.inventorySearch, prompt: Text(tr("Search", "Inventory")))
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
    }

    @ViewBuilder
    private func content(_ visible: [InventoryEntry]) -> some View {
        if loaded && visible.isEmpty {
            if model.nav.inventorySearch.trimmingCharacters(in: .whitespaces).isEmpty {
                EmptyState(systemImage: "network",
                           title: tr("No domains or IPs yet", "Inventory"),
                           message: tr("Every domain and IP that Surge sees shows up here once, whichever app or probe reached it.", "Inventory"))
            } else {
                ContentUnavailableView.search(text: model.nav.inventorySearch)
            }
        } else if model.nav.inventoryGrouped {
            groupedTable(visible)
        } else {
            flatTable(visible)
        }
    }

    private var subtitle: String {
        let domains = entries.filter { $0.kind == .domain }.count
        return trf("%1$@ · %2$@, deduplicated across every app and probe", "Inventory",
                   trn("%lld domain", "%lld domains", domains, "Inventory"),
                   trn("%lld IP", "%lld IPs", entries.count - domains, "Inventory"))
    }

    private func visibleEntries() -> [InventoryEntry] {
        let kind = model.nav.inventoryKind
        return entries.filter { kind == nil || $0.kind == kind }.sorted(using: sortOrder)
    }

    // MARK: Flat table

    private func flatTable(_ rows: [InventoryEntry]) -> some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(tr("Name", "Inventory"), value: \.value) { entry in
                Text(entry.value)
                    .font(entry.kind == .ip ? Theme.mono(12, weight: .medium) : .system(size: 12, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(entry.geo?.display ?? entry.value)
            }
            .width(min: 150, ideal: 230)

            TableColumn(tr("Type", "Inventory")) { entry in
                InventoryKindChip(kind: entry.kind)
            }
            .width(58)

            TableColumn(tr("Seen by · process path", "Inventory")) { entry in
                InventorySourcesList(model: model, sources: entry.sources)
            }
            .width(min: 240, ideal: 440)

            TableColumn(tr("First seen", "Inventory"), value: \.firstSeen) { entry in
                Text(AnalyzeFormat.seen(entry.firstSeen)).foregroundStyle(Theme.ink2)
            }
            .width(min: 84, ideal: 96)

            TableColumn(tr("Last seen", "Inventory"), value: \.lastSeen) { entry in
                Text(AnalyzeFormat.seen(entry.lastSeen, timeOnlyToday: true)).foregroundStyle(Theme.ink2)
            }
            .width(min: 70, ideal: 84)

            TableColumn(tr("Requests", "Inventory"), value: \.requestCount) { entry in
                Text(Fmt.count(entry.requestCount))
                    .font(Theme.mono(11))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 60, ideal: 74)
        }
        .font(.system(size: 12))
        .contextMenu(forSelectionType: InventoryEntry.ID.self) { ids in
            selectionMenu(ids)
        }
    }

    @ViewBuilder
    private func selectionMenu(_ ids: Set<InventoryEntry.ID>) -> some View {
        let values = entries.filter { ids.contains($0.id) }.map(\.value)
        if !values.isEmpty {
            Button(values.count == 1 ? tr("Copy", "Inventory") : trf("Copy %lld Items", "Inventory", values.count)) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(values.joined(separator: "\n"), forType: .string)
            }
            if values.count == 1, let value = values.first {
                let state = AnalyzeMuteState(value, alerts: model.alerts)
                Button(AnalyzeMuteButton.title(state)) {
                    Task { await AnalyzeMuteButton.toggle(value, state: state, model: model) }
                }
                .disabled(state == .mutedByRule)
            }
        }
    }

    // MARK: Grouped table

    private func groupedTable(_ rows: [InventoryEntry]) -> some View {
        let groups = InventoryGroup.make(rows, site: { model.classifier.site(for: $0) },
                                         unknownNetwork: tr("Unknown network", "Inventory"))
        return Table(groups) {
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
            .width(min: 110, ideal: 140)

            TableColumn(tr("Requests", "Inventory")) { group in
                Text(Fmt.count(group.requests))
                    .font(Theme.mono(11))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 84)
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
            if let fresh = try? await model.database.inventory(kind: nil, search: search, scope: model.devices.scope), !Task.isCancelled {
                entries = fresh
            }
            loaded = true
            try? await Task.sleep(for: .seconds(30))
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

/// Up to six "seen by" rows: a tile (app icon, letter, or the purple probe tile) and the process path.
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
            if sources.count > 6 {
                Text(trf("+%lld more", "Inventory", sources.count - 6))
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.ink3)
            }
        }
        .padding(.vertical, 3)
    }

    static let probePrefix = "Site probe · "

    /// Lets long paths wrap after each `/` (like the design's `word-break: break-all`) for display only.
    static func wrappable(_ path: String) -> String {
        path.replacingOccurrences(of: "/", with: "/\u{200B}")
    }

    static func isProbe(_ source: InventorySource) -> Bool {
        source.probeSessionID != nil || source.path.hasPrefix(probePrefix) || source.path.hasPrefix("probe:")
    }

    /// The process path, or `Site probe · github.com` in the current language.
    @MainActor
    static func displayPath(_ source: InventorySource) -> String {
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
            for source in entry.sources where !(groups[key]?.sources.contains { $0.title == source.title } ?? true) {
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
