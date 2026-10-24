import Foundation

// Inert implementations used before `AppBootstrap` wires the real services (and in tests / previews).

struct OfflineDatabase: TidemarkDatabase {
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
    func deleteRequests(olderThan: Date, deviceID: DeviceID?) async throws -> Int64 { 0 }

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
    func markAllAlertsRead(appID: AppID?, scope: DeviceScope) async throws {}
    func deleteAlert(_ id: Int64) async throws {}
    func mutes() async throws -> [String] { [] }
    func addMute(_ pattern: String) async throws {}
    func removeMute(_ pattern: String) async throws {}

    func saveProbeSession(_ session: ProbeSession) async throws {}
    func probeSessions(limit: Int) async throws -> [ProbeSession] { [] }
    func deleteProbeSession(_ id: UUID) async throws {}

    func hostInsight(_ host: String, language: String) async throws -> HostInsight? { nil }
    func saveHostInsight(_ insight: HostInsight) async throws {}

    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws {}
    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample] { [] }
    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws {}
    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange] { [] }
}

struct UnavailableSurgeClient: SurgeClient {
    var endpoint: SurgeEndpoint

    private var error: SurgeError { .cliNotFound(path: endpoint.cliPath) }

    func events() -> AsyncThrowingStream<SurgeEvent, Error> {
        let error = self.error
        return AsyncThrowingStream { $0.finish(throwing: error) }
    }
    func status() async throws -> SurgeStatus { throw error }
    func environment() async throws -> SurgeEnvironment { throw error }
    func recentRequests() async throws -> [SurgeRequest] { throw error }
    func activeRequests() async throws -> [SurgeRequest] { throw error }
    func dnsLookup(_ domain: String) async throws -> SurgeDNSLookup { throw error }
    func dnsCache() async throws -> [String: [String]] { throw error }
    func geoIP(_ ip: String) async throws -> SurgeGeoIP { throw error }
    func ruleMatch(host: String, processPath: String?) async throws -> SurgeRuleMatch { throw error }
    func httpProbe(url: String, policy: String?) async throws -> SurgeHTTPProbe { throw error }
    func policyGroups() async throws -> [SurgePolicyGroup] { throw error }
    func externalIP(policy: String?) async throws -> String { throw error }
    func policyLatency(policy: String) async throws -> Int? { throw error }
    func network() async throws -> ThisMacNetwork { throw error }
    func httpProxyPort() async throws -> Int { throw error }
}

struct NoProcessInspector: ProcessInspecting {
    func process(pid: Int32) -> LiveProcess? { nil }
    func chain(pid: Int32, notAfter: Date?) -> [ProcessLink] { [] }
    func isRunning(pid: Int32, startTime: Date) -> Bool { false }
}

/// Last-two-labels fallback until the Public Suffix List classifier is wired in.
struct NaiveSiteClassifier: SiteClassifying {
    func site(for host: String) -> String {
        if HostName.isIPAddress(host) { return host }
        let labels = host.lowercased().split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let lastTwo = labels.suffix(2).joined(separator: ".")
        let secondLevel: Set<String> = ["com.cn", "net.cn", "org.cn", "gov.cn", "edu.cn", "com.hk", "co.jp", "co.uk", "com.au", "co.kr", "com.tw"]
        return secondLevel.contains(lastTwo) ? labels.suffix(3).joined(separator: ".") : lastTwo
    }
}

@MainActor
final class NoopCaptureActions: CaptureActions {
    func setRecording(_ on: Bool) {}
    func reconnect() {}
    func monitorApp(path: String, includeChildren: Bool, alertOnDomain: Bool, alertOnIP: Bool, backfill: Bool) async throws -> MonitoredApp {
        throw DatabaseError.notConfigured
    }
    func updateApp(_ app: MonitoredApp) async throws {}
    func archiveApp(_ id: AppID) async throws {}
    func restoreApp(_ id: AppID) async throws {}
    func deleteApp(_ id: AppID) async throws {}
    func setMonitoring(_ id: AppID, enabled: Bool) {}
    func monitorCandidates() async -> [AppCandidate] { [] }
    func markAlertsRead(_ ids: [Int64]) async {}
    func markAllAlertsRead(appID: AppID?) async {}
    func mute(_ pattern: String, dismissingAlert: Int64?) async {}
    func unmute(_ pattern: String) async {}
    func renameThisMac(_ name: String) async {}
    func testDatabaseConnection() async -> Result<String, Error> { .failure(DatabaseError.notConfigured) }
}

@MainActor
final class NoopProbeActions: ProbeActions {
    func startProbe(url: String, mode: ProbeDeviceMode, tail: Bool) async throws -> UInt16 { throw DatabaseError.notConfigured }
    func recordStep(label: String, url: String?) {}
    func stopProbe() async -> ProbeSession? { nil }
    func deleteProbe(_ id: UUID) async {}
}

@MainActor
final class NoopEgressActions: EgressActions {
    func checkAll() async {}
    func lookup(ip: String) async -> IPLookupResult { IPLookupResult(ip: ip) }
}

@MainActor
final class UnavailableHostInsights: HostInsightProviding {
    var isAvailable: Bool { false }
    var unavailableReason: String? { "On-device model not configured." }
    func insight(for context: HostContext) async throws -> HostInsight { throw DatabaseError.notConfigured }
    func cachedInsight(for host: String) async -> HostInsight? { nil }
    func prewarm() {}
}
