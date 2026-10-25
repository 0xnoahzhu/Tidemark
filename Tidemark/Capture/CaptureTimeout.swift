import Foundation
import Synchronization

/// Thrown when an operation outlives its deadline.
struct CaptureTimeoutError: Error, LocalizedError, Equatable {
    var seconds: Double
    /// English, and stable: stored in `egress_checks.error` and read back by `EgressFormat.error` (on other
    /// Macs too). The UI says it in its own language (`CaptureEngine.message(for:)`, the probe controller).
    var errorDescription: String? { "Timed out after \(Int(seconds.rounded())) s." }

    init(seconds: Double) {
        self.seconds = seconds
    }

    init(_ timeout: Duration) {
        seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
    }
}

/// Races an operation against a deadline; the loser is cancelled.
enum CaptureTimeout {
    /// Structured race: returns once both children finished, so an operation that ignores cancellation
    /// still delays the caller. Use `unstructured` when the caller must regain control on time.
    static func run<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CaptureTimeoutError(timeout)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }

    /// Returns (or throws `CaptureTimeoutError`) as soon as the deadline passes, without waiting for the
    /// operation to honour cancellation: a query stuck on a black-holed TCP connection cannot hold the
    /// caller. The abandoned operation is cancelled and finishes in the background. Cancelling the caller
    /// throws `CancellationError` right away.
    static func unstructured<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = CaptureRace<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, any Error>) in
                race.install(continuation)
                race.add(Task {
                    do {
                        race.finish(.success(try await operation()))
                    } catch {
                        race.finish(.failure(error))
                    }
                })
                race.add(Task {
                    do {
                        try await Task.sleep(for: timeout)
                        race.finish(.failure(CaptureTimeoutError(timeout)))
                    } catch {
                        // Cancelled because the operation finished first.
                    }
                })
            }
        } onCancel: {
            race.finish(.failure(CancellationError()))
        }
    }

    /// The operation's value, or nil when it fails or `timeout` passes first (never waits longer).
    static func value<T: Sendable>(within timeout: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        let result = try? await unstructured(timeout) { await operation() }
        return result ?? nil
    }
}

/// First-finisher-wins state shared by the tasks of `CaptureTimeout.unstructured`.
private final class CaptureRace<T: Sendable>: Sendable {
    private struct State {
        var continuation: CheckedContinuation<T, any Error>?
        /// The outcome when it arrived before the continuation was installed.
        var outcome: Result<T, any Error>?
        var finished = false
        var tasks: [Task<Void, Never>] = []
    }

    private let state = Mutex(State())

    func install(_ continuation: CheckedContinuation<T, any Error>) {
        let early: Result<T, any Error>? = state.withLock { state in
            if let outcome = state.outcome { return outcome }
            state.continuation = continuation
            return nil
        }
        if let early { continuation.resume(with: early) }
    }

    func add(_ task: Task<Void, Never>) {
        let cancel = state.withLock { state -> Bool in
            if state.finished { return true }
            state.tasks.append(task)
            return false
        }
        if cancel { task.cancel() }
    }

    func finish(_ result: Result<T, any Error>) {
        let (continuation, tasks) = state.withLock { state -> (CheckedContinuation<T, any Error>?, [Task<Void, Never>]) in
            guard !state.finished else { return (nil, []) }
            state.finished = true
            let continuation = state.continuation
            state.continuation = nil
            if continuation == nil { state.outcome = result }
            let tasks = state.tasks
            state.tasks = []
            return (continuation, tasks)
        }
        continuation?.resume(with: result)
        for task in tasks { task.cancel() }
    }
}
