import Darwin
import Foundation

/// One surge-cli command line: the executable, its full argv and what to feed its standard input.
struct SurgeInvocation: Sendable, Hashable {
    var executable: String
    var arguments: [String]
    /// Written to the child's standard input before launch (the remote password line), or nil for `/dev/null`.
    var input: Data?
    /// The command as shown in errors, without `--raw`, `--remote` or anything secret (e.g. `dump recent`).
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
final class SurgeChildProcess: Sendable {
    let process: Process
    /// Chunks of standard output; finishes at end of file.
    let stdout: AsyncStream<Data>
    /// Chunks of standard error; finishes at end of file.
    let stderr: AsyncStream<Data>
    private let exit: Task<Int32, Never>

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
        if let input = invocation.input {
            // The pipe buffer holds the short password line, so writing before launch never blocks and
            // never raises SIGPIPE; closing the write end gives surge-cli a clean end of file.
            let pipe = Pipe()
            do {
                try pipe.fileHandleForWriting.write(contentsOf: input)
                try pipe.fileHandleForWriting.close()
            } catch {
                throw .commandFailed(command: invocation.label, message: error.localizedDescription)
            }
            process.standardInput = pipe
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        let (statusStream, statusContinuation) = AsyncStream.makeStream(of: Int32.self, bufferingPolicy: .bufferingNewest(1))
        process.terminationHandler = { finished in
            statusContinuation.yield(finished.terminationStatus)
            statusContinuation.finish()
        }

        stdout = Self.chunks(of: output.fileHandleForReading)
        stderr = Self.chunks(of: errors.fileHandleForReading)

        do {
            try process.run()
        } catch {
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
