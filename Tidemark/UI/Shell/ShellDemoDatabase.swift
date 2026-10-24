#if DEBUG
import Foundation

/// In-memory request store behind the History view in demo mode, previews and tests.
///
/// Request queries, histograms and policy lists are answered from `rows`; everything else behaves like
/// `OfflineDatabase`.
struct ShellDemoDatabase: TidemarkDatabase {
    var rows: [RequestRecord]
    /// Names for the search filter's app match (the real database joins `apps`).
    var appNames: [AppID: String] = [:]
    private let base = OfflineDatabase()

    init(rows: [RequestRecord], appNames: [AppID: String] = [:]) {
        // Newest first by `(started_at, id)`, the order the real database pages in.
        self.rows = rows.sorted { a, b in
            a.startedAt != b.startedAt ? a.startedAt > b.startedAt : (a.rowID ?? 0) > (b.rowID ?? 0)
        }
        self.appNames = appNames
    }

    /// Rows matching every filter of `query` except its paging (`offset`, `limit`, `before`).
    func matching(_ query: RequestQuery, now: Date = .now) -> [RequestRecord] {
        let lower = query.range.lowerBound(now: now)
        let needle = query.search.trimmingCharacters(in: .whitespaces).lowercased()
        return rows.filter { r in
            guard query.scope.includes(r.deviceID) else { return false }
            if let lower, r.startedAt < lower { return false }
            if let app = query.appID, r.appID != app { return false }
            if let policy = query.policy, r.finalPolicy != policy { return false }
            switch query.status {
            case .any: break
            case .completed: if r.state != .completed { return false }
            case .active: if r.state != .active { return false }
            case .failed: if r.state != .failed && r.state != .rejected { return false }
            }
            if !needle.isEmpty {
                let app = r.appID.flatMap { appNames[$0] } ?? ""
                return RequestsPresentation.matches(r, needle: needle, appName: app)
            }
            return true
        }
    }

    // Requests
    func queryRequests(_ query: RequestQuery) async throws -> RequestPage {
        let all = matching(query)
        var remaining = all[...]
        if let cursor = query.before {
            remaining = remaining.drop { !RequestsCSV.isOlder($0, than: cursor) }
        } else {
            remaining = remaining.dropFirst(query.offset)
        }
        let page = Array(remaining.prefix(query.limit))
        return RequestPage(rows: page, totalCount: Int64(all.count), elapsed: .milliseconds(3))
    }

    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram {
        let now = Date.now
        let all = matching(query, now: now)
        let start = query.range.lowerBound(now: now) ?? all.last?.startedAt ?? now.addingTimeInterval(-3600)
        let width = max(now.timeIntervalSince(start), 1) / Double(max(buckets, 1))
        var counts = Array(repeating: Int64(0), count: buckets)
        for r in all {
            let index = Int(r.startedAt.timeIntervalSince(start) / width)
            if index >= 0, index < buckets { counts[index] += 1 }
        }
        return Histogram(start: start, end: now, counts: counts)
    }

    func distinctPolicies(since: Date?) async throws -> [String] {
        let recent = rows.filter { record in since.map { record.startedAt >= $0 } ?? true }
        return Array(Set(recent.compactMap(\.finalPolicy))).sorted()
    }

    func countRequests(since: Date, scope: DeviceScope) async throws -> Int64 {
        Int64(rows.filter { $0.startedAt >= since && scope.includes($0.deviceID) }.count)
    }

    func estimatedRequestCount() async throws -> Int64 { Int64(rows.count) }

