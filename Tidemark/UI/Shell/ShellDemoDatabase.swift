#if DEBUG
import Foundation

/// In-memory request store behind the History view in demo mode, previews and tests.
///
/// Request queries, histograms, policy lists, the domains and IPs of Domains & IPs and the app pages and the processes
/// that reached them are answered from `rows`, site probes and egress history from `sources`; everything else behaves
/// like `OfflineDatabase`.
struct ShellDemoDatabase: TidemarkDatabase {
    /// The records besides requests that the demo's requests are joined to (`relatedRecords(of:)`).
    struct Sources {
        var alerts: [AlertItem] = []
        var probes: [ProbeSession] = []
        /// Each Mac's egress checks, oldest first, every policy flagged current while it was.
        var egressChecks: [DeviceID: [EgressSample]] = [:]
        /// Each Mac's egress changes, newest first.
        var egressChanges: [DeviceID: [EgressChange]] = [:]
    }

    var rows: [RequestRecord]
    /// Names for the search filter's app match (the real database joins `apps`).
    var appNames: [AppID: String] = [:]
    var sources = Sources()
    private let base = OfflineDatabase()

    init(rows: [RequestRecord], appNames: [AppID: String] = [:], sources: Sources = Sources()) {
        // Newest first by `(started_at, id)`, the order the real database pages in.
        self.rows = rows.sorted { a, b in
            a.startedAt != b.startedAt ? a.startedAt > b.startedAt : (a.rowID ?? 0) > (b.rowID ?? 0)
        }
        self.appNames = appNames
        self.sources = sources
    }

