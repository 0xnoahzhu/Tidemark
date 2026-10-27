import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// "Domains & IPs" tab of a monitored app: every domain (grouped by site) and every IP it used, each
/// listed once, with a search field and CSV export. Selecting a domain lists only the IPs it resolved to, until "Show
/// all"; selecting a domain or an IP lists under it every process that reached it (`AppDetailHostProcessList`). A row's
/// count and context menu open the app's requests to that host in History, filtered to the app as the count is
/// (`AppDetailRequestsLink`). An alert's View opens the tab on its domain or IP, which the tab scrolls into view once it
/// lists it (`arrive(at:)`).
///
/// The tab shows what it showed last for the app (`AppDetailCache`) right after its first frame and reads the
/// database again in the background; the summary is computed off the main actor, and only when the hosts, the
/// search or a NEW mark changed.
struct AppDetailInventoryTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var app: MonitoredApp
    /// Whose hosts are listed: the sidebar's Mac, or every Mac when the app is not on that one.
    var scope: DeviceScope
    /// The search as typed.
    var search: String
    var cache: AppDetailCache

    @State private var content = Content()
    /// Where each pane is scrolled to, set only for a moment: to hold a pane's rows on screen (or its top) through a
    /// reorder, take it to the front of its list with a selected row that moves there, bring an alert's row into view,
    /// or take the IP pane to its top when its filter changes (`AppDetailPaneScroll`).
    @State private var domainsPosition = ScrollPosition(idType: AppDetailInventoryRowID.self)
    @State private var ipsPosition = ScrollPosition(idType: AppDetailInventoryRowID.self)
    @State private var domainsScroll = AppDetailPaneScroll()
    @State private var ipsScroll = AppDetailPaneScroll()
    /// The row an alert's View opened the tab on, marked for a moment once it is in view.
    @State private var arrived: AppDetailInventoryRowID?
    /// The serial of the latest arrival the tab took (`Navigation.HostArrival`).
    @State private var arrivalSerial = 0
    @State private var exportDocument: AnalyzeCSVDocument?
    @State private var isExporting = false
    @State private var exportError: (any Error)?

    static let domainColumns = domainColumns(factor: UIScale.factor)
    /// The Domains pane's columns without First seen, for a narrow page.
    static let narrowDomainColumns = domainColumns(factor: UIScale.factor, showsFirstSeen: false)
    static let ipColumns = ipColumns(factor: UIScale.factor)

    /// The width of a pane less its names at `factor`: its fixed columns, the spaces between its columns, its 16 px
    /// margins and the scroller.
    private static func fixedWidth(_ columns: [AnalyzeColumnsLayout.Column], factor: CGFloat) -> CGFloat {
        func px(_ value: CGFloat) -> CGFloat { UIScale.length(value, factor: factor) }
        let scroller = NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy)
        return columns.reduce(px(10) * CGFloat(columns.count - 1) + px(16) * 2 + scroller) { total, column in
            if case .fixed(let width) = column { total + width } else { total }
        }
    }

    // The columns at any UI scale. First seen, Last seen and the counts are fixed to the longest of their text
    // (`Yesterday 23:59` in 12 px, `Yesterday` and `1,234,567` in 11 px SF Mono), the IP to `255.255.255.255` in
    // 11.5 px SF Mono and a NEW badge: text that grows with the scale as the widths do. The names take what is left
    // (the design's `minmax(0, 1fr)`); `split` keeps them room.
    static func domainColumns(factor: CGFloat, showsFirstSeen: Bool = true) -> [AnalyzeColumnsLayout.Column] {
        func px(_ value: CGFloat) -> CGFloat { UIScale.length(value, factor: factor) }
        return [.flexible(weight: 1)] + (showsFirstSeen ? [.fixed(px(104))] : []) + [.fixed(px(70)), .fixed(px(64))]
    }

    static func domainColumns(showsFirstSeen: Bool) -> [AnalyzeColumnsLayout.Column] {
        showsFirstSeen ? domainColumns : narrowDomainColumns
    }

    static func ipColumns(factor: CGFloat) -> [AnalyzeColumnsLayout.Column] {
        func px(_ value: CGFloat) -> CGFloat { UIScale.length(value, factor: factor) }
        return [.fixed(px(150)), .flexible(weight: 1), .fixed(px(64))]
    }

    /// What a row an alert's View opened the tab on takes on under its selection's tint for a moment, so the eye finds it.
    static let arrivalTint = Theme.accent.opacity(0.22)

    /// The arrival's tint comes on quickly and fades back slowly.
    static func arrivalAnimation(_ arrived: Bool) -> Animation {
        arrived ? .easeIn(duration: 0.2) : .easeOut(duration: 0.8)
    }

    /// How the tab shares a page between its panes.
    struct PaneSplit: Equatable {
        /// The Domains pane's width; the IP pane takes the rest, after the hairline between them.
        var domainsWidth: CGFloat
        /// The Domains pane has room for its First seen column.
        var showsFirstSeen: Bool
    }

    /// The panes of a page `width` points wide. The Domains pane takes 1.4 of every 2.4, as in the design, while each
    /// pane keeps its fixed columns and an always-visible scroller, and its names their old minimums: 150 px for a site
    /// and its NEW SITE badge, 90 px for the network. A page too narrow for both drops the Domains pane's First seen
    /// (the NEW badges still mark what is new) rather than squeeze the names; one too narrow even then cuts the Domains
    /// pane.
    static func split(_ width: CGFloat, factor: CGFloat = UIScale.factor) -> PaneSplit {
        func px(_ value: CGFloat) -> CGFloat { UIScale.length(value, factor: factor) }
        func fixed(_ columns: [AnalyzeColumnsLayout.Column]) -> CGFloat { fixedWidth(columns, factor: factor) }
        // The IP pane with the hairline between the panes.
        let ipMinimum = fixed(ipColumns(factor: factor)) + px(90) + 0.5
        let showsFirstSeen = fixed(domainColumns(factor: factor)) + px(150) + ipMinimum <= width
        let domainsMinimum = fixed(domainColumns(factor: factor, showsFirstSeen: showsFirstSeen)) + px(150)
        let domains = min(max(width * 1.4 / 2.4, domainsMinimum), width - ipMinimum)
        return PaneSplit(domainsWidth: max(0, domains), showsFirstSeen: showsFirstSeen)
    }

    /// Whether the processes of a selected IP have room for their First seen column in an IP pane `width` points wide:
    /// they take the Domains pane's columns, and their names keep 200 px for a process's tile, name and path.
    static func ipProcessesShowFirstSeen(_ width: CGFloat, factor: CGFloat = UIScale.factor) -> Bool {
        fixedWidth(domainColumns(factor: factor), factor: factor) + UIScale.length(200, factor: factor) <= width
    }

    /// The hosts and the summary shown, with what they were read and computed for.
    private struct Content {
        /// The app and scope `hosts` were last loaded for (nil before the first load).
        var key: AppDetailCache.Key?
        var hosts: [AppHost] = []
        /// Bumped whenever `hosts` changes, so a summary computed meanwhile can tell it is out of date.
        var revision = 0
        /// Groups and counts of `hosts` for `summary.search`.
        var summary = AppDetailInventorySummary()
    }

    /// What the tab last showed for `key`, when it fits the search and the selected domain and IP.
    private static func cached(_ key: AppDetailCache.Key, search: String, selectedHost: String?, selectedIP: String?,
                               in cache: AppDetailCache) -> Content? {
        guard let cached = cache.inventory(key), cached.fits(search: search, selectedHost: selectedHost, selectedIP: selectedIP) else { return nil }
        return Content(key: key, hosts: cached.hosts, summary: cached.summary)
    }

    var body: some View {
        let key = AppDetailCache.Key(appID: app.id, scope: scope)
        Group {
            if content.key == key && content.hosts.isEmpty {
                waitingState
            } else {
                VStack(spacing: 0) {
                    summaryLine
                    Text(trf("Every domain and IP %@ has used, each listed once; select one to see the processes that reached it. The first time a new one appears you get an alert, and it stays marked NEW for 24 hours.", "AppDetail", app.name))
                        .font(.design(11.5))
                        .foregroundStyle(Theme.ink2)
                        .lineHeight(Theme.noteLineHeight)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 20.px)
                        .padding(.vertical, 8.px)
                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
                    GeometryReader { geometry in
                        let split = Self.split(geometry.size.width)
                        HStack(spacing: 0) {
                            domainsPane(showsFirstSeen: split.showsFirstSeen).frame(width: split.domainsWidth)
                            Rectangle().fill(Theme.line).frame(width: 0.5)
                            ipsPane(showsProcessFirstSeen: Self.ipProcessesShowFirstSeen(geometry.size.width - split.domainsWidth - 0.5))
                                .frame(maxWidth: .infinity)
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
        .task(id: search) {
            await follow(search)
        }
        .onChange(of: summary.selectedHost(model.nav.appSelectedHost)) { _, domain in
            filterIPs(to: domain)
        }
        .onChange(of: arrival, initial: true) { _, arrival in
            if let arrival { arrive(at: arrival) }
        }
    }

    private var summary: AppDetailInventorySummary { content.summary }

    /// An alert's View, for the tab to take once it lists the row.
    private struct Arrival: Equatable {
        var serial: Int
        var row: AppDetailInventoryRowID
    }

    /// The row the app's pending arrival brings into view, once the tab lists it (`AppDetailInventorySummary.row(arriving:)`).
    private var arrival: Arrival? {
        guard let arrival = model.nav.appArrival, arrival.appID == app.id,
              let row = summary.row(arriving: arrival, filter: model.nav.appIPFilter) else { return nil }
        return Arrival(serial: arrival.serial, row: row)
    }

    // MARK: Header

    private var summaryLine: some View {
        @Bindable var nav = model.nav
        // In a narrow page the search field gives way before the headline; the pill and the button stay whole.
        return HStack(spacing: 12.px) {
            Text(summary.headline)
                .font(.design(12, .semibold))
                .lineLimit(1)
                .layoutPriority(2)
            if summary.newCount > 0 {
                AnalyzePill(text: trn("%lld new domain or IP in 24 h", "%lld new domains & IPs in 24 h", summary.newCount, "AppDetail"), size: 11)
            }
            Spacer(minLength: 0)
            FilterField(prompt: tr("Search", "AppDetail"), text: $nav.appInventorySearch, width: 190, minWidth: 120)
                .layoutPriority(1)
            Button(tr("Export CSV", "AppDetail"), action: export)
                .buttonStyle(DesignButtonStyle())
                .fixedSize()
                .disabled(content.hosts.isEmpty)
                .help(tr("Save every domain and IP of this app as a CSV file", "AppDetail"))
        }
        .padding(.horizontal, 20.px)
        .frame(height: 48.px)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private var waitingState: some View {
        VStack(spacing: 8.px) {
            Circle()
                .strokeBorder(Theme.ink3, style: StrokeStyle(lineWidth: 2.px, dash: [4.px, 3.px]))
                .frame(width: 44.px, height: 44.px)
            Text(trf("Waiting for the first request from %@", "AppDetail", app.name))
                .font(.design(15, .semibold))
                .foregroundStyle(Theme.ink)
            Text(tr("Nothing in the database yet. Domains and IPs show up here as soon as Surge sees this app, or anything it launches, open a connection.", "AppDetail"))
                .font(.design(12.5))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 400.px)
        }
        .padding(40.px)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: Domains

    private func domainsPane(showsFirstSeen: Bool) -> some View {
        let selected = summary.selectedHost(model.nav.appSelectedHost)
        return VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8.px) {
                Text(tr("Domains", "AppDetail")).font(.design(12.5, .bold))
                Text(trf("%1$@ in %2$@", "AppDetail",
                         trn("%lld host", "%lld hosts", summary.domainCount, "AppDetail"),
                         trn("%lld site", "%lld sites", summary.siteCount, "AppDetail")))
                    .font(.design(11.5))
                    .foregroundStyle(Theme.ink3)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16.px)
            .padding(.top, 10.px)
            .padding(.bottom, 6.px)
            ScrollView {
                // The column header is pinned inside the scroll view so it keeps the rows' width when an
                // always-visible scroller takes room.
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        // One row each, so a site, a domain and its processes keep their identity as they move.
                        ForEach(summary.domainRows(opening: selected)) { row in
                            Group {
                                switch row {
                                case .site(let group):
                                    siteRow(group, showsFirstSeen: showsFirstSeen)
                                case .domain(let host):
                                    AppDetailDomainRow(requests: requestsLink, host: host, selected: selected == host.value, arrived: arrived == row.id,
                                                       showsFirstSeen: showsFirstSeen)
                                case .processes(let domain):
                                    // The processes' tree glyphs under the domain's name.
                                    processList(.domain, host: domain, showsFirstSeen: showsFirstSeen, indent: 26.px)
                                }
                            }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AppDetailPaneScroll.content)) } action: {
                                domainsScroll.frames[row.id] = $0
                            }
                        }
                    } header: {
                        AnalyzeHeaderRow(columns: Self.domainColumns(showsFirstSeen: showsFirstSeen), height: 26.px, horizontalPadding: 16.px) {
                            Text(tr("Site · host", "AppDetail"))
                            if showsFirstSeen { Text(tr("First seen", "AppDetail")) }
                            Text(tr("Last seen", "AppDetail"))
                            Text(tr("Requests", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .background(Theme.bg)
                    }
                }
                .scrollTargetLayout()
                .coordinateSpace(.named(AppDetailPaneScroll.content))
                .padding(.bottom, 10.px)
                // A process list opens and closes at once rather than sliding the rows below it: that animation lays out
                // every row of the pane in each of its frames, at twice the work of a frame on a page without the lists.
                // Only a reorder moves rows, briefly (`show`). The rows animate their own highlight.
                .transaction { if !$0.reordersAppInventory { $0.animation = nil } }
            }
            .scrollPosition($domainsPosition)
            .onScrollTargetVisibilityChange(idType: AppDetailInventoryRowID.self, threshold: 0.5) { domainsScroll.visible = Set($0) }
            .onScrollGeometryChange(for: CGRect.self, of: \.visibleRect) { domainsScroll.visibleRect = $1 }
        }
    }

    private func siteRow(_ group: AppDetailInventorySummary.SiteGroup, showsFirstSeen: Bool) -> some View {
        let hosts = InventoryRequests.hosts(of: group)
        return AnalyzeColumnsLayout(columns: Self.domainColumns(showsFirstSeen: showsFirstSeen)) {
            // In a narrow pane the host count goes and NEW SITE becomes NEW before the site shortens.
            AppDetailNameLayout(spacing: 8.px) {
                Text(group.site).fontWeight(.semibold).lineLimit(1)
                ViewThatFits(in: .horizontal) {
                    Text(trn("%lld host", "%lld hosts", group.hosts.count, "AppDetail"))
                        .font(.design(11))
                        .foregroundStyle(Theme.ink2)
                        .fixedSize()
                    Color.clear.frame(width: 0, height: 0)
                }
                if group.isNewSite {
                    ViewThatFits(in: .horizontal) {
                        TagBadge(text: tr("NEW SITE", "AppDetail"), style: .new)
                        TagBadge(text: tr("NEW", "AppDetail"), style: .new)
                    }
                }
            }
            if showsFirstSeen {
                Text(AnalyzeFormat.seen(group.firstSeen)).font(.design(12)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Text(AppDetailInventoryFormat.lastSeen(group.lastSeen)).font(Theme.mono(11)).foregroundStyle(Theme.ink2).lineLimit(1)
            AnalyzeRequestsCount(count: group.requests, font: Theme.mono(11, weight: .semibold), hosts: hosts,
                                 help: requestsLink.help(hosts: hosts), open: openRequests)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.design(12.5))
        .padding(.horizontal, 16.px)
        .frame(height: 30.px)
        .background(Theme.bg2)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        .contextMenu { AnalyzeRequestsMenu(hosts: hosts, open: openRequests) }
    }

    private func openRequests(_ host: String) {
        requestsLink.open(host, in: model.nav)
    }

    /// The processes under the selected domain or IP; the IP pane's header has no date columns, so their caption names them.
    private func processList(_ kind: HostKind, host: String, showsFirstSeen: Bool, indent: CGFloat) -> some View {
        AppDetailHostProcessList(key: AppDetailCache.HostKey(appID: app.id, scope: scope, kind: kind, value: host), app: app, cache: cache,
                                 requests: requestsLink, showsFirstSeen: showsFirstSeen, indent: indent, labelsDates: kind == .ip)
    }

    /// What the rows open in History. History keeps the sidebar's Mac, not the tab's.
    private var requestsLink: AppDetailRequestsLink {
        AppDetailRequestsLink(appID: app.id, appName: app.name, oneMac: model.devices.scope.deviceID != nil)
    }

    // MARK: IPs

    private func ipsPane(showsProcessFirstSeen: Bool) -> some View {
        let nav = model.nav
        let selected = summary.selectedHost(nav.appSelectedHost)
        let selectedIP = summary.selectedIP(nav.appSelectedIP, usedBy: selected)
        return VStack(spacing: 0) {
            ipsHeader(selected: selected)
                .padding(.horizontal, 16.px)
                .padding(.top, 10.px)
                .padding(.bottom, 6.px)
            ScrollView {
                LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                    Section {
                        // With a domain selected only the IPs it resolved to, whichever group they are in; an IP also
                        // reached by IP alone has its BY IP badge. One row each, like the Domains pane's.
                        ForEach(summary.ipRows(filter: nav.appIPFilter, domain: selected, opening: selectedIP)) { row in
                            Group {
                                switch row {
                                case .section(let group, let count):
                                    ipGroupHeader(group, count: count)
                                case .nothingDirect:
                                    ipNote(tr("Nothing reached by IP alone.", "AppDetail"))
                                case .noIPs:
                                    ipNote(selected.map(summary.hasIPs) == true ? tr("None of its IPs match the search.", "AppDetail")
                                        : tr("No IP on record for this domain.", "AppDetail"))
                                case .ip(let ip):
                                    AppDetailIPRow(requests: requestsLink, ip: ip, selected: selectedIP == ip.value, arrived: arrived == row.id)
                                case .processes(let ip):
                                    processList(.ip, host: ip, showsFirstSeen: showsProcessFirstSeen, indent: 12.px)
                                        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
                                }
                            }
                            .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(AppDetailPaneScroll.content)) } action: {
                                ipsScroll.frames[row.id] = $0
                            }
                        }
                    } header: {
                        AnalyzeHeaderRow(columns: Self.ipColumns, height: 26.px, horizontalPadding: 16.px) {
                            Text(verbatim: "IP")
                            Text(tr("Network · domains", "AppDetail"))
                            Text(tr("Requests", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
                        }
                        .background(Theme.bg)
                    }
                }
                .scrollTargetLayout()
                .coordinateSpace(.named(AppDetailPaneScroll.content))
                // Like the Domains pane's: only a reorder moves rows; the rows animate their own highlight.
                .transaction { if !$0.reordersAppInventory { $0.animation = nil } }
            }
            .scrollPosition($ipsPosition)
            .onScrollTargetVisibilityChange(idType: AppDetailInventoryRowID.self, threshold: 0.5) { ipsScroll.visible = Set($0) }
            .onScrollGeometryChange(for: CGRect.self, of: \.visibleRect) { ipsScroll.visibleRect = $1 }
        }
    }

    /// The IP pane's title with how many IPs it lists, then the Direct / From domains switch; with a domain selected,
    /// "Show all" in the switch's place, which lists every IP again. The domain's IPs are those it resolved to whichever
    /// group they are in, so the switch keeps its choice for then.
    @ViewBuilder
    private func ipsHeader(selected: String?) -> some View {
        @Bindable var nav = model.nav
        // Like the design's "N of M", the Direct / From domains switch doesn't change the count.
        let title = HStack(alignment: .firstTextBaseline, spacing: 8.px) {
            Text(selected.map { trf("IPs used by %@", "AppDetail", $0) } ?? tr("All IPs", "AppDetail"))
                .font(.design(12.5, .bold))
                .lineLimit(1)
                .truncationMode(.middle)
            Text(trf("%1$lld of %2$lld", "AppDetail", summary.listedIPCount(selectedHost: selected), summary.ipCount))
                .font(.design(11.5))
                .foregroundStyle(Theme.ink3)
                .fixedSize()
        }
        if selected != nil {
            // The domain shortens in the middle before "Show all" gives way. As tall as the switch, so where the pane has
            // room for the title and the switch on one row the list stays put.
            HStack(alignment: .firstTextBaseline, spacing: 8.px) {
                title
                Spacer(minLength: 0)
                Button(tr("Show all", "AppDetail")) {
                    withAnimation(.easeOut(duration: 0.2)) { model.nav.appSelectedHost = nil }
                }
                .buttonStyle(.link)
                .font(.design(11.5))
                .fixedSize()
            }
            .frame(minHeight: DesignSegmentedControl<Navigation.IPFilter>.Size.small().height)
        } else {
            // One row when the pane is wide enough, otherwise the switch moves under the title. The counts are those of
            // the list's group headers; a pane too narrow for the switch drops them, then its icons.
            AppDetailIPHeaderLayout {
                title
                DesignSegmentedControl(tr("Show", "AppDetail"), selection: $nav.appIPFilter, segments: [
                    .init(.all, tr("All", "AppDetail"), systemImage: "list.bullet", count: summary.directIPs.count + summary.resolvedIPs.count),
                    .init(.direct, tr("Direct", "AppDetail"), systemImage: "number", count: summary.directIPs.count),
                    .init(.resolved, tr("From domains", "AppDetail"), systemImage: "globe", count: summary.resolvedIPs.count),
                ])
            }
        }
    }

    /// The IP pane lists another domain's IPs, or every IP again: it goes to its top, and a selected IP it no longer
    /// lists is no longer selected, so "Show all" doesn't bring its processes back.
    private func filterIPs(to domain: String?) {
        if let domain, let ip = model.nav.appSelectedIP, summary.selectedIP(ip) != nil, summary.selectedIP(ip, usedBy: domain) == nil {
            model.nav.appSelectedIP = nil
        }
        ipsPosition.scrollTo(edge: .top)
        letGo(ips: true)
    }

    /// Before the rows reorder to `next`: each pane holds its topmost row on screen that doesn't move where it is, or its
    /// top, through the reorder; one whose selected row on screen moves above that row goes to the front of its list
    /// first, in the layout it has, where the place is exact (`AppDetailPaneScroll`).
    private func positionPanes(for next: AppDetailInventorySummary) {
        let domain = summary.selectedHost(model.nav.appSelectedHost)
        let ip = summary.selectedIP(model.nav.appSelectedIP, usedBy: domain)
        let domainsTarget = next.domainsTarget(keeping: domain, from: summary, visible: domainsScroll.visible, atTop: domainsScroll.isAtTop)
        let ipsTarget = next.ipsTarget(keeping: ip, domain: domain, filter: model.nav.appIPFilter, from: summary,
                                       visible: ipsScroll.visible, atTop: ipsScroll.isAtTop)
        domainsPosition = domainsScroll.position(domainsTarget)
        ipsPosition = ipsScroll.position(ipsTarget)
        letGo(domains: domainsTarget != nil, ips: ipsTarget != nil)
    }

    /// Takes an alert's View: scrolls its row into view in its pane, a quarter of the way down (or as far as the list
    /// goes), then, unless Reduce Motion is on, deepens its selection's tint for a moment so the eye finds it. The pane
    /// goes there a frame later, once the rows the selection opens (its processes, a domain's IPs) are laid out, and
    /// again a moment later: until a lazy stack has built the rows above one far down, it places it where it estimates
    /// them to end. The selection already opened its processes, and the IP pane filtered to a domain goes to its top.
    private func arrive(at arrival: Arrival) {
        model.nav.appArrival = nil
        arrivalSerial = arrival.serial
        let ips = if case .host(.ip, _) = arrival.row { true } else { false }
        Task {
            for delay in [16, 150] {
                try? await Task.sleep(for: .milliseconds(delay))
                // A later View takes over.
                guard arrivalSerial == arrival.serial else { break }
                if ips {
                    ipsPosition.scrollTo(id: arrival.row, anchor: AppDetailPaneScroll.arrivalAnchor)
                } else {
                    domainsPosition.scrollTo(id: arrival.row, anchor: AppDetailPaneScroll.arrivalAnchor)
                }
            }
            letGo(domains: !ips, ips: ips)
            guard !reduceMotion, arrivalSerial == arrival.serial else { return }
            arrived = arrival.row
            try? await Task.sleep(for: .milliseconds(600))
            if arrived == arrival.row { arrived = nil }
        }
    }

    /// Empties the scroll position of the panes it names once they have taken it in, unless it was set again meanwhile:
    /// a position that kept a row or an edge would hold its pane there through later updates.
    private func letGo(domains: Bool = false, ips: Bool = false) {
        let domainsMove = domains ? domainsScroll.move() : nil, ipsMove = ips ? ipsScroll.move() : nil
        guard domainsMove != nil || ipsMove != nil else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            if let domainsMove, domainsScroll.isLatest(domainsMove) { domainsPosition = ScrollPosition(idType: AppDetailInventoryRowID.self) }
            if let ipsMove, ipsScroll.isLatest(ipsMove) { ipsPosition = ScrollPosition(idType: AppDetailInventoryRowID.self) }
        }
    }

    /// A line in the IP pane where it has no IP to list.
    private func ipNote(_ text: String) -> some View {
        Text(text)
            .font(.design(11.5))
            .foregroundStyle(Theme.ink3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16.px)
            .padding(.vertical, 10.px)
    }

    /// The header of the Direct (`.direct`) or Resolved from domains (`.resolved`) group.
    private func ipGroupHeader(_ group: Navigation.IPFilter, count: Int) -> some View {
        let direct = group == .direct
        let title = direct ? tr("Direct", "AppDetail") : tr("Resolved from domains", "AppDetail")
        let note = direct ? tr("reached by IP, no hostname", "AppDetail") : tr("the domains on the left resolved to these", "AppDetail")
        // In a narrow pane the note shortens; the title and the count stay on one line.
        return HStack(alignment: .firstTextBaseline, spacing: 7.px) {
            Text(title).foregroundStyle(Theme.ink).fixedSize()
            Text(verbatim: String(count)).fontWeight(.medium).foregroundStyle(Theme.ink3).fixedSize()
            Text(note).fontWeight(.medium).foregroundStyle(Theme.ink3).lineLimit(1)
            Spacer(minLength: 0)
        }
        .font(.design(11, .semibold))
        .padding(.horizontal, 16.px)
        .padding(.top, 10.px)
        .padding(.bottom, 5.px)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    // MARK: Loading and export

    private func refresh(_ key: AppDetailCache.Key) async {
        if content.key != key {
            // Nothing rather than another scope's list (the tab stays when the sidebar's Mac changes).
            if !content.hosts.isEmpty { content = Content() }
            // Then what the tab last showed for the app and scope, while it reads the database. SwiftUI can start
            // this task while it draws the tab, so the lists wait for the next turn of the run loop: the switch to the
            // tab draws as fast as an empty tab, and the lists follow in the next frame.
            if let cached = Self.cached(key, search: model.nav.appInventorySearch, selectedHost: model.nav.appSelectedHost,
                                        selectedIP: model.nav.appSelectedIP, in: cache) {
                await Task.yield()
                if Task.isCancelled { return }
                content = cached
            }
        }
        while !Task.isCancelled {
            let read = Date.now
            do {
                let fresh = try await model.database.appHosts(key.appID, scope: key.scope)
                if Task.isCancelled { return }
                await show(fresh, for: key)
                if Task.isCancelled { return }
            } catch {
                // Keep the last list; the sidebar footer reports database problems.
            }
            if content.key != key { content.key = key }
            await waitForNextRead(after: read, of: key)
        }
    }

    /// Waits 10 s, or less once the app made a request the read begun at `read` may have missed
    /// (`AppDetailInventoryActivity`): then for as long as the batch that also moves its domain's and IP's last seen
    /// takes to be written (Settings › Database's interval, and a second for the IP to resolve), so the site of a domain
    /// that got a request moves to the top a few seconds later. However many requests the app makes meanwhile, one read
    /// follows; a request that started just before a read and was written after it gets the next one.
    private func waitForNextRead(after read: Date, of key: AppDetailCache.Key) async {
        let live = model.live
        let settle = model.preferences.batchInterval + 1
        let requested = await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                try? await Task.sleep(for: .seconds(10))
                return false
            }
            group.addTask { await AppDetailInventoryActivity.request(of: key, missedBy: read, settle: settle, in: live) }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        if requested { try? await Task.sleep(for: .seconds(settle)) }
    }

    /// Shows hosts just read. Nothing changes when they are the ones shown and the summary is still current (its
    /// NEW marks expire with time); otherwise the summary is computed off the main actor. Rows that move slide to their
    /// place (at once with Reduce Motion) while each pane holds the rows on screen where they are, and a selected row on
    /// screen that moves to the front of its list takes its pane there (`positionPanes`).
    private func show(_ fresh: [AppHost], for key: AppDetailCache.Key) async {
        let same = content.key == key && fresh == content.hosts
        if same, content.summary.isCurrent(search: model.nav.appInventorySearch, at: .now) { return }
        while !Task.isCancelled {
            let search = model.nav.appInventorySearch
            let summary = await AppDetailInventorySummary.make(hosts: fresh, search: search, classifier: model.classifier)
            // Typed meanwhile: summarize again for the new search.
            guard !Task.isCancelled, search == model.nav.appInventorySearch else { continue }
            let reorders = content.key == key && !content.summary.hasSameOrder(as: summary)
            if reorders {
                positionPanes(for: summary)
                // The panes take their positions in before the rows move.
                try? await Task.sleep(for: .milliseconds(20))
                guard !Task.isCancelled, search == model.nav.appInventorySearch else { continue }
            }
            var next = content
            if !same || next.key != key {
                next.hosts = fresh
                next.revision &+= 1
            }
            next.key = key
            next.summary = summary
            if reorders {
                var transaction = Transaction(animation: reduceMotion ? nil : .easeOut(duration: 0.2))
                transaction.reordersAppInventory = true
                withTransaction(transaction) { content = next }
            } else {
                content = next
            }
            cache.setInventory(AppDetailCache.Inventory(hosts: fresh, summary: summary), for: key)
            return
        }
    }

    /// Filters the shown hosts for a new search, off the main actor.
    private func follow(_ search: String) async {
        while !Task.isCancelled {
            guard let key = content.key, content.summary.search != search else { return }
            let hosts = content.hosts, revision = content.revision
            let summary = await AppDetailInventorySummary.make(hosts: hosts, search: search, classifier: model.classifier)
            // New hosts arrived meanwhile: summarize those.
            guard !Task.isCancelled, revision == content.revision, key == content.key else { continue }
            content.summary = summary
            cache.setInventory(AppDetailCache.Inventory(hosts: hosts, summary: summary), for: key)
            return
        }
    }

    /// Every host, whatever the search, in the tab's order.
    private func export() {
        let classifier = model.classifier
        let hosts = AppDetailInventorySummary.ordered(content.hosts, site: { classifier.site(for: $0) })
        exportDocument = AnalyzeCSVDocument(text: AnalyzeCSV.appHosts(hosts))
        isExporting = true
    }
}

