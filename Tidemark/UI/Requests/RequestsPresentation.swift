import Foundation

/// View-independent logic of the Requests page: live filtering, status, attribution and freshness.
enum RequestsPresentation {
    /// Rows younger than this get the "fresh" background in the live table.
    static let freshInterval: TimeInterval = 1.4

    /// "Open <App>" on a request shows the app's Domains & IPs, as in the design and like a notification's View.
    static let openAppTab: AppTab = .inventory

    /// Live rows for the current Mac scope, filter text and Requests view preferences.
    ///
    /// The filter matches host, remote IP, process and app name, case-insensitively.
    static func liveRows(
        _ rows: [RequestRecord],
        scope: DeviceScope,
        search: String,
        monitoredOnly: Bool = false,
        hideAppleServices: Bool = false,
        identity: (RequestRecord) -> AppIdentity
    ) -> [RequestRecord] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if case .all = scope, needle.isEmpty, !monitoredOnly, !hideAppleServices { return rows }
        return rows.filter { record in
            guard scope.includes(record.deviceID) else { return false }
            if hideAppleServices, isAppleService(record) { return false }
            if monitoredOnly || !needle.isEmpty {
                let app = identity(record)
                if monitoredOnly, !app.isMonitored { return false }
                if !needle.isEmpty, !matches(record, needle: needle, appName: app.name) { return false }
            }
            return true
        }
    }

    /// `needle` must already be lowercased.
    static func matches(_ record: RequestRecord, needle: String, appName: String) -> Bool {
        if record.host.lowercased().contains(needle) { return true }
        if let ip = record.remoteIP, ip.lowercased().contains(needle) { return true }
        if let process = processName(of: record), process.lowercased().contains(needle) { return true }
        return appName.lowercased().contains(needle)
    }

    // MARK: Unknown processes

    /// The process that sent the request (leaf of the chain, else the executable's name); nil when Surge
    /// reported neither a chain nor a path (QUIC / UDP flows without a PID). Unlike
    /// `RequestRecord.processName` it never returns the untranslated "Unknown" placeholder.
    static func processName(of record: RequestRecord) -> String? {
        if let leaf = record.chain.last, !leaf.name.isEmpty { return leaf.name }
        if let path = record.processPath, !path.isEmpty {
            let name = URL(fileURLWithPath: path).lastPathComponent
            return name.isEmpty ? nil : name
        }
        return nil
    }

    /// `true` when nothing identifies who sent the request: no monitored app, no bundle and no process.
    static func isUnattributed(_ record: RequestRecord, identity: AppIdentity) -> Bool {
        identity.appID == nil && (identity.bundlePath ?? "").isEmpty && record.chain.isEmpty && processName(of: record) == nil
    }

    /// `identity` for display: an unattributed request is shown as `unknownName` with a "?" tile instead of
    /// the model's English "Unknown" placeholder.
    static func displayIdentity(_ identity: AppIdentity, for record: RequestRecord, unknownName: String) -> AppIdentity {
        guard isUnattributed(record, identity: identity) else { return identity }
        return AppIdentity(name: unknownName, bundlePath: nil, letter: "?", hue: nil, isMonitored: false, appID: nil)
    }

    /// Apple system daemons and Apple-operated hosts (Settings › Requests › Hide Apple services).
    static func isAppleService(_ record: RequestRecord) -> Bool {
        let systemPrefixes = ["/System/", "/usr/libexec/", "/usr/sbin/", "/Library/Apple/"]
        if let path = record.chain.first?.path ?? record.processPath, systemPrefixes.contains(where: path.hasPrefix) {
            return true
        }
        let host = record.host.lowercased()
        return appleDomains.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    private static let appleDomains = [
        "apple.com", "icloud.com", "icloud-content.com", "apple-cloudkit.com", "mzstatic.com", "aaplimg.com",
        "apple-dns.net", "cdn-apple.com", "apple.news", "itunes.com", "push.apple.com",
    ]

    static func isFresh(_ record: RequestRecord, now: Date) -> Bool {
        now.timeIntervalSince(record.startedAt) < freshInterval
    }

    // MARK: Status

    /// The inspector's status chip.
    enum Status: Equatable {
        case active
        case tunnel
        case completed
        case failed
        case rejected

        var isError: Bool { self == .failed || self == .rejected }
    }

    static func status(of record: RequestRecord) -> Status {
        switch record.state {
        case .failed: .failed
        case .rejected: .rejected
        case .active: .active
        case .completed: record.isTunnel ? .tunnel : .completed
        }
    }

    // MARK: Attribution

    /// How a request was attributed to an app, for the sentence under the process chain.
    enum Attribution: Equatable {
        /// "Rolled up to Cursor through 2 parent processes"
        case rolledUp(app: String, parents: Int)
        /// "Matched Cursor directly"
        case direct(app: String)
        /// "Spotify is not monitored, so this only lands in the global log."
        case unmonitored(app: String)
    }

    /// Counts the hops from the leaf process up to the top-most process inside the app's bundle.
    static func attribution(for record: RequestRecord, app: MonitoredApp?, displayName: String) -> Attribution {
        guard let app, record.appID == app.id else { return .unmonitored(app: displayName) }
        let chain = record.chain
        guard chain.count > 1 else { return .direct(app: app.name) }
        let top = chain.firstIndex { link in link.path.map(app.contains(processPath:)) ?? false } ?? 0
        let parents = chain.count - 1 - top
        return parents > 0 ? .rolledUp(app: app.name, parents: parents) : .direct(app: app.name)
    }

    /// Process chain rows for the inspector, root first; falls back to the leaf when no chain was captured.
    /// The fallback's name is empty when the process is unknown (the view shows a localized placeholder).
    static func chainLinks(for record: RequestRecord) -> [ProcessLink] {
        if !record.chain.isEmpty { return record.chain }
        return [ProcessLink(name: processName(of: record) ?? "", pid: record.pid ?? 0, path: record.processPath, startTime: nil)]
    }

    /// `HostContext` handed to the on-device host insight. `appName` is nil when the sender is unknown.
    static func hostContext(for record: RequestRecord, appName: String?) -> HostContext {
        HostContext(
            host: record.host,
            appName: appName,
            processName: processName(of: record),
            port: record.port,
            ips: record.remoteIP.map { [$0] } ?? [],
            geo: record.geo,
            policy: record.policyPath.isEmpty ? nil : record.policyDisplay,
            firstSeen: record.isNew ? record.startedAt : nil,
            requestCount: nil
        )
    }

    /// Pretty-printed JSON of a record for "Copy as JSON".
    static func json(for record: RequestRecord) -> String {
        encode(record) ?? "{}"
    }

    /// One record as an object, several as an array.
    static func json(for records: [RequestRecord]) -> String {
        if records.count == 1 { return json(for: records[0]) }
        return encode(records) ?? "[]"
    }

    private static func encode(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(value) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}

extension RequestsPresentation {
    /// Shown for the app and the process of a request that nothing identifies.
    @MainActor
    static var unknownProcessLabel: String { tr("Unknown process", "Requests") }
}

extension AppModel {
    /// `appIdentity(for:)` as the Requests page shows it: an unattributed request reads "Unknown process" in
    /// the current language instead of the model's English placeholder.
    func requestsIdentity(for record: RequestRecord) -> AppIdentity {
        RequestsPresentation.displayIdentity(appIdentity(for: record), for: record, unknownName: RequestsPresentation.unknownProcessLabel)
    }
}
