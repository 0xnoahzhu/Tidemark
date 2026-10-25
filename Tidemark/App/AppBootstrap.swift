import AppKit
import SwiftUI

/// Composition root: builds the concrete services and starts capture.
@MainActor
enum AppBootstrap {
    private static var engine: CaptureEngine?
    private static var egress: EgressMonitor?
    private static var probe: ProbeController?

    static func start(_ model: AppModel) {
        Localizer.shared.preference = model.preferences.language
        applyAppearance(model.preferences.appearance)
        applyActivationPolicy(model.preferences.showIn)

        let classifier = PublicSuffixClassifier()
        let processes = LibProcInspector()
        let surge = SurgeCLIClient(endpoint: model.preferences.surgeEndpoint)
        let databaseURL = model.preferences.databaseURLWithPassword
        let database = PostgresDatabase(url: databaseURL, siteClassifier: classifier)
        model.classifier = classifier
        model.processes = processes
        model.surge = surge
        model.database = database
        model.insights = HostInsightService(database: database)

        let engine = CaptureEngine(model: model, surge: surge, database: database, processes: processes, classifier: classifier)
        engine.adoptDatabaseURL(databaseURL)
        // Rebuilt when the endpoint or a password changes (`reconnect()`), and for testing new settings.
        engine.makeSurgeClient = { endpoint in SurgeCLIClient(endpoint: endpoint) }
        engine.makeDatabase = { url in PostgresDatabase(url: url, siteClassifier: classifier) }
        // On-device host explanations are cached in the database the engine records into.
        engine.databaseChanged = { [weak model] database in model?.insights = HostInsightService(database: database) }
        engine.retireDatabase = { database in await (database as? PostgresDatabase)?.shutdown() }
        let egress = EgressMonitor(model: model)
        engine.egress = egress
        let probe = ProbeController(model: model, registry: engine.probeRegistry)
        model.capture = engine
        model.egressActions = egress
        model.probeActions = probe
        self.engine = engine
        self.egress = egress
        self.probe = probe

        StatusItemController.install(model: model)
        DockIconUpdater.start(model: model)

        engine.start()
        egress.start()
        #if DEBUG
        DebugTour.runIfRequested(model)
        #endif
    }

    /// Stops a running probe and the egress checks, and flushes buffered rows to PostgreSQL (or the on-disk
    /// spool). The probe is saved right away (no tail, no grace) while capture flushes, so a slow probe save
    /// cannot use up the time the final flush needs. Returns after `timeout` at the latest, whatever is still
    /// running, so quitting never hangs on an unreachable server. Then every surge-cli child still running is
    /// stopped (a second more at most, for one that ignores SIGTERM), so none outlives Tidemark.
    static func stop(_ model: AppModel, timeout: Duration = .seconds(6)) async {
        StatusItemController.uninstall()
        DockIconUpdater.stop()
        await shutDown(probe: probe, egress: egress, engine: engine, timeout: timeout)
        // Lookups nobody cancelled may still be running, and a child that ignored SIGTERM would get its SIGKILL
        // only after Tidemark exited.
        await SurgeChildProcess.terminateAll()
    }

    /// The shutdown work, raced against `timeout` (`CaptureTimeout` returns at the deadline without waiting for
    /// the work, which awaiting a task's value would).
    static func shutDown(probe: ProbeController?, egress: EgressMonitor?, engine: CaptureEngine?, timeout: Duration) async {
        let shutdown = Task(name: "shutdown") { @MainActor in
            egress?.stop()
            let probeStopped = Task { @MainActor in _ = await probe?.stopProbe(quitting: true) }
            await engine?.stop()
            await probeStopped.value
        }
        _ = await CaptureTimeout.value(within: timeout) { () async -> Bool? in
            await shutdown.value
            return true
        }
    }

    static func applyAppearance(_ appearance: Preferences.Appearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func applyActivationPolicy(_ showIn: Preferences.ShowIn) {
        NSApp.setActivationPolicy(showIn == .menuBarAndDock ? .regular : .accessory)
    }
}
