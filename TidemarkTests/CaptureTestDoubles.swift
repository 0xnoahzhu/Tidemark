import Foundation
import Synchronization
@testable import Tidemark

// Test doubles for the capture, egress and probe suites. Nothing here touches the network, Surge or
// PostgreSQL.

/// Hand-written `surge-cli --raw` request fixtures (shapes from `dump recent` / `watch request`).
enum CaptureFixtures {
    static let cursorProxied = """
    {"id":58577,"remoteHost":"api3.cursor.sh:443","URL":"api3.cursor.sh:443","method":"HTTPS","status":"Active",
     "processPath":"/Applications/Cursor.app/Contents/Frameworks/Cursor Helper (Plugin).app/Contents/MacOS/Cursor Helper (Plugin)",
     "pathForStatistics":"/Applications/Cursor.app/","pid":851,"policyName":"AT&T-RackNerd-Hysteria2",
     "originalPolicyName":"AT&T-RackNerd-Hysteria2","remoteAddress":"23.254.139.175 (Proxy)","localAddress":"10.1.2.133",
     "sourceAddress":"198.18.0.1","sourcePort":65373,"interface":"en0","deviceName":"Mac mini",
     "notes":["12:49:41.330039 [Connection] Handled by VIF","12:49:41.331985 [TLS] TLS Client Hello SNI: api3.cursor.sh",
              "12:49:41.332571 [Rule] Global proxy outbound mode: AI",
              "12:49:41.332696 [Rule] Policy decision path: AI -> AT&T-RackNerd-Hysteria2",
              "12:49:41.333263 [Connection-Pool] Use an existing master connector: SGHysteriaMasterConnector-16"],
     "inBytes":4037,"outBytes":1236,"startDate":1792871381.33004,"setupCompletedDate":1792871381.333627,"completedDate":0,
     "completed":false,"failed":false,"rejected":false,"modified":false,"replica":false,"local":true,"takeoverMode":40,
     "engineIdentifier":80,"streamHasRequestBody":false}
    """

    static let wechatDirectIP = """
    {"id":7001,"remoteHost":"157.148.69.80:443","URL":"157.148.69.80:443","method":"TCP","status":"Completed",
     "processPath":"/Applications/WeChat.app/Contents/MacOS/WeChat","pathForStatistics":"/Applications/WeChat.app/","pid":633,
     "policyName":"DIRECT","remoteAddress":"157.148.69.80","localAddress":"10.1.2.133","sourcePort":51000,
     "notes":["09:00:00.000001 [Rule] Rule matched: IP-CIDR,157.148.0.0/16,DIRECT"],
     "inBytes":100,"outBytes":50,"startDate":1792871000.5,"completedDate":1792871001.5,"completed":true,"failed":false,"rejected":false}
    """

    static let ruleModeHTTP = """
    {"id":9001,"remoteHost":"registry.npmjs.org:80","URL":"http://registry.npmjs.org/@types%2fnode","method":"GET","status":"Completed",
     "processPath":"/usr/local/bin/node","pathForStatistics":"/usr/local/bin/node","pid":1201,"policyName":"HK-01",
     "remoteAddress":"103.152.220.41 (Proxy)","notes":["10:00:00.000001 [Rule] Rule matched: DOMAIN-SUFFIX,npmjs.org,Proxy",
     "10:00:00.000002 [Rule] Policy decision path: Proxy -> HK-01"],
     "inBytes":2048,"outBytes":512,"startDate":1792871100,"completedDate":1792871100.8,"completed":true}
    """

    static let failedRequest = """
    {"id":9002,"remoteHost":"[2001:db8::1]:8443","method":"HTTPS","status":"Failed","failed":true,"completed":true,
     "startDate":1792871200,"notes":[]}
    """

    static let rejected = """
    {"id":9003,"remoteHost":"ads.example.com:443","method":"HTTPS","status":"Rejected","rejected":true,"policyName":"REJECT",
     "startDate":1792871300,"notes":["10:00:00.000001 [Rule] Rule matched: DOMAIN-SUFFIX,example.com"]}
    """

