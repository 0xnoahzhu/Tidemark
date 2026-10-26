import Darwin
import Foundation
import Synchronization

/// One surge-cli command line: the executable and its full argv.
struct SurgeInvocation: Sendable, Hashable {
    var executable: String
    var arguments: [String]
    /// The command as shown in errors, without `--raw` (e.g. `dump recent`).
    var label: String
    /// Maximum run time of a one-shot command; ignored for `watch`.
    var timeout: Duration
}

/// A running surge-cli child process with non-blocking access to its output.
///
/// Output is read with `readabilityHandler` and bridged into `AsyncStream`s instead of `FileHandle.bytes`:
/// every `FileHandle.AsyncBytes` read goes through one shared I/O actor, so an idle `watch` pipe would stall
/// the output of every other command until the next event arrived (and byte-wise iteration is ~700× slower
/// on a 300 KB `dump recent`). The exit status arrives through `terminationHandler`; the typed
/// `Process.DidTerminateMessage` is posted on the launching thread's run loop, which tasks on the
/// cooperative pool do not have.
///
/// Every child is tracked until it exits, so quitting can stop the ones no caller cancelled (`terminateAll`):
/// a lookup still in flight, or a child that ignored SIGTERM and whose SIGKILL would otherwise be scheduled
/// by a process that is about to exit.
final class SurgeChildProcess: Sendable {
    let process: Process
    /// Chunks of standard output; finishes at end of file.
    let stdout: AsyncStream<Data>
    /// Chunks of standard error; finishes at end of file.
    let stderr: AsyncStream<Data>
    private let exit: Task<Int32, Never>

    /// Children launched that have not exited yet, by process object.
    private static let launched = Mutex<[ObjectIdentifier: Process]>([:])

    var pid: Int32 { process.processIdentifier }

    /// Launches `invocation`. Throws `SurgeError.cliNotFound` when the executable is missing.
    init(_ invocation: SurgeInvocation) throws(SurgeError) {
        guard FileManager.default.isExecutableFile(atPath: invocation.executable) else {
            throw .cliNotFound(path: invocation.executable)
        }
        let process = Process()
        process.executableURL = URL(filePath: invocation.executable)
        process.arguments = invocation.arguments

        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice

        let (statusStream, statusContinuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        let key = ObjectIdentifier(process)
        process.terminationHandler = { finished in
            Self.launched.withLock { $0[key] = nil }
            statusContinuation.yield(finished.terminationStatus)
            statusContinuation.finish()
        }

        stdout = Self.chunks(of: output.fileHandleForReading)
        stderr = Self.chunks(of: errors.fileHandleForReading)

        // Tracked before launch: a child that exits at once is untracked by its termination handler.
        Self.launched.withLock { $0[key] = process }
        do {
            try process.run()
        } catch {
            Self.launched.withLock { $0[key] = nil }
            output.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            if Self.isMissingFile(error) { throw .cliNotFound(path: invocation.executable) }
            throw .commandFailed(command: invocation.label, message: error.localizedDescription)
        }
        self.process = process
        exit = Task(name: "surge-cli-exit") {
            for await status in statusStream { return status }
            return -1
        }
    }

    /// Waits for the child to exit and returns its termination status (the signal number when it was killed).
    func waitForExit() async -> Int32 {
        await exit.value
    }

    /// Sends SIGTERM, then SIGKILL if the child is still running after `grace`.
    /// Returns `false` when the child had already exited.
    @discardableResult
    func terminate(grace: Duration = .seconds(2)) -> Bool {
        guard process.isRunning else { return false }
        process.terminate()
        let process = self.process
        Task(name: "surge-cli-kill") {
            try? await Task.sleep(for: grace)
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        return true
    }

    /// The children launched that have not exited yet (an exited child is reaped before it leaves the list).
    static var running: [Process] {
        launched.withLock { Array($0.values) }
    }

    /// Stops every child still running before Tidemark quits, so none outlives it: SIGTERM, then SIGKILL for
    /// the ones still running after `grace`. Returns once they exited (at most `grace` after the SIGKILL).
    static func terminateAll(grace: Duration = .milliseconds(500)) async {
        await terminate(running, grace: grace)
    }

    /// SIGTERM to each of `processes` still running, SIGKILL to the ones still running after `grace`, then waits
    /// up to `grace` again for them to exit. Returns whether every one exited.
    @discardableResult
    static func terminate(_ processes: [Process], grace: Duration) async -> Bool {
        let alive = processes.filter(\.isRunning)
        guard !alive.isEmpty else { return true }
        for process in alive { process.terminate() }
        if await waitForExit(of: alive, within: grace) { return true }
        for process in alive where process.isRunning { kill(process.processIdentifier, SIGKILL) }
        return await waitForExit(of: alive, within: grace)
    }

    /// Polls until none of `processes` is running, at most `limit` (a cancelled caller stops waiting).
    private static func waitForExit(of processes: [Process], within limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while processes.contains(where: \.isRunning), ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return !processes.contains(where: \.isRunning)
    }

    /// Concatenates a chunk stream, keeping at most the last `limit` bytes.
    static func collect(_ chunks: AsyncStream<Data>, limit: Int = .max) async -> Data {
        var data = Data()
        for await chunk in chunks {
            data.append(chunk)
            if data.count > limit { data.removeFirst(data.count - limit) }
        }
        return data
    }

    private static func chunks(of handle: FileHandle) -> AsyncStream<Data> {
        AsyncStream { continuation in
            handle.readabilityHandler = { readable in
                let data = readable.availableData
                if data.isEmpty {
                    readable.readabilityHandler = nil
                    continuation.finish()
                } else {
                    continuation.yield(data)
                }
            }
        }
    }

    private static func isMissingFile(_ error: any Error) -> Bool {
        let error = error as NSError
        return (error.domain == NSCocoaErrorDomain && error.code == NSFileNoSuchFileError)
            || (error.domain == NSPOSIXErrorDomain && error.code == Int(ENOENT))
    }
}
