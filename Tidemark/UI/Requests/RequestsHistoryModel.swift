import Foundation
import Observation

/// Results of the History view's current query: a page of rows, the histogram and the timing line.
///
/// The page and the histogram load side by side and land on their own: over a long history the histogram
/// can take far longer than the page, so the rows never wait for it, and a histogram that fails leaves the
/// rows in place. A page that fails takes the chart with it.
///
/// `AppModel` owns it rather than the page, so History brought back by the sidebar or the Live / History switch
/// shows its last results at once (`show`) when they are for the same filters, were read from the same database
/// and loaded in full within `reuseInterval`. Once older than `refreshInterval` they are queried again in the
/// background, and only what changed is replaced.
@MainActor
@Observable
final class RequestsHistoryModel {
    /// Rows fetched per page (scrolling to the end of the table appends the next page).
    static let pageSize = 500
    static let histogramBuckets = 48

    /// How long results that loaded in full are shown again for the same filters.
    let reuseInterval: Duration
    /// Results shown again once they are this old are queried again in the background.
    let refreshInterval: Duration

    private(set) var rows: [RequestRecord] = []
    private(set) var totalCount: Int64 = 0
    private(set) var elapsed: Duration = .zero
    /// The chart of the rows shown: nil while the current query's histogram is still loading after its page
    /// arrived, or when either of them failed.
    private(set) var histogram: Histogram?
    private(set) var policies: [String] = []
    /// The current query's page is loading.
    private(set) var isLoading = false
    /// The current query's histogram is loading.
    private(set) var isLoadingHistogram = false
    private(set) var isLoadingMore = false
    /// Why the current query's first page failed, nil after one succeeded.
    private(set) var failure: (any Error)?
    /// Next pages that failed in a row. The rows already loaded stay and the next `loadMore` asks again; the
    /// view retries after each failure while it is shown.
    private(set) var nextPageFailures = 0
    /// Why the current query's histogram failed; the rows are unaffected.
    private(set) var histogramFailure: (any Error)?
    /// The query the rows belong to (offset 0).
    private(set) var query = RequestQuery()

    /// Bumped by every load and refresh: only the latest one may change the results.
    @ObservationIgnored private var generation = 0
    /// The latest load's queries; a newer load cancels them.
    @ObservationIgnored private var loading: Task<Void, Never>?
    /// Bumped when `AppModel` replaces its database (`databaseChanged`).
    @ObservationIgnored private var databaseGeneration = 0
    /// The `databaseGeneration` the current query reads.
    @ObservationIgnored private var queryDatabase = 0
    /// When the current query's page and histogram both last arrived; nil while it first loads, and after either
    /// failed.
    @ObservationIgnored private var completedAt: ContinuousClock.Instant?
    /// The range and database `policies` belong to, and when they arrived.
    @ObservationIgnored private var policiesLoaded: (range: HistoryRange, database: Int, at: ContinuousClock.Instant)?

    init(reuseInterval: Duration = .seconds(60), refreshInterval: Duration = .seconds(5)) {
        self.reuseInterval = reuseInterval
        self.refreshInterval = refreshInterval
    }

    var canLoadMore: Bool { Int64(rows.count) < totalCount && !isLoadingMore && failure == nil }

    /// `failure` in the UI language, described when it is shown so it follows a change of language.
    var errorMessage: String? { failure.map { CaptureEngine.message(for: $0) } }
    /// `histogramFailure` in the UI language.
    var histogramError: String? { histogramFailure.map { CaptureEngine.message(for: $0) } }

    /// Whether `show` keeps the results here for `query`: they are for the same filters, were read from the current
    /// database and loaded in full within `reuseInterval`.
    func keeps(_ query: RequestQuery) -> Bool {
        guard let completedAt, queryDatabase == databaseGeneration, sameFilter(query, self.query) else { return false }
        return ContinuousClock.now - completedAt < reuseInterval
    }

    /// Shows the results of `query`. Results it `keeps` stay up, and once older than `refreshInterval` they are
    /// queried again in the background with no loading state: only what changed is replaced, so an unchanged
    /// answer redraws nothing. Other results are loaded again (`load`); `clearsOthers` clears them first, as on a
    /// new model, instead of leaving them up until the new page arrives.
    func show(_ query: RequestQuery, database: any TidemarkDatabase, clearsOthers: Bool = false) async {
        guard keeps(query), let completedAt else {
            if clearsOthers { clear() }
            await load(query, database: database)
            return
        }
        guard ContinuousClock.now - completedAt >= refreshInterval else { return }
        await run(self.query, quietly: true, database: database)
    }

    /// Runs `query` from the first page and refreshes the histogram. The rows and total appear as soon as
    /// the page arrives and the histogram follows when it is ready. A newer load cancels this one, so a
    /// slow histogram of an earlier filter never lands beside the newer rows.
    func load(_ query: RequestQuery, database: any TidemarkDatabase) async {
        var first = query
        first.limit = Self.pageSize
        first.offset = 0
        self.query = first
        queryDatabase = databaseGeneration
        nextPageFailures = 0
        completedAt = nil
        isLoading = true
        isLoadingHistogram = true
        await run(first, quietly: false, database: database)
    }

    /// Called when `AppModel` replaces its database: results and policies read from the previous one are not kept.
    func databaseChanged() {
        databaseGeneration &+= 1
    }

