import Foundation

/// What the app pages' Domains & IPs and Process Tree tabs showed last, per app and scope, and the processes the
/// Domains & IPs tab listed for each domain or IP it opened. `AppModel` keeps it
/// (and empties it when the database changes), so a tab shows its last list right after its first frame and
/// refreshes it in the background, rather than staying empty while it waits for the database. It is not
/// observable: each tab keeps its own state and only starts from here.
@MainActor
final class AppDetailCache {
    struct Key: Hashable {
        var appID: AppID
        var scope: DeviceScope
    }

    /// A domain or IP of an app, for a scope.
    struct HostKey: Hashable {
        var appID: AppID
        var scope: DeviceScope
        var kind: HostKind
        var value: String
    }

    /// A Domains & IPs tab's hosts and their summary.
    struct Inventory {
        var hosts: [AppHost]
        var summary: AppDetailInventorySummary

        /// Whether a tab searching for `search`, with `selectedHost` and `selectedIP` selected, can show this list
        /// before it reads the database: the summary was made for that search and has the selected domain and IP. One
        /// selected since (a notification's View opens the app on a domain or IP that is new) isn't in it, so the tab
        /// waits for the database rather than show the list without it and then reorder it.
        func fits(search: String, selectedHost: String?, selectedIP: String? = nil) -> Bool {
            summary.search == search && (selectedHost == nil || summary.selectedHost(selectedHost) != nil)
                && (selectedIP == nil || summary.selectedIP(selectedIP) != nil)
        }
    }

    private var inventories: Recent<Key, Inventory>
    private var trees: Recent<Key, [ProcessNode]>
    private var processes: Recent<HostKey, [HostProcess]>

    /// - Parameters:
    ///   - limit: How many apps' (and scopes') lists of each kind are kept; the least recently used go first.
    ///   - hostLimit: How many domains' and IPs' process lists are kept.
    init(limit: Int = 8, hostLimit: Int = 64) {
        inventories = Recent(limit: limit)
        trees = Recent(limit: limit)
        processes = Recent(limit: hostLimit)
    }

    func inventory(_ key: Key) -> Inventory? { inventories[key] }

    func setInventory(_ inventory: Inventory, for key: Key) { inventories[key] = inventory }

    func tree(_ key: Key) -> [ProcessNode]? { trees[key] }

    func setTree(_ nodes: [ProcessNode], for key: Key) { trees[key] = nodes }

    func processes(_ key: HostKey) -> [HostProcess]? { processes[key] }

    func setProcesses(_ list: [HostProcess], for key: HostKey) { processes[key] = list }

    /// Forgets every list, e.g. when they came from a database Tidemark no longer reads.
    func removeAll() {
        inventories = Recent(limit: inventories.limit)
        trees = Recent(limit: trees.limit)
        processes = Recent(limit: processes.limit)
    }

    /// A dictionary that keeps only the `limit` most recently read or written values.
    private struct Recent<Key: Hashable, Value> {
        let limit: Int
        private var values: [Key: Value] = [:]
        /// Least recently used first.
        private var order: [Key] = []

        init(limit: Int) {
            self.limit = max(1, limit)
        }

        subscript(key: Key) -> Value? {
            mutating get {
                guard let value = values[key] else { return nil }
                touch(key)
                return value
            }
            set {
                values[key] = newValue
                if newValue == nil {
                    order.removeAll { $0 == key }
                    return
                }
                touch(key)
                while order.count > limit { values[order.removeFirst()] = nil }
            }
        }

        private mutating func touch(_ key: Key) {
            if order.last == key { return }
            order.removeAll { $0 == key }
            order.append(key)
        }
    }
}