    /// Rows matching every filter of `query` except its paging (`offset`, `limit`).
    func matching(_ query: RequestQuery, now: Date = .now) -> [RequestRecord] {
        let lower = query.range.lowerBound(now: now)
        let needle = query.search.trimmingCharacters(in: .whitespaces).lowercased()
        let host = query.host.map(RequestsHostFilter.normalized)
        let ip = query.remoteIP.map(RequestsHostFilter.normalized)
        return rows.filter { r in
            guard query.scope.includes(r.deviceID) else { return false }
            if let lower, r.startedAt < lower { return false }
            if let until = query.until, r.startedAt > until { return false }
            if let app = query.appID, r.appID != app { return false }
            if let policy = query.policy, r.finalPolicy != policy { return false }
            switch query.status {
            case .any: break
            case .completed: if r.state != .completed { return false }
            case .active: if r.state != .active { return false }
            case .failed: if r.state != .failed && r.state != .rejected { return false }
            }
            if let host, r.host != host { return false }
            if let ip, r.remoteIP.map(RequestsHostFilter.normalized) != ip { return false }
            if query.endedWithError, !r.endedWithError { return false }
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
        let page = Array(all.dropFirst(query.offset).prefix(query.limit))
        return RequestPage(rows: page, totalCount: Int64(all.count), elapsed: .milliseconds(3))
    }

    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram {
        let now = Date.now
        let all = matching(query, now: now)
        let end = query.until.map { min($0, now) } ?? now
        let start = query.range.lowerBound(now: now) ?? all.last?.startedAt ?? end.addingTimeInterval(-3600)
        let width = max(end.timeIntervalSince(start), 1) / Double(max(buckets, 1))
        var counts = Array(repeating: Int64(0), count: buckets)
        for r in all {
            // A request at the very end (`until`) counts in the last bucket, as in PostgreSQL.
            let index = min(Int(r.startedAt.timeIntervalSince(start) / width), buckets - 1)
            if index >= 0 { counts[index] += 1 }
        }
        return Histogram(start: start, end: end, counts: counts)
    }

    func request(id: Int64) async throws -> RequestRecord? {
        rows.first { $0.rowID == id }
    }

    func newerRequestStarts(than request: RequestRecord, matching query: RequestQuery, limit: Int) async throws -> [Date] {
        // `rows` is newest first by `(started_at, id)`, so the newer ones come before the request, the nearest last.
        let newer = matching(query).prefix { row in
            row.startedAt != request.startedAt ? row.startedAt > request.startedAt : (row.rowID ?? 0) > (request.rowID ?? 0)
        }
        return Array(newer.reversed().prefix(max(0, limit)).map(\.startedAt))
    }

    func distinctPolicies(since: Date?) async throws -> [String] {
        let recent = rows.filter { record in since.map { record.startedAt >= $0 } ?? true }
        return Array(Set(recent.compactMap(\.finalPolicy))).sorted()
    }

    func countRequests(since: Date, scope: DeviceScope) async throws -> Int64 {
        Int64(rows.filter { $0.startedAt >= since && scope.includes($0.deviceID) }.count)
    }

    func estimatedRequestCount() async throws -> Int64 { Int64(rows.count) }

    // Inventory, as capture records it: each request counts once for its domain and once for the IP it reached (the
    // address its domain resolved to, or the host itself when it is an IP).

    func appHosts(_ appID: AppID, scope: DeviceScope) async throws -> [AppHost] {
        // Oldest first, so the first request of a host names its first process and the domains of an IP keep their order.
        // As in the real database, one Mac keeps the entries it reported, whose counts and dates stay every Mac's.
        var hosts: [String: AppHost] = [:]
        var reported: Set<String> = []
        for row in rows.reversed() where row.appID == appID {
            for (kind, value) in Self.inventoryValues(of: row) {
                let key = "\(kind.rawValue):\(value)"
                if scope.includes(row.deviceID) { reported.insert(key) }
                var host = hosts[key] ?? AppHost(
                    appID: appID, kind: kind, value: value, site: nil, firstSeen: row.startedAt, lastSeen: row.startedAt, requestCount: 0,
                    processName: row.processName, policy: nil, geo: nil, isDirect: kind == .ip && row.isIPLiteral, hosts: [],
                    firstDeviceID: row.deviceID
                )
                host.lastSeen = row.startedAt
                host.requestCount += 1
                host.policy = row.policyPath.isEmpty ? host.policy : row.policyDisplay
                host.geo = row.geo ?? host.geo
                if kind == .ip, !row.isIPLiteral, !host.hosts.contains(row.host) { host.hosts.append(row.host) }
                hosts[key] = host
            }
        }
        return hosts.filter { reported.contains($0.key) }.values
            .sorted { a, b in a.firstSeen != b.firstSeen ? a.firstSeen > b.firstSeen : a.value < b.value }
    }

    func inventory(kind: HostKind?, search: String, scope: DeviceScope) async throws -> [InventoryEntry] {
        var entries: [String: InventoryEntry] = [:]
        for row in rows.reversed() where scope.includes(row.deviceID) {
            let source = inventorySource(of: row)
            for (entryKind, value) in Self.inventoryValues(of: row) where kind == nil || entryKind == kind {
                let key = "\(entryKind.rawValue):\(value)"
                var entry = entries[key] ?? InventoryEntry(kind: entryKind, value: value, sources: [], firstSeen: row.startedAt,
                                                           lastSeen: row.startedAt, requestCount: 0, geo: nil)
                entry.lastSeen = row.startedAt
                entry.requestCount += 1
                if entryKind == .ip { entry.geo = row.geo ?? entry.geo }
                if !entry.sources.contains(source) { entry.sources.append(source) }
                entries[key] = entry
            }
        }
        let term = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let matches = entries.values.filter { entry in
            term.isEmpty || entry.value.contains(term) || entry.sources.contains { $0.title.lowercased().contains(term) }
        }
        return Array(matches.map { entry in
            var entry = entry
            entry.sources.sort { ($0.title, $0.path) < ($1.title, $1.path) }
            return entry
        }
        .sorted { a, b in a.firstSeen != b.firstSeen ? a.firstSeen > b.firstSeen : a.value < b.value }
        .prefix(2000))
    }

    func hostProcesses(kind: HostKind, value: String, appID: AppID, scope: DeviceScope) async throws -> [HostProcess] {
        // An `app_host_sources` row per Mac and process, as capture writes them for the app's requests.
        struct Key: Hashable { var device: DeviceID; var path: String }
        var sightings: [Key: HostProcess.Sighting] = [:]
        for row in rows.reversed() where row.appID == appID && row.probeSessionID == nil {
            guard Self.inventoryValues(of: row).contains(where: { $0.0 == kind && $0.1 == value }) else { continue }
            let path = row.processPath ?? row.bundlePath ?? ""
            let key = Key(device: row.deviceID, path: path)
            var sighting = sightings[key] ?? HostProcess.Sighting(
                deviceID: row.deviceID, path: path, title: "", firstSeen: row.startedAt, lastSeen: row.startedAt, requestCount: 0
            )
            sighting.title = path.isEmpty ? "" : (row.chain.last?.name ?? row.processName)
            sighting.lastSeen = row.startedAt
            sighting.requestCount += 1
            sightings[key] = sighting
        }
        return HostProcess.merge(Array(sightings.values), scope: scope)
    }

    /// Who a request counts for: its process, or the site probe it belonged to, named as the real database names it.
    private func inventorySource(of row: RequestRecord) -> InventorySource {
        if let id = row.probeSessionID {
            let site = sources.probes.first { $0.id == id }?.host ?? row.host
            return InventorySource(title: "Probe · \(site)", path: "Site probe · \(site)", appID: nil, probeSessionID: id, bundlePath: nil)
        }
        let path = row.processPath ?? row.bundlePath ?? ""
        return InventorySource(title: path.isEmpty ? "" : (row.chain.last?.name ?? row.processName), path: path, appID: row.appID,
                               probeSessionID: nil, bundlePath: row.bundlePath)
    }

    /// The domain and the IP a request counts for in the inventory.
    private static func inventoryValues(of row: RequestRecord) -> [(HostKind, String)] {
        let host = RequestsHostFilter.normalized(row.host)
        guard !host.isEmpty else { return [] }
        if row.isIPLiteral { return [(.ip, host)] }
        return [(.domain, host)] + (row.remoteIP.map { [(.ip, $0.lowercased())] } ?? [])
    }

    // Everything else is offline.
    func connect() async throws { try await base.connect() }
    func migrate() async throws -> Int { try await base.migrate() }
    func ping() async throws -> (roundTrip: Duration, serverVersion: String) { try await base.ping() }
    func schemaVersion() async throws -> Int { try await base.schemaVersion() }
    func tableNames() async throws -> [String] { try await base.tableNames() }
    func upsertDevice(_ device: Device) async throws { try await base.upsertDevice(device) }
    func devices() async throws -> [Device] { try await base.devices() }
    func renameDevice(_ id: DeviceID, name: String) async throws { try await base.renameDevice(id, name: name) }
    func mergeDevice(_ from: DeviceID, into: DeviceID, idleFor: Duration?) async throws -> DeviceMergeResult { try await base.mergeDevice(from, into: into, idleFor: idleFor) }
    func devicesSharingHistory(with device: DeviceID, sessions: [Int64]) async throws -> [DeviceID] { try await base.devicesSharingHistory(with: device, sessions: sessions) }
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
    func requestsWritten(after cursor: RequestWriteCursor, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] {
        try await base.requestsWritten(after: cursor, excluding: excluding, limit: limit)
    }
    func requestWritePosition() async throws -> RequestWriteCursor { try await base.requestWritePosition() }
    func upsertProcessChain(deviceID: DeviceID, chain: [ProcessLink], appID: AppID?) async throws -> Int64? {
        try await base.upsertProcessChain(deviceID: deviceID, chain: chain, appID: appID)
    }
    func processTree(appID: AppID, scope: DeviceScope) async throws -> [ProcessNode] { try await base.processTree(appID: appID, scope: scope) }
    func knownHosts() async throws -> [AppID: Set<String>] { try await base.knownHosts() }
    func insertAppHosts(_ hosts: [AppHost]) async throws -> [AppHost] { try await base.insertAppHosts(hosts) }
    func touchAppHosts(_ hosts: [AppHost]) async throws { try await base.touchAppHosts(hosts) }
    func touchHostSources(_ sources: [HostSourceTouch]) async throws { try await base.touchHostSources(sources) }
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
    func saveProbeSession(_ session: ProbeSession) async throws { try await base.saveProbeSession(session) }
    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws {
        try await base.saveEgressSamples(samples, deviceID: deviceID)
    }
    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws { try await base.insertEgressChange(change, deviceID: deviceID) }

    // Site probes and egress history, from `sources`.
    func probeSessions(limit: Int) async throws -> [ProbeSession] {
        Array(sources.probes.sorted { $0.startedAt > $1.startedAt }.prefix(limit))
    }

    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample] { latestEgressSamples(deviceID: deviceID) }

    /// The latest check of each policy, only the newest current one still flagged current.
    func latestEgressSamples(deviceID: DeviceID) -> [EgressSample] {
        let checks = sources.egressChecks[deviceID] ?? []
        let current = checks.last(where: \.isCurrent)
        var latest: [String: EgressSample] = [:]
        for check in checks { latest[check.id] = check }
        return latest.values.map { check in
            var check = check
            check.isCurrent = check == current
            return check
        }
        .sorted { $0.policyDisplay < $1.policyDisplay }
    }

    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange] {
        Array((sources.egressChanges[deviceID] ?? []).prefix(limit))
    }
}
#endif