/// A domain under its site.
private struct AppDetailDomainRow: View {
    @Environment(AppModel.self) private var model
    var requests: AppDetailRequestsLink
    var host: AppHost
    var selected: Bool
    /// An alert's View opened the tab on it a moment ago.
    var arrived: Bool
    var showsFirstSeen: Bool

    var body: some View {
        let hosts = InventoryRequests.hosts(of: host)
        AnalyzeColumnsLayout(columns: AppDetailInventoryTab.domainColumns(showsFirstSeen: showsFirstSeen)) {
            HStack(spacing: 7.px) {
                Text(verbatim: "└").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                Text(host.value).lineLimit(1).truncationMode(.middle)
                if host.isNew() { TagBadge(text: tr("NEW", "AppDetail"), style: .new) }
            }
            .padding(.leading, 12.px)
            if showsFirstSeen {
                Text(AnalyzeFormat.seen(host.firstSeen)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Text(AppDetailInventoryFormat.lastSeen(host.lastSeen)).font(Theme.mono(11)).foregroundStyle(Theme.ink2).lineLimit(1)
            AnalyzeRequestsCount(count: host.requestCount, font: Theme.mono(11), hosts: hosts, help: requests.help(hosts: hosts),
                                 open: openRequests)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.design(12))
        .padding(.horizontal, 16.px)
        .frame(height: 28.px)
        .background(selected ? Theme.accentTint : .clear)
        .background(arrived ? AppDetailInventoryTab.arrivalTint : .clear)
        .animation(.easeOut(duration: 0.2), value: selected)
        .animation(AppDetailInventoryTab.arrivalAnimation(arrived), value: arrived)
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) {
                model.nav.appSelectedHost = model.nav.appSelectedHost == host.value ? nil : host.value
            }
        }
        .help(host.processName.map { trf("First reached by %@", "AppDetail", $0) } ?? host.value)
        .contextMenu { AnalyzeRequestsMenu(hosts: hosts, open: openRequests) }
    }