    // Everything else is offline.
    func connect() async throws { try await base.connect() }
    func migrate() async throws -> Int { try await base.migrate() }
    func ping() async throws -> (roundTrip: Duration, serverVersion: String) { try await base.ping() }
    func schemaVersion() async throws -> Int { try await base.schemaVersion() }
    func tableNames() async throws -> [String] { try await base.tableNames() }
    func upsertDevice(_ device: Device) async throws { try await base.upsertDevice(device) }
    func devices() async throws -> [Device] { try await base.devices() }
    func renameDevice(_ id: DeviceID, name: String) async throws { try await base.renameDevice(id, name: name) }
    func apps() async throws -> [MonitoredApp] { try await base.apps() }
    func insertApp(_ app: MonitoredApp) async throws { try await base.insertApp(app) }
    func updateApp(_ app: MonitoredApp) async throws { try await base.updateApp(app) }
    func deleteApp(_ id: AppID) async throws { try await base.deleteApp(id) }
    func setInstalled(appID: AppID, deviceID: DeviceID, installed: Bool) async throws {
        try await base.setInstalled(appID: appID, deviceID: deviceID, installed: installed)
    }
    func installs() async throws -> [AppID: [DeviceID: Bool]] { try await base.installs() }
    func appStats(_ id: AppID, scope: DeviceScope) async throws -> AppStats { try await base.appStats(id, scope: scope) }
    func countRequests(inBundle bundlePath: String) async throws -> Int64 { try await base.countRequests(inBundle: bundlePath) }
    func backfill(appID: AppID, bundlePath: String) async throws -> Int64 { try await base.backfill(appID: appID, bundlePath: bundlePath) }
    func upsertRequests(_ rows: [RequestRecord]) async throws -> [RequestKey: Int64] { try await base.upsertRequests(rows) }
    func requestsWritten(after cursor: Date, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] {
        try await base.requestsWritten(after: cursor, excluding: excluding, limit: limit)
    }
    func deleteRequests(olderThan: Date, deviceID: DeviceID?) async throws -> Int64 { try await base.deleteRequests(olderThan: olderThan, deviceID: deviceID) }
    func upsertProcessChain(deviceID: DeviceID, chain: [ProcessLink], appID: AppID?) async throws -> Int64? {
        try await base.upsertProcessChain(deviceID: deviceID, chain: chain, appID: appID)
    }
    func processTree(appID: AppID, scope: DeviceScope) async throws -> [ProcessNode] { try await base.processTree(appID: appID, scope: scope) }
    func knownHosts() async throws -> [AppID: Set<String>] { try await base.knownHosts() }
    func insertAppHosts(_ hosts: [AppHost]) async throws -> [AppHost] { try await base.insertAppHosts(hosts) }
    func touchAppHosts(_ hosts: [AppHost]) async throws { try await base.touchAppHosts(hosts) }
    func appHosts(_ appID: AppID, scope: DeviceScope) async throws -> [AppHost] { try await base.appHosts(appID, scope: scope) }
    func touchHostSources(_ sources: [HostSourceTouch]) async throws { try await base.touchHostSources(sources) }
    func inventory(kind: HostKind?, search: String, scope: DeviceScope) async throws -> [InventoryEntry] {
        try await base.inventory(kind: kind, search: search, scope: scope)
    }
    func ipInfo(_ ip: String) async throws -> GeoInfo? { try await base.ipInfo(ip) }
    func saveIPInfo(_ ip: String, geo: GeoInfo) async throws { try await base.saveIPInfo(ip, geo: geo) }
    func insertAlerts(_ alerts: [AlertItem]) async throws -> [AlertItem] { try await base.insertAlerts(alerts) }
    func alerts(filter: AlertFilter, appID: AppID?, scope: DeviceScope, limit: Int) async throws -> [AlertItem] {
        try await base.alerts(filter: filter, appID: appID, scope: scope, limit: limit)
    }
    func alerts(after id: Int64, excluding: DeviceID?) async throws -> [AlertItem] { try await base.alerts(after: id, excluding: excluding) }
    func unreadAlertCount(scope: DeviceScope) async throws -> Int { try await base.unreadAlertCount(scope: scope) }
    func markAlertsRead(_ ids: [Int64]) async throws { try await base.markAlertsRead(ids) }
    func markAllAlertsRead(appID: AppID?, scope: DeviceScope) async throws { try await base.markAllAlertsRead(appID: appID, scope: scope) }
    func deleteAlert(_ id: Int64) async throws { try await base.deleteAlert(id) }
    func mutes() async throws -> [String] { try await base.mutes() }
    func addMute(_ pattern: String) async throws { try await base.addMute(pattern) }
    func removeMute(_ pattern: String) async throws { try await base.removeMute(pattern) }
    func saveProbeSession(_ session: ProbeSession) async throws { try await base.saveProbeSession(session) }
    func probeSessions(limit: Int) async throws -> [ProbeSession] { try await base.probeSessions(limit: limit) }
    func deleteProbeSession(_ id: UUID) async throws { try await base.deleteProbeSession(id) }
    func hostInsight(_ host: String, language: String) async throws -> HostInsight? { try await base.hostInsight(host, language: language) }
    func saveHostInsight(_ insight: HostInsight) async throws { try await base.saveHostInsight(insight) }
    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws {
        try await base.saveEgressSamples(samples, deviceID: deviceID)
    }
    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample] { try await base.latestEgress(deviceID: deviceID) }
    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws { try await base.insertEgressChange(change, deviceID: deviceID) }
    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange] { try await base.egressChanges(deviceID: deviceID, limit: limit) }
}
#endif
