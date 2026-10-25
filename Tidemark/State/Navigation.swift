import Foundation
import Observation

/// Main window pages (sidebar destinations).
enum Page: Hashable, Sendable {
    case requests
    case notifications
    case inventory
    case probe
    case egress
    case app(AppID)
}

/// Tabs of a monitored app's page.
enum AppTab: String, Hashable, Sendable, CaseIterable {
    case requests
    case inventory
    case tree
}

/// Settings window tabs.
enum SettingsTab: String, Hashable, Sendable, CaseIterable {
    case general
    case surge
    case database
}

/// UI navigation and transient presentation state.
@MainActor
@Observable
final class Navigation {
    var page: Page = .requests
    var appTab: AppTab = .requests

    // Requests page
    var requestsLive = true
    var requestSearch = ""
    var selectedRequest: RequestKey?
    var history = RequestQuery()

    // Notifications page
    var alertFilter: AlertFilter = .all

    // Global inventory page
    var inventoryKind: HostKind?
    var inventorySearch = ""
    var inventoryGrouped = false

    // App page
    var appRequestsLive = true
    var appRequestSearch = ""
    var appInventorySearch = ""
    var appDomainsBySite = true
    /// Host selected in the app's domain list; highlights the IPs it resolved to.
    var appSelectedHost: String?
    var appIPFilter: IPFilter = .all

    enum IPFilter: String, CaseIterable, Sendable { case all, direct, resolved }

    // Sheets and dialogs
    var showAddApp = false
    /// Bundle path to preselect in the "Monitor an App" sheet.
    var addAppPreselect: String?
    var confirmRecordingToggle = false
    var confirmDeleteApp: AppID?
    var confirmMonitoringToggle: AppID?

    var settingsTab: SettingsTab = .general

    func open(_ page: Page, tab: AppTab? = nil) {
        self.page = page
        if let tab { appTab = tab }
    }

    func openAddApp(preselect path: String? = nil) {
        addAppPreselect = path
        showAddApp = true
    }
}