    private func openRequests(_ value: String) {
        requests.open(value, in: model.nav)
    }
}

/// An IP with its network and the domains that resolved to it. A click selects it, which lists the processes that
/// reached it under it, and another click closes them. The address is not selectable text, which would take the click
/// on it; the context menu copies it.
///
/// It takes its highlight as a plain flag rather than the selection, so selecting another IP only redraws the rows
/// whose state changes.
private struct AppDetailIPRow: View {
    @Environment(AppModel.self) private var model
    var requests: AppDetailRequestsLink
    var ip: AppHost
    var selected: Bool
    /// An alert's View opened the tab on it a moment ago.
    var arrived: Bool

    var body: some View {
        let hosts = InventoryRequests.hosts(of: ip)
        AnalyzeColumnsLayout(columns: AppDetailInventoryTab.ipColumns) {
            HStack(spacing: 6.px) {
                Text(ip.value).font(Theme.mono(11.5)).lineLimit(1)
                if ip.isNew() { TagBadge(text: tr("NEW", "AppDetail"), style: .new) }
            }
            VStack(alignment: .leading, spacing: 1.px) {
                Text(ip.geo?.display ?? "—")
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .help(ip.geo.map(AppDetailInventoryFormat.fullGeo) ?? "")
                HStack(spacing: 5.px) {
                    if ip.isDirect { TagBadge(text: tr("BY IP", "AppDetail")) }
                    // Whole host names, cut at the end: a cut in the middle invents names that don't exist.
                    Text(ip.hosts.isEmpty ? tr("No hostname · connected by IP", "AppDetail") : AppDetailInventoryFormat.domains(ip.hosts))
                        .font(.design(11))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(ip.hosts.joined(separator: "\n"))
                }
            }
            AnalyzeRequestsCount(count: ip.requestCount, font: Theme.mono(11), hosts: hosts, help: requests.help(hosts: hosts),
                                 open: openRequests)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.design(12))
        .padding(.horizontal, 16.px)
        .padding(.vertical, 6.px)
        .background(selected ? Theme.accentTint : .clear)
        .background(arrived ? AppDetailInventoryTab.arrivalTint : .clear)
        .animation(.easeOut(duration: 0.2), value: selected)
        .animation(AppDetailInventoryTab.arrivalAnimation(arrived), value: arrived)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        .contentShape(.rect)
        .onTapGesture {
            withAnimation(.easeOut(duration: 0.2)) {
                model.nav.appSelectedIP = model.nav.appSelectedIP == ip.value ? nil : ip.value
            }
        }
        .contextMenu {
            AnalyzeRequestsMenu(hosts: hosts, open: openRequests)
            Button(tr("Copy IP Address", "AppDetail")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ip.value, forType: .string)
            }
        }
    }

    private func openRequests(_ value: String) {
        requests.open(value, in: model.nav)
    }
}

