import Foundation
import Observation

/// Egress IP page state, written by the egress monitor.
@MainActor
@Observable
final class EgressState {
    /// One sample per policy, the current one flagged.
    var samples: [EgressSample] = []
    var changes: [EgressChange] = []
    var lastChecked: Date?
    var isChecking = false
    var network: ThisMacNetwork?
    /// Surge outbound mode: 0 direct, 1 global proxy, 2 rule (from `environment`).
    var proxyMode: Int?
    /// Rule that routes the current egress, e.g. `FINAL` (rule mode) or `Global · AI`.
    var currentRule: String?

    var current: EgressSample? { samples.first(where: \.isCurrent) }
}

/// Live site-probe state, written by the probe controller.
@MainActor
@Observable
final class ProbeState {
    enum Phase: Equatable, Sendable {
        case idle
        /// Waiting for the first page load to finish.
        case loading
        /// Page loaded; still recording late requests and clicks.
        case recording
    }

    var phase: Phase = .idle
    /// The running session (steps and hosts grow while it runs).
    var running: ProbeSession?
    /// Loopback port of the per-session proxy while a probe runs.
    var proxyPort: UInt16?
    /// Saved sessions, newest first.
    var sessions: [ProbeSession] = []
    /// Session shown in the detail pane when nothing is running.
    var selectedID: UUID?

    var isRunning: Bool { running != nil }
    var selected: ProbeSession? {
        if let running { return running }
        return sessions.first { $0.id == selectedID }
    }
}
