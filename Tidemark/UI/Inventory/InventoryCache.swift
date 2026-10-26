import Foundation
import Observation

/// The Domains & IPs page's lists, kept by `AppModel` while the app runs: coming back to the page shows the last
/// list at once while the database is asked again in the background, and a search narrows the cached list as it is
/// typed.
@MainActor
@Observable
final class InventoryCache {
    /// What one list answers: a search (trimmed; empty for every entry) and the sidebar's Mac scope.
    struct Key: Hashable, Sendable {
        var search: String
        var scope: DeviceScope

        /// The unsearched list of the same scope, which a search narrows.
        var base: Key { Key(search: "", scope: scope) }
    }

    /// One list in the page's order (newest first seen first, then by name), with its domains and its IPs in the
    /// same order, so that switching between All, Domains and IPs only picks an array.
    struct Snapshot: Equatable {
        let all: [InventoryEntry]
        let domains: [InventoryEntry]
        let ips: [InventoryEntry]
        /// The database returned as many entries as it ever does (`queryLimit`), so older ones may be missing.
        let isTruncated: Bool

        init(sorted entries: [InventoryEntry], isTruncated: Bool) {
            all = entries
            domains = entries.filter { $0.kind == .domain }
            ips = entries.filter { $0.kind == .ip }
            self.isTruncated = isTruncated
        }

        static let empty = Snapshot(sorted: [], isTruncated: false)

        /// The entries of `kind`, all of them when nil.
        func entries(_ kind: HostKind?) -> [InventoryEntry] {
            switch kind {
            case nil: all
            case .domain: domains
            case .ip: ips
            }
        }

        var domainCount: Int { domains.count }

        static func == (a: Snapshot, b: Snapshot) -> Bool {
            a.isTruncated == b.isTruncated && a.all == b.all
        }
    }

    /// The most entries one `TidemarkDatabase.inventory` query returns (the `LIMIT` of `PostgresDatabase.inventory`).
    static let queryLimit = 2000
    /// Searches whose lists are kept besides the unsearched ones.
    static let keptSearches = 4

    /// A list fetched this recently is shown as it is when the page opens; an older one is fetched again at once.
    @ObservationIgnored var revalidateAfter: Duration = .seconds(5)
    /// How long the shown list waits after the database's last answer, or failure, before it is fetched again.
    @ObservationIgnored var refreshInterval: Duration = .seconds(30)
    /// The pause in typing after which a search is sent to the database.
    @ObservationIgnored var searchDelay: Duration = .milliseconds(300)

    private var snapshots: [Key: Snapshot] = [:]
    @ObservationIgnored private var fetchedAt: [Key: ContinuousClock.Instant] = [:]
    /// When the database last answered, or failed to, for each key.
    @ObservationIgnored private var attemptedAt: [Key: ContinuousClock.Instant] = [:]
    /// Searched keys, the most recently stored last.
    @ObservationIgnored private var searches: [Key] = []
    /// The key the page last showed: its list stays on screen while a new search or scope has none yet.
    @ObservationIgnored private var shown: Key?
    @ObservationIgnored private var groupCache: [GroupKey: [InventoryGroup]] = [:]

    private struct GroupKey: Hashable {
        var key: Key
        var kind: HostKind?
        var unknownNetwork: String
    }

    /// The list for `key`, or while it has none yet the list the page showed last; nil before anything was loaded.
    func snapshot(for key: Key) -> Snapshot? {
        snapshots[key] ?? shown.flatMap { snapshots[$0] }
    }

    /// Notes that the page shows `key` (once it has a list).
    func show(_ key: Key) {
        if snapshots[key] != nil { shown = key }
    }

    /// Time since the database last answered for `key`; nil when it never did.
    func age(of key: Key) -> Duration? {
        fetchedAt[key].map { ContinuousClock.now - $0 }
    }

    /// Stores what the database returned for `key`. The list is replaced only when it changed, so an unchanged
    /// answer redraws nothing.
    func store(_ fetched: [InventoryEntry], for key: Key) {
        fetchedAt[key] = .now
        attemptedAt[key] = .now
        assign(Snapshot(sorted: InventoryPresentation.visible(fetched, kind: nil), isTruncated: fetched.count >= Self.queryLimit), to: key)
    }

    /// A query that failed leaves a key without a list with an empty one, so the page stops waiting for it.
    func storeFailure(for key: Key) {
        attemptedAt[key] = .now
        if snapshots[key] == nil { assign(.empty, to: key) }
    }

