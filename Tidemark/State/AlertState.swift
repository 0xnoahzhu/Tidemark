import Foundation
import Observation

/// Recent alerts.
@MainActor
@Observable
final class AlertState {
    /// Newest first, from every Mac whatever the sidebar's Mac menu shows.
    var items: [AlertItem] = []
    var unreadCount: Int = 0

    /// The first of `ids` that is listed: the alert a notification about them names first.
    func first(of ids: [Int64]) -> AlertItem? {
        ids.lazy.compactMap { id in self.items.first { $0.id == id } }.first
    }

    /// Returns `first(of: ids)` once one of them is listed, or nil when the task is cancelled first.
    func listed(_ ids: [Int64]) async -> AlertItem? {
        for await alert in Observations({ self.first(of: ids) }) {
            if let alert { return alert }
        }
        return nil
    }
}
