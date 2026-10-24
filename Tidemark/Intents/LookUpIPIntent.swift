import AppIntents
import Foundation

/// Country, ASN and organization of an IP address, from Surge's GeoIP data and the IP info service.
struct LookUpIPIntent: AppIntent {
    static let title = LocalizedStringResource("Look Up IP Address", table: "Intents")
    static let description: IntentDescription? = IntentDescription(
        LocalizedStringResource("Shows the country, network and organization of an IP address.", table: "Intents"),
        resultValueName: LocalizedStringResource("IP Details", table: "Intents")
    )
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(
        title: LocalizedStringResource("IP Address", table: "Intents"),
        requestValueDialog: IntentDialog(LocalizedStringResource("Which IP address?", table: "Intents"))
    )
    var ip: String

    static var parameterSummary: some ParameterSummary {
        Summary("Look up \(\.$ip)", table: "Intents")
    }

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<String> & ProvidesDialog {
        guard let address = IntentsText.normalizedIP(ip) else { throw TidemarkIntentError.invalidIP(ip) }
        let result = await model.egressActions.lookup(ip: address)
        let line = IntentsText.lookupLine(result)
        return .result(value: line, dialog: "\(line)")
    }
}
