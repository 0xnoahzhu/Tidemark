import Foundation

/// What the inspector shows beside a request's own record: Tidemark's records joined to it (its DNS answer, proxy
/// errors, first-contact alert, probe session and the egress around it), the type of the proxy node it left through
/// and the network of the proxy server.
struct RequestsInspectorDetails {
    /// How long the selection rests before the details load: going through requests with a held arrow key asks
    /// PostgreSQL only for the one it stops on, and the inspector draws each request passed once.
    static let settleDelay: Duration = .milliseconds(150)

    /// The request these details are for.
    var key: RequestKey
    var related: RequestRelatedRecords?
    /// Why the related records could not be read.
    var failure: (any Error)?
    var nodeType: String?
    var proxyGeo: GeoInfo?

    /// What the details depend on: a live request gets them again once it has a row, a final policy and an end.
    struct Source: Hashable {
        var key: RequestKey
        var rowID: Int64?
        var finalPolicy: String?
        var remoteAddress: String?
        var completedAt: Date?

        init(_ record: RequestRecord) {
            key = record.key
            rowID = record.rowID
            finalPolicy = record.finalPolicy
            remoteAddress = record.remoteAddress
            completedAt = record.completedAt
        }
    }

    /// Loads the details of `record` and passes them to `update` as each part arrives: the related records first,
    /// which never wait for Surge, then the proxy server's network and the node's type.
    @MainActor
    static func load(for record: RequestRecord, model: AppModel, update: (RequestsInspectorDetails) -> Void) async {
        let database = model.database
        let surge = model.surge
        // Surge's policy groups are this Mac's, as they are now: they say nothing of another Mac's nodes.
        let node = record.deviceID == model.devices.thisDeviceID && RequestsJourney.isProxied(record) ? record.finalPolicy : nil
        async let related = database.relatedRecords(of: record)
        async let proxyGeo = loadProxyGeo(of: record, database: database)
        async let nodeType = loadNodeType(of: node, surge: surge)
        var details = RequestsInspectorDetails(key: record.key)
        do {
            details.related = try await related
        } catch {
            details.failure = error
        }
        update(details)
        if let geo = await proxyGeo {
            details.proxyGeo = geo
            update(details)
        }
        if let type = await nodeType {
            details.nodeType = type
            update(details)
        }
    }

    /// What Tidemark knows of the network of the proxy server the request went through.
    private static func loadProxyGeo(of record: RequestRecord, database: any TidemarkDatabase) async -> GeoInfo? {
        guard let server = RequestsJourney.proxyServer(of: record), HostName.isIPAddress(server) else { return nil }
        return try? await database.ipInfo(server)
    }

    /// The type of the proxy node named `node`.
    private static func loadNodeType(of node: String?, surge: any SurgeClient) async -> String? {
        guard let node else { return nil }
        return await RequestsNodeTypes.type(of: node, surge: surge)
    }
}

/// Proxy node types (`Hysteria 2`, `Snell`) by node name, from Surge's policy groups, for the inspector's route.
///
/// One `policy-group list` serves every request shown for ten minutes (after a failure, the next ask waits a minute),
/// so going through requests in the inspector asks Surge at most that often.
@MainActor
enum RequestsNodeTypes {
    static let lifetime: Duration = .seconds(600)
    static let retryInterval: Duration = .seconds(60)

    private static var types: [String: String] = [:]
    /// When the current list arrived, or when asking for it last failed.
    private static var asked: (at: ContinuousClock.Instant, failed: Bool)?
    private static var loading: Task<Void, Never>?

    /// The type of the node named `node`; nil when Surge's policy groups do not list it or Surge cannot be asked.
    static func type(of node: String, surge: any SurgeClient) async -> String? {
        if needsRefresh {
            let task = loading ?? Task {
                await refresh(surge: surge)
                loading = nil
            }
            loading = task
            await task.value
        }
        return types[node]
    }

    private static var needsRefresh: Bool {
        guard let asked else { return true }
        return ContinuousClock.now - asked.at >= (asked.failed ? retryInterval : lifetime)
    }

    private static func refresh(surge: any SurgeClient) async {
        do {
            let groups = try await CaptureTimeout.run(.seconds(5)) { try await surge.policyGroups() }
            types = nodeTypes(in: groups)
            asked = (.now, false)
        } catch {
            asked = (.now, true)
        }
    }

    /// Each node's (not group's) type by name.
    nonisolated static func nodeTypes(in groups: [SurgePolicyGroup]) -> [String: String] {
        var types: [String: String] = [:]
        for option in groups.flatMap(\.options) where option.isGroup != true {
            if let type = option.typeDescription, !type.isEmpty { types[option.name] = type }
        }
        return types
    }
}
