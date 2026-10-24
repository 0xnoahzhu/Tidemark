import AppIntents
import Foundation

/// Opens the main window on a monitored app's page.
struct OpenMonitoredAppIntent: OpenIntent {
    static let title = LocalizedStringResource("Open Monitored App", table: "Intents")
    static let description: IntentDescription? = IntentDescription(
        LocalizedStringResource("Shows a monitored app's requests, domains and IPs in Tidemark.", table: "Intents")
    )
    static let supportedModes: IntentModes = .foreground(.immediate)
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(title: LocalizedStringResource("App", table: "Intents"))
    var target: MonitoredAppEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Open \(\.$target)", table: "Intents")
    }

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult {
        guard await TidemarkIntents.apps(model).contains(where: { $0.id == target.id }) else {
            throw TidemarkIntentError.appNotFound
        }
        model.nav.open(.app(target.id), tab: .requests)
        TidemarkIntents.showMainWindow()
        return .result()
    }
}