/// The IP pane's header while it lists every IP: the title and the Direct / From domains switch on one row when both fit
/// at their ideal widths, otherwise the switch on a row of its own under the title. It lays out what a `ViewThatFits`
/// of those two arrangements did, with each view built and measured once.
///
/// Subviews: the title, then the switch.
private struct AppDetailIPHeaderLayout: Layout {
    private let spacing = 8.px
    private let rowSpacing = 6.px

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let frames = arrange(width: proposal.width, subviews: subviews)
        return CGSize(width: frames.width, height: frames.height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let frames = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, frames.items) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY), anchor: .topLeading,
                          proposal: ProposedViewSize(width: frame.width, height: nil))
        }
    }

    private struct Arrangement {
        var items: [CGRect]
        var width: CGFloat
        var height: CGFloat
    }

    /// A subview at its x and width in a row.
    private struct Cell {
        var subview: LayoutSubview
        var x: CGFloat
        var width: CGFloat
    }

    private func arrange(width proposed: CGFloat?, subviews: Subviews) -> Arrangement {
        guard subviews.count >= 2 else { return Arrangement(items: [], width: proposed ?? 0, height: 0) }
        let title = subviews[0], filter = subviews[1]
        let titleWidth = title.sizeThatFits(.unspecified).width
        let filterWidth = filter.sizeThatFits(.unspecified).width
        // title, a spacer of at least 8 and the switch, 8 apart.
        let oneRow = titleWidth + spacing + spacing + spacing + filterWidth
        let width = proposed ?? oneRow

        if oneRow <= width {
            let row = Self.row([Cell(subview: title, x: 0, width: titleWidth),
                                Cell(subview: filter, x: width - filterWidth, width: filterWidth)])
            return Arrangement(items: row.frames, width: width, height: row.height)
        }
        // The title (cut if needed) on the first row, the switch under it.
        let first = Self.row([Cell(subview: title, x: 0, width: min(titleWidth, width))])
        // A pane narrower than the switch gets it without its counts (or icons).
        let filterSize = filter.sizeThatFits(ProposedViewSize(width: min(filterWidth, width), height: nil))
        let frames = first.frames + [CGRect(x: 0, y: first.height + rowSpacing, width: filterSize.width, height: filterSize.height)]
        return Arrangement(items: frames, width: width, height: first.height + rowSpacing + filterSize.height)
    }

    /// Cells at their x and width, aligned on their first text baselines like an `HStack(alignment: .firstTextBaseline)`.
    private static func row(_ cells: [Cell]) -> (frames: [CGRect], height: CGFloat) {
        let dimensions = cells.map { $0.subview.dimensions(in: ProposedViewSize(width: $0.width, height: nil)) }
        let ascent = dimensions.map { $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
        let descent = dimensions.map { $0.height - $0[VerticalAlignment.firstTextBaseline] }.max() ?? 0
        let frames = zip(cells, dimensions).map { cell, size in
            CGRect(x: cell.x, y: ascent - size[VerticalAlignment.firstTextBaseline], width: cell.width, height: size.height)
        }
        return (frames, ascent + descent)
    }
}

