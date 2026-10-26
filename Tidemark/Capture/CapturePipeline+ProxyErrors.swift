import Foundation

/// The errors proxy nodes report (`proxy-runtime-status`), stored in `proxy_errors` so a request that failed on its
/// way out can show what its proxy said. A node keeps only its last 15 errors, so the nodes that carry requests are
/// asked about once a minute: a few short-lived surge-cli processes a minute at most, never one per request.
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

    /// Asks the proxy nodes that carried requests within `proxyNodeRecency` for their errors, the ones asked least
    /// recently first, and queues the errors each had not listed before. Runs `proxyPollProcesses` surge-cli processes
    /// at most, so with more busy nodes than that each is asked every few minutes. A node whose line hash is not known
    /// costs a `dump traffic` read first (at most every `proxyNodeRetryInterval`), and is asked by name when Surge
    /// lists no hash for it. The engine calls this once a minute.
    func pollProxyErrors(now: Date = .now) async {
        guard recording else { return }
        proxyNodesSeen = proxyNodesSeen.filter { now.timeIntervalSince($0.value) < proxyNodeRecency }
        proxyNodeRetryAt = proxyNodeRetryAt.filter { $0.value > now }
        let nodes = proxyNodesSeen.keys.filter { proxyNodeRetryAt[$0] == nil }
            .sorted { (proxyNodesPolledAt[$0] ?? .distantPast, $0) < (proxyNodesPolledAt[$1] ?? .distantPast, $1) }
        var processes = 0
        for node in nodes {
            if proxyLineHashes[node] == nil, proxyLineHashesReadAt.map({ now.timeIntervalSince($0) >= proxyNodeRetryInterval }) ?? true {
                guard processes < proxyPollProcesses else { break }
                processes += 1
                proxyLineHashesReadAt = now
                if let hashes = try? await surge.proxyLineHashes() { proxyLineHashes = hashes }
            }
            guard processes < proxyPollProcesses, recording else { break }
            processes += 1
            await askProxyNode(node, now: now)
        }
        // Nodes that went quiet are forgotten after a while; their errors are stored already.
        proxyNodesPolledAt = proxyNodesPolledAt.filter { now.timeIntervalSince($0.value) < 3_600 }
        proxyErrorsListed = proxyErrorsListed.filter { proxyNodesPolledAt[$0.key] != nil }
    }

    /// Asks one node for its errors, by its line hash or else by name, and queues the ones it had not listed before.
    /// A node Surge cannot report on waits `proxyNodeRetryInterval`, unless it was asked by a line hash read at least
    /// that long ago: a hash changes when the profile or a policy-path subscription does, so the node is asked by a
    /// fresh one first.
    private func askProxyNode(_ node: String, now: Date) async {
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
    }

    /// Surge reloaded its profile or started anew: the nodes' line hashes may have changed, and a node it could not
    /// report on may be back.
    func forgetProxyLineHashes() {
        proxyLineHashes = [:]
        proxyLineHashesReadAt = nil
        proxyNodeRetryAt = [:]
    }
}
