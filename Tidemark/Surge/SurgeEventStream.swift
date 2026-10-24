import Foundation

/// Runs `surge-cli --raw watch …` and turns its output into `SurgeEvent`s.
///
/// The child runs in a named task; its standard output is split into lines and classified as it arrives.
/// The stream finishes when the child exits — with `SurgeError.commandFailed` (carrying standard error)
/// when the exit status is non-zero — and terminating the stream (the consumer cancelling or dropping it)
/// terminates the child. The buffer is unbounded: request updates can arrive at ~100 per second and must
/// not be dropped, so consumers are expected to keep up and coalesce.
enum SurgeEventStream {
    static func make(_ invocation: SurgeInvocation, killGrace: Duration = .seconds(2)) -> AsyncThrowingStream<SurgeEvent, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: SurgeEvent.self, throwing: (any Error).self)
        let task = Task(name: "Surge watch") {
            do {
                try await pump(invocation, killGrace: killGrace, into: continuation)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
        continuation.onTermination = { _ in task.cancel() }
        return stream
    }

    private static func pump(
        _ invocation: SurgeInvocation,
        killGrace: Duration,
        into continuation: AsyncThrowingStream<SurgeEvent, any Error>.Continuation
    ) async throws {
        try Task.checkCancellation()
        let child = try SurgeChildProcess(invocation)
        let status: Int32
        let errors: Data
        (status, errors) = await withTaskCancellationHandler {
            async let stderr = SurgeChildProcess.collect(child.stderr, limit: 16_384)
            var splitter = SurgeLineSplitter()
            for await chunk in child.stdout {
                for line in splitter.append(chunk) {
                    continuation.yield(SurgeLineParser.event(from: line))
                }
            }
            if let last = splitter.finish() {
                continuation.yield(SurgeLineParser.event(from: last))
            }
            return (await child.waitForExit(), await stderr)
        } onCancel: {
            child.terminate(grace: killGrace)
        }
        // A child stopped because the consumer went away is not a failure.
        if Task.isCancelled { return }
        if status != 0 {
            throw SurgeError.commandFailed(
                command: invocation.label,
                message: SurgeOutputParser.failureMessage(stderr: errors, stdout: Data(), status: status)
            )
        }
    }
}
