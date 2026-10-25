import Foundation
import FoundationModels
import Testing
@testable import Tidemark

@MainActor
struct InsightVerdictTests {
    @Test func mapsVerdictToInsight() {
        let verdict = HostInsightVerdict(
            operatorName: "  GitHub ",
            summary: "Serves GitHub's REST API v3.0 for repository data. Cursor uses it to clone and sync. It also does more.",
            category: "API",
            concern: "none"
        )
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let insight = verdict.insight(host: "api.github.com", languageCode: "en", model: "AFM 3 Core", now: date)
        #expect(insight.host == "api.github.com")
        #expect(insight.category == .api)
        #expect(insight.operatorName == "GitHub")
        #expect(insight.summary == "Serves GitHub's REST API v3.0 for repository data. Cursor uses it to clone and sync.")
        #expect(insight.concern == nil)
        #expect(insight.language == "en")
        #expect(insight.model == "AFM 3 Core")
        #expect(insight.createdAt == date)
    }

    @Test func keepsConcernAndChineseSentences() {
        let verdict = HostInsightVerdict(
            operatorName: "腾讯",
            summary: "这是微信的统计接口。用于上报使用数据。第三句会被去掉。",
            category: "analytics",
            concern: "会上报使用情况。"
        )
        let insight = verdict.insight(host: "report.weixin.qq.com", languageCode: "zh-Hans", model: nil)
        #expect(insight.category == .analytics)
        #expect(insight.summary == "这是微信的统计接口。用于上报使用数据。")
        #expect(insight.concern == "会上报使用情况。")
        #expect(insight.language == "zh-Hans")
    }

    @Test(arguments: HostCategory.allCases)
    func acceptsEveryCategoryRawValue(_ category: HostCategory) {
        #expect(HostInsightVerdict.category(from: category.rawValue) == category)
        #expect(HostInsightVerdict.category(from: " \(category.rawValue.uppercased()) ") == category)
    }

    @Test func normalizesOrRejectsCategories() {
        #expect(HostInsightVerdict.category(from: "ai_inference") == .aiInference)
        #expect(HostInsightVerdict.category(from: "AI Inference") == .aiInference)
        #expect(HostInsightVerdict.category(from: "malware") == .unknown)
        #expect(HostInsightVerdict.category(from: "") == .unknown)
    }

    @Test func dropsPlaceholderText() {
        for placeholder in ["", "  ", "None", "unknown.", "N/A", "-"] {
            #expect(HostInsightVerdict.cleaned(placeholder) == nil)
        }
        #expect(HostInsightVerdict.cleaned(nil) == nil)
        #expect(HostInsightVerdict.cleaned(" Cloudflare ") == "Cloudflare")
    }

    @Test func clampsLongSummaries() {
        let long = String(repeating: "word ", count: 120)
        let clamped = HostInsightVerdict.clampSentences(long, limit: 2)
        #expect(clamped.count == HostInsightVerdict.summaryCharacterLimit)
        #expect(clamped.hasSuffix("…"))
        #expect(HostInsightVerdict.clampSentences("No ending punctuation", limit: 2) == "No ending punctuation")
    }

    @Test func summarizesForNotifications() {
        var insight = HostInsight(host: "report.weixin.qq.com", category: .analytics, operatorName: "Tencent", summary: "WeChat statistics.", concern: "Reports usage statistics.", language: "en", model: nil, createdAt: .now)
        #expect(HostInsightStyle.notificationLine(for: insight) == "\(HostInsightStyle.label(for: .analytics)) · Tencent — Reports usage statistics.")
        insight.concern = nil
        insight.operatorName = nil
        #expect(HostInsightStyle.notificationLine(for: insight) == HostInsightStyle.label(for: .analytics))
        insight.category = .unknown
        #expect(HostInsightStyle.notificationLine(for: insight) == nil)
    }

    @Test func tintsEveryKnownCategory() {
        for category in HostCategory.allCases {
            #expect((HostInsightStyle.hue(for: category) == nil) == (category == .unknown))
            #expect(!HostInsightStyle.label(for: category).isEmpty)
        }
    }

    @Test func guidesCategoryToKnownValues() throws {
        // The generation schema must constrain `category` to HostCategory raw values.
        let data = try JSONEncoder().encode(HostInsightVerdict.generationSchema)
        let schema = try #require(String(data: data, encoding: .utf8))
        for category in HostCategory.allCases {
            #expect(schema.contains("\"\(category.rawValue)\""))
        }
    }
}

