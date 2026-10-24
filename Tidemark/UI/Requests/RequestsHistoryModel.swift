import Foundation
import Observation

/// Results of the History view's current query: a page of rows, the histogram and the timing line.
@MainActor
@Observable
final class RequestsHistoryModel {
    /// Rows fetched per page ("Load More" appends the next page).
    static let pageSize = 500
    static let histogramBuckets = 48

    private(set) var rows: [RequestRecord] = []
    private(set) var totalCount: Int64 = 0
    private(set) var elapsed: Duration = .zero
    private(set) var histogram: Histogram?
    private(set) var policies: [String] = []
    private(set) var isLoading = false
    private(set) var isLoadingMore = false
    private(set) var errorMessage: String?
    /// The query the rows belong to (offset 0). Its `interval` is set while the chart is zoomed.
    private(set) var query = RequestQuery()

    var canLoadMore: Bool { Int64(rows.count) < totalCount && !isLoadingMore && errorMessage == nil }

    /// Runs `query` from the first page and refreshes the histogram.
    func load(_ query: RequestQuery, database: any TidemarkDatabase) async {
        var first = query
        first.limit = Self.pageSize
        first.offset = 0
        first.before = nil
        self.query = first
        isLoading = true
        defer { isLoading = false }
        let pageQuery = first
        let histogramQuery = first
        do {
            async let page = database.queryRequests(pageQuery)
            async let buckets = database.histogram(histogramQuery, buckets: Self.histogramBuckets)
            let (result, histogram) = try await (page, buckets)
            try Task.checkCancellation()
            rows = result.rows
            totalCount = result.totalCount
            elapsed = result.elapsed
            self.histogram = histogram
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            rows = []
            totalCount = 0
            histogram = nil
            errorMessage = error.localizedDescription
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
            if !Task.isCancelled { errorMessage = error.localizedDescription }
        }
    }

    /// Final policies seen in the selected range, for the policy filter menu.
    func loadPolicies(since: Date?, database: any TidemarkDatabase) async {
        if let list = try? await database.distinctPolicies(since: since), !Task.isCancelled {
            policies = list.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    private func sameFilter(_ a: RequestQuery, _ b: RequestQuery) -> Bool {
        a.scope == b.scope && a.range == b.range && a.interval == b.interval && a.appID == b.appID && a.policy == b.policy
            && a.status == b.status && a.search == b.search
    }
}
