import Foundation
import Observation

/// Recent alerts and muted host patterns.
@MainActor
@Observable
final class AlertState {
    /// Newest first, from every Mac whatever the sidebar's Mac menu shows.
    var items: [AlertItem] = []
    var unreadCount: Int = 0
    /// Host, IP or `*.example.com` patterns. Muted hosts are still recorded but never alert.
    var mutes: [String] = []

    /// `true` if `value` matches a mute pattern exactly or by `*.` suffix.
    func isMuted(_ value: String) -> Bool { Self.matches(value, patterns: mutes) }

    /// `true` if `value` is muted by a wildcard rule rather than an exact entry.
    func isMutedByRule(_ value: String) -> Bool {
        !mutes.contains(value) && isMuted(value)
    }

    nonisolated static func matches(_ value: String, patterns: [String]) -> Bool {
        let v = value.lowercased()
        return patterns.contains { raw in
            let p = raw.lowercased()
            if p == v { return true }
            if p.hasPrefix("*.") {
                let base = String(p.dropFirst(2))
                return v == base || v.hasSuffix("." + base)
            }
            return false
        }
    }
}