/// What the tab's rows open: History filtered to the app as well, so it lists what the row counts.
extension InventoryRequests {
    /// The domain or IP of one of the app's rows.
    static func hosts(of host: AppHost) -> [String] { [RequestsHostFilter.normalized(host.value)] }

    /// The domains a site's row lists (those the search keeps), in its order.
    static func hosts(of group: AppDetailInventorySummary.SiteGroup) -> [String] {
        group.hosts.map { RequestsHostFilter.normalized($0.value) }
    }
}

/// What an app's rows open in History: the app's requests to a domain, or that reached an IP, over all time
/// (`InventoryRequests.open`). The tab's counts are every Mac's (the inventory is shared), while History keeps the
/// sidebar's Mac, so with one Mac there the count's help says History lists only that Mac's.
struct AppDetailRequestsLink: Equatable {
    var appID: AppID
    var appName: String
    /// The sidebar has one Mac.
    var oneMac: Bool

    @MainActor
    func open(_ host: String, in nav: Navigation) {
        InventoryRequests.open(host, in: nav, app: appID)
    }

    /// The help of a row's count: what it opens.
    @MainActor
    func help(hosts: [String]) -> String {
        let opens = if hosts.count == 1, let host = hosts.first {
            HostName.isIPAddress(host)
                ? trf("Show %1$@ requests that reached %2$@ in History", "AppDetail", appName, host)
                : trf("Show %1$@ requests to %2$@ in History", "AppDetail", appName, host)
        } else {
            trf("Choose a host to show its %@ requests in History", "AppDetail", appName)
        }
        guard oneMac else { return opens }
        return opens + "\n" + tr("The count covers every Mac; History lists only the requests of the Mac chosen in the sidebar.", "AppDetail")
    }
}

