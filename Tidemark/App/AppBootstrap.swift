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
        let database = PostgresDatabase(url: model.preferences.databaseURLWithPassword, siteClassifier: classifier)
        model.classifier = classifier
        model.processes = processes
        model.surge = surge
        model.database = database
        model.insights = HostInsightService(database: database)

        let engine = CaptureEngine(model: model, surge: surge, database: database, processes: processes, classifier: classifier)
        engine.makeSurgeClient = { endpoint in SurgeCLIClient(endpoint: endpoint) }
        engine.makeDatabase = { [weak model] preferences in
            let database = PostgresDatabase(url: preferences.databaseURLWithPassword, siteClassifier: classifier)
            model?.insights = HostInsightService(database: database)
            return database
        }
        let egress = EgressMonitor(model: model)
        engine.egress = egress
        let probe = ProbeController(model: model, registry: engine.probeRegistry)
        model.capture = engine
        model.egressActions = egress
        model.probeActions = probe
        self.engine = engine
        self.egress = egress
        self.probe = probe

        TidemarkIntents.register(model: model)
        StatusItemController.install(model: model)
        DockIconUpdater.start(model: model)

        engine.start()
        egress.start()
    }

    /// Stops a running probe and the egress checks, then flushes buffered rows to PostgreSQL (or the
    /// on-disk spool). Gives up after `timeout` so quitting never hangs on an unreachable server.
    static func stop(_ model: AppModel, timeout: Duration = .seconds(6)) async {
        StatusItemController.uninstall()
        DockIconUpdater.stop()
        let probe = self.probe, egress = self.egress, engine = self.engine
        let shutdown = Task(name: "shutdown") { @MainActor in
            _ = await probe?.stopProbe()
            egress?.stop()
            await engine?.stop()
        }
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await shutdown.value }
            group.addTask { try? await Task.sleep(for: timeout) }
            await group.next()
            group.cancelAll()
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
