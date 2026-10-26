import SwiftUI

/// History mode of the Requests page: filters, a histogram and every stored request matching them. The next
/// page of rows loads when the table is scrolled to its end; a selected row opens in the inspector, as in Live.
struct RequestsHistoryView: View {
    @Environment(AppModel.self) private var model
    var history: RequestsHistoryModel
    /// The first History since the Requests page opened (see `init`).
    private let opensPage: Bool

    /// Search text of the last query that ran; a change of only the search is debounced. Nil until the view first
    /// asks for results.
    @State private var lastSearch: String?
    /// False while the table is built empty, until its first layout.
    @State private var showsRows: Bool

    /// `opensPage` is true for the first History since the Requests page opened and false for the ones the Live /
    /// History switch brings back.
    ///
    /// The first one opens as on a new model: results the model `keeps` appear at once, and others are not drawn
    /// but cleared and loaded again. Its table is built without rows and given them right after its first layout,
    /// as when they arrive from PostgreSQL: a table built with its rows keeps every column at its ideal width even
    /// where they add up to more than the table's width, while one laid out empty first shares that width out.
    /// The ones the switch brings back show the results the model has, with their rows, until newer ones arrive.
    /// So each History keeps the look it has always had.
    init(history: RequestsHistoryModel, opensPage: Bool) {
        self.history = history
        self.opensPage = opensPage
        _showsRows = State(initialValue: !opensPage)
    }

    /// Never loaded: drawn by a History that opens the page in place of results the model will not keep, until it
    /// has asked for new ones.
    private static let unloaded = RequestsHistoryModel()