struct InsightPromptTests {
    @Test func listsObservedFacts() {
        let context = HostContext(
            host: "api2.cursor.sh",
            appName: "Cursor",
            processName: "Cursor Helper (Plugin)",
            port: 443,
            ips: ["104.18.19.125", ""],
            geo: GeoInfo(countryCode: "us", asn: 13335, organization: "Cloudflare, Inc."),
            policy: "AI › US-West",
            firstSeen: Date(timeIntervalSince1970: 1_761_264_000),
            requestCount: 1284
        )
        let facts = HostInsightPrompt.facts(for: context)
        #expect(facts.contains("Host: api2.cursor.sh"))
        #expect(facts.contains("Port: 443"))
        #expect(facts.contains("App: Cursor"))
        #expect(facts.contains("Process: Cursor Helper (Plugin)"))
        #expect(facts.contains("IP addresses: 104.18.19.125\n"))
        #expect(facts.contains("Network: US · AS13335 Cloudflare"))
        #expect(facts.contains("Proxy policy: AI › US-West"))
        #expect(facts.contains("Requests so far: 1284"))
    }

    @Test func omitsUnknownFacts() {
        let facts = HostInsightPrompt.facts(for: HostContext(host: "149.154.175.60", ips: ["149.154.175.60"]))
        #expect(facts == "Host: 149.154.175.60\nExplain this host.")
    }

    @Test func asksForChineseOnlyWhenRequested() {
        #expect(HostInsightPrompt.instructions(languageCode: "zh-Hans").contains("Simplified Chinese"))
        #expect(!HostInsightPrompt.instructions(languageCode: "en").contains("Chinese"))
        #expect(HostInsightPrompt.options.maximumResponseTokens == 320)
        #expect(HostInsightPrompt.options.samplingMode == .greedy)
    }
}

struct InsightFailureTests {
    @Test func classifiesModelErrors() {
        #expect(HostInsightFailure(LanguageModelError.guardrailViolation(.init(debugDescription: "blocked"))) == .declined)
        #expect(HostInsightFailure(LanguageModelError.refusal(.init(explanation: "no", debugDescription: "refused"))) == .declined)
        let reset = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(HostInsightFailure(LanguageModelError.rateLimited(.init(resetDate: reset, debugDescription: "slow down"))) == .rateLimited(resetDate: reset))
        #expect(HostInsightFailure(LanguageModelError.timeout(.init(debugDescription: "late"))) == .timedOut)
        #expect(HostInsightFailure(LanguageModelError.unsupportedLanguageOrLocale(.init(languageCode: .chinese, debugDescription: "zh"))) == .unsupportedLanguage)
        #expect(HostInsightFailure(SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "missing"))) == .assetsUnavailable)
        #expect(HostInsightFailure(LanguageModelSession.Error.concurrentRequests) == .busy)
        #expect(HostInsightFailure(CancellationError()) == .cancelled)
        if case .other = HostInsightFailure(DatabaseError.notConfigured) {} else {
            Issue.record("Unrelated errors should map to .other")
        }
    }

    @Test func mapsSystemAvailability() {
        #expect(HostInsightAvailability(.available) == .available)
        #expect(HostInsightAvailability(.unavailable(.deviceNotEligible)) == .unavailable(.deviceNotEligible))
        #expect(HostInsightAvailability(.unavailable(.appleIntelligenceNotEnabled)) == .unavailable(.appleIntelligenceOff))
        #expect(HostInsightAvailability(.unavailable(.modelNotReady)) == .unavailable(.modelNotReady))
    }
}

@MainActor
struct InsightServiceTests {
    private func makeService(rows: [HostInsight] = []) -> (HostInsightService, ScriptedInsightGenerator, InsightTestStore) {
        let store = InsightTestStore(rows: rows)
        let generator = ScriptedInsightGenerator()
        return (HostInsightService(database: InsightTestDatabase(store: store), generator: generator), generator, store)
    }

    @Test func generatesOnceThenServesFromMemory() async throws {
        let (service, generator, store) = makeService()
        let first = try await service.insight(for: HostContext(host: "API.GitHub.com.", ips: []))
        #expect(first.host == "api.github.com")
        #expect(first.category == .api)
        #expect(first.model == "Test Model")
        #expect(first.language == "en")
        let second = try await service.insight(for: HostContext(host: "api.github.com", ips: []))
        #expect(second == first)
        #expect(generator.calls == ["api.github.com"])
        #expect(await store.saves == 1)
        #expect(await store.lookups == 1)
    }

