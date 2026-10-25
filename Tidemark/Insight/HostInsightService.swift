import Foundation
import Observation
import os
import Synchronization

/// Failure surfaced to the UI when an insight cannot be produced.
struct HostInsightError: LocalizedError, Equatable {
    enum Kind: Equatable, Sendable {
        case unavailable
        case rateLimited
        case timedOut
        case busy
        case failed
    }

    var kind: Kind
    /// Localized message, resolved on the main actor when the error is created.
    var message: String

    var errorDescription: String? { message }
}

/// On-device host explanations (FoundationModels), cached in memory and in `host_insights` so every Mac
/// sharing the database reuses them.
///
/// Lookup order: memory → database → model. Model requests run one at a time; concurrent callers asking
/// for the same host share one request, which is cancelled (and leaves the queue) once every caller waiting
/// for it was cancelled.
@MainActor
@Observable
final class HostInsightService: HostInsightProviding {
    @ObservationIgnored private let database: any TidemarkDatabase
    @ObservationIgnored private let generator: any HostInsightGenerating
    @ObservationIgnored private var memory: [String: HostInsight] = [:]
    @ObservationIgnored private var inFlight: [String: HostInsightRequest] = [:]
    /// Completes when the most recently queued model request finishes.
    @ObservationIgnored private var queueTail: Task<Void, Never>?
    @ObservationIgnored private let log = Logger(subsystem: "io.tidemark.Tidemark", category: "insight")

    /// Set when a request reports missing model assets; cleared by `prewarm()` so the next inspector visit retries.
    private var assetsMissing = false

    convenience init(database: any TidemarkDatabase) {
        self.init(database: database, generator: OnDeviceHostInsightGenerator())
    }

    init(database: any TidemarkDatabase, generator: any HostInsightGenerating) {
        self.database = database
        self.generator = generator
    }

    // MARK: HostInsightProviding

    var availability: HostInsightAvailability {
        if assetsMissing { return .unavailable(.assetsUnavailable) }
        return generator.availability
    }

    var isAvailable: Bool { availability == .available }

    var unavailableReason: String? {
        guard case .unavailable(let reason) = availability else { return nil }
        return Self.message(for: reason)
    }

    func insight(for context: HostContext) async throws -> HostInsight {
        let host = Self.normalizedHost(context.host)
        let language = languageCode
        let key = Self.cacheKey(host: host, language: language)
        if let hit = memory[key] { return hit }
        // A request whose callers all gave up is being cancelled: start afresh instead of joining it.
        if let running = inFlight[key], running.join() { return try await running.value() }

        var facts = context
        facts.host = host
        let request = HostInsightRequest(Task { @MainActor [self] in
            try await self.resolve(facts, key: key, language: language)
        })
        inFlight[key] = request
        defer { if inFlight[key] === request { inFlight[key] = nil } }
        return try await request.value()
    }

    // MARK: Cache

    func cachedInsight(for host: String) async -> HostInsight? {
        let host = Self.normalizedHost(host)
        let language = languageCode
        let key = Self.cacheKey(host: host, language: language)
        if let hit = memory[key] { return hit }
        guard let stored = try? await database.hostInsight(host, language: language) else { return nil }
        memory[key] = stored
        return stored
    }

    func prewarm() {
        assetsMissing = false
        guard isAvailable else { return }
        generator.prewarm(languageCode: languageCode)
    }

    // MARK: Internals

    /// `zh-Hans` when the UI is Chinese and the model can answer in Chinese, otherwise `en`.
    var languageCode: String {
        Localizer.shared.isChinese && generator.supports(languageCode: "zh-Hans") ? "zh-Hans" : "en"
    }

