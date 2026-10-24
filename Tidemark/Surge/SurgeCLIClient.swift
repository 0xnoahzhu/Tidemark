import Foundation

/// `SurgeClient` backed by `surge-cli --raw` (JSON output).
///
/// Every call launches surge-cli as a child process with
/// `["--raw"] + (remote ? ["--remote", host, "--password-stdin"] : []) + command`; the remote password is
/// written to standard input, never to argv. One-shot commands time out after 20 s (60 s for `test…` and
/// `http probe`, which go out to the network); on timeout the child gets SIGTERM, then SIGKILL.
/// Output is parsed in a `@concurrent` function, so a 300 KB `dump recent` never decodes on the caller's
/// actor. Commands never change Surge's state.
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
        try await run(["status"], decoding: SurgeStatus.self)
    }

    func environment() async throws -> SurgeEnvironment {
        try await run(["environment"]) { try SurgeOutputParser.environment(from: $0, command: $1) }
    }

    func recentRequests() async throws -> [SurgeRequest] {
        try await run(["dump", "recent"]) { try SurgeOutputParser.requests(from: $0, command: $1) }
    }

    func activeRequests() async throws -> [SurgeRequest] {
        try await run(["dump", "active"]) { try SurgeOutputParser.requests(from: $0, command: $1) }
    }

    func dnsLookup(_ domain: String) async throws -> SurgeDNSLookup {
        try await run(["dns", "lookup", domain], decoding: SurgeDNSLookup.self)
    }

    func dnsCache() async throws -> [String: [String]] {
        try await run(["dump", "dns"]) { try SurgeOutputParser.dnsCache(from: $0, command: $1) }
    }

    func geoIP(_ ip: String) async throws -> SurgeGeoIP {
        try await run(["geoip", ip], decoding: SurgeGeoIP.self)
    }

    func ruleMatch(host: String, processPath: String?) async throws -> SurgeRuleMatch {
        var command = ["rule", "match", host]
        if let processPath, !processPath.isEmpty { command.append("process-path=\(processPath)") }
        return try await run(command, decoding: SurgeRuleMatch.self)
    }

    func httpProbe(url: String, policy: String?) async throws -> SurgeHTTPProbe {
        var command = ["http", "probe", url]
        if let policy, !policy.isEmpty { command.append(policy) }
        return try await run(command, decoding: SurgeHTTPProbe.self)
    }

    /// `policy-group list`; selections missing from the list are taken from `environment`.
    func policyGroups() async throws -> [SurgePolicyGroup] {
        let groups = try await run(["policy-group", "list"]) { try SurgeOutputParser.policyGroups(from: $0, command: $1) }
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
        return try await run(command) { try SurgeOutputParser.externalIP(from: $0, command: $1) }
    }

    /// `test-policy <policy>`; the `receive` time in milliseconds (see `SurgeOutputParser.latency`).
    func policyLatency(policy: String) async throws -> Int? {
        try await run(["test-policy", policy]) { try SurgeOutputParser.latency(from: $0, command: $1) }
    }

    /// `summary` for the interface, address, router and DNS servers; `status` for the mode line.
    func network() async throws -> ThisMacNetwork {
        async let status = statusIfAvailable()
        let summary = try await run(["summary"]) { data, _ in data }
        return try SurgeOutputParser.network(summary: summary, status: await status, command: "summary")
    }

    /// Parsed from `dump event` ("HTTP proxy listen on interface: 0.0.0.0, port: 6152"), else 6152.
    func httpProxyPort() async throws -> Int {
        let port = try await run(["dump", "event"]) { try SurgeOutputParser.httpProxyPort(fromEvents: $0, command: $1) }
        return port ?? Self.defaultHTTPProxyPort
    }

    private func statusIfAvailable() async -> SurgeStatus? {
        try? await status()
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
            label: command.joined(separator: " "),
            timeout: usesNetwork ? timeouts.network : timeouts.standard
        )
    }

    private func run<Value: Decodable & Sendable>(_ command: [String], decoding type: Value.Type) async throws -> Value {
        try await run(command) { try SurgeOutputParser.decode(type, from: $0, command: $1) }
    }

    /// Runs a one-shot command and parses its JSON payload with `parse(payload, label)`, off the caller's actor.
    @concurrent
    private func run<Value: Sendable>(_ command: [String], parse: @Sendable (Data, String) throws -> Value) async throws -> Value {
        let invocation = invocation(command)
        let output = try await Self.execute(invocation, killGrace: timeouts.killGrace)
        return try parse(try SurgeOutputParser.payload(of: output, command: invocation.label), invocation.label)
    }

    /// Launches `invocation`, drains both pipes while it runs and waits for it to exit, enforcing the timeout.
    /// Cancelling the calling task terminates the child.
    @concurrent
    static func execute(_ invocation: SurgeInvocation, killGrace: Duration) async throws -> SurgeCommandOutput {
        try Task.checkCancellation()
        let child = try SurgeChildProcess(invocation)
        let watchdog = Task(name: "surge-cli-timeout") {
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
