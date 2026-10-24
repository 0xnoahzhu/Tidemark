import Foundation

/// `SurgeClient` backed by `surge-cli --raw` (JSON output).
///
/// Every call launches surge-cli as a child process with
/// `["--raw"] + (remote ? ["--remote", host, "--password-stdin"] : []) + command`; the remote password is
/// written to standard input, never to argv. One-shot commands time out after 20 s (60 s for `test…` and
/// `http probe`, which go out to the network); on timeout the child gets SIGTERM, then SIGKILL.
/// Commands never change Surge's state.
struct SurgeCLIClient: SurgeClient {
    /// How long one-shot commands may run.
    struct Timeouts: Sendable, Hashable {
        var standard: Duration = .seconds(20)
        /// `test`, `test-policy…` and `http probe`.
        var network: Duration = .seconds(60)
        /// Between SIGTERM and SIGKILL.
        var killGrace: Duration = .seconds(2)
    }

    /// Events subscribed by `events()`. All six are accepted by Surge 6.10 (it ignores names it does not know).
    static let watchedEvents = ["request", "request-update", "real-time-speed", "environment", "reload", "shutdown"]
    /// Surge's default `http-listen` port, used when `dump event` has no listener entry.
    static let defaultHTTPProxyPort = 6152

    let endpoint: SurgeEndpoint
    let timeouts: Timeouts

    init(endpoint: SurgeEndpoint) {
        self.init(endpoint: endpoint, timeouts: Timeouts())
    }

    init(endpoint: SurgeEndpoint, timeouts: Timeouts) {
        self.endpoint = endpoint
        self.timeouts = timeouts
    }