/// Text helpers of the "Domains & IPs" tab.
enum AppDetailInventoryFormat {
    /// The Last seen column's short form, as in the design: `14:31` today, `Yesterday`, then `Oct 24`, so the value
    /// fits its column whole.
    @MainActor
    static func lastSeen(_ date: Date, now: Date = .now) -> String {
        switch Fmt.seen(date, now: now, timeOnlyToday: true) {
        case .time(let time), .today(let time): time
        case .yesterday: tr("Yesterday", "AppDetail")
        case .date(let day): Fmt.monthDay(day, locale: Localizer.shared.locale)
        }
    }

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

/// Groups and counts behind the "Domains & IPs" tab (pure, so it can be tested, and computed off the main actor).
struct AppDetailInventorySummary: Sendable {
    struct SiteGroup: Identifiable, Equatable, Sendable {
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
    /// Site groups matching the search, each with its domains the search keeps, the latest activity first (`byActivity`):
    /// a domain that gets a request takes its site back to the top.
    var groups: [SiteGroup] = []
    /// IPs matching the search, the latest activity first.
    var directIPs: [AppHost] = []
    var resolvedIPs: [AppHost] = []
    /// The search the groups and IPs were filtered by.
    private(set) var search = ""
    /// When the first of the hosts' NEW marks runs out; `newCount` and the NEW badges change then.
    private(set) var expires: Date?
    private var domainValues: Set<String> = []
    /// Every IP of the app, with the domains that resolved to it.
    private var ipDomains: [String: [String]] = [:]
    /// The IPs matching the search under each domain that resolved to them, in their order.
    private var domainIPs: [String: [AppHost]] = [:]
    /// The IPs matching the search, the latest activity first, whichever group they are in: the order of each domain's.
    private var ipOrder: [String] = []

