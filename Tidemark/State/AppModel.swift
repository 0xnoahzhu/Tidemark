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

    // Services. Replaced by the real implementations in `AppBootstrap`.
    @ObservationIgnored var database: any TidemarkDatabase
    @ObservationIgnored var surge: any SurgeClient
    @ObservationIgnored var classifier: any SiteClassifying
    @ObservationIgnored var capture: any CaptureActions
    @ObservationIgnored var probeActions: any ProbeActions
    @ObservationIgnored var egressActions: any EgressActions
    @ObservationIgnored var insights: any HostInsightProviding

    init(preferences: Preferences = Preferences()) {
        self.preferences = preferences
        live = LiveState()
        catalog = CatalogState()
        alerts = AlertState()
        devices = DeviceState(thisDeviceID: preferences.thisDeviceID)
        egress = EgressState()
        probe = ProbeState()
        nav = Navigation()
        database = OfflineDatabase()
        surge = UnavailableSurgeClient(endpoint: preferences.surgeEndpoint)
        classifier = NaiveSiteClassifier()
        capture = NoopCaptureActions()
        probeActions = NoopProbeActions()
        egressActions = NoopEgressActions()
        insights = UnavailableHostInsights()
    }

    /// Name and tile for a request's app column: the monitored app, else the top-most bundle, else the process.
    func appIdentity(for record: RequestRecord) -> AppIdentity {
        if let app = catalog.app(record.appID) {
            return AppIdentity(name: app.name, bundlePath: app.path, letter: app.tileLetter, hue: app.tileHue, isMonitored: catalog.isMonitoring(app.id), appID: app.id)
        }
        if let bundle = record.bundlePath, !bundle.isEmpty {
            let name = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent
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
