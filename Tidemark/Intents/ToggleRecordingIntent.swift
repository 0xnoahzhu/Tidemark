import AppIntents
import Foundation

/// Pauses or resumes recording. Without a value it flips the current state.
struct ToggleRecordingIntent: AppIntent {
    static let title = LocalizedStringResource("Pause or Resume Recording", table: "Intents")
    static let description: IntentDescription? = IntentDescription(
        LocalizedStringResource("Turns Tidemark's recording on or off. Leave Recording empty to switch it.", table: "Intents"),
        resultValueName: LocalizedStringResource("Recording", table: "Intents")
    )
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Parameter(
        title: LocalizedStringResource("Recording", table: "Intents"),
        displayName: Bool.IntentDisplayName(
            true: LocalizedStringResource("On", table: "Intents"),
            false: LocalizedStringResource("Off", table: "Intents")
        )
    )
    var recording: Bool?

    static var parameterSummary: some ParameterSummary {
        Summary("Turn recording \(\.$recording)", table: "Intents")
    }

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Bool> & ProvidesDialog {
        let target = recording ?? !model.live.recording
        model.capture.setRecording(target)
        return .result(value: target, dialog: "\(IntentsText.recordingDialog(isOn: target))")
    }
}
