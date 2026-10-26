import Foundation
import Observation

/// Root of Tidemark's observable state and service graph, injected into SwiftUI with `.environment(model)`.
@MainActor
@Observable
final class AppModel {
    let preferences: Preferences
    let live: LiveState
    let catalog: CatalogState
    let alerts: AlertState
    let devices: DeviceState
    let egress: EgressState
    let probe: ProbeState
    let nav: Navigation
    /// The Domains & IPs page's lists, kept between visits.
    let inventory: InventoryCache
    /// The Requests page's History results, kept while the page is not shown.
    let requestsHistory = RequestsHistoryModel()

    // Services. Replaced by the real implementations in `AppBootstrap`.
    @ObservationIgnored var database: any TidemarkDatabase {
        // History results read from the previous database are not shown again.
        didSet { requestsHistory.databaseChanged() }
    }
    @ObservationIgnored var surge: any SurgeClient
    @ObservationIgnored var classifier: any SiteClassifying
    /// Live process table of this Mac (Running / Exited in process trees).
    @ObservationIgnored var processes: any ProcessInspecting
    @ObservationIgnored var capture: any CaptureActions
    @ObservationIgnored var probeActions: any ProbeActions
    @ObservationIgnored var egressActions: any EgressActions

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        live = LiveState()
        catalog = CatalogState()
        alerts = AlertState()
        devices = DeviceState(thisDeviceID: preferences.thisDeviceID)
        egress = EgressState()
        probe = ProbeState()
        nav = Navigation()
        inventory = InventoryCache()
        database = OfflineDatabase()
        surge = UnavailableSurgeClient(endpoint: preferences.surgeEndpoint)
        classifier = NaiveSiteClassifier()
        processes = NoProcessInspector()
        capture = NoopCaptureActions()
        probeActions = NoopProbeActions()
        egressActions = NoopEgressActions()
    }

    /// Name and tile for a request's app column: the monitored app, else the top-most bundle, else the process.
    func appIdentity(for record: RequestRecord) -> AppIdentity {
        if let app = catalog.app(record.appID) {
            return AppIdentity(name: app.name, bundlePath: app.path, letter: app.tileLetter, hue: app.tileHue, isMonitored: catalog.isMonitoring(app.id), appID: app.id)
        }
        if let bundle = record.bundlePath, !bundle.isEmpty {
            let name = AppNaming.displayName(forBundlePath: bundle)
            return AppIdentity(name: name, bundlePath: bundle, letter: String(name.prefix(1)), hue: nil, isMonitored: false, appID: nil)
        }
        let name = record.chain.first?.name ?? record.processName
        return AppIdentity(name: name, bundlePath: nil, letter: String(name.prefix(1)), hue: nil, isMonitored: false, appID: nil)
    }
}

/// How an app (or an unmonitored process) is presented in tables.
struct AppIdentity: Hashable, Sendable {
    var name: String
    var bundlePath: String?
    var letter: String
    /// Tile hue for monitored apps; nil renders a neutral grey tile.
    var hue: Double?
    var isMonitored: Bool
    var appID: AppID?
}
