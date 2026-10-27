import SwiftUI

/// "All Requests" tab of a monitored app: every request from the app and everything it launched,
/// live from the stream or from PostgreSQL, with its filter field. A click expands a row into its
/// process chain, connection and timing.
struct AppDetailRequestsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResources
    var app: MonitoredApp
    /// The app is not installed on the selected Mac; rows from every Mac are shown.
    var absent: Bool
    /// The page's counters (requests stored for the app).
    var counters: AppDetailCounters

    /// The request whose card is open.
    @State private var expanded: RequestKey?
    /// The row drawn highlighted, always `expanded`. It changes in a transaction of its own, without the cards'
    /// animation, so the highlight switches at once, like a table's selection, yet still moves with its row.
    @State private var highlighted: RequestKey?
    /// Cards sliding back under their rows, each with the click that closed it. A card stays in the layout until its
    /// space has shrunk to nothing, so the rows below move up with it, and only then leaves.
    @State private var closing: [RequestKey: UUID] = [:]
    @State private var history: [RequestRecord] = []
    @State private var historyLoaded = false
    /// Why the history could not be loaded, described while rendering so it follows the UI language.
    @State private var historyFailure: (any Error)?
    /// Bumped once fresh rows have aged out, so their tint fades even when nothing new arrives.
    @State private var freshTick = 0

    /// Policy grows like the global table's (up to 200 px), so a chip such as `AI › AT&T-RackNerd-Hysteria2` is
    /// whole at the default window width and only shortens when the window is narrow. At the narrowest window, beside
    /// an always-visible scroller, every column is still at least its minimum.
    static let columns = columns(factor: UIScale.factor)
    /// The method before each host (`HTTPS`, `CONNECT`): the design's 40 px and the 2 px more a seven-letter method
    /// needs, which the design lets run into the gap.
    static let methodWidth = methodWidth(factor: UIScale.factor)

    // The widths above at any UI scale. Time, Remote IP and Size are fixed to the longest of their text in 11 px SF
    // Mono (`10-24 23:59:59`, `255.255.255.255`, `999.9 KB`) and the method to `CONNECT` in 9.5 px, text that grows
    // with the scale as the widths do.
    static func columns(factor: CGFloat) -> [AnalyzeColumnsLayout.Column] {
        func px(_ value: CGFloat) -> CGFloat { UIScale.length(value, factor: factor) }
        return [
            .fixed(px(104)), .flexible(weight: 1, min: px(108)), .flexible(weight: 1.5, min: px(150)), .fixed(px(118)),
            .flexible(weight: 1, min: px(104), max: px(200)), .fixed(px(62)),
        ]
    }

    static func methodWidth(factor: CGFloat) -> CGFloat { UIScale.length(42, factor: factor) }

    var body: some View {
        let nav = model.nav
        let live = nav.appRequestsLive
        let rows = live ? liveRows() : history
        let _ = freshTick
        let now = Date.now
        let badges = deviceBadges()

        VStack(spacing: 0) {
            statusLine(live: live)
            if rows.isEmpty {
                header
                emptyMessage(live: live)
            } else {
                ScrollView {
                    // The header scrolls with the rows (pinned), so both get the same width when the scroll
                    // view reserves room for an always-visible scroller.
                    LazyVStack(spacing: 0, pinnedViews: .sectionHeaders) {
                        Section {
                            ForEach(Array(rows.enumerated()), id: \.element.key) { index, record in
                                row(record, index: index, history: !live, now: now, badges: badges)
                                if expanded == record.key || closing[record.key] != nil {
                                    AppDetailCardSpace(fraction: expanded == record.key ? 1 : 0) {
                                        AppDetailRequestCard(record: record, app: app)
                                            .padding(.horizontal, 14.px)
                                            .padding(.top, 2.px)
                                            .padding(.bottom, 8.px)
                                    }
                                    .transition(AppDetailCardEntrance())
                                }
                            }
                        } header: {
                            header.background(Theme.bg)
                        }
                    }
                }
            }
        }
        .task(id: HistoryKey(appID: app.id, live: live, search: nav.appRequestSearch, scope: scope)) {
            guard !live else { return }
            await loadHistory()
        }
        .task(id: live ? rows.first?.key : nil) {
            guard live, let newest = rows.first, RequestsPresentation.isFresh(newest, now: .now) else { return }
            let remaining = RequestsPresentation.freshInterval - Date.now.timeIntervalSince(newest.startedAt)
            try? await Task.sleep(for: .seconds(max(0.05, remaining + 0.05)))
            if !Task.isCancelled { freshTick &+= 1 }
        }
    }

    private var header: some View {
        AnalyzeHeaderRow(columns: Self.columns) {
            Text(tr("Time", "AppDetail"))
            Text(tr("Process", "AppDetail"))
            Text(tr("Host", "AppDetail"))
            Text(tr("Remote IP", "AppDetail"))
            Text(tr("Policy", "AppDetail"))
            Text(tr("Size", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    // MARK: Status line

    private func statusLine(live: Bool) -> some View {
        @Bindable var nav = model.nav
        return HStack(spacing: 10.px) {
            if model.live.recording {
                StatusDot(color: Theme.recording, size: 8.px, pulsing: !reduceMotion && !reducedResources)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Fmt.rate(rate(at: context.date)))
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            Text(trf("from %@ and everything it launched", "AppDetail", app.name))
                .font(.design(12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            DesignSegmentedControl(tr("Source", "AppDetail"), selection: $nav.appRequestsLive, segments: [
                .init(true, tr("Live", "AppDetail"), systemImage: "dot.radiowaves.left.and.right"),
                .init(false, tr("History", "AppDetail"), systemImage: "clock.arrow.circlepath"),
            ])
            AppDetailStoredCount(app: app, absent: absent, counters: counters)
            Spacer(minLength: 0)
            FilterField(prompt: tr("Filter host, IP, process", "AppDetail"), text: $nav.appRequestSearch, width: 200)
        }
        .padding(.horizontal, 20.px)
        .padding(.vertical, 10.px)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    /// New requests per second from this app and the processes it launched on this Mac over the last 10 seconds, like
    /// the sidebar's rate: other Macs' rows reach the live list seconds late, so they are left out.
    private func rate(at now: Date) -> Double {
        guard model.live.recording else { return 0 }
        let since = now.addingTimeInterval(-10)
        let thisMac = model.devices.thisDeviceID
        let count = model.live.rows.lazy.filter { $0.appID == app.id && $0.deviceID == thisMac && $0.startedAt >= since }.count
        return Double(count) / 10
    }

    // MARK: Rows

    private var scope: DeviceScope { absent ? .all : model.devices.scope }

    private var showsDevice: Bool { model.devices.showsDeviceBadges || (absent && model.devices.devices.count > 1) }

    /// Each Mac's badge, looked up once per update and handed to the rows as plain values: the Macs' list also
    /// changes whenever one writes (its row count), and rows that read it would all be redrawn every time.
    private func deviceBadges() -> [DeviceID: AppDetailDeviceBadge]? {
        guard showsDevice else { return nil }
        return Dictionary(model.devices.devices.map { ($0.id, AppDetailDeviceBadge(shortName: $0.shortName, hue: $0.hue)) },
                          uniquingKeysWith: { first, _ in first })
    }

    private func liveRows() -> [RequestRecord] {
        let scope = scope
        let query = model.nav.appRequestSearch.trimmingCharacters(in: .whitespaces).lowercased()
        return Array(model.live.rows.lazy
            .filter { $0.appID == app.id && scope.includes($0.deviceID) }
            .filter { query.isEmpty || Self.matches($0, query) }
            .prefix(300))
    }

    static func matches(_ record: RequestRecord, _ query: String) -> Bool {
        record.host.lowercased().contains(query)
            || (record.remoteIP?.lowercased().contains(query) ?? false)
            || record.processName.lowercased().contains(query)
    }

    private func row(_ record: RequestRecord, index: Int, history: Bool, now: Date, badges: [DeviceID: AppDetailDeviceBadge]?) -> some View {
        let isExpanded = expanded == record.key
        let isFresh = !history && RequestsPresentation.isFresh(record, now: now)
        let background: Color = highlighted == record.key ? Theme.accentTint : isFresh ? Theme.fresh : index.isMultiple(of: 2) ? .clear : Theme.zebra
        return AppDetailRequestRow(record: record, history: history, badge: badges.map { $0[record.deviceID] ?? .unknown })
            .padding(.horizontal, 20.px)
            .frame(height: 28.px)
            .background(background)
            .contentShape(Rectangle())
            .onTapGesture { expand(isExpanded ? nil : record.key) }
    }

    /// Opens the card of the request `key` (closing any other) or, with nil, closes it.
    private func expand(_ key: RequestKey?) {
        highlighted = key
        guard !reduceMotion else {
            expanded = key
            return
        }
        // A card reopened while it slides back keeps its `closing` entry: `withAnimation` applies the changes made
        // before it on their own, so clearing the entry first would drop the card for a moment and replay its entrance.
        let closed = expanded == key ? nil : expanded
        let click = UUID()
        if let closed { closing[closed] = click }
        withAnimation(.snappy(duration: 0.2), completionCriteria: .removed) {
            expanded = key
        } completion: {
            // The closed card's space is empty now, or the card is open again: its entry can go, unless a later
            // click closed it again.
            if let closed, closing[closed] == click { closing[closed] = nil }
        }
    }

    @ViewBuilder
    private func emptyMessage(live: Bool) -> some View {
        let text: String = if live {
            trf("No requests from %@ in the last few minutes.", "AppDetail", app.name)
        } else if let historyFailure {
            CaptureEngine.message(for: historyFailure)
        } else if historyLoaded {
            trf("No stored requests from %@ match.", "AppDetail", app.name)
        } else {
            tr("Loading…", "AppDetail")
        }
        Text(text)
            .font(.design(12.5))
            .foregroundStyle(Theme.ink2)
            .multilineTextAlignment(.center)
            .padding(.vertical, 60.px)
            .padding(.horizontal, 20.px)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: History

    private struct HistoryKey: Hashable {
        var appID: AppID
        var live: Bool
        var search: String
        var scope: DeviceScope
    }

    private func loadHistory() async {
        // Debounce typing in the filter field.
        if historyLoaded {
            try? await Task.sleep(for: .milliseconds(300))
            if Task.isCancelled { return }
        }
        let query = RequestQuery(scope: scope, range: .all, appID: app.id,
                                 search: model.nav.appRequestSearch.trimmingCharacters(in: .whitespaces), limit: 500)
        do {
            let page = try await model.database.queryRequests(query)
            if Task.isCancelled { return }
            history = page.rows
            historyFailure = nil
        } catch {
            if Task.isCancelled { return }
            history = []
            historyFailure = error
        }
        historyLoaded = true
    }
}

/// "1,204 stored": the app's stored requests, in a view of its own so the counters' updates don't redraw the tab.
private struct AppDetailStoredCount: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp
    var absent: Bool
    var counters: AppDetailCounters

    var body: some View {
        Text(trf("%@ stored", "AppDetail", Fmt.count(counters.stats(for: app, absent: absent, model: model).requests)))
            .font(.design(11.5))
            .foregroundStyle(Theme.ink3)
            .lineLimit(1)
            .fixedSize()
    }
}

/// A Mac's badge in the request rows.
private struct AppDetailDeviceBadge: Equatable {
    var shortName: String
    var hue: Double

    /// A Mac the device list doesn't name (yet), drawn like `DeviceState.shortName` / `hue` draw it.
    static let unknown = AppDetailDeviceBadge(shortName: "?", hue: 240)
}

/// One 28 px row of an app's request table.
private struct AppDetailRequestRow: View {
    var record: RequestRecord
    var history: Bool
    /// The Mac's badge, when rows show them.
    var badge: AppDetailDeviceBadge?

    var body: some View {
        AnalyzeColumnsLayout(columns: AppDetailRequestsTab.columns) {
            Text(history ? Fmt.dayClock(record.startedAt) : Fmt.clock(record.startedAt))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)

            HStack(spacing: 6.px) {
                if let badge {
                    DeviceBadge(shortName: badge.shortName, hue: badge.hue)
                }
                if record.chain.count > 1 {
                    Text(verbatim: "└").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                }
                Text(record.processName).lineLimit(1)
                if let pid = record.pid {
                    Text(verbatim: String(pid)).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).fixedSize()
                }
            }

            HStack(spacing: 6.px) {
                Text(record.method)
                    .font(Theme.mono(9.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .frame(width: AppDetailRequestsTab.methodWidth, alignment: .leading)
                // In a narrow column BY IP goes before the host shortens: the host is the address it marks, and
                // Remote IP repeats it.
                AppDetailNameLayout(spacing: 6.px) {
                    Text(record.host).lineLimit(1).truncationMode(.middle)
                    if record.isIPLiteral {
                        ViewThatFits(in: .horizontal) {
                            TagBadge(text: tr("BY IP", "AppDetail"))
                            Color.clear.frame(width: 0, height: 0)
                        }
                    }
                    if record.isNew { TagBadge(text: tr("NEW", "AppDetail"), style: .new) }
                }
            }

            Text(record.remoteIP ?? "—")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)

            PolicyChip(policyPath: record.policyPath, maxWidth: .infinity)

            sizeLabel.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.design(12))
        .foregroundStyle(Theme.ink)
    }

    private var sizeLabel: some View {
        let failed = record.state == .failed || record.state == .rejected
        return Text(failed ? tr("failed", "AppDetail") : Fmt.bytes(record.totalBytes))
            .font(Theme.mono(11))
            .foregroundStyle(failed ? Color(oklch: 0.64, 0.19, 27) : Theme.ink3)
            .lineLimit(1)
    }
}

/// The space the card under an expanded row takes up: `fraction` of the card's height, the part of it that is out,
/// with the card's bottom edge on the space's bottom edge. The rows below are placed under this space on every frame,
/// so the card slides out from under its row with them and back in, even when a click retargets an animation that is
/// still under way. A plain `.move(edge: .top)` would start the card a card's height higher, drawn over the row and
/// the rows above it.
private struct AppDetailCardSpace: Layout {
    var fraction: Double

    var animatableData: Double {
        get { fraction }
        set { fraction = newValue }
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let card = subviews.first else { return .zero }
        let size = card.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        // A spring overshoots below 0 as the card goes; a negative height would pull the rows below over the row.
        return CGSize(width: size.width, height: size.height * max(0, fraction))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        guard let card = subviews.first else { return }
        let size = card.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
        card.place(at: CGPoint(x: bounds.minX, y: bounds.maxY), anchor: .bottomLeading, proposal: ProposedViewSize(size))
    }
}

/// A card's way in: its space starts empty and grows to the whole card. The card is clipped to its space, so it is
/// never drawn over its row or the rows above, and takes clicks only inside it: a clip only hides the rest of the card,
/// which would still take the clicks meant for those rows while the card slides.
///
/// It only plays on the way in. SwiftUI takes a view out of the layout as soon as its removal starts, so on the way
/// out the rows below would move up on their own, under a card left where it was. A card is removed only once its
/// space has shrunk to nothing (`AppDetailRequestsTab.closing`).
private struct AppDetailCardEntrance: Transition {
    func body(content: Content, phase: TransitionPhase) -> some View {
        AppDetailCardSpace(fraction: phase.isIdentity ? 1 : 0) { content }
            .clipShape(Uncovered())
            .contentShape(Rectangle())
    }

    /// The card's space, from the row's bottom edge down, with room at the sides and bottom for the card's shadow.
    /// The room below grows with the space, so a card that is barely out casts no shadow over the next row.
    private struct Uncovered: Shape {
        func path(in rect: CGRect) -> Path {
            let shadow = 40.px
            return Path(CGRect(x: rect.minX - shadow, y: rect.minY,
                               width: rect.width + 2 * shadow, height: rect.height + min(shadow, rect.height)))
        }
    }
}

/// The inline card under an expanded request row: process chain and attribution, connection, timing.
struct AppDetailRequestCard: View {
    var record: RequestRecord
    var app: MonitoredApp

    var body: some View {
        let phases = RequestTiming.phases(for: record)
        let total = phases.reduce(0) { $0 + $1.duration }
        AnalyzeColumnsLayout(columns: [.flexible(weight: 1.5), .flexible(weight: 1), .flexible(weight: 1)], spacing: 20.px, topAligned: true) {
            VStack(alignment: .leading, spacing: 6.px) {
                SectionLabel(text: tr("Process chain", "AppDetail"))
                Text(Self.chainText(record))
                    .font(Theme.mono(11.5))
                    .lineHeight(Theme.noteLineHeight)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(Self.attribution(record, app: app))
                    .font(.design(11.5))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6.px) {
                SectionLabel(text: tr("Connection", "AppDetail"))
                Text(record.geo?.display ?? "—")
                Text(record.rule ?? "—")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7.px) {
                HStack {
                    SectionLabel(text: tr("Timing", "AppDetail"))
                    Spacer(minLength: 4.px)
                    Text(Fmt.ms(total * 1000)).font(Theme.mono(11)).foregroundStyle(Theme.ink2)
                }
                if phases.isEmpty {
                    Text(verbatim: "—").foregroundStyle(Theme.ink3)
                } else {
                    TimingBar(phases: phases, barHeight: 7.px, showsLegend: false)
                }
                if let rowID = record.rowID {
                    Text(trf("Stored as row %@", "AppDetail", "#\(rowID)"))
                        .font(.design(11))
                        .foregroundStyle(Theme.ink2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.design(12))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14.px)
        .padding(.vertical, 12.px)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10.px, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10.px, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 9.px, y: 6.px)
    }

    /// `Cursor (812)  →  Cursor Helper (Plugin) (851)  →  node (1201)`
    static func chainText(_ record: RequestRecord) -> String {
        guard !record.chain.isEmpty else {
            return record.pid.map { "\(record.processName) (\($0))" } ?? record.processName
        }
        return record.chain.map { "\($0.name) (\($0.pid))" }.joined(separator: "  →  ")
    }

    /// Parent processes between the app's own process and the one that sent the request.
    static func parentHops(_ record: RequestRecord, app: MonitoredApp) -> Int {
        guard record.chain.count > 1 else { return 0 }
        let root = record.chain.firstIndex { $0.path.map(app.contains(processPath:)) ?? false } ?? 0
        return max(0, record.chain.count - 1 - root)
    }

    @MainActor
    static func attribution(_ record: RequestRecord, app: MonitoredApp) -> String {
        let hops = parentHops(record, app: app)
        guard hops > 0 else { return trf("Sent by %@ itself", "AppDetail", app.name) }
        return trn("Rolled up to %2$@ through %1$lld parent", "Rolled up to %2$@ through %1$lld parents", hops, "AppDetail", app.name)
    }
}