    static func decode(_ json: String) throws -> SurgeRequest {
        try JSONDecoder().decode(SurgeRequest.self, from: Data(json.utf8))
    }

    /// A minimal request for pipeline tests.
    static func request(
        id: Int64, host: String, port: Int = 443, processPath: String?, pid: Int32? = nil, remoteAddress: String? = nil,
        policy: String = "Proxy", completed: Bool = false, sourcePort: Int? = nil, start: Double = 1_792_871_000
    ) -> SurgeRequest {
        var r = SurgeRequest(id: id)
        r.remoteHost = "\(host):\(port)"
        r.url = "\(host):\(port)"
        r.method = "HTTPS"
        r.processPath = processPath
        r.pid = pid
        r.policyName = policy
        r.remoteAddress = remoteAddress
        r.sourcePort = sourcePort
        r.startDate = start
        r.completed = completed
        r.completedDate = completed ? start + 1 : 0
        r.notes = ["10:00:00.000001 [Rule] Policy decision path: \(policy)"]
        return r
    }

    static func app(_ name: String, path: String, includeChildren: Bool = true, rule: AlertRule = .anyHost, alertNewIP: Bool = true,
                    createdAt: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> MonitoredApp {
        MonitoredApp(id: UUID(), name: name, path: path, bundleID: nil, tileLetter: String(name.prefix(1)), tileHue: 240,
                     includeChildren: includeChildren, alertRule: rule, alertNewIP: alertNewIP, archivedAt: nil, createdAt: createdAt)
    }
}

/// A fixed process table.
struct CaptureFakeProcesses: ProcessInspecting {
    var processes: [Int32: LiveProcess] = [:]

    init(_ list: [LiveProcess] = []) {
        for p in list { processes[p.pid] = p }
    }

    func process(pid: Int32) -> LiveProcess? { processes[pid] }

    func chain(pid: Int32, notAfter: Date?) -> [ProcessLink] {
        guard let leaf = processes[pid] else { return [] }
        if let notAfter, leaf.startTime > notAfter { return [] }
        var chain: [ProcessLink] = []
        var current: LiveProcess? = leaf
        while let p = current, p.pid > 1, chain.count < 16 {
            chain.insert(ProcessLink(name: p.name, pid: p.pid, path: p.path, startTime: p.startTime), at: 0)
            current = processes[p.parentPID]
        }
        return chain
    }

    func isRunning(pid: Int32, startTime: Date) -> Bool { processes[pid]?.startTime == startTime }
}

/// Last two labels; enough for tests.
struct CaptureFakeClassifier: SiteClassifying {
    func site(for host: String) -> String {
        if HostName.isIPAddress(host) { return host }
        return host.lowercased().split(separator: ".").suffix(2).joined(separator: ".")
    }
}

/// Scriptable Surge client.
final class CaptureFakeSurge: SurgeClient {
    struct State {
        var dns: [String: [String]] = [:]
        var dnsCache: [SurgeDNSRecord] = []
        var geo: [String: SurgeGeoIP] = [:]
        var externalIPs: [String: String] = [:]
        var latencies: [String: Int] = [:]
        var groups: [SurgePolicyGroup] = []
        var environment = SurgeEnvironment(proxyMode: 2, globalPolicy: nil, groupSelections: [:])
        var ruleMatch = SurgeRuleMatch(policy: "Proxy", rule: "FINAL")
        var httpPort = 6152
        var startTime: Double = 1_792_000_000
        var recent: [SurgeRequest] = []
        var active: [SurgeRequest] = []
        var dnsLookups: [String] = []
        var externalIPCalls: [String] = []
        /// `events()` stays open without delivering anything until the consumer is cancelled.
        var silentStream = false
        var eventsCalls = 0
        var statusCalls = 0
        /// Open silent streams; `emit(_:)` delivers to them.
        var streams: [AsyncThrowingStream<SurgeEvent, Error>.Continuation] = []
        /// What `dump traffic` lists: node → line hash.
        var lineHashes: [String: String] = [:]
        /// What `proxy-runtime-status` answers, by line hash or name; others fail like an unknown policy.
        var runtimeStatus: [String: SurgeProxyRuntimeStatus] = [:]
        /// Every `dump traffic` and `proxy-runtime-status <policy>` call, in order.
        var proxyCommands: [String] = []
    }

