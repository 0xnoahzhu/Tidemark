import Foundation

/// The errors proxy nodes report (`proxy-runtime-status`), stored in `proxy_errors` so a request that failed on its
/// way out can show what its proxy said. A node keeps only its last 15 errors, so the nodes that carry requests are
/// asked about once a minute: one short-lived surge-cli process a minute at most, never one per request.
extension CapturePipeline {
    /// Surge's built-in policies: no proxy node to ask.
    static let builtInPolicies: Set<String> = [
        "DIRECT", "REJECT", "REJECT-TINYGIF", "REJECT-DROP", "REJECT-NO-DROP", "CELLULAR", "CELLULAR-ONLY", "HYBRID", "NO-HYBRID",
    ]

    /// A request went through `policy` (its final policy) just now.
    func noteProxyNode(_ policy: String?, now: Date) {
        guard let policy, !policy.isEmpty, !Self.builtInPolicies.contains(policy.uppercased()) else { return }
        proxyNodesSeen[policy] = now
    }

    /// Asks one proxy node that carried requests within `proxyNodeRecency` for its errors, the one asked least
    /// recently, and queues the errors it had not listed before. Runs one surge-cli process at most: when the node's
    /// line hash is not known, that is `dump traffic` instead (at most every `proxyNodeRetryInterval`), and the node is
    /// asked the next time, by name when Surge listed no hash for it. A node Surge cannot report on waits
    /// `proxyNodeRetryInterval`, unless it was asked by a line hash read at least that long ago: a hash changes when
    /// the profile or a policy-path subscription does, so the node is asked by a fresh one first. The engine calls
    /// this once a minute.
    func pollProxyErrors(now: Date = .now) async {
        guard recording else { return }
        proxyNodesSeen = proxyNodesSeen.filter { now.timeIntervalSince($0.value) < proxyNodeRecency }
        proxyNodeRetryAt = proxyNodeRetryAt.filter { $0.value > now }
        let nodes = proxyNodesSeen.keys.filter { proxyNodeRetryAt[$0] == nil }
        guard let node = nodes.min(by: { (proxyNodesPolledAt[$0] ?? .distantPast, $0) < (proxyNodesPolledAt[$1] ?? .distantPast, $1) }) else { return }
        let surge = self.surge
        if proxyLineHashes[node] == nil, proxyLineHashesReadAt.map({ now.timeIntervalSince($0) >= proxyNodeRetryInterval }) ?? true {
            proxyLineHashesReadAt = now
            if let hashes = try? await surge.proxyLineHashes() { proxyLineHashes = hashes }
            return
        }
        let target = proxyLineHashes[node] ?? node
        proxyNodesPolledAt[node] = now
        guard let status = try? await surge.proxyRuntimeStatus(target) else {
            let stale = proxyLineHashes.removeValue(forKey: node) != nil
                && proxyLineHashesReadAt.map { now.timeIntervalSince($0) >= proxyNodeRetryInterval } ?? true
            if !stale { proxyNodeRetryAt[node] = now.addingTimeInterval(proxyNodeRetryInterval) }
            return
        }
        // Keyed by the node, not by how it was asked: a node asked by name before Surge listed its hash, or by a hash
        // that changed since, lists the same errors.
        let known = proxyErrorsListed[node] ?? []
        for error in status.errors where !known.contains(error) {
            buffer.add(proxyError: ProxyNodeError(deviceID: settings.deviceID, policy: node, lineHash: target, at: error.time,
                                                  targetHost: error.targetHost, error: error.message))
        }
        proxyErrorsListed[node] = Set(status.errors)
        // Nodes that went quiet are forgotten after a while; their errors are stored already.
        proxyNodesPolledAt = proxyNodesPolledAt.filter { now.timeIntervalSince($0.value) < 3_600 }
        proxyErrorsListed = proxyErrorsListed.filter { proxyNodesPolledAt[$0.key] != nil }
    }

    /// Surge reloaded its profile or started anew: the nodes' line hashes may have changed, and a node it could not
    /// report on may be back.
    func forgetProxyLineHashes() {
        proxyLineHashes = [:]
        proxyLineHashesReadAt = nil
        proxyNodeRetryAt = [:]
    }
}
