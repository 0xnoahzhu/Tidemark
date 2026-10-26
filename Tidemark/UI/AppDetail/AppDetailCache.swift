import Foundation

/// What the app pages' Domains & IPs and Process Tree tabs showed last, per app and scope. The main window keeps
/// it, so a tab shows its last list right after its first frame and refreshes it in the background, rather than
/// staying empty while it waits for the database. It is not observable: each tab keeps its own state and only
/// starts from here.
@MainActor
final class AppDetailCache {
    struct Key: Hashable {
        var appID: AppID
        var scope: DeviceScope
    }

    /// A Domains & IPs tab's hosts and their summary.
    struct Inventory {
        var hosts: [AppHost]
        var summary: AppDetailInventorySummary
    }

    private var inventories: Recent<Inventory>
    private var trees: Recent<[ProcessNode]>

    /// - Parameter limit: How many apps' (and scopes') lists of each kind are kept; the least recently used go first.
    init(limit: Int = 8) {
        inventories = Recent(limit: limit)
        trees = Recent(limit: limit)
    }

    func inventory(_ key: Key) -> Inventory? { inventories[key] }

    func setInventory(_ inventory: Inventory, for key: Key) { inventories[key] = inventory }

    func tree(_ key: Key) -> [ProcessNode]? { trees[key] }

    func setTree(_ nodes: [ProcessNode], for key: Key) { trees[key] = nodes }

    /// A dictionary that keeps only the `limit` most recently read or written values.
    private struct Recent<Value> {
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
