import SwiftUI
import UniformTypeIdentifiers

/// "Domains & IPs" tab of a monitored app: every domain (grouped by site) and every IP it used, each
/// listed once. Selecting a domain highlights the IPs it resolved to.
struct AppDetailInventoryTab: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp
    var absent: Bool

    @State private var hosts: [AppHost] = []
    @State private var loaded = false
    @State private var hovered: String?
    @State private var exportDocument: AnalyzeCSVDocument?
    @State private var isExporting = false
    @State private var exportError: (any Error)?

    private static let domainColumns: [AnalyzeColumnsLayout.Column] = [.flexible(weight: 1, min: 150), .fixed(104), .fixed(70), .fixed(64)]
    private static let ipColumns: [AnalyzeColumnsLayout.Column] = [.fixed(150), .flexible(weight: 1, min: 90), .fixed(56)]

    var body: some View {
        @Bindable var nav = model.nav
        let summary = AppDetailInventorySummary(hosts: hosts, search: nav.appInventorySearch,
                                                site: { model.classifier.site(for: $0) })
        Group {
            if loaded && hosts.isEmpty {
                waitingState
            } else {
                VStack(spacing: 0) {
                    summaryLine(summary)
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
                            domainsPane(summary).frame(width: geometry.size.width * 1.4 / 2.4)
                            Rectangle().fill(Theme.line).frame(width: 0.5)
                            ipsPane(summary).frame(maxWidth: .infinity)
                        }
                    }
                }
            }
        }
        .searchable(text: $nav.appInventorySearch, prompt: Text(tr("Search", "AppDetail")))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(tr("Export CSV", "AppDetail"), action: export)
                    .disabled(hosts.isEmpty)
                    .help(tr("Save every domain and IP of this app as a CSV file", "AppDetail"))
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
        .task(id: LoadKey(appID: app.id, scope: absent ? .all : model.devices.scope)) {
            await refresh(scope: absent ? .all : model.devices.scope)
        }
    }

    // MARK: Header

    private func summaryLine(_ summary: AppDetailInventorySummary) -> some View {
        HStack(spacing: 12) {
            Text(summary.headline)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            if summary.newCount > 0 {
                AnalyzePill(text: trn("%lld new domain or IP in 24 h", "%lld new domains & IPs in 24 h", summary.newCount, "AppDetail"), size: 11)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
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

    private func domainsPane(_ summary: AppDetailInventorySummary) -> some View {
        VStack(spacing: 0) {
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
            AnalyzeHeaderRow(columns: Self.domainColumns, height: 26, horizontalPadding: 16) {
                Text(tr("Site · host", "AppDetail"))
                Text(tr("First seen", "AppDetail"))
                Text(tr("Last seen", "AppDetail"))
                Text(tr("Requests", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(summary.groups) { group in
                        siteRow(group)
                        ForEach(group.hosts) { host in
                            domainRow(host, selected: summary.selectedHost(model.nav.appSelectedHost) == host.value)
                        }
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

    private func domainRow(_ host: AppHost, selected: Bool) -> some View {
        let muteState = AnalyzeMuteState(host.value, alerts: model.alerts)
        return AnalyzeColumnsLayout(columns: Self.domainColumns) {
            HStack(spacing: 7) {
                Text(verbatim: "└").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                Text(host.value).lineLimit(1).truncationMode(.middle)
                if host.isNew() { TagBadge(text: tr("NEW", "AppDetail"), style: .new) }
                if muteState != .unmuted { TagBadge(text: tr("MUTED", "AppDetail")) }
                Spacer(minLength: 0)
                if hovered == host.id { AnalyzeMuteButton(value: host.value) }
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
        .onHover { inside in hovered = inside ? host.id : (hovered == host.id ? nil : hovered) }
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) {
                model.nav.appSelectedHost = model.nav.appSelectedHost == host.value ? nil : host.value
            }
        }
        .contextMenu { hostMenu(host.value, state: muteState) }
        .help(host.processName.map { trf("First reached by %@", "AppDetail", $0) } ?? host.value)
    }

    @ViewBuilder
    private func hostMenu(_ value: String, state: AnalyzeMuteState) -> some View {
        Button(tr("Copy", "AppDetail")) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }
        Button(AnalyzeMuteButton.title(state)) {
            Task { await AnalyzeMuteButton.toggle(value, state: state, model: model) }
        }
        .disabled(state == .mutedByRule)
    }

    // MARK: IPs

    private func ipsPane(_ summary: AppDetailInventorySummary) -> some View {
        @Bindable var nav = model.nav
        let selected = summary.selectedHost(nav.appSelectedHost)
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
        let filter = Picker(tr("Show", "AppDetail"), selection: $nav.appIPFilter) {
            Text(tr("All", "AppDetail")).tag(Navigation.IPFilter.all)
            Text(tr("Direct", "AppDetail")).tag(Navigation.IPFilter.direct)
            Text(tr("From domains", "AppDetail")).tag(Navigation.IPFilter.resolved)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.mini)
        .fixedSize()
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
            AnalyzeHeaderRow(columns: Self.ipColumns, height: 26, horizontalPadding: 16) {
                Text(verbatim: "IP")
                Text(tr("Network · domains", "AppDetail"))
                Text(tr("Requests", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
            }
            ScrollView {
                LazyVStack(spacing: 0) {
                    if nav.appIPFilter != .resolved {
                        ipGroupHeader(tr("Direct", "AppDetail"), count: summary.directIPs.count,
                                      note: tr("reached by IP, no hostname", "AppDetail"))
                        ForEach(summary.directIPs) { ipRow($0, selectedHost: selected) }
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
                        ForEach(summary.resolvedIPs) { ipRow($0, selectedHost: selected) }
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

    private func ipRow(_ ip: AppHost, selectedHost: String?) -> some View {
        let highlighted = selectedHost.map { ip.hosts.contains($0) } ?? false
        let dimmed = selectedHost != nil && !highlighted
        let muteState = AnalyzeMuteState(ip.value, alerts: model.alerts)
        return AnalyzeColumnsLayout(columns: Self.ipColumns) {
            HStack(spacing: 6) {
                Text(ip.value).font(Theme.mono(11.5)).lineLimit(1).textSelection(.enabled)
                if ip.isNew() { TagBadge(text: tr("NEW", "AppDetail"), style: .new) }
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(ip.geo?.display ?? "—").foregroundStyle(Theme.ink2).lineLimit(1)
                HStack(spacing: 5) {
                    if ip.isDirect { TagBadge(text: tr("BY IP", "AppDetail")) }
                    if muteState != .unmuted { TagBadge(text: tr("MUTED", "AppDetail")) }
                    Text(ip.hosts.isEmpty ? tr("No hostname · connected by IP", "AppDetail") : ip.hosts.joined(separator: ", "))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .overlay(alignment: .trailing) {
                if hovered == ip.id { AnalyzeMuteButton(value: ip.value) }
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
        .contentShape(Rectangle())
        .onHover { inside in hovered = inside ? ip.id : (hovered == ip.id ? nil : hovered) }
        .contextMenu { hostMenu(ip.value, state: muteState) }
    }

    // MARK: Loading and export

    private struct LoadKey: Hashable {
        var appID: AppID
        var scope: DeviceScope
    }

    private func refresh(scope: DeviceScope) async {
        while !Task.isCancelled {
            do {
                let fresh = try await model.database.appHosts(app.id, scope: scope)
                if Task.isCancelled { return }
                hosts = fresh
            } catch {
                // Keep the last list; the sidebar footer reports database problems.
            }
            loaded = true
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func export() {
        exportDocument = AnalyzeCSVDocument(text: AnalyzeCSV.appHosts(hosts, mutes: model.alerts.mutes))
        isExporting = true
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

    /// `11 domains · 6 sites · 9 IPs (1 by IP only)`
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

    /// IPs not dimmed by the host selection (all of them when nothing is selected).
    func visibleIPCount(selectedHost: String?) -> Int {
        let all = directIPs + resolvedIPs
        guard let selectedHost else { return all.count }
        return all.filter { $0.hosts.contains(selectedHost) }.count
    }
}