    /// The first `SurgeEndpoint.defaultCLIPaths` entry that exists and is executable.
    static func locateCLI() -> String? {
        SurgeEndpoint.defaultCLIPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    // MARK: - Stream

    func events() -> AsyncThrowingStream<SurgeEvent, any Error> {
        SurgeEventStream.make(invocation(["watch"] + Self.watchedEvents), killGrace: timeouts.killGrace)
    }

    // MARK: - Commands

    func status() async throws -> SurgeStatus {
        try await decoded(SurgeStatus.self, ["status"])
    }

    func environment() async throws -> SurgeEnvironment {
        let command = ["environment"]
        return try SurgeOutputParser.environment(from: try await run(command), command: label(command))
    }

    func recentRequests() async throws -> [SurgeRequest] {
        let command = ["dump", "recent"]
        return try SurgeOutputParser.requests(from: try await run(command), command: label(command))
    }

    func activeRequests() async throws -> [SurgeRequest] {
        let command = ["dump", "active"]
        return try SurgeOutputParser.requests(from: try await run(command), command: label(command))
    }

    func dnsLookup(_ domain: String) async throws -> SurgeDNSLookup {
        try await decoded(SurgeDNSLookup.self, ["dns", "lookup", domain])
    }

    func dnsCache() async throws -> [String: [String]] {
        let command = ["dump", "dns"]
        return try SurgeOutputParser.dnsCache(from: try await run(command), command: label(command))
    }

    func geoIP(_ ip: String) async throws -> SurgeGeoIP {
        try await decoded(SurgeGeoIP.self, ["geoip", ip])
    }

    func ruleMatch(host: String, processPath: String?) async throws -> SurgeRuleMatch {
        var command = ["rule", "match", host]
        if let processPath, !processPath.isEmpty { command.append("process-path=\(processPath)") }
        return try await decoded(SurgeRuleMatch.self, command)
    }

    func httpProbe(url: String, policy: String?) async throws -> SurgeHTTPProbe {
        var command = ["http", "probe", url]
        if let policy, !policy.isEmpty { command.append(policy) }
        return try await decoded(SurgeHTTPProbe.self, command)
    }

    /// `policy-group list`; selections missing from the list are taken from `environment`.
    func policyGroups() async throws -> [SurgePolicyGroup] {
        let command = ["policy-group", "list"]
        let groups = try SurgeOutputParser.policyGroups(from: try await run(command), command: label(command))
        guard groups.contains(where: { $0.selected == nil }), let current = try? await environment() else { return groups }
        return groups.map { group in
            var group = group
            if group.selected == nil { group.selected = current.groupSelections[group.name] }
            return group
        }
    }

    /// `test external-ip` for the default route, else `test-policy-external-ip <policy>`. Policies from a
    /// policy-path subscription must be given as their `POLICY::…` line hash.
    func externalIP(policy: String?) async throws -> String {
        let command = policy.map { ["test-policy-external-ip", $0] } ?? ["test", "external-ip"]
        return try SurgeOutputParser.externalIP(from: try await run(command), command: label(command))
    }

    /// `test-policy <policy>`; the `receive` time in milliseconds (see `SurgeOutputParser.latency`).
    func policyLatency(policy: String) async throws -> Int? {
        let command = ["test-policy", policy]
        return try SurgeOutputParser.latency(from: try await run(command), command: label(command))
    }

    /// `summary` for the interface, address, router and DNS servers; `status` for the mode line.
    func network() async throws -> ThisMacNetwork {
        let command = ["summary"]
        async let summary = run(command)
        async let status = statusIfAvailable()
        return try SurgeOutputParser.network(summary: try await summary, status: await status, command: label(command))
    }

    private func statusIfAvailable() async -> SurgeStatus? {
        try? await status()
    }

    /// Parsed from `dump event` ("HTTP proxy listen on interface: 0.0.0.0, port: 6152"), else 6152.
    func httpProxyPort() async throws -> Int {
        let command = ["dump", "event"]
        let port = try SurgeOutputParser.httpProxyPort(fromEvents: try await run(command), command: label(command))
        return port ?? Self.defaultHTTPProxyPort
    }

    // MARK: - Running

    /// The full invocation for `command`, with the remote options and password line when configured.
    func invocation(_ command: [String]) -> SurgeInvocation {
        var arguments = ["--raw"]
        var input: Data?
        if let remote = endpoint.remote?.trimmingCharacters(in: .whitespaces), !remote.isEmpty {
            arguments += ["--remote", remote, "--password-stdin"]
            input = Data(((endpoint.password ?? "") + "\n").utf8)
        }
        arguments += command
        let usesNetwork = command.first?.hasPrefix("test") == true || command.starts(with: ["http", "probe"])
        return SurgeInvocation(
            executable: endpoint.cliPath,
            arguments: arguments,
            input: input,
            label: label(command),
            timeout: usesNetwork ? timeouts.network : timeouts.standard
        )
    }

    private func label(_ command: [String]) -> String {
        command.joined(separator: " ")
    }

    private func decoded<T: Decodable>(_ type: T.Type, _ command: [String]) async throws -> T {
        try SurgeOutputParser.decode(type, from: try await run(command), command: label(command))
    }

    /// Runs a one-shot command and returns its JSON payload.
    private func run(_ command: [String]) async throws -> Data {
        let invocation = invocation(command)
        let output = try await Self.execute(invocation, killGrace: timeouts.killGrace)
        return try SurgeOutputParser.payload(of: output, command: invocation.label)
    }

    /// Launches `invocation`, drains both pipes while it runs and waits for it to exit, enforcing the timeout.
    /// Cancelling the calling task terminates the child.
    @concurrent
    static func execute(_ invocation: SurgeInvocation, killGrace: Duration) async throws -> SurgeCommandOutput {
        try Task.checkCancellation()
        let child = try SurgeChildProcess(invocation)
        let watchdog = Task(name: "surge-cli timeout") {
            try await Task.sleep(for: invocation.timeout)
            return child.terminate(grace: killGrace)
        }
        let output = await withTaskCancellationHandler {
            async let stdout = SurgeChildProcess.collect(child.stdout)
            async let stderr = SurgeChildProcess.collect(child.stderr, limit: 65_536)
            let status = await child.waitForExit()
            return SurgeCommandOutput(exitStatus: status, stdout: await stdout, stderr: await stderr)
        } onCancel: {
            child.terminate(grace: killGrace)
        }
        watchdog.cancel()
        try Task.checkCancellation()
        if (try? await watchdog.value) == true {
            throw SurgeError.timedOut(command: invocation.label)
        }
        return output
    }
}
