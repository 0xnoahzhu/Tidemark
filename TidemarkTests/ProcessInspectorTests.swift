import Darwin
import Foundation
import Testing
@testable import Tidemark

@Suite("Process inspector")
struct ProcessInspectorTests {
    let inspector = LibProcInspector()

    @Test func describesTheTestProcess() throws {
        let me = getpid()
        let process = try #require(inspector.process(pid: me))
        #expect(process.pid == me)
        #expect(process.parentPID == getppid())
        #expect(process.path == Bundle.main.executablePath)
        #expect(process.name == "Tidemark")
        #expect(process.startTime < .now)
        #expect(process.startTime > .now.addingTimeInterval(-86_400))
        #expect(inspector.isRunning(pid: me, startTime: process.startTime))
        #expect(inspector.isRunning(pid: me, startTime: process.startTime.addingTimeInterval(0.5)))
        #expect(!inspector.isRunning(pid: me, startTime: process.startTime.addingTimeInterval(-60)))
    }

    @Test func walksTheAncestryOfTheTestProcess() throws {
        let me = getpid()
        let chain = inspector.chain(pid: me, notAfter: .now)
        let leaf = try #require(chain.last)
        #expect(leaf.pid == me)
        #expect(leaf.path == Bundle.main.executablePath)
        #expect(!chain.contains { $0.pid <= 1 }, "launchd and the kernel are excluded")
        #expect(chain.count <= LibProcInspector.maxDepth)
        if chain.count > 1 {
            #expect(chain[chain.count - 2].pid == getppid())
        }
        // Cached and uncached walks agree.
        #expect(inspector.chain(pid: me, notAfter: nil) == chain)
        #expect(LibProcInspector().chain(pid: me, notAfter: nil) == chain)
    }

    @Test func rollsAChildUpToItsParent() async throws {
        let child = Process()
        child.executableURL = URL(filePath: "/bin/sleep")
        child.arguments = ["5"]
        try child.run()
        defer { child.terminate() }

        let chain = inspector.chain(pid: child.processIdentifier, notAfter: .now.addingTimeInterval(1))
        #expect(chain.map(\.pid).suffix(2) == [getpid(), child.processIdentifier])
        let leaf = try #require(chain.last)
        #expect(leaf.name == "sleep")
        #expect(leaf.path == "/bin/sleep")
        let start = try #require(leaf.startTime)
        #expect(inspector.isRunning(pid: child.processIdentifier, startTime: start))
    }

    @Test func treatsAProcessThatStartedAfterTheRequestAsAReusedPID() {
        // The request happened an hour before this process started: its PID must have been reused.
        #expect(inspector.chain(pid: getpid(), notAfter: .now.addingTimeInterval(-3600)).isEmpty)
    }

    @Test(arguments: [Int32(0), 1, 99_999])
    func ignoresLaunchdTheKernelAndDeadPIDs(_ pid: Int32) {
        #expect(inspector.chain(pid: pid, notAfter: nil).isEmpty)
    }

    @Test func reportsDeadPIDs() async throws {
        let pid = try await Self.run("/usr/bin/true").pid
        #expect(inspector.process(pid: pid) == nil)
        #expect(inspector.chain(pid: pid, notAfter: nil).isEmpty)
        #expect(!inspector.isRunning(pid: pid, startTime: .now))
        #expect(inspector.process(pid: 99_999) == nil)
    }

    @Test func readsProcessesOfOtherUsers() async throws {
        // syslogd runs as root; proc_pidinfo is denied and the sysctl fallback answers.
        let output = try await Self.run("/usr/bin/pgrep", "-x", "syslogd").output
        let pid = try #require(output.split(separator: "\n").first.flatMap { Int32($0) })

        let process = try #require(inspector.process(pid: pid))
        #expect(process.name == "syslogd")
        #expect(process.parentPID == 1)
        #expect(process.path == "/usr/sbin/syslogd")
        #expect(inspector.chain(pid: pid, notAfter: nil).map(\.pid) == [pid])
        #expect(inspector.isRunning(pid: pid, startTime: process.startTime))
    }

    /// Runs a tool to completion; returns its PID and standard output.
    private static func run(_ path: String, _ arguments: String...) async throws -> (pid: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
        let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return (process.processIdentifier, output)
    }
}