    /// No hosts.
    init() {}

    init(hosts: [AppHost], search: String, now: Date = .now, site: (String) -> String) {
        self.search = search
        expires = hosts.lazy.filter { $0.isNew(now: now) }.map { $0.firstSeen.addingTimeInterval(24 * 3600) }.min()
        let domains = hosts.filter { $0.kind == .domain }
        let ips = hosts.filter { $0.kind == .ip }.sorted(by: Self.byActivity)
        domainValues = Set(domains.map(\.value))
        ipDomains = Dictionary(ips.map { ($0.value, $0.hosts) }, uniquingKeysWith: { first, _ in first })
        domainCount = domains.count
        ipCount = ips.count
        directIPCount = ips.filter(\.isDirect).count
        newCount = hosts.filter { $0.isNew(now: now) }.count

        let query = search.trimmingCharacters(in: .whitespaces).lowercased()
        var bySite: [String: [AppHost]] = [:]
        for domain in domains { bySite[domain.site ?? site(domain.value), default: []].append(domain) }
        siteCount = bySite.count

        groups = bySite.compactMap { site, members in
            let visible = query.isEmpty ? members : members.filter { $0.value.lowercased().contains(query) }
            guard !visible.isEmpty else { return nil }
            return SiteGroup(site: site, hosts: visible.sorted(by: Self.byActivity),
                             firstSeen: members.map(\.firstSeen).min() ?? now,
                             lastSeen: members.map(\.lastSeen).max() ?? now,
                             requests: members.reduce(0) { $0 + $1.requestCount },
                             isNewSite: members.allSatisfy { $0.isNew(now: now) })
        }
        .sorted(by: Self.byActivity)

        let visibleIPs = ips.filter { ip in
            query.isEmpty || ip.value.lowercased().contains(query)
                || (ip.geo?.display.lowercased().contains(query) ?? false)
                || ip.hosts.contains { $0.lowercased().contains(query) }
        }
        directIPs = visibleIPs.filter(\.isDirect)
        resolvedIPs = visibleIPs.filter { !$0.isDirect }
        ipOrder = visibleIPs.map(\.value)
        for ip in visibleIPs {
            for domain in Set(ip.hosts) { domainIPs[domain, default: []].append(ip) }
        }
    }

