import Foundation
import Observation

/// Recent alerts.
@MainActor
@Observable
final class AlertState {
    /// Newest first, from every Mac whatever the sidebar's Mac menu shows.
    var items: [AlertItem] = []
    var unreadCount: Int = 0
}
