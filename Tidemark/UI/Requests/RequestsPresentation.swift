import Foundation

/// View-independent logic of the Requests page: live filtering, status, attribution and freshness.
enum RequestsPresentation {
    /// Rows younger than this get the "fresh" background in the live table.
    static let freshInterval: TimeInterval = 1.4

    /// "Open <App>" on a request shows the app's Domains & IPs, as in the design and like a notification's View.
    static let openAppTab: AppTab = .inventory

    /// Live rows for the current Mac scope and filter text.
    ///
    /// The filter matches host, remote IP, process and app name, case-insensitively.
    static func liveRows(
        _ rows: [RequestRecord],
        scope: DeviceScope,
        search: String,
        identity: (RequestRecord) -> AppIdentity
    ) -> [RequestRecord] {
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if case .all = scope, needle.isEmpty { return rows }
        return rows.filter { record in
            guard scope.includes(record.deviceID) else { return false }
            return needle.isEmpty || matches(record, needle: needle, appName: identity(record).name)
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

    static func isFresh(_ record: RequestRecord, now: Date) -> Bool {
        now.timeIntervalSince(record.startedAt) < freshInterval
    }

    // MARK: Status

    /// The inspector's status chip. As in the design, a request Surge failed or rejected reads "Failed" and a
    /// tunnel reads "Tunnel" whether or not it is still open. A connection that ended with an error reads how it
    /// ended, as the journey's Ended stage and History's "Ended with an error" tell it, though Surge marked it
    /// completed (as it marks resets and broken pipes).
    enum Status: Equatable {
        case tunnel
        case failed
        /// Surge's words for the error the connection ended with.
        case ended(String)
    }

    /// Nil for any other request: the design's chip reads its HTTP status (`200 OK`), which Surge does not
    /// report, so no chip is shown rather than a wording the design does not have.
    static func status(of record: RequestRecord) -> Status? {
        switch record.state {
        case .failed, .rejected:
            return .failed
        case .active, .completed:
            if let reason = RequestsJourney.endReason(of: record), RequestEndReason.isError(reason) { return .ended(reason) }
            return record.isTunnel ? .tunnel : nil
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

    /// Pretty-printed JSON of a record for "Copy as JSON".
    static func json(for record: RequestRecord) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(record) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}

extension RequestsPresentation {
    /// Shown for the app and the process of a request that nothing identifies.
    @MainActor
    static var unknownProcessLabel: String { tr("Unknown process", "Requests") }

    /// The status chip's text: `Tunnel`, `Failed`, or the ending in the journey's words (`Connection reset`).
    @MainActor
    static func label(of status: Status) -> String {
        switch status {
        case .tunnel: tr("Tunnel", "Requests")
        case .failed: tr("Failed", "Requests")
        case .ended(let reason): RequestsJourneyLabels.endReason(reason)
        }
    }
}

extension AppModel {
    /// `appIdentity(for:)` as the Requests page shows it: an unattributed request reads "Unknown process" in
    /// the current language instead of the model's English placeholder.
    func requestsIdentity(for record: RequestRecord) -> AppIdentity {
        RequestsPresentation.displayIdentity(appIdentity(for: record), for: record, unknownName: RequestsPresentation.unknownProcessLabel)
    }
}