    private func resolve(_ context: HostContext, key: String, language: String) async throws -> HostInsight {
        if let stored = try? await database.hostInsight(context.host, language: language) {
            memory[key] = stored
            return stored
        }
        guard isAvailable else {
            throw HostInsightError(kind: .unavailable, message: unavailableReason ?? Self.message(for: .other))
        }
        try Task.checkCancellation()
        let insight = try await serialized { [self] in
            try await self.generate(context, language: language)
        }
        memory[key] = insight
        do {
            try await database.saveHostInsight(insight)
        } catch {
            log.error("Saving the insight for \(context.host, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
        return insight
    }

    private func generate(_ context: HostContext, language: String) async throws -> HostInsight {
        do {
            let verdict = try await generator.verdict(for: context, languageCode: language)
            return verdict.insight(host: context.host, languageCode: language, model: generator.modelName)
        } catch {
            // Every caller gave up: end as cancelled, whatever the model reported.
            if Task.isCancelled { throw CancellationError() }
            let failure = HostInsightFailure(error)
            log.notice("Insight for \(context.host, privacy: .public) failed: \(String(describing: failure), privacy: .public)")
            switch failure {
            case .declined:
                return Self.declinedInsight(host: context.host, languageCode: language, model: generator.modelName)
            case .unsupportedLanguage where language != "en":
                return try await generate(context, language: "en")
            case .rateLimited:
                throw HostInsightError(kind: .rateLimited, message: tr("Apple Intelligence is busy right now. Try again in a moment.", "Insight"))
            case .assetsUnavailable:
                assetsMissing = true
                throw HostInsightError(kind: .unavailable, message: Self.message(for: .assetsUnavailable))
            case .timedOut:
                throw HostInsightError(kind: .timedOut, message: tr("The on-device model took too long. Try again.", "Insight"))
            case .busy:
                throw HostInsightError(kind: .busy, message: tr("Apple Intelligence is busy right now. Try again in a moment.", "Insight"))
            case .cancelled:
                throw CancellationError()
            case .unsupportedLanguage, .other:
                throw HostInsightError(kind: .failed, message: tr("Couldn't explain this host.", "Insight"))
            }
        }
    }

    /// Runs `work` after every previously queued request has finished (a session takes one request at a time).
    /// Cancelling the caller cancels `work`, or skips it while it is still queued, so an abandoned request
    /// never holds up the ones behind it.
    private func serialized<T: Sendable>(_ work: @escaping @MainActor @Sendable () async throws -> T) async throws -> T {
        let previous = queueTail
        let task = Task { @MainActor in
            await previous?.value
            try Task.checkCancellation()
            return try await work()
        }
        queueTail = Task { _ = await task.result }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Stored when the model declines to describe a host, so it is not asked again.
    static func declinedInsight(host: String, languageCode: String, model: String?, now: Date = .now) -> HostInsight {
        HostInsight(
            host: host,
            category: .unknown,
            operatorName: nil,
            summary: tr("No description is available for this host.", "Insight"),
            concern: nil,
            language: languageCode,
            model: model,
            createdAt: now
        )
    }

    static func message(for reason: HostInsightUnavailability) -> String {
        switch reason {
        case .deviceNotEligible: tr("This Mac doesn't support Apple Intelligence.", "Insight")
        case .appleIntelligenceOff: tr("Turn on Apple Intelligence in System Settings to explain hosts.", "Insight")
        case .modelNotReady: tr("The on-device model is still downloading.", "Insight")
        case .assetsUnavailable: tr("The on-device model isn't installed yet.", "Insight")
        case .other: tr("The on-device model is unavailable.", "Insight")
        }
    }

    nonisolated static func normalizedHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    nonisolated static func cacheKey(host: String, language: String) -> String { "\(language)|\(host)" }
}

/// A model request shared by every caller asking about the same host. It keeps going while at least one
/// caller still waits for it and is cancelled once every one of them was cancelled.
private final class HostInsightRequest: Sendable {
    private let task: Task<HostInsight, any Error>
    /// Callers waiting for the answer that were not cancelled (the one that started the request counts), and
    /// whether the last of them left: the request is then being cancelled and takes no new callers.
    private let state = Mutex((waiters: 1, closed: false))

    init(_ task: Task<HostInsight, any Error>) {
        self.task = task
    }

    /// Counts one more caller in before it awaits `value()`; `false` once every caller left, so that it
    /// starts a new request instead. One step under the lock, so nobody joins as the last caller leaves.
    func join() -> Bool {
        state.withLock { current in
            guard !current.closed else { return false }
            current.waiters += 1
            return true
        }
    }

    /// The answer, for the caller that started the request or one that joined it.
    func value() async throws -> HostInsight {
        try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            let last = state.withLock { current in
                current.waiters -= 1
                if current.waiters == 0 { current.closed = true }
                return current.closed
            }
            if last { task.cancel() }
        }
    }
}
