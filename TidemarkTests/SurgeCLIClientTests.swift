import Darwin
import Foundation
import Testing
@testable import Tidemark

/// Process handling of `SurgeCLIClient`, driven by shell scripts that stand in for surge-cli.
@Suite("Surge CLI client", .timeLimit(.minutes(1)))
struct SurgeCLIClientTests {
    @Test func buildsLocalInvocations() {
        let client = SurgeCLIClient(endpoint: SurgeEndpoint(cliPath: "/usr/local/bin/surge-cli"))
        let status = client.invocation(["status"])
        #expect(status.arguments == ["--raw", "status"])
        #expect(status.input == nil)
        #expect(status.label == "status")
        #expect(status.timeout == .seconds(20))
        #expect(client.invocation(["test-policy", "POLICY::abc"]).timeout == .seconds(60))
        #expect(client.invocation(["test", "external-ip"]).timeout == .seconds(60))
        #expect(client.invocation(["http", "probe", "https://example.com"]).timeout == .seconds(60))
    }

    @Test func sendsTheRemotePasswordOnStandardInputOnly() async throws {
        let cli = try await SurgeFakeCLI(#"printf '%s\n' "$*"; cat"#)
        defer { cli.remove() }
        let client = cli.client(remote: "10.0.0.2:6171", password: "correct horse")
        let invocation = client.invocation(["status"])
        #expect(invocation.arguments == ["--raw", "--remote", "10.0.0.2:6171", "--password-stdin", "status"])
        #expect(!invocation.arguments.contains { $0.contains("correct horse") })

        let output = try await SurgeCLIClient.execute(invocation, killGrace: .seconds(1))
        #expect(output.exitStatus == 0)
        #expect(String(decoding: output.stdout, as: UTF8.self) == "--raw --remote 10.0.0.2:6171 --password-stdin status\ncorrect horse\n")
    }

    @Test func keepsStandardInputEmptyForTheLocalInstance() async throws {
        let cli = try await SurgeFakeCLI(#"cat; printf 'done'"#)
        defer { cli.remove() }
        let output = try await SurgeCLIClient.execute(cli.client().invocation(["status"]), killGrace: .seconds(1))
        #expect(String(decoding: output.stdout, as: UTF8.self) == "done")
    }

    @Test func decodesLargeOutputWithoutBlocking() async throws {
        // ~1 MB, far beyond a pipe buffer: the output must be drained while the child runs.
        let cli = try await SurgeFakeCLI(#"""
        printf '{"requests":['
        i=0
        while [ $i -lt 1000 ]; do
          [ $i -gt 0 ] && printf ','
          printf '{"id":%d,"URL":"host%d.example:443","notes":["%0900d"]}' $i $i 0
          i=$((i+1))
        done
        printf ']}'
        """#)
        defer { cli.remove() }
        let requests = try await cli.client().recentRequests()
        #expect(requests.count == 1000)
        #expect(requests.last?.url == "host999.example:443")
        #expect(requests.last?.notes?.first?.count == 900)
    }

    @Test func mapsFailuresToCommandFailed() async throws {
        let cli = try await SurgeFakeCLI(#"echo "Error: Policy doesn't exist" >&2; exit 1"#)
        defer { cli.remove() }
        await #expect(throws: SurgeError.commandFailed(command: "test-policy-external-ip Missing", message: "Policy doesn't exist")) {
            try await cli.client().externalIP(policy: "Missing")
        }
    }

    @Test func reportsAMissingExecutable() async {
        let client = SurgeCLIClient(endpoint: SurgeEndpoint(cliPath: "/nonexistent/surge-cli"))
        await #expect(throws: SurgeError.cliNotFound(path: "/nonexistent/surge-cli")) {
            try await client.status()
        }
        var failure: (any Error)?
        do {
            for try await _ in client.events() {}
        } catch {
            failure = error
        }
        #expect(failure as? SurgeError == .cliNotFound(path: "/nonexistent/surge-cli"))
    }

    @Test func timesOutWithSIGTERM() async throws {
        let cli = try await SurgeFakeCLI(SurgeFakeCLI.waitWhileTheTestRuns)
        defer { cli.remove() }
        let client = cli.client(timeouts: .init(standard: .milliseconds(300), network: .seconds(60), killGrace: .seconds(5)))
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: SurgeError.timedOut(command: "status")) {
            try await client.status()
        }
        #expect(clock.now - started < .seconds(3))
    }

    @Test func escalatesToSIGKILLWhenSIGTERMIsIgnored() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "tidemark-kill-\(UUID().uuidString).pid")
        // The PID is written once SIGTERM is ignored.
        let cli = try await SurgeFakeCLI("trap '' TERM\necho $$ > '\(pidFile.path)'\n" + SurgeFakeCLI.waitWhileTheTestRuns)
        defer {
            cli.remove()
            try? FileManager.default.removeItem(at: pidFile)
        }
        let client = cli.client(timeouts: .init(standard: .milliseconds(500), network: .seconds(60), killGrace: .milliseconds(300)))
        let clock = ContinuousClock()
        let started = clock.now
        await #expect(throws: SurgeError.timedOut(command: "dump active")) {
            try await client.activeRequests()
        }
        #expect(clock.now - started < .seconds(3))
        // A fake that set its trap before the timeout could only be ended by SIGKILL.
        let pid = try #require(Self.pid(in: pidFile), "the fake ignored SIGTERM before the timeout")
        #expect(await Self.waitUntilGone(pid), "killed and reaped")
    }

    @Test func quittingStopsEveryChildStillRunning() async throws {
        // One child ends at SIGTERM; the other ignores it and is killed. Each writes its PID once it is ready.
        let ready = (0..<2).map { FileManager.default.temporaryDirectory.appending(path: "tidemark-quit-\(UUID().uuidString)-\($0).pid") }
        let plain = try await SurgeFakeCLI("echo $$ > '\(ready[0].path)'\n" + SurgeFakeCLI.waitWhileTheTestRuns)
        let stubborn = try await SurgeFakeCLI("trap '' TERM\necho $$ > '\(ready[1].path)'\n" + SurgeFakeCLI.waitWhileTheTestRuns)
        defer {
            plain.remove()
            stubborn.remove()
            for file in ready { try? FileManager.default.removeItem(at: file) }
        }
        let children = try [plain, stubborn].map { try SurgeChildProcess($0.client().invocation(["status"])) }
        for file in ready { _ = try await Self.waitForPID(in: file) }
        let running = SurgeChildProcess.running
        #expect(children.allSatisfy { child in running.contains { $0 === child.process } })

        let clock = ContinuousClock()
        let started = clock.now
        #expect(await SurgeChildProcess.terminate(children.map(\.process), grace: .milliseconds(300)))
        #expect(clock.now - started < .seconds(2))
        #expect(await children[1].waitForExit() == SIGKILL, "SIGTERM was ignored")
        for child in children { #expect(await Self.waitUntilGone(child.pid), "reaped") }
        let left = SurgeChildProcess.running
        #expect(!children.contains { child in left.contains { $0 === child.process } })
    }

    @Test func cancellingACommandTerminatesTheChild() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "tidemark-cancel-\(UUID().uuidString).pid")
        let cli = try await SurgeFakeCLI("echo $$ > '\(pidFile.path)'\n" + SurgeFakeCLI.waitWhileTheTestRuns)
        defer {
            cli.remove()
            try? FileManager.default.removeItem(at: pidFile)
        }
        let task = Task { try await cli.client().status() }
        let pid = try await Self.waitForPID(in: pidFile)
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await Self.waitUntilGone(pid))
    }

    // MARK: - Events

    @Test func streamsEventsUntilTheChildExits() async throws {
        let cli = try await SurgeFakeCLI("cat '\(SurgeFixtures.url("surge-watch.jsonl").path)'")
        defer { cli.remove() }
        var kinds: [String] = []
        for try await event in cli.client().events() {
            switch event {
            case .subscribed: kinds.append("subscribed")
            case .speed: kinds.append("speed")
            case .request(let request): kinds.append("request \(request.id)")
            default: kinds.append("other")
            }
        }
        #expect(kinds == ["subscribed", "speed", "request 58452", "request 58452"])
    }

    @Test func passesTheWatchedEventNames() async throws {
        let cli = try await SurgeFakeCLI(#"printf '%s\n' "$*""#)
        defer { cli.remove() }
        var lines: [String] = []
        for try await event in cli.client().events() {
            if case .other(let line) = event { lines.append(line) }
        }
        #expect(lines == ["--raw watch request request-update real-time-speed environment reload shutdown"])
    }

    @Test func failsTheStreamWithStandardErrorOnNonZeroExit() async throws {
        let cli = try await SurgeFakeCLI(#"echo '{"result":"Event subscribed"}'; echo "Error: The controller connection has been closed" >&2; exit 2"#)
        defer { cli.remove() }
        var subscribed = false
        var failure: (any Error)?
        do {
            for try await event in cli.client().events() {
                if case .subscribed = event { subscribed = true }
            }
        } catch {
            failure = error
        }
        #expect(subscribed)
        let label = "watch " + SurgeCLIClient.watchedEvents.joined(separator: " ")
        #expect(failure as? SurgeError == .commandFailed(command: label, message: "The controller connection has been closed"))
    }

    @Test func stoppingTheConsumerTerminatesTheWatch() async throws {
        let pidFile = FileManager.default.temporaryDirectory.appending(path: "tidemark-watch-\(UUID().uuidString).pid")
        let cli = try await SurgeFakeCLI("echo $$ > '\(pidFile.path)'\necho '{\"result\":\"Event subscribed\"}'\n" + SurgeFakeCLI.waitWhileTheTestRuns)
        defer {
            cli.remove()
            try? FileManager.default.removeItem(at: pidFile)
        }
        for try await event in cli.client().events() {
            if case .subscribed = event { break }
        }
        let pid = try await Self.waitForPID(in: pidFile)
        #expect(await Self.waitUntilGone(pid))
    }

    // MARK: - Helpers

    private static func waitForPID(in file: URL) async throws -> pid_t {
        for _ in 0..<100 {
            if let pid = pid(in: file) { return pid }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    /// The PID a fake wrote to `file`, nil when it has not written it.
    private static func pid(in file: URL) -> pid_t? {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Polls until no process has `pid` (at most 5 s).
    private static func waitUntilGone(_ pid: pid_t) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return false
    }
}

/// A throwaway shell script standing in for surge-cli, to exercise process handling without Surge.
private struct SurgeFakeCLI {
    let directory: URL
    let path: String

    /// Script lines that keep a fake running while the test host that launched it lives, for a minute at most,
    /// without a grandchild holding the output pipes open. A fake orphaned by a test run that was killed or
    /// crashed (before Tidemark could stop it) ends on its own instead of running, or spinning, forever.
    static let waitWhileTheTestRuns = """
    i=0
    while [ $i -lt 600 ] && kill -0 $PPID 2>/dev/null; do sleep 0.1 </dev/null >/dev/null 2>&1; i=$((i + 1)); done
    """

    /// Writes the script and launches it once, doing nothing. macOS checks a new executable on its first launch,
    /// which can take longer than the short timeouts these tests use (a busy Mac took 0.2–1.6 s): SIGTERM would
    /// then reach the script before it ran a line, and a test of what the script does about it would prove nothing.
    init(_ body: String) async throws {
        directory = FileManager.default.temporaryDirectory.appending(path: "TidemarkFakeSurge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "surge-cli")
        let script = "#!/bin/sh\n[ -n \"$TIDEMARK_FAKE_WARM_UP\" ] && exit 0\n" + body + "\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        path = url.path

        let warmUp = Process()
        warmUp.executableURL = url
        warmUp.environment = ["TIDEMARK_FAKE_WARM_UP": "1"]
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            warmUp.terminationHandler = { _ in continuation.resume() }
            do {
                try warmUp.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    func client(remote: String? = nil, password: String? = nil, timeouts: SurgeCLIClient.Timeouts = .init()) -> SurgeCLIClient {
        SurgeCLIClient(endpoint: SurgeEndpoint(cliPath: path, remote: remote, password: password), timeouts: timeouts)
    }

    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