    @Test func prefersTheSharedDatabase() async throws {
        let stored = HostInsight(host: "linear.app", category: .web, operatorName: "Linear", summary: "Linear's web app.", concern: nil, language: "en", model: "AFM 3 Core", createdAt: .now)
        let (service, generator, store) = makeService(rows: [stored])
        #expect(try await service.insight(for: HostContext(host: "linear.app", ips: [])) == stored)
        #expect(await service.cachedInsight(for: "linear.app") == stored)
        #expect(generator.calls.isEmpty)
        #expect(await store.saves == 0)
    }

    @Test func cachedLookupNeverRunsTheModel() async {
        let (service, generator, _) = makeService()
        #expect(await service.cachedInsight(for: "example.com") == nil)
        #expect(generator.calls.isEmpty)
    }

    @Test func sharesOneRequestPerHost() async throws {
        let (service, generator, _) = makeService()
        generator.delay = .milliseconds(50)
        async let a = service.insight(for: HostContext(host: "cdn.example.com", ips: []))
        async let b = service.insight(for: HostContext(host: "cdn.example.com", ips: []))
        let results = try await [a, b]
        #expect(results[0] == results[1])
        #expect(generator.calls.count == 1)
    }

    @Test func runsOneModelRequestAtATime() async throws {
        let (service, generator, _) = makeService()
        generator.delay = .milliseconds(30)
        try await withThrowingTaskGroup(of: HostInsight.self) { group in
            for host in ["a.example.com", "b.example.com", "c.example.com"] {
                group.addTask { try await service.insight(for: HostContext(host: host, ips: [])) }
            }
            for try await _ in group {}
        }
        #expect(generator.calls.count == 3)
        #expect(generator.maxConcurrent == 1)
    }

