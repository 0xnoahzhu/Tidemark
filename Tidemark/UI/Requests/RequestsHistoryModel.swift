import Foundation
import Observation

/// Results of the History view's current query: a page of rows, the histogram and the timing line.
///
/// The page and the histogram load side by side and land on their own: over a long history the histogram
/// can take far longer than the page, so the rows never wait for it, and a histogram that fails leaves the
/// rows in place. A page that fails takes the chart with it.
@MainActor
@Observable
final class RequestsHistoryModel {
    /// Rows fetched per page ("Load More" appends the next page).
    static let pageSize = 500
    static let histogramBuckets = 48

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
    /// Why the last load failed, nil after one succeeded.
    private(set) var failure: (any Error)?
    /// Why the current query's histogram failed; the rows are unaffected.
    private(set) var histogramFailure: (any Error)?
    /// The query the rows belong to (offset 0). Its `interval` is set while the chart is zoomed.
    private(set) var query = RequestQuery()

    /// Bumped by every `load`: only the latest load may change the results.
    @ObservationIgnored private var generation = 0
    /// The latest load's queries; a newer load cancels them.
    @ObservationIgnored private var loading: Task<Void, Never>?

    var canLoadMore: Bool { Int64(rows.count) < totalCount && !isLoadingMore && failure == nil }

    /// `failure` in the UI language, described when it is shown so it follows a change of language.
    var errorMessage: String? { failure.map { CaptureEngine.message(for: $0) } }
    /// `histogramFailure` in the UI language.
    var histogramError: String? { histogramFailure.map { CaptureEngine.message(for: $0) } }

    /// Runs `query` from the first page and refreshes the histogram. The rows and total appear as soon as
    /// the page arrives and the histogram follows when it is ready. A newer load cancels this one, so a
    /// slow histogram of an earlier filter never lands beside the newer rows.
    func load(_ query: RequestQuery, database: any TidemarkDatabase) async {
        var first = query
        first.limit = Self.pageSize
        first.offset = 0
        first.before = nil
        self.query = first
        generation &+= 1
        let generation = generation
        isLoading = true
        isLoadingHistogram = true
        loading?.cancel()
        let task = Task { await self.fetch(first, generation: generation, database: database) }
        loading = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
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
        } catch {
            if !Task.isCancelled { failure = error }
        }
    }

    /// Final policies seen in the selected range, for the policy filter menu.
    func loadPolicies(since: Date?, database: any TidemarkDatabase) async {
        if let list = try? await database.distinctPolicies(since: since), !Task.isCancelled {
            policies = list.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    // MARK: Loading

    /// One of a load's two results.
    private enum Part: Sendable {
        case page(Result<RequestPage, any Error>)
        case histogram(Result<Histogram, any Error>)
    }

    /// Runs the page and the histogram of `query` side by side and applies each as it arrives, as long as
    /// this is still the latest load.
    private func fetch(_ query: RequestQuery, generation: Int, database: any TidemarkDatabase) async {
        let buckets = Self.histogramBuckets
        await withTaskGroup(of: Part.self) { group in
            group.addTask { .page(await Self.result { try await database.queryRequests(query) }) }
            group.addTask { .histogram(await Self.result { try await database.histogram(query, buckets: buckets) }) }
            for await part in group where generation == self.generation && !Task.isCancelled {
                apply(part)
                // A failed page stands for the whole query: its histogram is no longer wanted.
                if case .page(.failure) = part {
                    group.cancelAll()
                    break
                }
            }
        }
        // Cancelled with no newer load (the view went away): nothing is loading any more.
        if generation == self.generation {
            isLoading = false
            isLoadingHistogram = false
        }
    }

    private func apply(_ part: Part) {
        switch part {
        case .page(let result):
            isLoading = false
            switch result {
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
            isLoadingHistogram = false
            switch result {
            case .success(let value):
                histogram = value
                histogramFailure = nil
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
        a.scope == b.scope && a.range == b.range && a.interval == b.interval && a.appID == b.appID && a.policy == b.policy
            && a.status == b.status && a.search == b.search
    }
}
