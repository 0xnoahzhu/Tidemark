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
        var dnsCache: [String: [String]] = [:]
        var geo: [String: SurgeGeoIP] = [:]
        var externalIPs: [String: String] = [:]
        var latencies: [String: Int] = [:]
        var groups: [SurgePolicyGroup] = []
        var environment = SurgeEnvironment(proxyMode: 2, globalPolicy: nil, groupSelections: [:])
        var ruleMatch = SurgeRuleMatch(policy: "Proxy", rule: "FINAL")
        var httpPort = 6152
        var startTime: Double = 1_792_000_000
        var recent: [SurgeRequest] = []
        var dnsLookups: [String] = []
        var externalIPCalls: [String] = []
    }

    let endpoint: SurgeEndpoint
    let state = Mutex(State())

    init(remote: String? = nil) {
        endpoint = SurgeEndpoint(cliPath: "/usr/bin/false", remote: remote, password: nil)
    }

    func update(_ body: (inout State) -> Void) { state.withLock { body(&$0) } }
    var snapshot: State { state.withLock { $0 } }

    func events() -> AsyncThrowingStream<SurgeEvent, Error> { AsyncThrowingStream { $0.finish() } }
    func status() async throws -> SurgeStatus {
        SurgeStatus(version: "6.10.0", build: nil, profile: nil, mode: nil, globalPolicy: nil, deviceName: nil, deviceIdentifier: nil,
                    controllerProtocol: 25, startTime: snapshot.startTime, uptime: nil, features: nil)
    }
    func environment() async throws -> SurgeEnvironment { snapshot.environment }
    func recentRequests() async throws -> [SurgeRequest] { snapshot.recent }
    func activeRequests() async throws -> [SurgeRequest] { [] }
    func dnsLookup(_ domain: String) async throws -> SurgeDNSLookup {
        let ips = state.withLock { s -> [String]? in
            s.dnsLookups.append(domain)
            return s.dns[domain]
        }
        guard let ips else { throw SurgeError.commandFailed(command: "dns lookup", message: "NXDOMAIN") }
        return SurgeDNSLookup(domain: domain, server: nil, path: nil, v4Addresses: ips.filter(HostName.isIPv4),
                              v6Addresses: ips.filter { !HostName.isIPv4($0) }, durationMs: 1, expiresIn: 0)
    }
    func dnsCache() async throws -> [String: [String]] { snapshot.dnsCache }
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
}