    var body: some View {
        @Bindable var nav = model.nav
        let key = RequestsHistoryKey(
            scope: model.devices.scope,
            range: nav.history.range,
            appID: nav.history.appID,
            policy: nav.history.policy,
            status: nav.history.status,
            host: nav.history.host,
            remoteIP: nav.history.remoteIP,
            endedWithError: nav.history.endedWithError,
            search: nav.requestSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        let results = opensPage && lastSearch == nil && !history.keeps(key.query) ? Self.unloaded : history
        VStack(spacing: 0) {
            RequestsHistoryFilterBar(history: results)
                .padding(.horizontal, 20.px)
                .padding(.top, 12.px)
                .padding(.bottom, 4.px)

            Group {
                if let histogram = results.histogram, histogram.counts.contains(where: { $0 > 0 }) {
                    RequestsHistogramChart(histogram: histogram)
                } else if results.isLoadingHistogram, !results.isLoading {
                    ProgressView().controlSize(.small)
                } else if let message = results.histogramError, results.errorMessage == nil {
                    RequestsHistogramUnavailable(message: message)
                } else {
                    Color.clear
                }
            }
            .frame(height: 86.px)
            .padding(.horizontal, 20.px)
            .padding(.top, 8.px)
            .padding(.bottom, 6.px)

            Divider()

            RequestsTable(
                model: model, rows: showsRows ? results.rows : [], selection: $nav.selectedRequest, timeStyle: .dayClock, now: nil,
                showsHostBadges: false
            ) {
                Task { await history.loadMore(database: model.database) }
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .overlay { RequestsHistoryOverlay(history: results, search: key.search, host: key.host ?? key.remoteIP, endedWithError: key.endedWithError) }
        }
        .task {
            guard !showsRows else { return }
            // The update that built the table lays it out before this resumes.
            await Task.yield()
            showsRows = true
        }
        .task(id: key) {
            let first = lastSearch == nil
            if let lastSearch, lastSearch != key.search {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            lastSearch = key.search
            await history.show(key.query, database: model.database, clearsOthers: opensPage && first)
        }
        .task(id: nav.history.range) {
            await history.loadPolicies(for: nav.history.range, database: model.database)
        }
        .task(id: history.nextPageFailures) {
            // A next page that failed is asked for again after a pause that grows with each failure, even
            // when the end of the table stays in view (only scrolling to it again would ask otherwise).
            let failures = history.nextPageFailures
            guard failures > 0 else { return }
            try? await Task.sleep(for: .seconds(min(5 * failures, 60)))
            guard !Task.isCancelled else { return }
            await history.loadMore(database: model.database)
        }
    }
}

/// Everything that re-runs the History query when it changes.
private struct RequestsHistoryKey: Hashable {
    var scope: DeviceScope
    var range: HistoryRange
    var appID: AppID?
    var policy: String?
    var status: StatusFilter
    var host: String?
    var remoteIP: String?
    var endedWithError: Bool
    var search: String

    var query: RequestQuery {
        RequestQuery(
            scope: scope, range: range, appID: appID, policy: policy, status: status, search: search, host: host,
            remoteIP: remoteIP, endedWithError: endedWithError
        )
    }
}

/// Range, app, policy and status menus and the exact host or IP; row count and query time. The filters wrap onto a second
/// line where the page is narrow (the inspector open in a small window).
private struct RequestsHistoryFilterBar: View {
    @Environment(AppModel.self) private var model
    var history: RequestsHistoryModel

    var body: some View {
        @Bindable var nav = model.nav
        let apps = model.catalog.active + model.catalog.archived
        RequestsFilterBarLayout(spacing: 8.px, rowSpacing: 6.px) {
            RequestsFilterMenu(title: tr("Time range", "Requests"), label: RequestsHistoryLabels.range(nav.history.range), selection: $nav.history.range) {
                ForEach(HistoryRange.allCases, id: \.self) { range in
                    Text(RequestsHistoryLabels.range(range)).tag(range)
                }
            }
            RequestsFilterMenu(
                title: tr("App", "Requests"),
                label: apps.first { $0.id == nav.history.appID }?.name ?? tr("All apps", "Requests"),
                selection: $nav.history.appID
            ) {
                Text(tr("All apps", "Requests")).tag(AppID?.none)
                if !apps.isEmpty { Divider() }
                ForEach(apps) { app in
                    Text(app.name).tag(AppID?.some(app.id))
                }
            }
            RequestsFilterMenu(title: tr("Policy", "Requests"), label: nav.history.policy ?? tr("All policies", "Requests"), selection: $nav.history.policy) {
                Text(tr("All policies", "Requests")).tag(String?.none)
                if !history.policies.isEmpty { Divider() }
                ForEach(history.policies, id: \.self) { policy in
                    Text(policy).tag(String?.some(policy))
                }
            }
            let status = RequestsStatusChoice.binding(nav)
            RequestsFilterMenu(title: tr("Status", "Requests"), label: RequestsHistoryLabels.status(status.wrappedValue), selection: status) {
                ForEach(RequestsStatusChoice.states, id: \.self) { choice in
                    Text(RequestsHistoryLabels.status(choice)).tag(choice)
                }
                Divider()
                Text(RequestsHistoryLabels.status(.endedWithError)).tag(RequestsStatusChoice.endedWithError)
            }
            if let host = nav.history.host {
                RequestsHostChip(title: tr("Host", "Requests"), host: host, help: host) { nav.history.host = nil }
            }
            if let ip = nav.history.remoteIP {
                RequestsHostChip(
                    title: tr("IP", "Requests"), host: ip,
                    help: trf("Every request that reached %@, to it or to a domain that resolved to it", "Requests", ip)
                ) { nav.history.remoteIP = nil }
            }
            Group {
                if history.isLoading {
                    ProgressView().controlSize(.small)
                }
                if history.errorMessage == nil, history.totalCount > 0 || !history.isLoading {
                    Text(RequestsHistoryLabels.rowCount(history.totalCount, elapsed: history.elapsed))
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.ink3)
                        .lineLimit(1)
                        .contentTransition(.numericText())
                }
            }
            .layoutValue(key: RequestsFilterBarLayout.Trailing.self, value: true)
        }
    }
}

/// A filter menu drawn as the design's pill (`Last 24 hours ▾` on the fill, 26 px tall), hugging its current
/// choice. (A `.menu` picker sizes itself to its longest option, so one long policy name would stretch
/// "All policies".)
private struct RequestsFilterMenu<Value: Hashable, Options: View>: View {
    var title: String
    var label: String
    @Binding var selection: Value
    @ViewBuilder var options: Options

    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                options
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 5.px) {
                Text(label)
                Text(verbatim: "▾")
                    .foregroundStyle(Theme.ink2)
            }
            .font(.design(12))
            .foregroundStyle(Theme.ink)
            .lineLimit(1)
            .padding(.horizontal, 10.px)
            .frame(height: 26.px)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 7.px, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 7.px, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(title)
        .accessibilityLabel(title)
        .accessibilityValue(label)
    }
}