    private func eventually(_ timeout: Duration = .seconds(3), _ condition: () async -> Bool) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return await condition()
    }

    @Test func cancellingTheOnlyCallerFreesTheQueue() async throws {
        let (service, generator, store) = makeService()
        generator.delay = .seconds(5)
        let abandoned = Task { try await service.insight(for: HostContext(host: "slow.example", ips: [])) }
        #expect(await eventually { generator.calls == ["slow.example"] })
        abandoned.cancel()
        generator.delay = .zero

        // The next host does not wait for the abandoned generation.
        let clock = ContinuousClock()
        let started = clock.now
        let next = try await service.insight(for: HostContext(host: "next.example", ips: []))
        #expect(next.host == "next.example")
        #expect(started.duration(to: clock.now) < .seconds(2))
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        #expect(await store.saves == 1)

        // Nothing was cached for the abandoned host, so asking again runs the model again.
        _ = try await service.insight(for: HostContext(host: "slow.example", ips: []))
        #expect(generator.calls == ["slow.example", "next.example", "slow.example"])
        #expect(generator.maxConcurrent == 1)
    }

    @Test func skipsAQueuedRequestWhoseCallerGaveUp() async throws {
        let (service, generator, _) = makeService()
        generator.delay = .milliseconds(300)
        let first = Task { try await service.insight(for: HostContext(host: "first.example", ips: [])) }
        #expect(await eventually { generator.calls == ["first.example"] })
        let queued = Task { try await service.insight(for: HostContext(host: "queued.example", ips: [])) }
        try await Task.sleep(for: .milliseconds(50))
        queued.cancel()

        _ = try await first.value
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(generator.calls == ["first.example"])

        generator.delay = .zero
        _ = try await service.insight(for: HostContext(host: "queued.example", ips: []))
        #expect(generator.calls == ["first.example", "queued.example"])
    }

    @Test func aCallerArrivingAsTheLastOneLeavesStartsAfresh() async throws {
        let (service, generator, store) = makeService()
        generator.delay = .seconds(5)
        let abandoned = Task { try await service.insight(for: HostContext(host: "again.example", ips: [])) }
        #expect(await eventually { generator.calls == ["again.example"] })
        abandoned.cancel()
        generator.delay = .zero

        // The abandoned request is still registered for the host, but takes no new callers.
        let insight = try await service.insight(for: HostContext(host: "again.example", ips: []))
        #expect(insight.host == "again.example")
        #expect(generator.calls == ["again.example", "again.example"])
        await #expect(throws: CancellationError.self) { try await abandoned.value }
        #expect(await store.saves == 1)
    }

    @Test func keepsASharedRequestWhileAnotherCallerWaits() async throws {
        let (service, generator, store) = makeService()
        generator.delay = .milliseconds(400)
        let a = Task { try await service.insight(for: HostContext(host: "shared.example", ips: [])) }
        #expect(await eventually { generator.calls == ["shared.example"] })
        let b = Task { try await service.insight(for: HostContext(host: "shared.example", ips: [])) }
        try await Task.sleep(for: .milliseconds(50))
        a.cancel()

        let insight = try await b.value
        #expect(insight.host == "shared.example")
        #expect(generator.calls == ["shared.example"])
        #expect(await store.saves == 1)
        _ = await a.result
    }

    @Test func storesNeutralUnknownWhenTheModelDeclines() async throws {
        let (service, generator, store) = makeService()
        generator.respond = { _, _ in throw LanguageModelError.guardrailViolation(.init(debugDescription: "blocked")) }
        let insight = try await service.insight(for: HostContext(host: "blocked.example", ips: []))
        #expect(insight.category == .unknown)
        #expect(insight.operatorName == nil)
        #expect(insight.summary == tr("No description is available for this host.", "Insight"))
        #expect(await store.saves == 1)
    }

    @Test func reportsRateLimitsWithoutCaching() async {
        let (service, generator, store) = makeService()
        generator.respond = { _, _ in throw LanguageModelError.rateLimited(.init(resetDate: nil, debugDescription: "busy")) }
        await #expect(throws: HostInsightError.self) {
            try await service.insight(for: HostContext(host: "busy.example", ips: []))
        }
        do {
            _ = try await service.insight(for: HostContext(host: "busy.example", ips: []))
        } catch let error as HostInsightError {
            #expect(error.kind == .rateLimited)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
        #expect(await store.saves == 0)
        #expect(generator.calls.count == 2)
    }

    @Test func missingAssetsMakeTheModelUnavailable() async {
        let (service, generator, _) = makeService()
        generator.respond = { _, _ in throw SystemLanguageModel.Error.assetsUnavailable(.init(debugDescription: "gone")) }
        #expect(service.isAvailable)
        _ = try? await service.insight(for: HostContext(host: "x.example", ips: []))
        #expect(!service.isAvailable)
        #expect(service.unavailableReason == tr("The on-device model isn't installed yet.", "Insight"))
        service.prewarm()
        #expect(service.isAvailable)
    }

    @Test func unavailableModelStillServesStoredInsights() async throws {
        let stored = HostInsight(host: "github.com", category: .web, operatorName: "GitHub", summary: "GitHub.", concern: nil, language: "en", model: nil, createdAt: .now)
        let (service, generator, _) = makeService(rows: [stored])
        generator.availability = .unavailable(.appleIntelligenceOff)
        #expect(!service.isAvailable)
        #expect(service.unavailableReason == tr("Turn on Apple Intelligence in System Settings to explain hosts.", "Insight"))
        #expect(try await service.insight(for: HostContext(host: "github.com", ips: [])) == stored)
        do {
            _ = try await service.insight(for: HostContext(host: "new.example", ips: []))
            Issue.record("Expected an unavailable error")
        } catch let error as HostInsightError {
            #expect(error.kind == .unavailable)
        }
        #expect(generator.calls.isEmpty)
    }

    @Test func survivesAnOfflineDatabase() async throws {
        let (service, generator, store) = makeService()
        await store.setOffline(true)
        let insight = try await service.insight(for: HostContext(host: "offline.example", ips: []))
        #expect(insight.category == .api)
        #expect(generator.calls == ["offline.example"])
        // Served from memory afterwards.
        _ = try await service.insight(for: HostContext(host: "offline.example", ips: []))
        #expect(generator.calls.count == 1)
    }

    @Test func prewarmsOnlyWhenAvailable() {
        let (service, generator, _) = makeService()
        service.prewarm()
        generator.availability = .unavailable(.modelNotReady)
        service.prewarm()
        #expect(generator.prewarms == 1)
    }
}

/// Runs the real on-device model; skipped on Macs without Apple Intelligence.
@MainActor
@Suite(.enabled(if: SystemLanguageModel.default.isAvailable), .timeLimit(.minutes(1)))
struct InsightOnDeviceModelTests {
    @Test func explainsAWellKnownHost() async throws {
        let generator = OnDeviceHostInsightGenerator()
        let context = HostContext(host: "api.github.com", appName: "GitHub Desktop", port: 443, ips: ["140.82.112.6"], geo: GeoInfo(countryCode: "US", asn: 36459, organization: "GitHub, Inc."))
        let verdict = try await generator.verdict(for: context, languageCode: "en")
        let insight = verdict.insight(host: context.host, languageCode: "en", model: generator.modelName)
        #expect(HostCategory.allCases.map(\.rawValue).contains(verdict.category))
        #expect(!insight.summary.isEmpty)
        #expect(!generator.modelName.isEmpty)
        // The session is reused: a second host must not see the first one's transcript.
        let second = try await generator.verdict(for: HostContext(host: "registry.npmjs.org", ips: []), languageCode: "en")
        #expect(!second.summary.isEmpty)
    }
}