    /// Summarizes `hosts` off the caller's actor.
    @concurrent
    static func make(hosts: [AppHost], search: String, now: Date = .now, classifier: any SiteClassifying) async -> AppDetailInventorySummary {
        AppDetailInventorySummary(hosts: hosts, search: search, now: now, site: { classifier.site(for: $0) })
    }

    /// The latest activity first: the later last seen, then the name, so hosts seen at the same moment keep one order.
    static func byActivity(_ a: AppHost, _ b: AppHost) -> Bool {
        a.lastSeen != b.lastSeen ? a.lastSeen > b.lastSeen : a.value < b.value
    }

    /// The site whose latest domain was seen last first (its row's Last seen), then by name.
    static func byActivity(_ a: SiteGroup, _ b: SiteGroup) -> Bool {
        a.lastSeen != b.lastSeen ? a.lastSeen > b.lastSeen : a.site < b.site
    }

    /// Every host of `hosts` in the tab's order, whatever the search: the domains site by site, then the IPs reached by
    /// IP alone, then those resolved from domains. Export CSV writes them so.
    static func ordered(_ hosts: [AppHost], site: (String) -> String) -> [AppHost] {
        let summary = AppDetailInventorySummary(hosts: hosts, search: "", site: site)
        return summary.groups.flatMap(\.hosts) + summary.directIPs + summary.resolvedIPs
    }

    /// Whether `other` lists the same rows in the same order, whatever their dates and counts: the IPs of each group,
    /// and those of a selected domain, which can be in both groups.
    func hasSameOrder(as other: AppDetailInventorySummary) -> Bool {
        groups.map(\.site) == other.groups.map(\.site)
            && groups.flatMap(\.hosts).map(\.value) == other.groups.flatMap(\.hosts).map(\.value)
            && directIPs.map(\.value) == other.directIPs.map(\.value)
            && resolvedIPs.map(\.value) == other.resolvedIPs.map(\.value)
            && ipOrder == other.ipOrder
    }

    /// Whether this summary still describes its hosts for `search` at `now` (no NEW mark has run out since).
    func isCurrent(search: String, at now: Date) -> Bool {
        self.search == search && (expires.map { now < $0 } ?? true)
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

    /// The selected IP, if it is still one of the app's IPs and, with `domain` selected, one that domain resolved to: the
    /// IP pane then lists only those, and a selected IP it filters out is cleared.
    func selectedIP(_ ip: String?, usedBy domain: String? = nil) -> String? {
        guard let ip, let domains = ipDomains[ip] else { return nil }
        guard let domain else { return ip }
        return domains.contains(domain) ? ip : nil
    }

    /// The IPs `domain` resolved to that the search keeps, the latest activity first: the IP pane's rows while the domain
    /// is selected.
    func ips(usedBy domain: String) -> [AppHost] {
        domainIPs[domain] ?? []
    }

    /// The IPs the IP pane lists: those the search keeps, only the selected domain's when one is selected. Like the
    /// design's "N of M", the Direct / From domains switch doesn't change it.
    func listedIPCount(selectedHost: String?) -> Int {
        guard let selectedHost else { return directIPs.count + resolvedIPs.count }
        return ips(usedBy: selectedHost).count
    }

    /// Whether `domain` resolved to any of the app's IPs, whatever the search.
    func hasIPs(_ domain: String) -> Bool {
        ipDomains.values.contains { $0.contains(domain) }
    }
}