    /// Appends the next page of the current query.
    func loadMore(database: any TidemarkDatabase) async {
        guard canLoadMore else { return }
        var next = query
        next.offset = rows.count
        isLoadingMore = true
        defer { isLoadingMore = false }
        do {
            let result = try await database.queryRequests(next)
            guard next.offset == rows.count, query.offset == 0, sameFilter(next, query) else { return }
            let known = Set(rows.map(\.key))
            rows.append(contentsOf: result.rows.filter { !known.contains($0.key) })
            totalCount = result.totalCount
            elapsed = result.elapsed
            nextPageFailures = 0
        } catch {
            // A next page that fails leaves the rows above it alone; only a failed first page means
            // "Can't load history".
            guard !Task.isCancelled, next.offset == rows.count, sameFilter(next, query) else { return }
            nextPageFailures += 1
        }
    }

    /// Final policies seen in `range`, for the policy filter menu. The list already here is kept when it is for the
    /// same range and database and younger than `refreshInterval`, and replaced only when it changed.
    func loadPolicies(for range: HistoryRange, database: any TidemarkDatabase) async {
        let source = databaseGeneration
        if let loaded = policiesLoaded, loaded.range == range, loaded.database == source,
           ContinuousClock.now - loaded.at < refreshInterval { return }
        if let list = try? await database.distinctPolicies(since: range.lowerBound()), !Task.isCancelled {
            let sorted = list.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
            if sorted != policies { policies = sorted }
            policiesLoaded = (range, source, .now)
        }
    }

    // MARK: Loading

    /// One of a load's two results.
    private enum Part: Sendable {
        case page(Result<RequestPage, any Error>)
        case histogram(Result<Histogram, any Error>)
    }

    /// The results a new model starts with.
    private func clear() {
        rows = []
        totalCount = 0
        elapsed = .zero
        failure = nil
        histogram = nil
        histogramFailure = nil
    }

    /// Runs `query` (its first page) as the latest load, cancelling the one before. `quietly` refreshes the
    /// results already shown for it rather than loading them.
    private func run(_ query: RequestQuery, quietly: Bool, database: any TidemarkDatabase) async {
        generation &+= 1
        let generation = generation
        loading?.cancel()
        let task = Task { await self.fetch(query, generation: generation, quietly: quietly, database: database) }
        loading = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Runs the page and the histogram of `query` side by side and applies each as it arrives, as long as
    /// this is still the latest load.
    private func fetch(_ query: RequestQuery, generation: Int, quietly: Bool, database: any TidemarkDatabase) async {
        let buckets = Self.histogramBuckets
        var arrived = (page: false, histogram: false)
        var failed = false
        await withTaskGroup(of: Part.self) { group in
            group.addTask { .page(await Self.result { try await database.queryRequests(query) }) }
            group.addTask { .histogram(await Self.result { try await database.histogram(query, buckets: buckets) }) }
            for await part in group where generation == self.generation && !Task.isCancelled {
                apply(part, quietly: quietly)
                switch part {
                case .page(.success): arrived.page = true
                case .histogram(.success): arrived.histogram = true
                case .histogram(.failure(let error)): failed = failed || !(error is CancellationError)
                case .page(.failure(let error)):
                    failed = failed || !(error is CancellationError)
                    // A failed page stands for the whole query: its histogram is no longer wanted.
                    group.cancelAll()
                    return
                }
            }
        }
        // Cancelled with no newer load (the view went away): nothing is loading any more. A refresh cancelled
        // that way leaves the results it refreshed as they were.
        if generation == self.generation {
            if isLoading { isLoading = false }
            if isLoadingHistogram { isLoadingHistogram = false }
            if arrived.page, arrived.histogram {
                completedAt = .now
            } else if failed {
                completedAt = nil
            }
        }
    }

    private func apply(_ part: Part, quietly: Bool) {
        switch part {
        case .page(let result):
            if isLoading { isLoading = false }
            switch result {
            case .success(let page) where quietly:
                // The same filters again: only what changed is replaced, so an unchanged answer redraws nothing.
                let rowsChanged = page.rows != rows
                guard rowsChanged || page.totalCount != totalCount else { return }
                if rowsChanged {
                    rows = page.rows
                    if nextPageFailures != 0 { nextPageFailures = 0 }
                }
                totalCount = page.totalCount
                elapsed = page.elapsed
            case .success(let page):
                rows = page.rows
                totalCount = page.totalCount
                elapsed = page.elapsed
                failure = nil
                // The previous query's chart must not stay beside these rows while this query's is loading.
                if isLoadingHistogram {
                    histogram = nil
                    histogramFailure = nil
                }
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                rows = []
                totalCount = 0
                failure = error
                // No chart beside "Can't load history", even one that arrived before the page failed.
                histogram = nil
                histogramFailure = nil
                isLoadingHistogram = false
            }
        case .histogram(let result):
            if isLoadingHistogram { isLoadingHistogram = false }
            switch result {
            case .success(let value):
                if histogram != value { histogram = value }
                if histogramFailure != nil { histogramFailure = nil }
            case .failure(let error):
                guard !(error is CancellationError) else { return }
                histogram = nil
                histogramFailure = error
            }
        }
    }

    private nonisolated static func result<T>(_ work: () async throws -> T) async -> Result<T, any Error> {
        do {
            return .success(try await work())
        } catch {
            return .failure(error)
        }
    }

    private func sameFilter(_ a: RequestQuery, _ b: RequestQuery) -> Bool {
        a.scope == b.scope && a.range == b.range && a.appID == b.appID && a.policy == b.policy
            && a.status == b.status && a.search == b.search && a.host == b.host && a.endedWithError == b.endedWithError
    }
}
