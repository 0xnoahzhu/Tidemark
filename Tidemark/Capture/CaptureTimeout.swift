import Foundation

/// Thrown when an operation outlives its deadline.
struct CaptureTimeoutError: Error, LocalizedError, Equatable {
    var seconds: Double
    var errorDescription: String? { "Timed out after \(Int(seconds.rounded())) s." }
}

/// Races an operation against a deadline; the loser is cancelled.
enum CaptureTimeout {
    static func run<T: Sendable>(_ timeout: Duration, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw CaptureTimeoutError(seconds: Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw CancellationError() }
            return first
        }
    }
}