/// The chart area when the histogram failed but the rows loaded: a short note and the reason.
private struct RequestsHistogramUnavailable: View {
    var message: String

    var body: some View {
        HStack(spacing: 6.px) {
            Image(systemName: "chart.bar.xaxis")
                .foregroundStyle(Theme.ink3)
                .accessibilityHidden(true)
            Text(tr("Chart unavailable", "Requests"))
                .foregroundStyle(Theme.ink2)
                .layoutPriority(1)
            Text(message)
                .foregroundStyle(Theme.ink3)
                .truncationMode(.tail)
        }
        .font(.design(12))
        .lineLimit(1)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(message)
        .accessibilityElement(children: .combine)
    }
}

/// Empty and error states over the History table.
private struct RequestsHistoryOverlay: View {
    var history: RequestsHistoryModel
    var search: String
    /// The exact host or IP filtered on.
    var host: String?
    var endedWithError: Bool

    var body: some View {
        if let message = history.errorMessage {
            EmptyState(systemImage: "exclamationmark.triangle", title: tr("Can't load history", "Requests"), message: message)
        } else if history.rows.isEmpty, !history.isLoading {
            if search.isEmpty {
                let title = host.map { trf("No requests to %@ in this range", "Requests", $0) } ?? tr("No requests in this range", "Requests")
                // How a request ended is stored since schema v4: older requests tell it only in their notes, which the
                // query does not read, though the inspector does.
                let message = endedWithError
                    ? tr("“Ended with an error” finds only requests recorded since Tidemark began storing how requests end. Try a longer time range or fewer filters.", "Requests")
                    : tr("Try a longer time range or fewer filters.", "Requests")
                EmptyState(systemImage: "clock", title: title, message: message)
            } else {
                EmptyState(systemImage: "magnifyingglass", title: trf("No requests match “%@”", "Requests", search), message: tr("The filter looks at host, remote IP, process and app.", "Requests"))
            }
        }
    }
}

/// Labels of the History filter menus.
enum RequestsHistoryLabels {
    @MainActor
    static func range(_ range: HistoryRange) -> String {
        switch range {
        case .lastHour: tr("Last hour", "Requests")
        case .last24Hours: tr("Last 24 hours", "Requests")
        case .last7Days: tr("Last 7 days", "Requests")
        case .last30Days: tr("Last 30 days", "Requests")
        case .all: tr("All time", "Requests")
        }
    }

    @MainActor
    static func status(_ status: StatusFilter) -> String {
        switch status {
        case .any: tr("Any status", "Requests")
        case .completed: tr("Completed", "Requests")
        case .active: tr("Active", "Requests")
        case .failed: tr("Failed", "Requests")
        }
    }

    @MainActor
    static func status(_ choice: RequestsStatusChoice) -> String {
        switch choice {
        case .state(let status): Self.status(status)
        case .endedWithError: tr("Ended with an error", "Requests")
        }
    }

    /// `1 row · query 38 ms`, `12,345 rows · query 38 ms`
    @MainActor
    static func rowCount(_ count: Int64, elapsed: Duration) -> String {
        trn("%1$lld row · query %2$@", "%1$lld rows · query %2$@", Int(count), "Requests", milliseconds(elapsed))
    }

    /// `38 ms`
    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return Fmt.ms(Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }
}
