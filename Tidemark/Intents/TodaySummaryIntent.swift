import AppIntents
import Foundation
import SwiftUI

/// "12,345 requests today · 7 new destinations" for what this Mac records (the remote Surge's device when one
/// is configured, the same device as the menu bar's Today counter).
struct TodaySummaryIntent: AppIntent {
    static let title = LocalizedStringResource("Today's Summary", table: "Intents")
    static let description: IntentDescription? = IntentDescription(
        LocalizedStringResource("Counts the requests this Mac recorded today and the new destinations its monitored apps reached.", table: "Intents"),
        resultValueName: LocalizedStringResource("Requests Today", table: "Intents")
    )
    static let supportedModes: IntentModes = .background
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Dependency private var model: AppModel

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> & ProvidesDialog & ShowsSnippetView {
        let figures = await IntentsTodayFigures.load(model)
        return .result(
            value: Int(figures.requests),
            dialog: "\(IntentsText.summary(figures))",
            view: IntentsSummarySnippet(
                requests: Fmt.count(figures.requests),
                requestsLabel: tr("Requests today", "Intents"),
                destinations: Fmt.count(figures.newDestinations),
                destinationsLabel: tr("New destinations today", "Intents")
            )
        )
    }
}

/// Today's counts behind `TodaySummaryIntent`.
struct IntentsTodayFigures: Equatable, Sendable {
    var requests: Int64
    var newDestinations: Int

    /// Reads the database when it is reachable and falls back to the live counters.
    @MainActor
    static func load(_ model: AppModel, now: Date = .now) async -> IntentsTodayFigures {
        let startOfDay = Calendar.current.startOfDay(for: now)
        // Rows and alerts are written under the recording device, which `live.todayCount` also counts.
        let device = CaptureDeviceInfo.recordingDeviceID(model.preferences)
        let scope = DeviceScope.device(device)
        let counted = (try? await model.database.countRequests(since: startOfDay, scope: scope)) ?? 0
        let stored = (try? await model.database.alerts(filter: .all, appID: nil, scope: scope, limit: 5000)) ?? []
        return IntentsTodayFigures(
            requests: max(counted, model.live.todayCount),
            newDestinations: newDestinations(in: stored + model.alerts.items, since: startOfDay, device: device)
        )
    }

    /// Distinct hosts and IPs first contacted since `start` by `device`.
    static func newDestinations(in alerts: [AlertItem], since start: Date, device: DeviceID) -> Int {
        Set(alerts.lazy
            .filter { $0.createdAt >= start && $0.deviceID == device }
            .map { "\($0.kind.rawValue):\($0.value.lowercased())" }
        ).count
    }
}
