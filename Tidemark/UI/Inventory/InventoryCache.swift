import Foundation
import Observation

/// The Domains & IPs page's lists, kept by `AppModel` while the app runs: coming back to the page shows the last
/// list at once while the database is asked again in the background.
@MainActor
@Observable
final class InventoryCache {
    /// What one list answers: a search (trimmed; empty for every entry) and the sidebar's Mac scope.
    struct Key: Hashable, Sendable {
        var search: String
        var scope: DeviceScope
    }

    /// One list in the page's order (newest first seen first, then by name), with its domains and its IPs in the
    /// same order, so that switching between All, Domains and IPs only picks an array.
    struct Snapshot: Equatable {
        let all: [InventoryEntry]
        let domains: [InventoryEntry]
        let ips: [InventoryEntry]

        init(sorted entries: [InventoryEntry]) {
            all = entries
            domains = entries.filter { $0.kind == .domain }
            ips = entries.filter { $0.kind == .ip }
        }

        static let empty = Snapshot(sorted: [])

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
            a.all == b.all
        }
    }

    /// Searches whose lists are kept besides the unsearched ones.
    static let keptSearches = 4

    private var snapshots: [Key: Snapshot] = [:]
    @ObservationIgnored private var fetchedAt: [Key: ContinuousClock.Instant] = [:]
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
        assign(Snapshot(sorted: InventoryPresentation.visible(fetched, kind: nil)), to: key)
    }

    /// A query that failed leaves a key without a list with an empty one, so the page stops waiting for it.
    func storeFailure(for key: Key) {
        if snapshots[key] == nil { assign(.empty, to: key) }
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
            groupCache = groupCache.filter { $0.key.key != dropped }
        }
    }
}
