import Foundation
import FoundationModels
@testable import Tidemark

/// Rows of the fake `host_insights` table plus call counters.
actor InsightTestStore {
    private(set) var rows: [String: HostInsight] = [:]
    private(set) var lookups = 0
    private(set) var saves = 0
    /// When set, every database call throws (PostgreSQL offline).
    var offline = false

    init(rows: [HostInsight] = []) {
        for row in rows { self.rows["\(row.language)|\(row.host)"] = row }
    }

    func lookup(_ host: String, language: String) throws -> HostInsight? {
        lookups += 1
        if offline { throw DatabaseError.unreachable("test") }
        return rows["\(language)|\(host)"]
    }

    func save(_ insight: HostInsight) throws {
        if offline { throw DatabaseError.unreachable("test") }
        saves += 1
        rows["\(insight.language)|\(insight.host)"] = insight
    }

    func setOffline(_ value: Bool) { offline = value }
}

/// `TidemarkDatabase` that is inert like `OfflineDatabase` except for host insights, kept in `store`.
struct InsightTestDatabase: TidemarkDatabase {
    let store: InsightTestStore

    func connect() async throws { throw DatabaseError.notConfigured }
    func migrate() async throws -> Int { throw DatabaseError.notConfigured }
    func ping() async throws -> (roundTrip: Duration, serverVersion: String) { throw DatabaseError.notConfigured }
    func schemaVersion() async throws -> Int { throw DatabaseError.notConfigured }
    func tableNames() async throws -> [String] { [] }

    func upsertDevice(_ device: Device) async throws { throw DatabaseError.notConfigured }
    func devices() async throws -> [Device] { [] }
    func renameDevice(_ id: DeviceID, name: String) async throws { throw DatabaseError.notConfigured }

    func apps() async throws -> [MonitoredApp] { [] }
    func insertApp(_ app: MonitoredApp) async throws { throw DatabaseError.notConfigured }
    func updateApp(_ app: MonitoredApp) async throws { throw DatabaseError.notConfigured }
    func deleteApp(_ id: AppID) async throws { throw DatabaseError.notConfigured }
    func setInstalled(appID: AppID, deviceID: DeviceID, installed: Bool) async throws {}
    func installs() async throws -> [AppID: [DeviceID: Bool]] { [:] }
    func appStats(_ id: AppID, scope: DeviceScope) async throws -> AppStats { AppStats() }
    func countRequests(inBundle bundlePath: String) async throws -> Int64 { 0 }
    func backfill(appID: AppID, bundlePath: String) async throws -> Int64 { 0 }

    func upsertRequests(_ rows: [RequestRecord]) async throws -> [RequestKey: Int64] { throw DatabaseError.notConfigured }
    func queryRequests(_ query: RequestQuery) async throws -> RequestPage { RequestPage(rows: [], totalCount: 0, elapsed: .zero) }
    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram {
        Histogram(start: .now, end: .now, counts: Array(repeating: 0, count: buckets))
    }
    func requestsWritten(after cursor: Date, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] { [] }
    func distinctPolicies(since: Date?) async throws -> [String] { [] }
    func countRequests(since: Date, scope: DeviceScope) async throws -> Int64 { 0 }
    func estimatedRequestCount() async throws -> Int64 { 0 }
    func deleteRequests(olderThan: Date) async throws -> Int64 { 0 }

    func upsertProcessChain(deviceID: DeviceID, chain: [ProcessLink], appID: AppID?) async throws -> Int64? { nil }
    func processTree(appID: AppID, scope: DeviceScope) async throws -> [ProcessNode] { [] }

    func knownHosts() async throws -> [AppID: Set<String>] { [:] }
    func insertAppHosts(_ hosts: [AppHost]) async throws -> [AppHost] { [] }
    func touchAppHosts(_ hosts: [AppHost]) async throws {}
    func appHosts(_ appID: AppID, scope: DeviceScope) async throws -> [AppHost] { [] }
    func touchHostSources(_ sources: [HostSourceTouch]) async throws {}
    func inventory(kind: HostKind?, search: String, scope: DeviceScope) async throws -> [InventoryEntry] { [] }

    func ipInfo(_ ip: String) async throws -> GeoInfo? { nil }
    func saveIPInfo(_ ip: String, geo: GeoInfo) async throws {}

    func insertAlerts(_ alerts: [AlertItem]) async throws -> [AlertItem] { [] }
    func alerts(filter: AlertFilter, appID: AppID?, scope: DeviceScope, limit: Int) async throws -> [AlertItem] { [] }
    func alerts(after id: Int64, excluding: DeviceID?) async throws -> [AlertItem] { [] }
    func unreadAlertCount(scope: DeviceScope) async throws -> Int { 0 }
    func markAlertsRead(_ ids: [Int64]) async throws {}
    func markAllAlertsRead(appID: AppID?) async throws {}
    func deleteAlert(_ id: Int64) async throws {}
    func mutes() async throws -> [String] { [] }
    func addMute(_ pattern: String) async throws {}
    func removeMute(_ pattern: String) async throws {}

    func saveProbeSession(_ session: ProbeSession) async throws {}
    func probeSessions(limit: Int) async throws -> [ProbeSession] { [] }
    func deleteProbeSession(_ id: UUID) async throws {}

    func hostInsight(_ host: String, language: String) async throws -> HostInsight? {
        try await store.lookup(host, language: language)
    }
    func saveHostInsight(_ insight: HostInsight) async throws {
        try await store.save(insight)
    }

    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws {}
    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample] { [] }
    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws {}
    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange] { [] }
}

/// Scripted stand-in for the on-device model.
@MainActor
final class ScriptedInsightGenerator: HostInsightGenerating {
    var availability: HostInsightAvailability = .available
    var modelName = "Test Model"
    var chinese = false
    var delay: Duration = .zero
    var respond: (HostContext, String) throws -> HostInsightVerdict = { context, _ in
        HostInsightVerdict(operatorName: "Example Inc.", summary: "Serves \(context.host).", category: "api", concern: nil)
    }

    private(set) var calls: [String] = []
    private(set) var prewarms = 0
    private(set) var maxConcurrent = 0
    private var running = 0

    func supports(languageCode: String) -> Bool { languageCode == "en" || chinese }

    func prewarm(languageCode: String) { prewarms += 1 }

    func verdict(for context: HostContext, languageCode: String) async throws -> HostInsightVerdict {
        calls.append(context.host)
        running += 1
        maxConcurrent = max(maxConcurrent, running)
        defer { running -= 1 }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try respond(context, languageCode)
    }
}
