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
    var page: Page = .requests {
        didSet {
            // Another app's page opens with nothing selected in its Domains & IPs tab: the last app's domain or IP is none
            // of its own, and would keep the tab from showing its last list at once (`AppDetailCache.Inventory.fits`).
            guard case .app(let id) = page, id != selectionAppID else { return }
            selectionAppID = id
            appSelectedHost = nil
            appSelectedIP = nil
        }
    }
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
    /// Host selected in the app's domain list; the IP list then lists only the IPs it resolved to, and the processes that
    /// reached it are listed under it.
    var appSelectedHost: String?
    /// IP selected in the app's IP list; lists the processes that reached it.
    var appSelectedIP: String?
    /// The app whose page the selected domain and IP belong to.
    @ObservationIgnored private var selectionAppID: AppID?
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

    /// Opens an app's Domains & IPs tab with one of its domains or IPs selected, which lists the processes that reached
    /// it: an alert's View.
    func open(_ app: AppID, selecting kind: HostKind, _ value: String) {
        open(.app(app), tab: .inventory)
        appSelectedHost = kind == .domain ? value : nil
        appSelectedIP = kind == .ip ? value : nil
    }

    func openAddApp(preselect path: String? = nil) {
        addAppPreselect = path
        showAddApp = true
    }
}