    let endpoint: SurgeEndpoint
    let state = Mutex(State())

    init(cliPath: String = "/usr/bin/false") {
        endpoint = SurgeEndpoint(cliPath: cliPath)
    }

    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var snapshot: State { state.withLock { $0 } }

    func events() -> AsyncThrowingStream<SurgeEvent, Error> {
        let silent = state.withLock { s -> Bool in
            s.eventsCalls += 1
            return s.silentStream
        }
        guard silent else { return AsyncThrowingStream { $0.finish() } }
        let (stream, continuation) = AsyncThrowingStream<SurgeEvent, Error>.makeStream()
        state.withLock { $0.streams.append(continuation) }
        return stream
    }
    /// Delivers an event to every open silent stream.
    func emit(_ event: SurgeEvent) {
        for continuation in snapshot.streams { continuation.yield(event) }
    }
    func status() async throws -> SurgeStatus {
        let start = state.withLock { s -> Double in
            s.statusCalls += 1
            return s.startTime
        }
        return SurgeStatus(version: "6.10.0", build: nil, profile: nil, mode: nil, globalPolicy: nil, deviceName: nil, deviceIdentifier: nil,
                           controllerProtocol: 25, startTime: start, uptime: nil, features: nil)
    }
    func environment() async throws -> SurgeEnvironment { snapshot.environment }
    func recentRequests() async throws -> [SurgeRequest] { snapshot.recent }
    func activeRequests() async throws -> [SurgeRequest] { snapshot.active }
    func dnsLookup(_ domain: String) async throws -> SurgeDNSLookup {
        let ips = state.withLock { s -> [String]? in
            s.dnsLookups.append(domain)
            return s.dns[domain]
        }
        guard let ips else { throw SurgeError.commandFailed(command: "dns lookup", message: "NXDOMAIN") }
        return SurgeDNSLookup(domain: domain, server: nil, path: nil, v4Addresses: ips.filter(HostName.isIPv4),
                              v6Addresses: ips.filter { !HostName.isIPv4($0) }, durationMs: 1, expiresIn: 0)
    }
    func dnsCache() async throws -> [SurgeDNSRecord] { snapshot.dnsCache }
    func geoIP(_ ip: String) async throws -> SurgeGeoIP {
        guard let geo = snapshot.geo[ip] else { throw SurgeError.commandFailed(command: "geoip", message: "unknown") }
        return geo
    }
    func ruleMatch(host: String, processPath: String?) async throws -> SurgeRuleMatch { snapshot.ruleMatch }
    func httpProbe(url: String, policy: String?) async throws -> SurgeHTTPProbe { throw SurgeError.timedOut(command: "http probe") }
    func policyGroups() async throws -> [SurgePolicyGroup] { snapshot.groups }
    func externalIP(policy: String?) async throws -> String {
        let key = policy ?? "DIRECT"
        let ip = state.withLock { s -> String? in
            s.externalIPCalls.append(key)
            return s.externalIPs[key]
        }
        guard let ip else { throw SurgeError.commandFailed(command: "test-policy-external-ip", message: "failed") }
        return ip
    }
    func policyLatency(policy: String) async throws -> Int? { snapshot.latencies[policy] }
    func network() async throws -> ThisMacNetwork {
        ThisMacNetwork(interface: "en0", interfaceDetail: "Wi-Fi", localIP: "192.168.31.24", router: "192.168.31.1", dnsServers: ["223.5.5.5"], surgeMode: nil)
    }
    func httpProxyPort() async throws -> Int { snapshot.httpPort }
    func proxyLineHashes() async throws -> [String: String] {
        state.withLock { s in
            s.proxyCommands.append("dump traffic")
            return s.lineHashes
        }
    }
    func proxyRuntimeStatus(_ policy: String) async throws -> SurgeProxyRuntimeStatus {
        let status = state.withLock { s in
            s.proxyCommands.append("proxy-runtime-status \(policy)")
            return s.runtimeStatus[policy]
        }
        guard let status else { throw SurgeError.commandFailed(command: "proxy-runtime-status \(policy)", message: "Policy \(policy) doesn't exist.") }
        return status
    }
}

/// In-memory database that records what the engine writes. `failing` makes every write throw
/// `DatabaseError.unreachable`; `refusingEverything` makes request writes throw `DatabaseError.query`;
/// `enforcesForeignKeys` refuses rows that name an app missing from `appList`, and `enforcesDeviceKeys` request rows
/// of a device that was not registered (or was merged away), like PostgreSQL's foreign keys.
actor CaptureFakeDatabase: TidemarkDatabase {
    var failing = false
    var refusingEverything = false
    var enforcesForeignKeys = false
    var enforcesDeviceKeys = false
    /// Devices `upsertDevice` registered, less the ones merged away.
    var registeredDevices: Set<DeviceID> = []
    /// What `devices()` answers.
    var deviceList: [Device] = []
    /// Every device `upsertDevice` wrote, in order.
    var upsertedDevices: [Device] = []
    /// Every `mergeDevice` call, in order, with the number of request rows written before it.
    var deviceMerges: [(from: DeviceID, into: DeviceID, idleFor: Duration?, writesBefore: Int)] = []
    /// `mergeDevice` throws this while set.
    var mergeFailure: DatabaseError?
    /// What `mergeDevice` answers for these devices, without merging them.
    var mergeRefusals: [DeviceID: DeviceMergeResult.Refusal] = [:]
    /// What `devicesSharingHistory` answers.
    var historySharers: [DeviceID] = []
    /// Every `devicesSharingHistory` call, in order.
    var historyLookups: [(device: DeviceID, sessions: [Int64])] = []
    /// Request rows with these hosts are always refused (`DatabaseError.query`).
    var refusedHosts: Set<String> = []
    /// Request writes hang until cancelled (a black-holed connection), `stallLimit` at most.
    var stallingRequests = false
    /// Request writes fail at their statement timeout (`DatabaseError.timedOut`).
    var timingOutRequests = false
    /// Probe saves hang until cancelled, `stallLimit` at most.
    var stallingProbeSaves = false
    /// A stalled call that nobody cancels fails after this long (as on a connection that never answers), so a
    /// write the code under test forgot to abandon fails its test instead of holding it for good.
    static let stallLimit: Duration = .seconds(60)
    /// Closing rows of ended sessions fails at its statement timeout (`DatabaseError.timedOut`) while everything
    /// else works.
    var failingMaintenance = false
    /// `apps()` answers with the list as it was when called, this much later.
    var appsDelay: Duration = .zero
    var closedSessions: [(deviceID: DeviceID, before: Int64, at: Date)] = []
    var vanishedCloses: [(deviceID: DeviceID, session: Int64, keeping: Set<Int64>, startedBefore: Date, at: Date)] = []
    /// Number of `countVanishedRequests` calls.
    var vanishedCounts = 0
    /// Number of request upsert statements (refused ones included).
    var requestWriteCalls = 0
    /// The device of every `upsertDevice` call.
    var deviceUpserts: [DeviceID] = []
    /// Asked on every `upsertDevice` call; its answers go to `onlineWhenRegistered`.
    var onUpsertDevice: (@Sendable () async -> Bool)?
    var onlineWhenRegistered: [Bool] = []
    var knownHostsCalls = 0
    /// Returned by `alerts(after:excluding:)` (alerts other Macs wrote).
    var otherMacAlerts: [AlertItem] = []
    var chains: [(chain: [ProcessLink], appID: AppID?, deviceID: DeviceID)] = []
    /// Every request row written, in order (spool replays included).
    var writes: [RequestRecord] = []
    var rows: [RequestKey: RequestRecord] = [:]
    var rowIDs: [RequestKey: Int64] = [:]
    var appHosts: [String: AppHost] = [:]
    var touches: [AppHost] = []
    var sources: [HostSourceTouch] = []
    var alertsInserted: [AlertItem] = []
    var known: [AppID: Set<String>] = [:]
    var appList: [MonitoredApp] = []
    var probeSessionsSaved: [ProbeSession] = []
    var egressSamples: [EgressSample] = []
    var egressChangeList: [EgressChange] = []
    var ipInfoCache: [String: GeoInfo] = [:]
    /// Rows `requestsWritten(after:)` pages through (other Macs' writes), each with its `rowID` and `writtenAt`.
    var writtenRows: [RequestRecord] = []
    /// The server clock `requestWritePosition()` reports.
    var serverNow = Date(timeIntervalSince1970: 1_800_000_000)
    /// The cursor of every `requestsWritten(after:)` call.
    var writtenCursors: [RequestWriteCursor] = []
    /// Number of `requestsWritten(after:)` calls.
    var writtenPages: Int { writtenCursors.count }
    private var nextID: Int64 = 1

    func setFailing(_ on: Bool) { failing = on }
    func setOnUpsertDevice(_ hook: @escaping @Sendable () async -> Bool) { onUpsertDevice = hook }
    func setRefusingEverything(_ on: Bool) { refusingEverything = on }
    func setEnforcesForeignKeys(_ on: Bool) { enforcesForeignKeys = on }
    func setEnforcesDeviceKeys(_ on: Bool) { enforcesDeviceKeys = on }
    /// Pretends `device`'s row exists (registered by an earlier run).
    func register(_ device: DeviceID) { registeredDevices.insert(device) }
    func setRefusedHosts(_ hosts: Set<String>) { refusedHosts = hosts }
    func setStallingRequests(_ on: Bool) { stallingRequests = on }
    func setTimingOutRequests(_ on: Bool) { timingOutRequests = on }
    func setStallingProbeSaves(_ on: Bool) { stallingProbeSaves = on }
    func setFailingMaintenance(_ on: Bool) { failingMaintenance = on }
    /// `mergeDevice` fails at its statement timeout while set.
    func setFailingMerges(_ on: Bool) { mergeFailure = on ? .timedOut(.statement(PostgresDatabase.maintenanceTimeout)) : nil }
    func setMergeFailure(_ error: DatabaseError?) { mergeFailure = error }
    func setMergeRefusal(_ refusal: DeviceMergeResult.Refusal?, for device: DeviceID) { mergeRefusals[device] = refusal }
    func setHistorySharers(_ devices: [DeviceID]) { historySharers = devices }
    func setAppsDelay(_ delay: Duration) { appsDelay = delay }
    func setApps(_ apps: [MonitoredApp]) { appList = apps }
    func setOtherMacAlerts(_ alerts: [AlertItem]) { otherMacAlerts = alerts }
    func setKnown(_ value: [AppID: Set<String>]) { known = value }
    /// Adds or replaces (by key) a row another Mac wrote.
    func write(_ row: RequestRecord) {
        writtenRows.removeAll { $0.key == row.key }
        writtenRows.append(row)
    }
    func setServerNow(_ date: Date) { serverNow = date }
    /// Pretends a row was written before (e.g. by an earlier run).
    func preinsertRow(_ row: RequestRecord) {
        rowIDs[row.key] = newID()
        rows[row.key] = row
    }
    /// Pretends another Mac already inserted this inventory entry.
    func preinsert(_ host: AppHost) { appHosts["\(host.appID.uuidString)|\(host.id)"] = host }

    private func check() throws { if failing { throw DatabaseError.unreachable("test") } }
    /// The foreign key `app_id → apps(id)`.
    private func checkApp(_ appID: AppID?) throws {
        guard enforcesForeignKeys, let appID, !appList.contains(where: { $0.id == appID }) else { return }
        throw DatabaseError.query("insert or update violates foreign key constraint (app \(appID))")
    }
    /// The foreign key `device_id → devices(id)`.
    private func checkDevice(_ deviceID: DeviceID) throws {
        guard enforcesDeviceKeys, !registeredDevices.contains(deviceID) else { return }
        throw DatabaseError.query("insert or update violates foreign key constraint \"requests_device_id_fkey\" (device \(deviceID))")
    }
    private func newID() -> Int64 {
        defer { nextID += 1 }
        return nextID
    }

    func connect() async throws { try check() }
    func migrate() async throws -> Int { try check(); return 1 }
    func ping() async throws -> (roundTrip: Duration, serverVersion: String) { try check(); return (.milliseconds(2), "18.3") }
    func schemaVersion() async throws -> Int { 1 }
    func tableNames() async throws -> [String] { [] }

    func upsertDevice(_ device: Device) async throws {
        try check()
        deviceUpserts.append(device.id)
        upsertedDevices.append(device)
        registeredDevices.insert(device.id)
        if let onUpsertDevice { onlineWhenRegistered.append(await onUpsertDevice()) }
    }
    func devices() async throws -> [Device] { deviceList }
    func setDevices(_ devices: [Device]) { deviceList = devices }
    func renameDevice(_ id: DeviceID, name: String) async throws {}
    /// Moves `from`'s request rows to `into`; a row `into` already has is dropped.
    func mergeDevice(_ from: DeviceID, into: DeviceID, idleFor: Duration?) async throws -> DeviceMergeResult {
        try check()
        deviceMerges.append((from, into, idleFor, writes.count))
        if let mergeFailure { throw mergeFailure }
        guard from != into else { return DeviceMergeResult() }
        if let refusal = mergeRefusals[from] { return DeviceMergeResult(refusal: refusal) }
        var result = DeviceMergeResult(merged: registeredDevices.contains(from) || rows.keys.contains { $0.deviceID == from })
        for (key, row) in rows where key.deviceID == from {
            var moved = row
            moved.key.deviceID = into
            rows[key] = nil
            let id = rowIDs.removeValue(forKey: key)
            if rows[moved.key] == nil {
                rows[moved.key] = moved
                rowIDs[moved.key] = id
                result.requestsMoved += 1
            } else {
                result.duplicatesDropped += 1
            }
        }
        registeredDevices.remove(from)
        deviceList.removeAll { $0.id == from }
        historySharers.removeAll { $0 == from }
        return result
    }
    func devicesSharingHistory(with device: DeviceID, sessions: [Int64]) async throws -> [DeviceID] {
        try check()
        historyLookups.append((device, sessions))
        return historySharers.filter { $0 != device }
    }

    func apps() async throws -> [MonitoredApp] {
        try check()
        let snapshot = appList
        if appsDelay > .zero { try await Task.sleep(for: appsDelay) }
        return snapshot
    }
    func insertApp(_ app: MonitoredApp) async throws { try check(); appList.append(app) }
    func updateApp(_ app: MonitoredApp) async throws {
        try check()
        if let index = appList.firstIndex(where: { $0.id == app.id }) { appList[index] = app }
    }
    func deleteApp(_ id: AppID) async throws { try check(); appList.removeAll { $0.id == id } }
    func setInstalled(appID: AppID, deviceID: DeviceID, installed: Bool) async throws {}
    func installs() async throws -> [AppID: [DeviceID: Bool]] { [:] }
    func appStats(_ id: AppID, scope: DeviceScope) async throws -> AppStats { AppStats() }
    func countRequests(inBundle bundlePath: String) async throws -> Int64 { 0 }
    func backfill(appID: AppID, bundlePath: String) async throws -> Int64 { 0 }

    func upsertRequests(_ rows: [RequestRecord]) async throws -> [RequestKey: Int64] {
        try await upsertRequestsCountingInserts(rows).ids
    }
    func upsertRequestsCountingInserts(_ rows: [RequestRecord]) async throws -> RequestUpsertResult {
        try check()
        requestWriteCalls += 1
        if stallingRequests {
            try await Task.sleep(for: Self.stallLimit)
            throw DatabaseError.timedOut(.noReply(target: nil, within: Self.stallLimit))
        }
        if timingOutRequests { throw DatabaseError.timedOut(.statement(PostgresDatabase.SessionLimits.writer.statement)) }
        if refusingEverything { throw DatabaseError.query("could not extend file: No space left on device") }
        for row in rows {
            if refusedHosts.contains(row.host) { throw DatabaseError.query("value too long for \(row.host)") }
            try checkApp(row.appID)
            try checkDevice(row.key.deviceID)
        }
        var result: [RequestKey: Int64] = [:]
        var inserted = 0
        for row in rows {
            if rowIDs[row.key] == nil { inserted += 1 }
            let id = rowIDs[row.key] ?? newID()
            rowIDs[row.key] = id
            self.rows[row.key] = row
            writes.append(row)
            result[row.key] = id
        }
        return RequestUpsertResult(ids: result, inserted: inserted)
    }
    func closeActiveRequests(deviceID: DeviceID, before session: Int64, at date: Date) async throws -> Int64 {
        try check()
        closedSessions.append((deviceID, session, date))
        if failingMaintenance { throw DatabaseError.timedOut(.statement(PostgresDatabase.sessionCloseTimeout)) }
        var closed: Int64 = 0
        for (key, row) in rows where key.deviceID == deviceID && key.session < session && row.state == .active {
            var done = row
            done.state = .completed
            done.completedAt = done.completedAt ?? date
            rows[key] = done
            closed += 1
        }
        return closed
    }
    func closeVanishedRequests(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date, at date: Date) async throws -> Int64 {
        try check()
        let keeping = Set(surgeIDs)
        vanishedCloses.append((deviceID, session, keeping, startedBefore, date))
        if failingMaintenance { throw DatabaseError.timedOut(.statement(PostgresDatabase.sessionCloseTimeout)) }
        var closed: Int64 = 0
        for (key, row) in rows where key.deviceID == deviceID && key.session == session && row.state == .active
            && !keeping.contains(key.surgeID) && row.startedAt < startedBefore {
            var done = row
            done.state = .completed
            done.completedAt = done.completedAt ?? date
            rows[key] = done
            closed += 1
        }
        return closed
    }
    func countVanishedRequests(deviceID: DeviceID, session: Int64, keeping surgeIDs: [Int64], startedBefore: Date) async throws -> Int64 {
        try check()
        vanishedCounts += 1
        if failingMaintenance { throw DatabaseError.unreachable("canceling statement due to statement timeout") }
        let keeping = Set(surgeIDs)
        return Int64(rows.count { key, row in
            key.deviceID == deviceID && key.session == session && row.state == .active && !keeping.contains(key.surgeID)
                && row.startedAt < startedBefore
        })
    }
    func queryRequests(_ query: RequestQuery) async throws -> RequestPage { RequestPage(rows: [], totalCount: 0, elapsed: .zero) }
    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram { Histogram(start: .now, end: .now, counts: []) }
    func requestsWritten(after cursor: RequestWriteCursor, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] {
        try check()
        writtenCursors.append(cursor)
        let after = writtenRows.compactMap { row in RequestWriteCursor(row).map { ($0, row) } }
            .filter { $0.0 > cursor && $0.1.deviceID != excluding }
            .sorted { $0.0 < $1.0 }
        return after.prefix(max(0, limit)).map(\.1)
    }
    func requestWritePosition() async throws -> RequestWriteCursor {
        try check()
        return RequestWriteCursor(updatedAt: serverNow, rowID: 0)
    }
    func distinctPolicies(since: Date?) async throws -> [String] { [] }
    func countRequests(since: Date, scope: DeviceScope) async throws -> Int64 { Int64(rows.count) }
    func estimatedRequestCount() async throws -> Int64 { Int64(rows.count) }

    func upsertProcessChain(deviceID: DeviceID, chain: [ProcessLink], appID: AppID?) async throws -> Int64? {
        try check()
        try checkApp(appID)
        chains.append((chain, appID, deviceID))
        return newID()
    }
    func processTree(appID: AppID, scope: DeviceScope) async throws -> [ProcessNode] { [] }

    func knownHosts() async throws -> [AppID: Set<String>] {
        try check()
        knownHostsCalls += 1
        return known
    }
    func insertAppHosts(_ hosts: [AppHost]) async throws -> [AppHost] {
        try check()
        for host in hosts { try checkApp(host.appID) }
        var won: [AppHost] = []
        for host in hosts {
            let key = "\(host.appID.uuidString)|\(host.id)"
            guard appHosts[key] == nil else { continue }
            appHosts[key] = host
            won.append(host)
        }
        return won
    }
    func touchAppHosts(_ hosts: [AppHost]) async throws {
        try check()
        // Unknown entries are ignored, like the UPDATE … FROM (VALUES …) join.
        touches.append(contentsOf: hosts.filter { host in !enforcesForeignKeys || appList.contains { $0.id == host.appID } })
    }
    func appHosts(_ appID: AppID, scope: DeviceScope) async throws -> [AppHost] { [] }
    func touchHostSources(_ sources: [HostSourceTouch]) async throws {
        try check()
        for source in sources { try checkApp(source.appID) }
        self.sources.append(contentsOf: sources)
    }
    func inventory(kind: HostKind?, search: String, scope: DeviceScope) async throws -> [InventoryEntry] { [] }
    func hostProcesses(kind: HostKind, value: String, appID: AppID, scope: DeviceScope) async throws -> [HostProcess] { [] }

    func ipInfo(_ ip: String) async throws -> GeoInfo? { ipInfoCache[ip] }
    func saveIPInfo(_ ip: String, geo: GeoInfo) async throws { ipInfoCache[ip] = geo }

    func insertAlerts(_ alerts: [AlertItem]) async throws -> [AlertItem] {
        try check()
        for alert in alerts { try checkApp(alert.appID) }
        let inserted = alerts.map { alert -> AlertItem in
            var a = alert
            a.id = newID()
            return a
        }
        alertsInserted.append(contentsOf: inserted)
        return inserted
    }
    func alerts(filter: AlertFilter, appID: AppID?, scope: DeviceScope, limit: Int) async throws -> [AlertItem] { alertsInserted }
    func alerts(after id: Int64, excluding: DeviceID?) async throws -> [AlertItem] {
        otherMacAlerts.filter { $0.id > id && $0.deviceID != excluding }
    }
    func unreadAlertCount(scope: DeviceScope) async throws -> Int { alertsInserted.filter(\.isUnread).count }
    func markAlertsRead(_ ids: [Int64]) async throws {}
    func markAllAlertsRead(appID: AppID?, scope: DeviceScope) async throws {}

    func saveProbeSession(_ session: ProbeSession) async throws {
        try check()
        if stallingProbeSaves {
            try await Task.sleep(for: Self.stallLimit)
            throw DatabaseError.timedOut(.noReply(target: nil, within: Self.stallLimit))
        }
        probeSessionsSaved.append(session)
    }
    func probeSessions(limit: Int) async throws -> [ProbeSession] { probeSessionsSaved }

    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws { try check(); egressSamples = samples }
    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample] { try check(); return egressSamples }
    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws {
        try check()
        var c = change
        c.id = newID()
        egressChangeList.insert(c, at: 0)
    }
    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange] { try check(); return egressChangeList }

    /// Every DNS answer written, in order.
    var dnsAnswersSaved: [DNSAnswer] = []
    func saveDNSAnswers(_ answers: [DNSAnswer]) async throws {
        try check()
        dnsAnswersSaved.append(contentsOf: answers)
    }

    /// Every proxy error written, in order.
    var proxyErrorsSaved: [ProxyNodeError] = []
    func saveProxyErrors(_ errors: [ProxyNodeError]) async throws {
        try check()
        proxyErrorsSaved.append(contentsOf: errors)
    }
}

/// Waits with a deadline in the capture tests: work that never finishes fails its test at once instead of hanging
/// the whole run (Swift Testing has no time limit by default, and awaiting a task ignores cancellation).
enum CaptureWait {
    /// Whether `work` finished within `timeout`. Work still running then is left to finish in the background.
    static func finishes(within timeout: Duration = .seconds(10), _ work: @escaping @Sendable () async -> Void) async -> Bool {
        await CaptureTimeout.value(within: timeout) { () async -> Bool? in
            await work()
            return true
        } ?? false
    }
}

/// A temporary directory removed when the test ends.
final class CaptureTempDirectory {
    let url: URL

    init() {
        url = FileManager.default.temporaryDirectory.appending(path: "tidemark-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}
