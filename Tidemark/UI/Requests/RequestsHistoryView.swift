import SwiftUI

/// History mode of the Requests page: filters, a histogram and every stored request matching them. The next
/// page of rows loads when the table is scrolled to its end.
struct RequestsHistoryView: View {
    @Environment(AppModel.self) private var model
    var history: RequestsHistoryModel

    /// Search text of the last query that ran; a change of only the search is debounced.
    @State private var lastSearch: String?
    /// False while the table is built empty, until its first layout.
    @State private var showsRows: Bool

    /// `buildsTableEmpty` builds the table without rows and gives it the rows already loaded right after its first
    /// layout, as when they arrive from PostgreSQL. A table built with its rows keeps every column at its ideal width
    /// even where they add up to more than the table's width, while one laid out empty first shares that width out.
    /// `RequestsView` builds the first History after the page opens empty and the ones the Live / History switch
    /// brings back with their rows, so each keeps the columns it has always had.
    init(history: RequestsHistoryModel, buildsTableEmpty: Bool) {
        self.history = history
        _showsRows = State(initialValue: !buildsTableEmpty)
    }

    var body: some View {
        let nav = model.nav
        let key = RequestsHistoryKey(
            scope: model.devices.scope,
            range: nav.history.range,
            appID: nav.history.appID,
            policy: nav.history.policy,
            status: nav.history.status,
            search: nav.requestSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        VStack(spacing: 0) {
            RequestsHistoryFilterBar(history: history)
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)

            Group {
                if let histogram = history.histogram, histogram.counts.contains(where: { $0 > 0 }) {
                    RequestsHistogramChart(histogram: histogram)
                } else if history.isLoadingHistogram, !history.isLoading {
                    ProgressView().controlSize(.small)
                } else if let message = history.histogramError, history.errorMessage == nil {
                    RequestsHistogramUnavailable(message: message)
                } else {
                    Color.clear
                }
            }
            .frame(height: 86)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            // As in the design, History rows are not selectable: the inspector belongs to the live table.
            RequestsTable(model: model, rows: showsRows ? history.rows : [], timeStyle: .dayClock, now: nil, showsHostBadges: false) {
                Task { await history.loadMore(database: model.database) }
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .overlay { RequestsHistoryOverlay(history: history, search: key.search) }
        }
        .task {
            guard !showsRows else { return }
            // The update that built the table lays it out before this resumes.
            await Task.yield()
            showsRows = true
        }
        .task(id: key) {
            if let lastSearch, lastSearch != key.search {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            lastSearch = key.search
            await history.show(key.query, database: model.database)
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
    var search: String

    var query: RequestQuery {
        RequestQuery(scope: scope, range: range, appID: appID, policy: policy, status: status, search: search)
    }
}

/// Range, app, policy and status menus; row count and query time.
private struct RequestsHistoryFilterBar: View {
    @Environment(AppModel.self) private var model
    var history: RequestsHistoryModel

    var body: some View {
        @Bindable var nav = model.nav
        let apps = model.catalog.active + model.catalog.archived
        HStack(spacing: 8) {
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
            RequestsFilterMenu(title: tr("Status", "Requests"), label: RequestsHistoryLabels.status(nav.history.status), selection: $nav.history.status) {
                ForEach(StatusFilter.allCases, id: \.self) { status in
                    Text(RequestsHistoryLabels.status(status)).tag(status)
                }
            }
            Spacer(minLength: 8)
            if history.isLoading {
                ProgressView().controlSize(.small)
            }
            if history.errorMessage == nil, history.totalCount > 0 || !history.isLoading {
                Text(trf("%1$@ rows · query %2$@", "Requests", Fmt.count(history.totalCount), RequestsHistoryLabels.milliseconds(history.elapsed)))
                    .font(Theme.mono(11))
                    .foregroundStyle(Theme.ink3)
                    .lineLimit(1)
                    .contentTransition(.numericText())
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .controlSize(.regular)
    }
}

/// A filter menu whose button hugs its current choice. (A `.menu` picker sizes itself to its longest
/// option, so one long policy name would stretch "All policies".)
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
            Text(label)
                .lineLimit(1)
        }
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
        HStack(spacing: 6) {
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
        .font(.system(size: 12))
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

    var body: some View {
        if let message = history.errorMessage {
            EmptyState(systemImage: "exclamationmark.triangle", title: tr("Can't load history", "Requests"), message: message)
        } else if history.rows.isEmpty, !history.isLoading {
            if search.isEmpty {
                EmptyState(systemImage: "clock", title: tr("No requests in this range", "Requests"), message: tr("Try a longer time range or fewer filters.", "Requests"))
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

    /// `38 ms`
    static func milliseconds(_ duration: Duration) -> String {
        let (seconds, attoseconds) = duration.components
        return Fmt.ms(Double(seconds) * 1000 + Double(attoseconds) / 1e15)
    }
}
