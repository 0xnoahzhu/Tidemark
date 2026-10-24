import Foundation
import Observation

/// Monitored apps and their counters.
@MainActor
@Observable
final class CatalogState {
    /// Every app in the database, archived ones included.
    var apps: [MonitoredApp] = []
    /// Per-app counters for the current device scope.
    var stats: [AppID: AppStats] = [:]
    /// appID → deviceID → installed (path exists on that Mac).
    var installs: [AppID: [DeviceID: Bool]] = [:]
    /// Apps whose monitoring is paused for this session ("Stop monitoring").
    var paused: Set<AppID> = []

    var active: [MonitoredApp] { apps.filter { !$0.isArchived }.sorted { $0.createdAt < $1.createdAt } }
    var archived: [MonitoredApp] { apps.filter(\.isArchived).sorted { $0.name < $1.name } }

    func app(_ id: AppID?) -> MonitoredApp? {
        guard let id else { return nil }
        return apps.first { $0.id == id }
    }

    func isMonitoring(_ id: AppID) -> Bool {
        guard let app = app(id) else { return false }
        return !app.isArchived && !paused.contains(id)
    }

    /// `nil` = unknown (no report from that Mac yet).
    func isInstalled(_ appID: AppID, on device: DeviceID) -> Bool? {
        installs[appID]?[device]
    }

    /// Finds the monitored app a process path belongs to.
    func app(containing processPath: String) -> MonitoredApp? {
        active.first { $0.contains(processPath: processPath) }
    }
}
