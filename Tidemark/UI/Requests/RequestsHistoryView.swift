import SwiftUI
import UniformTypeIdentifiers

/// History mode of the Requests page: filters, a histogram and every stored request matching them.
struct RequestsHistoryView: View {
    @Environment(AppModel.self) private var model
    var history: RequestsHistoryModel

    /// Search text of the last query that ran; a change of only the search is debounced.
    @State private var lastSearch: String?
    @State private var reloadToken = 0
    @State private var exportDocument: RequestsCSVDocument?
    @State private var isExporting = false
    @State private var exportError: (any Error)?

    var body: some View {
        @Bindable var nav = model.nav
        let key = RequestsHistoryKey(
            scope: model.devices.scope,
            range: nav.history.range,
            interval: nav.history.interval,
            appID: nav.history.appID,
            policy: nav.history.policy,
            status: nav.history.status,
            search: nav.requestSearch.trimmingCharacters(in: .whitespacesAndNewlines),
            reload: reloadToken
        )
        VStack(spacing: 0) {
            RequestsHistoryFilterBar(history: history, export: startExport, reload: { reloadToken &+= 1 })
                .padding(.horizontal, 20)
                .padding(.top, 12)
                .padding(.bottom, 4)

            if let window = nav.history.interval {
                RequestsZoomBar(window: window) { nav.history.interval = nil }
                    .padding(.horizontal, 20)
                    .padding(.top, 4)
            }

            Group {
                if let histogram = history.histogram, histogram.counts.contains(where: { $0 > 0 }) || nav.history.interval != nil {
                    RequestsHistogramChart(histogram: histogram) { window in
                        nav.history.interval = window
                    }
                } else {
                    Color.clear
                }
            }
            .frame(height: 86)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider()

            RequestsTable(model: model, rows: history.rows, selection: $nav.selectedRequest, timeStyle: .dayClock, now: nil)
                .scrollEdgeEffectStyle(.hard, for: .top)
                .overlay { RequestsHistoryOverlay(history: history, search: key.search) }

            RequestsHistoryFooter(history: history)
        }
        .task(id: key) {
            if let lastSearch, lastSearch != key.search {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled else { return }
            }
            lastSearch = key.search
            await history.load(key.query, database: model.database)
        }
        .task(id: nav.history.range) {
            await history.loadPolicies(since: nav.history.range.lowerBound(), database: model.database)
        }
        // A zoomed window belongs to the range it was dragged in.
        .onChange(of: nav.history.range) { nav.history.interval = nil }
        .fileExporter(
            isPresented: $isExporting,
            document: exportDocument,
            contentType: .commaSeparatedText,
            defaultFilename: RequestsHistoryView.exportFilename(),
            onCompletion: { result in
                if case .failure(let error) = result { exportError = error }
                exportDocument = nil
            },
            onCancellation: { exportDocument = nil }
        )
        .alert(error: $exportError) {
            Button(tr("OK", "Requests")) {}
        }
    }

    private func startExport() {
        let snapshot = RequestsCSVSnapshot(
            query: history.query,
            database: model.database,
            appNames: Dictionary(model.catalog.apps.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first }),
            deviceNames: Dictionary(model.devices.devices.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        )
        exportDocument = RequestsCSVDocument(snapshot: snapshot)
        isExporting = true
    }

    /// `Tidemark Requests 2026-10-24 1432.csv`
    static func exportFilename(now: Date = .now) -> String {
        let stamp = now.formatted(.verbatim("\(year: .defaultDigits)-\(month: .twoDigits)-\(day: .twoDigits) \(hour: .twoDigits(clock: .twentyFourHour, hourCycle: .zeroBased))\(minute: .twoDigits)", timeZone: .current, calendar: .current))
        return "Tidemark Requests \(stamp).csv"
    }
}

/// Everything that re-runs the History query when it changes.
private struct RequestsHistoryKey: Hashable {
    var scope: DeviceScope
    var range: HistoryRange
    var interval: DateInterval?
    var appID: AppID?
    var policy: String?
    var status: StatusFilter
    var search: String
    var reload: Int

    var query: RequestQuery {
        RequestQuery(scope: scope, range: range, interval: interval, appID: appID, policy: policy, status: status, search: search)
    }
}

/// Range, app, policy and status menus; row count and query time; export.
private struct RequestsHistoryFilterBar: View {
    @Environment(AppModel.self) private var model
    var history: RequestsHistoryModel
    var export: () -> Void
    var reload: () -> Void

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
            Button(action: reload) {
                Image(systemName: "arrow.clockwise")
            }
            .help(tr("Run the query again", "Requests"))
            .accessibilityLabel(tr("Refresh", "Requests"))
            Button(tr("Export CSV…", "Requests"), action: export)
                .disabled(history.totalCount == 0 || history.errorMessage != nil)
                .help(tr("Save every row matching these filters as CSV", "Requests"))
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

/// `⌕ Zoomed to 14:05–16:30  Reset Zoom`, shown while the chart is zoomed: the dragged window and the way
/// back to the whole range.
private struct RequestsZoomBar: View {
    var window: DateInterval
    var reset: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "plus.magnifyingglass")
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            Text(trf("Zoomed to %@", "Requests", RequestsHistogramBin.windowLabel(window.start, window.end, locale: Localizer.shared.locale)))
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
            Button(tr("Reset Zoom", "Requests"), action: reset)
                .controlSize(.small)
                .help(tr("Show the whole time range again", "Requests"))
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .contain)
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

/// `Showing 500 of 48,211` and Load More.
private struct RequestsHistoryFooter: View {
    @Environment(AppModel.self) private var model
    var history: RequestsHistoryModel

    var body: some View {
        HStack(spacing: 8) {
            Text(trf("Showing %1$@ of %2$@", "Requests", Fmt.count(history.rows.count), Fmt.count(history.totalCount)))
            Spacer(minLength: 8)
            if history.isLoadingMore {
                ProgressView().controlSize(.mini)
            }
            if Int64(history.rows.count) < history.totalCount {
                Button(tr("Load More", "Requests")) {
                    Task { await history.loadMore(database: model.database) }
                }
                .buttonStyle(.borderless)
                .disabled(!history.canLoadMore)
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.ink3)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 28)
        .overlay(alignment: .top) { Divider() }
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
