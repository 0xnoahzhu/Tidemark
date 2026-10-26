import Foundation
import Network
import Synchronization

/// Loopback HTTP proxy opened for one site probe, built on the Swift-native Network API
/// (`NetworkListener` / `NetworkConnection`, macOS 26).
///
/// It listens on `127.0.0.1` with an ephemeral port and accepts `CONNECT` tunnels and absolute-URI plain
/// HTTP requests. Each browser connection gets its own upstream connection to Surge's HTTP proxy: the
/// proxy registers the upstream's local source address and port with the `ProbeRegistry` (so the capture
/// pipeline can match Surge's record of it) until shortly after it closes, replays the request head, and
/// then pipes both directions, relaying Surge's response untouched. Every host and its activity window are
/// reported to the registry. A client that does not finish its request head within `headTimeout` gets 408.
final class ProbeProxyServer: Sendable {
    let upstreamHost: String
    let upstreamPort: UInt16
    let registry: ProbeRegistry
    /// How long to wait for Surge to accept an upstream connection.
    let connectTimeout: Duration
    /// How long a client may take to send its request head; silent clients are answered 408 and closed.
    let headTimeout: Duration

    private let runTask = Mutex<Task<Void, Never>?>(nil)

    init(upstreamPort: UInt16, registry: ProbeRegistry, upstreamHost: String = "127.0.0.1", connectTimeout: Duration = .seconds(5),
         headTimeout: Duration = .seconds(10)) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.registry = registry
        self.connectTimeout = connectTimeout
        self.headTimeout = headTimeout
    }

    /// Starts listening and returns the loopback port.
    func start() async throws -> UInt16 {
        let listener = try NetworkListener(using: .parameters { TCP() }.localEndpoint(.hostPort(host: "127.0.0.1", port: .any)))
        let ready = ProbeOnce<UInt16>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
                ready.set(continuation)
                listener.onStateUpdate { listener, state in
                    switch state {
                    case .ready:
                        if let port = listener.port?.rawValue {
                            ready.resume(returning: port)
                        } else {
                            ready.resume(throwing: NWError.posix(.EADDRNOTAVAIL))
                        }
                    case .failed(let error):
                        ready.resume(throwing: error)
                    case .cancelled:
                        ready.resume(throwing: CancellationError())
                    default:
                        break
                    }
                }
                let task = Task { [self] in
                    do {
                        try await listener.run { connection in
                            await self.handle(connection)
                        }
                    } catch {
                        ready.resume(throwing: error)
                    }
                }
                runTask.withLock { $0 = task }
            }
        } onCancel: {
            stop()
        }
    }

    /// Closes the listener and every open connection.
    func stop() {
        runTask.withLock { task in
            task?.cancel()
            task = nil
        }
    }

    // MARK: Connections

    /// What arrived before the blank line that ends a request head.
    private enum HeadRead: Sendable {
        case head(Data, end: Int)
        case closed
        case tooLarge
    }

    private static func readHead(from client: NetworkConnection<TCP>) async throws -> HeadRead {
        var buffer = Data()
        while true {
            let message = try await client.receive(atLeast: 1, atMost: 65_536)
            // A cancelled receive returns an empty end of stream; the browser did not close.
            try Task.checkCancellation()
            buffer.append(message.content)
            if let end = ProbeHTTPHead.headEnd(in: buffer) { return .head(buffer, end: end) }
            if message.metadata.endOfStream { return .closed }
            if buffer.count > ProbeHTTPHead.maxLength { return .tooLarge }
        }
    }

    /// Reads the head, or returns nil after `timeout`. Cancelling a pending receive tears the connection
    /// down, so the reader is only cancelled after the caller has answered the client, or when the proxy
    /// stops.
    private static func readHead(from client: NetworkConnection<TCP>, timeout: Duration) async throws -> (read: HeadRead?, reader: Task<HeadRead, any Error>) {
        let reader = Task { try await readHead(from: client) }
        let once = ProbeOnce<HeadRead?>()
        let read = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<HeadRead?, any Error>) in
                once.set(continuation)
                let timer = Task {
                    try? await Task.sleep(for: timeout)
                    once.resume(returning: nil)
                }
                Task {
                    do {
                        let value = try await reader.value
                        once.resume(returning: value)
                    } catch {
                        once.resume(throwing: error)
                    }
                    timer.cancel()
                }
                // A stop that came before the continuation was set.
                if Task.isCancelled { once.resume(throwing: CancellationError()) }
            }
        } onCancel: {
            reader.cancel()
            once.resume(throwing: CancellationError())
        }
        return (read, reader)
    }

    private func handle(_ client: NetworkConnection<TCP>) async {
        var connections = [client]
        // Set when an operation on either connection may have been cancelled (see `retire`).
        var interrupted = false
        defer { if interrupted || Task.isCancelled { Self.retire(connections) } }
        do {
            let (head, reader) = try await Self.readHead(from: client, timeout: headTimeout)
            guard let read = head else {
                try? await client.send(ProbeHTTPHead.response(status: 408, reason: "Request Timeout"), endOfStream: true)
                reader.cancel()
                interrupted = true
                return
            }
            let buffer: Data, end: Int
            switch read {
            case .closed:
                return
            case .tooLarge:
                try await client.send(ProbeHTTPHead.response(status: 431, reason: "Request Header Fields Too Large"), endOfStream: true)
                return
            case .head(let data, let headEnd):
                buffer = data
                end = headEnd
            }
            guard let head = ProbeHTTPHead.parse(buffer.prefix(end)) else {
                try await client.send(ProbeHTTPHead.response(status: 400, reason: "Bad Request"), endOfStream: true)
                return
            }
            let early = buffer.dropFirst(end)
            // A stopped proxy records and opens nothing.
            try Task.checkCancellation()
            registry.connectionOpened(host: head.host)

            guard let port = NWEndpoint.Port(rawValue: upstreamPort) else { return }
            let upstream = NetworkConnection(to: .hostPort(host: NWEndpoint.Host(upstreamHost), port: port)) { TCP() }
            connections.append(upstream)
            do {
                // An empty send establishes the connection, so its source port is known before Surge sees
                // the request head.
                try await CaptureTimeout.run(connectTimeout) { try await upstream.send(Data()) }
            } catch {
                interrupted = true
                // A stopped proxy answers nothing.
                try Task.checkCancellation()
                try? await client.send(ProbeHTTPHead.response(status: 502, reason: "Bad Gateway"), endOfStream: true)
                return
            }
            var sourcePort: Int?
            if case .hostPort(let localHost, let localPort)? = upstream.localEndpoint {
                sourcePort = Int(localPort.rawValue)
                registry.registerUpstream(port: Int(localPort.rawValue), host: head.host, sourceAddress: Self.address(localHost))
            }
            defer { if let sourcePort { registry.upstreamClosed(port: sourcePort) } }
            var first = head.forwardedData()
            first.append(contentsOf: early)
            try await upstream.send(first)

            let registry = self.registry
            let host = head.host
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await Self.pipe(from: client, to: upstream, host: host, registry: registry) }
                group.addTask { try await Self.pipe(from: upstream, to: client, host: host, registry: registry) }
                // A pipe that ended with an end of stream has passed it on, and the other direction goes on.
                // One that failed (a reset browser, say) ends the tunnel: the throw cancels the other pipe,
                // whose pending operation closes its connection.
                while try await group.next() != nil {}
            }
        } catch {
            // The browser or Surge failed the connection, or the proxy stopped; a pipe may have been cancelled.
            interrupted = true
        }
    }

    /// Closes connections at once and releases them a while later. `NetworkConnection` has no `cancel()`, but an
    /// operation from a cancelled task cancels the connection, which closes its socket, also when a stop found
    /// the connection between operations. That operation, like any issued once a cancellation has torn the
    /// connection down, queues the connection's start again, in a task that holds it weakly; the start traps
    /// ("Neither nw nor nwGroup is initialized") when the connection is gone by the time it runs, so the
    /// connection outlives it. Connections that ended on their own are released at once and close their sockets.
    static func retire(_ connections: [NetworkConnection<TCP>]) {
        Task.detached {
            withUnsafeCurrentTask { $0?.cancel() }
            for connection in connections { _ = try? await connection.receive(atLeast: 1, atMost: 1) }
        }
        Task.detached {
            try? await Task.sleep(for: retirement)
            withExtendedLifetime(connections) {}
        }
    }

    /// Far longer than a start queued on the cooperative pool waits to run.
    private static let retirement = Duration.seconds(5)

    /// `127.0.0.1`, `::1`: the textual form Surge uses for a record's `sourceAddress`.
    static func address(_ host: NWEndpoint.Host) -> String {
        switch host {
        case .ipv4(let address): "\(address)"
        case .ipv6(let address): "\(address)"
        case .name(let name, _): name
        @unknown default: "\(host)"
        }
    }

    /// Copies bytes until end of stream, then half-closes the other side.
    private static func pipe(from source: NetworkConnection<TCP>, to sink: NetworkConnection<TCP>, host: String, registry: ProbeRegistry) async throws {
        while true {
            let message = try await source.receive(atLeast: 1, atMost: 65_536)
            // A cancelled receive returns an empty end of stream that the peer never sent, and has cancelled
            // `source`; nothing more goes to either side.
            try Task.checkCancellation()
            if !message.content.isEmpty {
                try await sink.send(message.content)
                registry.activity(host: host)
            }
            if message.metadata.endOfStream {
                try await sink.send(Data(), endOfStream: true)
                return
            }
        }
    }
}

/// Resumes a continuation at most once, from whichever callback gets there first.
final class ProbeOnce<Value: Sendable>: Sendable {
    private let continuation = Mutex<CheckedContinuation<Value, Error>?>(nil)

    func set(_ continuation: CheckedContinuation<Value, Error>) {
        self.continuation.withLock { $0 = continuation }
    }

    func resume(returning value: Value) {
        continuation.withLock { $0.take() }?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        continuation.withLock { $0.take() }?.resume(throwing: error)
    }
}
