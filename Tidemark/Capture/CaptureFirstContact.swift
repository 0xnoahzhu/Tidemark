import Foundation

/// Per-app inventory index used to detect first contact without a database round trip.
///
/// `TidemarkDatabase.knownHosts()` returns strings per app; entries may be bare values (`api.github.com`,
/// `104.18.19.125`) or prefixed with their kind like `AppHost.id` (`domain:api.github.com`, `ip:104.18.19.125`).
/// Both forms are accepted.
struct CaptureKnownHosts: Sendable {
    private(set) var domains: [AppID: Set<String>] = [:]
    private(set) var sites: [AppID: Set<String>] = [:]
    private(set) var ips: [AppID: Set<String>] = [:]

    init() {}

    init(loaded: [AppID: Set<String>], classifier: any SiteClassifying) {
        for (appID, values) in loaded {
            for raw in values {
                let (kind, value) = Self.decode(raw)
                insert(kind: kind, value: value, appID: appID, site: kind == .domain ? classifier.site(for: value) : nil)
            }
        }
    }

    func containsDomain(_ host: String, appID: AppID) -> Bool { domains[appID]?.contains(host.lowercased()) ?? false }
    func containsSite(_ site: String, appID: AppID) -> Bool { sites[appID]?.contains(site.lowercased()) ?? false }
    func containsIP(_ ip: String, appID: AppID) -> Bool { ips[appID]?.contains(ip.lowercased()) ?? false }

    mutating func insert(kind: HostKind, value: String, appID: AppID, site: String?) {
        let value = value.lowercased()
        switch kind {
        case .domain:
            domains[appID, default: []].insert(value)
            if let site { sites[appID, default: []].insert(site.lowercased()) }
        case .ip:
            ips[appID, default: []].insert(value)
        }
    }

    mutating func remove(appID: AppID) {
        domains[appID] = nil
        sites[appID] = nil
        ips[appID] = nil
    }

    /// Splits `domain:x` / `ip:x`, or infers the kind of a bare value.
    static func decode(_ raw: String) -> (HostKind, String) {
        if raw.hasPrefix("domain:") { return (.domain, String(raw.dropFirst(7))) }
        if raw.hasPrefix("ip:") { return (.ip, String(raw.dropFirst(3))) }
        return (HostName.isIPAddress(raw) ? .ip : .domain, raw)
    }
}

/// An alert waiting for its inventory entry to win the cross-Mac insert race.
struct CaptureAlertDraft: Hashable, Sendable {
    var appID: AppID
    var kind: HostKind
    var scope: AlertScope
    /// Host for domain alerts, IP for IP alerts.
    var value: String
    var site: String?
    var host: String?
    var ip: String?
    var geo: GeoInfo?
    var processName: String
    var isDirect: Bool
    var requestKey: RequestKey

    /// `AppHost.id` of the inventory entry that must be new for the alert to fire.
    var hostID: String { "\(kind.rawValue):\(value)" }

    func item(deviceID: DeviceID, requestRowID: Int64?, createdAt: Date) -> AlertItem {
        AlertItem(
            id: 0, deviceID: deviceID, appID: appID, kind: kind, scope: scope, value: value, site: site,
            host: host, ip: ip, geo: geo, processName: processName, isDirect: isDirect,
            requestRowID: requestRowID, createdAt: createdAt, readAt: nil
        )
    }
}

/// What one request revealed for its monitored app.
struct CaptureFirstContact: Hashable, Sendable {
    /// New inventory entries (a domain and/or an IP).
    var hosts: [AppHost]
    /// Known entries to bump (`last_seen`, `request_count`, policy, hosts).
    var touches: [AppHost]
    /// At most one alert per request: a new domain wins over its new IP.
    var alert: CaptureAlertDraft?
}

/// First-contact rules from ARCHITECTURE.md › First contact and alerts.
enum CaptureFirstContactDetector {
    /// Evaluates a request attributed to a monitoring app and records any new host/IP in `known`
    /// (optimistically, so later requests don't fire twice while the database insert is in flight).
    static func evaluate(
        record: RequestRecord,
        app: MonitoredApp,
        known: inout CaptureKnownHosts,
        classifier: any SiteClassifying,
        mutes: [String]
    ) -> CaptureFirstContact {
        var result = CaptureFirstContact(hosts: [], touches: [], alert: nil)
        let host = record.host.lowercased()
        let isIPLiteral = HostName.isIPAddress(host)
        let ip = (isIPLiteral ? host : record.remoteIP?.lowercased())
        let policy = record.policyPath.isEmpty ? nil : record.policyDisplay
        let process = record.processName
        let seen = record.startedAt

        // 1. Domain
        if !isIPLiteral, !host.isEmpty {
            let site = classifier.site(for: host).lowercased()
            let entry = AppHost(
                appID: app.id, kind: .domain, value: host, site: site, firstSeen: seen, lastSeen: seen,
                requestCount: 1, processName: process, policy: policy, geo: record.geo, isDirect: false, hosts: []
            )
            if known.containsDomain(host, appID: app.id) {
                result.touches.append(entry)
            } else {
                let scope: AlertScope = known.containsSite(site, appID: app.id) ? .host : .site
                known.insert(kind: .domain, value: host, appID: app.id, site: site)
                result.hosts.append(entry)
                let wanted = app.alertRule == .anyHost || (app.alertRule == .site && scope == .site)
                if wanted, !AlertState.matches(host, patterns: mutes) {
                    result.alert = CaptureAlertDraft(
                        appID: app.id, kind: .domain, scope: scope, value: host, site: site, host: host, ip: ip,
                        geo: record.geo, processName: process, isDirect: false, requestKey: record.key
                    )
                }
            }
        }

        // 2. IP
        if let ip {
            let entry = AppHost(
                appID: app.id, kind: .ip, value: ip, site: nil, firstSeen: seen, lastSeen: seen, requestCount: 1,
                processName: process, policy: policy, geo: record.geo, isDirect: isIPLiteral,
                hosts: isIPLiteral ? [] : [host]
            )
            if known.containsIP(ip, appID: app.id) {
                result.touches.append(entry)
            } else {
                known.insert(kind: .ip, value: ip, appID: app.id, site: nil)
                result.hosts.append(entry)
                let muted = AlertState.matches(ip, patterns: mutes) || (!isIPLiteral && AlertState.matches(host, patterns: mutes))
                if result.alert == nil, app.alertNewIP, !muted {
                    result.alert = CaptureAlertDraft(
                        appID: app.id, kind: .ip, scope: .ip, value: ip, site: nil, host: isIPLiteral ? nil : host, ip: ip,
                        geo: record.geo, processName: process, isDirect: isIPLiteral, requestKey: record.key
                    )
                }
            }
        }
        return result
    }
}
