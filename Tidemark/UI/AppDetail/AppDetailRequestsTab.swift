import SwiftUI

/// "All Requests" tab of a monitored app: every request from the app and everything it launched,
/// live from the stream or from PostgreSQL, with its filter field. A click expands a row into its
/// process chain, connection and timing.
struct AppDetailRequestsTab: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResources
    var app: MonitoredApp
    /// Requests stored for the app (header counter).
    var storedCount: Int64
    /// The app is not installed on the selected Mac; rows from every Mac are shown.
    var absent: Bool

    @State private var expanded: RequestKey?
    @State private var history: [RequestRecord] = []
    @State private var historyLoaded = false
    /// Why the history could not be loaded, described while rendering so it follows the UI language.
    @State private var historyFailure: (any Error)?
    /// Bumped once fresh rows have aged out, so their tint fades even when nothing new arrives.
    @State private var freshTick = 0

    /// Policy grows like the global table's (up to 200 pt), so a chip such as `AI › AT&T-RackNerd-Hysteria2` is
    /// whole at the default window width and only shortens when the window is narrow.
    static let columns: [AnalyzeColumnsLayout.Column] = [
        .fixed(104), .flexible(weight: 1, min: 120), .flexible(weight: 1.5, min: 150), .fixed(118),
        .flexible(weight: 1, min: 104, max: 200), .fixed(62),
    ]

    var body: some View {
        let nav = model.nav
        let live = nav.appRequestsLive
        let rows = live ? liveRows() : history
        let _ = freshTick
        let now = Date.now

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
                                row(record, index: index, history: !live, now: now)
                                if expanded == record.key {
                                    AppDetailRequestCard(record: record, app: app)
                                        .padding(.horizontal, 14)
                                        .padding(.top, 2)
                                        .padding(.bottom, 8)
                                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .move(edge: .top)))
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
        return HStack(spacing: 10) {
            if model.live.recording {
                StatusDot(color: Theme.recording, size: 7, pulsing: !reduceMotion && !reducedResources)
            }
            TimelineView(.periodic(from: .now, by: 1)) { context in
                Text(Fmt.rate(rate(at: context.date)))
                    .font(Theme.mono(12, weight: .semibold))
                    .foregroundStyle(Theme.ink)
            }
            Text(trf("from %@ and everything it launched", "AppDetail", app.name))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            Picker(tr("Source", "AppDetail"), selection: $nav.appRequestsLive) {
                Text(tr("Live", "AppDetail")).tag(true)
                Text(tr("History", "AppDetail")).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            Text(trf("%@ stored", "AppDetail", Fmt.count(storedCount)))
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.ink3)
                .lineLimit(1)
                .fixedSize()
            Spacer(minLength: 0)
            FilterField(prompt: tr("Filter host, IP, process", "AppDetail"), text: $nav.appRequestSearch, width: 200)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    /// Requests per second from this app over the last 10 seconds.
    private func rate(at now: Date) -> Double {
        guard model.live.recording else { return 0 }
        let since = now.addingTimeInterval(-10)
        let count = model.live.rows.lazy.filter { $0.appID == app.id && $0.startedAt >= since }.count
        return Double(count) / 10
    }

    // MARK: Rows

    private var scope: DeviceScope { absent ? .all : model.devices.scope }

    private var showsDevice: Bool { model.devices.showsDeviceBadges || (absent && model.devices.devices.count > 1) }

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

    private func row(_ record: RequestRecord, index: Int, history: Bool, now: Date) -> some View {
        let isExpanded = expanded == record.key
        let isFresh = !history && RequestsPresentation.isFresh(record, now: now)
        let background: Color = isExpanded ? Theme.accentTint : isFresh ? Theme.fresh : index.isMultiple(of: 2) ? .clear : Theme.zebra
        return AppDetailRequestRow(record: record, history: history, showsDevice: showsDevice)
            .padding(.horizontal, 20)
            .frame(height: 28)
            .background(background)
            .animation(.easeOut(duration: 0.9), value: isFresh)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { expanded = isExpanded ? nil : record.key }
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
            .font(.system(size: 12.5))
            .foregroundStyle(Theme.ink2)
            .multilineTextAlignment(.center)
            .padding(.vertical, 60)
            .padding(.horizontal, 20)
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

/// One 28-point row of an app's request table.
private struct AppDetailRequestRow: View {
    @Environment(AppModel.self) private var model
    var record: RequestRecord
    var history: Bool
    var showsDevice: Bool

    var body: some View {
        AnalyzeColumnsLayout(columns: AppDetailRequestsTab.columns) {
            Text(history ? Fmt.dayClock(record.startedAt) : Fmt.clock(record.startedAt))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)

            HStack(spacing: 6) {
                if showsDevice {
                    DeviceBadge(shortName: model.devices.shortName(record.deviceID), hue: model.devices.hue(record.deviceID))
                }
                if record.chain.count > 1 {
                    Text(verbatim: "└").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                }
                Text(record.processName).lineLimit(1)
                if let pid = record.pid {
                    Text(verbatim: String(pid)).font(Theme.mono(10.5)).foregroundStyle(Theme.ink3).fixedSize()
                }
            }

            HStack(spacing: 6) {
                Text(record.method)
                    .font(Theme.mono(9.5, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .lineLimit(1)
                    .frame(width: 40, alignment: .leading)
                Text(record.host).lineLimit(1).truncationMode(.middle)
                if record.isIPLiteral { TagBadge(text: tr("BY IP", "AppDetail")) }
                if record.isNew { TagBadge(text: tr("NEW", "AppDetail"), style: .new) }
            }

            Text(record.remoteIP ?? "—")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)

            PolicyChip(policyPath: record.policyPath, maxWidth: .infinity)

            sizeLabel.frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 12))
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

/// The inline card under an expanded request row: process chain and attribution, connection, timing.
struct AppDetailRequestCard: View {
    var record: RequestRecord
    var app: MonitoredApp

    var body: some View {
        let phases = RequestTiming.phases(for: record)
        let total = phases.reduce(0) { $0 + $1.duration }
        AnalyzeColumnsLayout(columns: [.flexible(weight: 1.5), .flexible(weight: 1), .flexible(weight: 1)], spacing: 20, topAligned: true) {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: tr("Process chain", "AppDetail"))
                Text(Self.chainText(record))
                    .font(Theme.mono(11.5))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Text(Self.attribution(record, app: app))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(text: tr("Connection", "AppDetail"))
                Text(record.geo?.display ?? "—")
                Text(record.rule ?? "—")
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    SectionLabel(text: tr("Timing", "AppDetail"))
                    Spacer(minLength: 4)
                    Text(Fmt.ms(total * 1000)).font(Theme.mono(11)).foregroundStyle(Theme.ink2)
                }
                if phases.isEmpty {
                    Text(verbatim: "—").foregroundStyle(Theme.ink3)
                } else {
                    TimingBar(phases: phases, barHeight: 7, showsLegend: false)
                }
                if let rowID = record.rowID {
                    Text(trf("Stored as row %@", "AppDetail", "#\(rowID)"))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.1), radius: 9, y: 6)
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