    /// Whether the cached unsearched list holds every entry of the scope, so narrowing it answers `key`'s search
    /// exactly and the database need not be asked.
    func answersLocally(_ key: Key) -> Bool {
        guard !key.search.isEmpty, let base = snapshots[key.base] else { return false }
        return !base.isTruncated
    }

    /// Narrows the cached unsearched list to `key`'s search as the database does: the domains and IPs that contain
    /// the text and those an app or probe whose name contains it reached. A key that has a list keeps it unless
    /// `replacing` (the database's own answer is the better one when the cached list is incomplete).
    func filterLocally(_ key: Key, replacing: Bool) {
        guard !key.search.isEmpty, replacing || snapshots[key] == nil, let base = snapshots[key.base] else { return }
        let term = key.search.lowercased()
        let matches = base.all.filter { entry in
            entry.value.lowercased().contains(term) || entry.sources.contains { $0.title.lowercased().contains(term) }
        }
        // Entries the cached list lacks may still match: no "nothing matches" before the database has answered.
        if matches.isEmpty, base.isTruncated, !replacing { return }
        assign(Snapshot(sorted: matches, isTruncated: base.isTruncated), to: key)
    }

    // MARK: Loading

    /// Keeps `key`'s list current while the page shows it, until the task is cancelled: a list fetched within
    /// `revalidateAfter` is shown as it is, an older one is fetched again at once, and the shown list is fetched
    /// again `refreshInterval` after each answer or failure. A search narrows the cached list at once and goes to
    /// the database once the typing pauses, unless the cached list answers it, which is then the list refreshed.
    func keepCurrent(_ key: Key, fetch: (Key) async throws -> [InventoryEntry]) async {
        if !key.search.isEmpty {
            // Narrow the cached list at once; the database's answer, when one is needed, waits for the typing to stop.
            filterLocally(key, replacing: false)
            show(key)
            if snapshot(for: key) != nil {
                try? await Task.sleep(for: searchDelay)
                if Task.isCancelled { return }
            }
        }
        // A search the complete unsearched list answers refreshes that list instead of running a query of its own.
        var source = answersLocally(key) ? key.base : key
        if let age = age(of: source), age < revalidateAfter {
            show(key)
        } else {
            await refresh(source, for: key, fetch: fetch)
        }
        while !Task.isCancelled {
            // Counted from the last attempt, not the last answer: a failing database is asked again only as often.
            let waited = attemptedAt[source].map { ContinuousClock.now - $0 } ?? .zero
            try? await Task.sleep(for: refreshInterval - min(waited, refreshInterval))
            if Task.isCancelled { return }
            source = answersLocally(key) ? key.base : key
            await refresh(source, for: key, fetch: fetch)
        }
    }

    /// Fetches `source`'s list for the page showing `key` (the same key, or the unsearched list that answers it).
    private func refresh(_ source: Key, for key: Key, fetch: (Key) async throws -> [InventoryEntry]) async {
        do {
            let fresh = try await fetch(source)
            if Task.isCancelled { return }
            store(fresh, for: source)
        } catch {
            if Task.isCancelled { return }
            storeFailure(for: source)
        }
        if source != key { filterLocally(key, replacing: true) }
        show(key)
    }

    /// The site (domains) and network (IPs) groups of the entries of `kind` shown for `key`, computed once per list.
    func groups(for key: Key, kind: HostKind?, unknownNetwork: String, site: (String) -> String) -> [InventoryGroup] {
        let listed = snapshots[key] != nil ? key : (shown ?? key)
        guard let snapshot = snapshots[listed] else { return [] }
        let groupKey = GroupKey(key: listed, kind: kind, unknownNetwork: unknownNetwork)
        if let groups = groupCache[groupKey] { return groups }
        let groups = InventoryGroup.make(snapshot.entries(kind), site: site, unknownNetwork: unknownNetwork)
        groupCache[groupKey] = groups
        return groups
    }

    private func assign(_ snapshot: Snapshot, to key: Key) {
        guard snapshots[key] != snapshot else { return }
        snapshots[key] = snapshot
        groupCache = groupCache.filter { $0.key.key != key }
        guard !key.search.isEmpty else { return }
        searches.removeAll { $0 == key }
        searches.append(key)
        for dropped in searches.dropLast(Self.keptSearches) where dropped != shown {
            searches.removeAll { $0 == dropped }
            snapshots[dropped] = nil
            fetchedAt[dropped] = nil
            attemptedAt[dropped] = nil
            groupCache = groupCache.filter { $0.key.key != dropped }
        }
    }
}
