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
    var appSelectedHost: String? {
        didSet { appArrival = nil }
    }
    /// IP selected in the app's IP list; lists the processes that reached it.
    var appSelectedIP: String? {
        didSet { appArrival = nil }
    }
    /// The app whose page the selected domain and IP belong to.
    @ObservationIgnored private var selectionAppID: AppID?
    var appIPFilter: IPFilter = .all
    /// The domain or IP an alert's View selected in the app's Domains & IPs tab, until the tab has brought its row into
    /// view or another domain or IP is selected.
    var appArrival: HostArrival?
    @ObservationIgnored private var arrivals = 0

    enum IPFilter: String, CaseIterable, Sendable { case all, direct, resolved }

    /// A domain or IP of an app that an alert's View opens the app's Domains & IPs tab on.
    struct HostArrival: Equatable, Sendable {
        var appID: AppID
        var kind: HostKind
        var value: String
        /// Counts the arrivals, so a second View of the same alert brings its row into view again.
        var serial: Int
    }

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
    /// it: an alert's View. Nothing the tab filters by hides it (its search, the Direct / From domains switch; a domain
    /// lists its own IPs), and the tab scrolls its row into view once it lists it (`appArrival`).
    func open(_ app: AppID, selecting kind: HostKind, _ value: String) {
        open(.app(app), tab: .inventory)
        appInventorySearch = ""
        appIPFilter = .all
        appSelectedHost = kind == .domain ? value : nil
        appSelectedIP = kind == .ip ? value : nil
        arrivals += 1
        appArrival = HostArrival(appID: app, kind: kind, value: value, serial: arrivals)
    }

    func openAddApp(preselect path: String? = nil) {
        addAppPreselect = path
        showAddApp = true
    }
}