/// In-memory database that records what the engine writes. `failing` makes every write throw
/// `DatabaseError.unreachable`.
actor CaptureFakeDatabase: TidemarkDatabase {
    var failing = false
    var chains: [(chain: [ProcessLink], appID: AppID?)] = []
    /// Every request row written, in order (spool replays included).
    var writes: [RequestRecord] = []
    var rows: [RequestKey: RequestRecord] = [:]
    var rowIDs: [RequestKey: Int64] = [:]
    var appHosts: [String: AppHost] = [:]
    var touches: [AppHost] = []
    var sources: [HostSourceTouch] = []
    var alertsInserted: [AlertItem] = []
    var known: [AppID: Set<String>] = [:]
    var mutesList: [String] = []
    var probeSessionsSaved: [ProbeSession] = []
    var egressSamples: [EgressSample] = []
    var egressChangeList: [EgressChange] = []
    var ipInfoCache: [String: GeoInfo] = [:]
    private var nextID: Int64 = 1

    func setFailing(_ on: Bool) { failing = on }
    func setKnown(_ value: [AppID: Set<String>]) { known = value }
    /// Pretends another Mac already inserted this inventory entry.
    func preinsert(_ host: AppHost) { appHosts["\(host.appID.uuidString)|\(host.id)"] = host }

    private func check() throws { if failing { throw DatabaseError.unreachable("test") } }
    private func newID() -> Int64 {
        defer { nextID += 1 }
        return nextID
    }

    func connect() async throws { try check() }
    func migrate() async throws -> Int { try check(); return 1 }
    func ping() async throws -> (roundTrip: Duration, serverVersion: String) { try check(); return (.milliseconds(2), "18.3") }
    func schemaVersion() async throws -> Int { 1 }
    func tableNames() async throws -> [String] { [] }

    func upsertDevice(_ device: Device) async throws { try check() }
    func devices() async throws -> [Device] { [] }
    func renameDevice(_ id: DeviceID, name: String) async throws {}

    func apps() async throws -> [MonitoredApp] { [] }
    func insertApp(_ app: MonitoredApp) async throws { try check() }
    func updateApp(_ app: MonitoredApp) async throws { try check() }
    func deleteApp(_ id: AppID) async throws { try check() }
    func setInstalled(appID: AppID, deviceID: DeviceID, installed: Bool) async throws {}
    func installs() async throws -> [AppID: [DeviceID: Bool]] { [:] }
    func appStats(_ id: AppID, scope: DeviceScope) async throws -> AppStats { AppStats() }
    func countRequests(inBundle bundlePath: String) async throws -> Int64 { 0 }
    func backfill(appID: AppID, bundlePath: String) async throws -> Int64 { 0 }

    func upsertRequests(_ rows: [RequestRecord]) async throws -> [RequestKey: Int64] {
        try check()
        var result: [RequestKey: Int64] = [:]
        for row in rows {
            let id = rowIDs[row.key] ?? newID()
            rowIDs[row.key] = id
            self.rows[row.key] = row
            writes.append(row)
            result[row.key] = id
        }
        return result
    }
    func queryRequests(_ query: RequestQuery) async throws -> RequestPage { RequestPage(rows: [], totalCount: 0, elapsed: .zero) }
    func histogram(_ query: RequestQuery, buckets: Int) async throws -> Histogram { Histogram(start: .now, end: .now, counts: []) }
    func requestsWritten(after cursor: Date, excluding: DeviceID?, limit: Int) async throws -> [RequestRecord] { [] }
    func distinctPolicies(since: Date?) async throws -> [String] { [] }
    func countRequests(since: Date, scope: DeviceScope) async throws -> Int64 { Int64(rows.count) }
    func estimatedRequestCount() async throws -> Int64 { Int64(rows.count) }
    func deleteRequests(olderThan: Date) async throws -> Int64 { 0 }

    func upsertProcessChain(deviceID: DeviceID, chain: [ProcessLink], appID: AppID?) async throws -> Int64? {
        try check()
        chains.append((chain, appID))
        return newID()
    }
    func processTree(appID: AppID, scope: DeviceScope) async throws -> [ProcessNode] { [] }

    func knownHosts() async throws -> [AppID: Set<String>] { try check(); return known }
    func insertAppHosts(_ hosts: [AppHost]) async throws -> [AppHost] {
        try check()
        var won: [AppHost] = []
        for host in hosts {
            let key = "\(host.appID.uuidString)|\(host.id)"
            guard appHosts[key] == nil else { continue }
            appHosts[key] = host
            won.append(host)
        }
        return won
    }
    func touchAppHosts(_ hosts: [AppHost]) async throws { try check(); touches.append(contentsOf: hosts) }
    func appHosts(_ appID: AppID, scope: DeviceScope) async throws -> [AppHost] { [] }
    func touchHostSources(_ sources: [HostSourceTouch]) async throws { try check(); self.sources.append(contentsOf: sources) }
    func inventory(kind: HostKind?, search: String, scope: DeviceScope) async throws -> [InventoryEntry] { [] }

    func ipInfo(_ ip: String) async throws -> GeoInfo? { ipInfoCache[ip] }
    func saveIPInfo(_ ip: String, geo: GeoInfo) async throws { ipInfoCache[ip] = geo }

    func insertAlerts(_ alerts: [AlertItem]) async throws -> [AlertItem] {
        try check()
        let inserted = alerts.map { alert -> AlertItem in
            var a = alert
            a.id = newID()
            return a
        }
        alertsInserted.append(contentsOf: inserted)
        return inserted
    }
    func alerts(filter: AlertFilter, appID: AppID?, scope: DeviceScope, limit: Int) async throws -> [AlertItem] { alertsInserted }
    func alerts(after id: Int64, excluding: DeviceID?) async throws -> [AlertItem] { [] }
    func unreadAlertCount(scope: DeviceScope) async throws -> Int { alertsInserted.filter(\.isUnread).count }
    func markAlertsRead(_ ids: [Int64]) async throws {}
    func markAllAlertsRead(appID: AppID?) async throws {}
    func deleteAlert(_ id: Int64) async throws { alertsInserted.removeAll { $0.id == id } }
    func mutes() async throws -> [String] { mutesList }
    func addMute(_ pattern: String) async throws { mutesList.append(pattern) }
    func removeMute(_ pattern: String) async throws { mutesList.removeAll { $0 == pattern } }

    func saveProbeSession(_ session: ProbeSession) async throws { try check(); probeSessionsSaved.append(session) }
    func probeSessions(limit: Int) async throws -> [ProbeSession] { probeSessionsSaved }
    func deleteProbeSession(_ id: UUID) async throws { probeSessionsSaved.removeAll { $0.id == id } }

    func hostInsight(_ host: String, language: String) async throws -> HostInsight? { nil }
    func saveHostInsight(_ insight: HostInsight) async throws {}

    func saveEgressSamples(_ samples: [EgressSample], deviceID: DeviceID) async throws { try check(); egressSamples = samples }
    func latestEgress(deviceID: DeviceID) async throws -> [EgressSample] { try check(); return egressSamples }
    func insertEgressChange(_ change: EgressChange, deviceID: DeviceID) async throws {
        try check()
        var c = change
        c.id = newID()
        egressChangeList.insert(c, at: 0)
    }
    func egressChanges(deviceID: DeviceID, limit: Int) async throws -> [EgressChange] { try check(); return egressChangeList }
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
