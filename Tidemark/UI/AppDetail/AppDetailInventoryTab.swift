import SwiftUI
import UniformTypeIdentifiers

/// "Domains & IPs" tab of a monitored app: every domain (grouped by site) and every IP it used, each
/// listed once, with a search field and CSV export. Selecting a domain highlights the IPs it resolved to.
struct AppDetailInventoryTab: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp
    var absent: Bool

    @State private var hosts: [AppHost] = []
    /// The app and scope `hosts` were last loaded for.
    @State private var loadedKey: LoadKey?
    /// Groups and counts of `hosts`, recomputed when they or the search change (not on every hover).
    @State private var summary = AppDetailInventorySummary()
    @State private var exportDocument: AnalyzeCSVDocument?
    @State private var isExporting = false
    @State private var exportError: (any Error)?

    fileprivate static let domainColumns: [AnalyzeColumnsLayout.Column] = [.flexible(weight: 1, min: 150), .fixed(104), .fixed(70), .fixed(64)]
    fileprivate static let ipColumns: [AnalyzeColumnsLayout.Column] = [.fixed(150), .flexible(weight: 1, min: 90), .fixed(56)]

    var body: some View {
        let key = LoadKey(appID: app.id, scope: absent ? .all : model.devices.scope)
        Group {
            if loadedKey == key && hosts.isEmpty {
                waitingState
            } else {
                VStack(spacing: 0) {
                    summaryLine
                    Text(trf("Every domain and IP %@ has used, each listed once. The first time a new one appears you get an alert, and it stays marked NEW for 24 hours.", "AppDetail", app.name))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.ink2)
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            domainsPane.frame(width: geometry.size.width * 1.4 / 2.4)
                            Rectangle().fill(Theme.line).frame(width: 0.5)
                            ipsPane.frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .fileExporter(isPresented: $isExporting, document: exportDocument, contentType: .commaSeparatedText,
                      defaultFilename: trf("%@ domains and IPs", "AppDetail", app.name),
                      onCompletion: { result in
                          if case .failure(let error) = result { exportError = error }
                      })
        .alert(error: $exportError) {
            Button(tr("OK", "AppDetail")) {}
        }
        .task(id: key) {
            await refresh(key)
        }
        .onChange(of: model.nav.appInventorySearch) { recompute() }
    }

    // MARK: Header

    private var summaryLine: some View {
        @Bindable var nav = model.nav
        return HStack(spacing: 12) {
            Text(summary.headline)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if summary.newCount > 0 {
                AnalyzePill(text: trn("%lld new domain or IP in 24 h", "%lld new domains & IPs in 24 h", summary.newCount, "AppDetail"), size: 11)
            }
            Spacer(minLength: 0)
            FilterField(prompt: tr("Search", "AppDetail"), text: $nav.appInventorySearch, width: 190)
            Button(tr("Export CSV", "AppDetail"), action: export)
                .buttonStyle(.bordered)
                .disabled(hosts.isEmpty)
                .help(tr("Save every domain and IP of this app as a CSV file", "AppDetail"))
        }
        .padding(.horizontal, 20)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private var waitingState: some View {
        VStack(spacing: 8) {
            Circle()
                .strokeBorder(Theme.ink3, style: StrokeStyle(lineWidth: 2, dash: [4, 3]))
                .frame(width: 44, height: 44)
            Text(trf("Waiting for the first request from %@", "AppDetail", app.name))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(tr("Nothing in the database yet. Domains and IPs show up here as soon as Surge sees this app, or anything it launches, open a connection.", "AppDetail"))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Domains

    private var domainsPane: some View {
        let selected = summary.selectedHost(model.nav.appSelectedHost)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(tr("Domains", "AppDetail")).font(.system(size: 12.5, weight: .bold))
                Text(trf("%1$@ in %2$@", "AppDetail",
                         trn("%lld host", "%lld hosts", summary.domainCount, "AppDetail"),
                         trn("%lld site", "%lld sites", summary.siteCount, "AppDetail")))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            ScrollView {
                // The column header is pinned inside the scroll view so it keeps the rows' width when an
                // always-visible scroller takes room.
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        ForEach(summary.groups) { group in
                            siteRow(group)
                            ForEach(group.hosts) { host in
                                AppDetailDomainRow(host: host, selected: selected == host.value)
                            }
                        }
                    } header: {
                        AnalyzeHeaderRow(columns: Self.domainColumns, height: 26, horizontalPadding: 16) {
                            Text(tr("Site · host", "AppDetail"))
                            Text(tr("First seen", "AppDetail"))
                            Text(tr("Last seen", "AppDetail"))
                            Text(tr("Requests", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .background(Theme.bg)
                    }
                }
                .padding(.bottom, 10)
            }
        }
    }

    private func siteRow(_ group: AppDetailInventorySummary.SiteGroup) -> some View {
        AnalyzeColumnsLayout(columns: Self.domainColumns) {
            HStack(spacing: 8) {
                Text(group.site).fontWeight(.semibold).lineLimit(1)
                Text(trn("%lld host", "%lld hosts", group.hosts.count, "AppDetail"))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize()
                if group.isNewSite { TagBadge(text: tr("NEW SITE", "AppDetail"), style: .new) }
            }
            Text(AnalyzeFormat.seen(group.firstSeen)).font(.system(size: 12)).foregroundStyle(Theme.ink2).lineLimit(1)
            Text(AnalyzeFormat.seen(group.lastSeen, timeOnlyToday: true)).font(Theme.mono(11)).foregroundStyle(Theme.ink2).lineLimit(1)
            Text(Fmt.count(group.requests)).font(Theme.mono(11, weight: .semibold)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12.5))
        .padding(.horizontal, 16)
        .frame(height: 30)
        .background(Theme.bg2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    // MARK: IPs

    private var ipsPane: some View {
        @Bindable var nav = model.nav
        let selected = summary.selectedHost(nav.appSelectedHost)
        // Like the design's "N of M", the Direct / From domains switch doesn't change the count.
        let shown = summary.visibleIPCount(selectedHost: selected)
        let title = HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(selected.map { trf("IPs used by %@", "AppDetail", $0) } ?? tr("All IPs", "AppDetail"))
                .font(.system(size: 12.5, weight: .bold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(trf("%1$lld of %2$lld", "AppDetail", shown, summary.ipCount))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize()
        }
        let filter = DesignSegmentedControl(tr("Show", "AppDetail"), selection: $nav.appIPFilter, size: .small(), segments: [
            (.all, tr("All", "AppDetail")),
            (.direct, tr("Direct", "AppDetail")),
            (.resolved, tr("From domains", "AppDetail")),
        ])
        return VStack(spacing: 0) {
            // One row when the pane is wide enough, otherwise the filter moves under the title.
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    title
                    Spacer(minLength: 8)
                    filter
                    showAllButton(selected)
                }
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title
                        Spacer(minLength: 0)
                        showAllButton(selected)
                    }
                    filter
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        if nav.appIPFilter != .resolved {
                            ipGroupHeader(tr("Direct", "AppDetail"), count: summary.directIPs.count,
                                          note: tr("reached by IP, no hostname", "AppDetail"))
                            ForEach(summary.directIPs) { AppDetailIPRow(ip: $0, selectedHost: selected) }
                            if summary.directIPs.isEmpty {
                                Text(tr("Nothing reached by IP alone.", "AppDetail"))
                                    .font(.system(size: 11.5))
                                    .foregroundStyle(Theme.ink3)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 10)
                            }
                        }
                        if nav.appIPFilter != .direct {
                            ipGroupHeader(tr("Resolved from domains", "AppDetail"), count: summary.resolvedIPs.count,
                                          note: tr("the domains on the left resolved to these", "AppDetail"))
                            ForEach(summary.resolvedIPs) { AppDetailIPRow(ip: $0, selectedHost: selected) }
                        }
                    } header: {
                        AnalyzeHeaderRow(columns: Self.ipColumns, height: 26, horizontalPadding: 16) {
                            Text(verbatim: "IP")
                            Text(tr("Network · domains", "AppDetail"))
                            Text(tr("Requests", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .background(Theme.bg)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func showAllButton(_ selected: String?) -> some View {
        if selected != nil {
            Button(tr("Show all", "AppDetail")) {
                withAnimation(.easeOut(duration: 0.2)) { model.nav.appSelectedHost = nil }
            }
            .buttonStyle(.link)
            .font(.system(size: 11.5))
            .fixedSize()
        }
    }

    private func ipGroupHeader(_ title: String, count: Int, note: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(title).foregroundStyle(Theme.ink)
            Text(verbatim: String(count)).fontWeight(.medium).foregroundStyle(Theme.ink3)
            Text(note).fontWeight(.medium).foregroundStyle(Theme.ink3).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11, weight: .semibold))
        .padding(.horizontal, 16)
        .padding(.top, 10)
        .padding(.bottom, 5)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    // MARK: Loading and export

    private struct LoadKey: Hashable {
        var appID: AppID
        var scope: DeviceScope
    }

    private func refresh(_ key: LoadKey) async {
        if loadedKey != key, !hosts.isEmpty {
            // Another app or scope: don't show the previous list while the new one loads.
            hosts = []
            recompute()
        }
        while !Task.isCancelled {
            do {
                let fresh = try await model.database.appHosts(key.appID, scope: key.scope)
                if Task.isCancelled { return }
                hosts = fresh
                // Also refreshes the NEW marks, which expire with time.
                recompute()
            } catch {
                // Keep the last list; the sidebar footer reports database problems.
            }
            loadedKey = key
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func recompute() {
        summary = AppDetailInventorySummary(hosts: hosts, search: model.nav.appInventorySearch,
                                            site: { model.classifier.site(for: $0) })
    }

    private func export() {
        exportDocument = AnalyzeCSVDocument(text: AnalyzeCSV.appHosts(hosts))
        isExporting = true
    }
}

/// A domain under its site.
private struct AppDetailDomainRow: View {
    @Environment(AppModel.self) private var model
    var host: AppHost
    var selected: Bool

    var body: some View {
        AnalyzeColumnsLayout(columns: AppDetailInventoryTab.domainColumns) {
            HStack(spacing: 7) {
                Text(verbatim: "└").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                Text(host.value).lineLimit(1).truncationMode(.middle)
                if host.isNew() { TagBadge(text: tr("NEW", "AppDetail"), style: .new) }
            }
            .padding(.leading, 12)
            Text(AnalyzeFormat.seen(host.firstSeen)).foregroundStyle(Theme.ink2).lineLimit(1)
            Text(AnalyzeFormat.seen(host.lastSeen, timeOnlyToday: true)).font(Theme.mono(11)).foregroundStyle(Theme.ink2).lineLimit(1)
            Text(Fmt.count(host.requestCount)).font(Theme.mono(11)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .frame(height: 28)
        .background(selected ? Theme.accentTint : .clear)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) {
                model.nav.appSelectedHost = model.nav.appSelectedHost == host.value ? nil : host.value
            }
        }
        .help(host.processName.map { trf("First reached by %@", "AppDetail", $0) } ?? host.value)
    }
}

/// An IP with its network and the domains that resolved to it; dimmed when another domain is selected.
private struct AppDetailIPRow: View {
    var ip: AppHost
    var selectedHost: String?

    var body: some View {
        let highlighted = selectedHost.map { ip.hosts.contains($0) } ?? false
        let dimmed = selectedHost != nil && !highlighted
        AnalyzeColumnsLayout(columns: AppDetailInventoryTab.ipColumns) {
            HStack(spacing: 6) {
                Text(ip.value).font(Theme.mono(11.5)).lineLimit(1).textSelection(.enabled)
                if ip.isNew() { TagBadge(text: tr("NEW", "AppDetail"), style: .new) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ip.geo?.display ?? "—")
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .help(ip.geo.map(AppDetailInventoryFormat.fullGeo) ?? "")
                HStack(spacing: 5) {
                    if ip.isDirect { TagBadge(text: tr("BY IP", "AppDetail")) }
                    // Whole host names, cut at the end: a cut in the middle invents names that don't exist.
                    Text(ip.hosts.isEmpty ? tr("No hostname · connected by IP", "AppDetail") : AppDetailInventoryFormat.domains(ip.hosts))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(ip.hosts.joined(separator: "\n"))
                }
            }
            Text(Fmt.count(ip.requestCount)).font(Theme.mono(11)).frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(highlighted ? Theme.accentTint : .clear)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        .opacity(dimmed ? 0.35 : 1)
        .animation(.easeOut(duration: 0.2), value: dimmed)
    }
}

/// Text helpers of the "Domains & IPs" tab.
enum AppDetailInventoryFormat {
    /// `api.anthropic.com, claude.ai +2`: the first hosts in full, then how many more there are.
    static func domains(_ hosts: [String], limit: Int = 3) -> String {
        let head = hosts.prefix(limit).joined(separator: ", ")
        return hosts.count > limit ? "\(head) +\(hosts.count - limit)" : head
    }

    /// `US · AS399358 Anthropic, PBC`: like `GeoInfo.display`, with the organization's full name.
    static func fullGeo(_ geo: GeoInfo) -> String {
        var parts: [String] = []
        if let country = geo.countryCode, !country.isEmpty { parts.append(country.uppercased()) }
        let network = [geo.asn.map { "AS\($0)" }, geo.organization].compactMap { $0 }.filter { !$0.isEmpty }
        if !network.isEmpty { parts.append(network.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }
}

/// Groups and counts behind the "Domains & IPs" tab (pure, so it can be tested).
struct AppDetailInventorySummary {
    struct SiteGroup: Identifiable, Equatable {
        var site: String
        var hosts: [AppHost]
        var firstSeen: Date
        var lastSeen: Date
        var requests: Int64
        /// Every host of the site is still new, i.e. the whole site is a first contact.
        var isNewSite: Bool
        var id: String { site }
    }

    var domainCount = 0
    var siteCount = 0
    var ipCount = 0
    var directIPCount = 0
    var newCount = 0
    /// Site groups matching the search, new sites first, then by requests.
    var groups: [SiteGroup] = []
    var directIPs: [AppHost] = []
    var resolvedIPs: [AppHost] = []
    private var domainValues: Set<String> = []

    /// No hosts.
    init() {}

    init(hosts: [AppHost], search: String, now: Date = .now, site: (String) -> String) {
        let domains = hosts.filter { $0.kind == .domain }
        let ips = hosts.filter { $0.kind == .ip }
        domainValues = Set(domains.map(\.value))
        domainCount = domains.count
        ipCount = ips.count
        directIPCount = ips.filter(\.isDirect).count
        newCount = hosts.filter { $0.isNew(now: now) }.count

        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var bySite: [String: [AppHost]] = [:]
        for domain in domains { bySite[domain.site ?? site(domain.value), default: []].append(domain) }
        siteCount = bySite.count

        let order: (AppHost, AppHost) -> Bool = { a, b in
            let newA = a.isNew(now: now), newB = b.isNew(now: now)
            if newA != newB { return newA }
            if a.requestCount != b.requestCount { return a.requestCount > b.requestCount }
            return a.value < b.value
        }
        groups = bySite.compactMap { site, members in
            let visible = query.isEmpty ? members : members.filter { $0.value.lowercased().contains(query) }
            guard !visible.isEmpty else { return nil }
            return SiteGroup(site: site, hosts: visible.sorted(by: order),
                             firstSeen: members.map(\.firstSeen).min() ?? now,
                             lastSeen: members.map(\.lastSeen).max() ?? now,
                             requests: members.reduce(0) { $0 + $1.requestCount },
                             isNewSite: members.allSatisfy { $0.isNew(now: now) })
        }
        .sorted { a, b in
            if a.isNewSite != b.isNewSite { return a.isNewSite }
            if a.requests != b.requests { return a.requests > b.requests }
            return a.site < b.site
        }

        let visibleIPs = ips.filter { ip in
            query.isEmpty || ip.value.lowercased().contains(query)
                || (ip.geo?.display.lowercased().contains(query) ?? false)
                || ip.hosts.contains { $0.lowercased().contains(query) }
        }
        .sorted(by: order)
        directIPs = visibleIPs.filter(\.isDirect)
        resolvedIPs = visibleIPs.filter { !$0.isDirect }
    }

    /// `11 domains · 6 sites · 9 IPs (1 by IP only)`, the clause included when it counts none, like the design.
    @MainActor
    var headline: String {
        let base = [
            trn("%lld domain", "%lld domains", domainCount, "AppDetail"),
            trn("%lld site", "%lld sites", siteCount, "AppDetail"),
            trn("%lld IP", "%lld IPs", ipCount, "AppDetail"),
        ].joined(separator: " · ")
        return trf("%1$@ (%2$lld by IP only)", "AppDetail", base, directIPCount)
    }

    /// The selected host, if it is still one of the app's domains.
    func selectedHost(_ host: String?) -> String? {
        guard let host, domainValues.contains(host) else { return nil }
        return host
    }

    /// IPs the search keeps that the host selection doesn't dim (all of them when nothing is selected).
    func visibleIPCount(selectedHost: String?) -> Int {
        let listed = directIPs + resolvedIPs
        guard let selectedHost else { return listed.count }
        return listed.filter { $0.hosts.contains(selectedHost) }.count
    }
}
