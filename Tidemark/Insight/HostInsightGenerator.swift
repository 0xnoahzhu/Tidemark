import Foundation
import FoundationModels

/// Whether host insights can be generated on this Mac.
enum HostInsightAvailability: Equatable, Sendable {
    case available
    case unavailable(HostInsightUnavailability)
}

/// Why the on-device model cannot run.
enum HostInsightUnavailability: Equatable, Sendable {
    case deviceNotEligible
    case appleIntelligenceOff
    case modelNotReady
    /// The model assets are missing or were evicted (reported by a failed request).
    case assetsUnavailable
    case other
}

extension HostInsightAvailability {
    init(_ availability: SystemLanguageModel.Availability) {
        switch availability {
        case .available:
            self = .available
        case .unavailable(let reason):
            switch reason {
            case .deviceNotEligible: self = .unavailable(.deviceNotEligible)
            case .appleIntelligenceNotEnabled: self = .unavailable(.appleIntelligenceOff)
            case .modelNotReady: self = .unavailable(.modelNotReady)
            @unknown default: self = .unavailable(.other)
            }
        }
    }
}

/// Runs the language model for one host. `HostInsightService` talks to it through this protocol so
/// tests can substitute a scripted generator.
@MainActor
protocol HostInsightGenerating: AnyObject {
    var availability: HostInsightAvailability { get }
    /// Display name of the model, recorded in `HostInsight.model` (e.g. `AFM 3 Core`).
    var modelName: String { get }
    /// Whether the model can answer in `languageCode` (`en`, `zh-Hans`).
    func supports(languageCode: String) -> Bool
    /// Loads the model and processes the instructions ahead of the first request.
    func prewarm(languageCode: String)
    /// One model request. Callers serialize requests; implementations may assume one at a time.
    func verdict(for context: HostContext, languageCode: String) async throws -> HostInsightVerdict
}

/// `HostInsightGenerating` backed by Apple's on-device foundation model.
///
/// One session per language is kept warm and reused: after every request the transcript is trimmed
/// back to the instructions (macOS 27 transcripts are mutable), so each host is judged on its own
/// facts while the instructions stay cached.
@MainActor
final class OnDeviceHostInsightGenerator: HostInsightGenerating {
    private let model: SystemLanguageModel
    private var session: LanguageModelSession?
    private var sessionLanguage: String?
    /// Transcript entries that belong to the session itself (the instructions).
    private var baseEntryCount = 0

    init(model: SystemLanguageModel = .default) {
        self.model = model
    }

    var availability: HostInsightAvailability { HostInsightAvailability(model.availability) }

    var modelName: String { model.variant.displayName }

    func supports(languageCode: String) -> Bool {
        languageCode == "en" || model.supportsLocale(Locale(identifier: languageCode))
    }

    func prewarm(languageCode: String) {
        let session = session(for: languageCode)
        guard !session.isResponding else { return }
        session.prewarm()
    }

    func verdict(for context: HostContext, languageCode: String) async throws -> HostInsightVerdict {
        let session = session(for: languageCode)
        defer { resetTranscript(of: session) }
        let response = try await session.respond(
            to: HostInsightPrompt.facts(for: context),
            generating: HostInsightVerdict.self,
            options: HostInsightPrompt.options,
            contextOptions: ContextOptions(includeSchemaInPrompt: true)
        )
        return response.content
    }

    private func session(for languageCode: String) -> LanguageModelSession {
        if let session, sessionLanguage == languageCode { return session }
        let fresh = LanguageModelSession(model: model, instructions: HostInsightPrompt.instructions(languageCode: languageCode))
        fresh.transcriptErrorHandlingPolicy = .revertTranscript
        session = fresh
        sessionLanguage = languageCode
        baseEntryCount = fresh.transcript.count
        return fresh
    }

    /// Drops the prompt and response of the last request so the next host starts from the instructions.
    private func resetTranscript(of session: LanguageModelSession) {
        guard session === self.session, !session.isResponding else { return }
        let count = session.transcript.count
        if count > baseEntryCount {
            session.transcript.removeSubrange(baseEntryCount..<count)
        }
    }
}

/// What went wrong with a model request, reduced to what the service acts on.
enum HostInsightFailure: Equatable {
    /// Guardrail violation or refusal: stored as an `unknown` insight with a neutral summary.
    case declined
    case rateLimited(resetDate: Date?)
    case assetsUnavailable
    case unsupportedLanguage
    case timedOut
    /// The session was already responding (should not happen: requests are serialized).
    case busy
    case cancelled
    case other(String)

    init(_ error: any Error) {
        if error is CancellationError {
            self = .cancelled
        } else if let error = error as? LanguageModelError {
            switch error {
            case .guardrailViolation, .refusal: self = .declined
            case .rateLimited(let info): self = .rateLimited(resetDate: info.resetDate)
            case .unsupportedLanguageOrLocale: self = .unsupportedLanguage
            case .timeout: self = .timedOut
            case .contextSizeExceeded, .unsupportedCapability, .unsupportedTranscriptContent, .unsupportedGenerationGuide:
                self = .other(error.debugDescription)
            @unknown default: self = .other(error.debugDescription)
            }
        } else if let error = error as? SystemLanguageModel.Error {
            switch error {
            case .assetsUnavailable: self = .assetsUnavailable
            @unknown default: self = .other(error.debugDescription)
            }
        } else if let error = error as? LanguageModelSession.Error {
            switch error {
            case .concurrentRequests, .transcriptMutationWhileResponding: self = .busy
            @unknown default: self = .other(error.debugDescription)
            }
        } else {
            self = .other(String(describing: error))
        }
    }
}
