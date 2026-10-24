import Foundation
import Network
import Synchronization

/// Loopback HTTP proxy opened for one site probe, built on the Swift-native Network API
/// (`NetworkListener` / `NetworkConnection`, macOS 26).
///
/// It listens on `127.0.0.1` with an ephemeral port and accepts `CONNECT` tunnels and absolute-URI plain
/// HTTP requests. Each browser connection gets its own upstream connection to Surge's HTTP proxy: the
/// proxy registers the upstream's local source port with the `ProbeRegistry` (so the capture pipeline can
/// match Surge's record of it), replays the request head, and then pipes both directions, relaying
/// Surge's response untouched. Every host and its activity window are reported to the registry.
final class ProbeProxyServer: Sendable {
    let upstreamHost: String
    let upstreamPort: UInt16
    let registry: ProbeRegistry
    /// How long to wait for Surge to accept an upstream connection.
    let connectTimeout: Duration

    private let runTask = Mutex<Task<Void, Never>?>(nil)

    init(upstreamPort: UInt16, registry: ProbeRegistry, upstreamHost: String = "127.0.0.1", connectTimeout: Duration = .seconds(5)) {
        self.upstreamHost = upstreamHost
        self.upstreamPort = upstreamPort
        self.registry = registry
        self.connectTimeout = connectTimeout
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

    private func handle(_ client: NetworkConnection<TCP>) async {
        do {
            var buffer = Data()
            var end: Int?
            while end == nil {
                let message = try await client.receive(atLeast: 1, atMost: 65_536)
                buffer.append(message.content)
                end = ProbeHTTPHead.headEnd(in: buffer)
                if end == nil, message.metadata.endOfStream { return }
                if end == nil, buffer.count > ProbeHTTPHead.maxLength {
                    try await client.send(ProbeHTTPHead.response(status: 431, reason: "Request Header Fields Too Large"), endOfStream: true)
                    return
                }
            }
            guard let end, let head = ProbeHTTPHead.parse(buffer.prefix(end)) else {
                try await client.send(ProbeHTTPHead.response(status: 400, reason: "Bad Request"), endOfStream: true)
                return
            }
            let early = buffer.dropFirst(end)
            registry.connectionOpened(host: head.host)

            guard let port = NWEndpoint.Port(rawValue: upstreamPort) else { return }
            let upstream = NetworkConnection(to: .hostPort(host: NWEndpoint.Host(upstreamHost), port: port)) { TCP() }
            do {
                // An empty send establishes the connection, so its source port is known before Surge sees
                // the request head.
                try await CaptureTimeout.run(connectTimeout) { try await upstream.send(Data()) }
            } catch {
                try? await client.send(ProbeHTTPHead.response(status: 502, reason: "Bad Gateway"), endOfStream: true)
                return
            }
            if case .hostPort(_, let localPort)? = upstream.localEndpoint {
                registry.registerUpstream(port: Int(localPort.rawValue), host: head.host)
            }
            var first = head.forwardedData()
            first.append(contentsOf: early)
            try await upstream.send(first)

            let registry = self.registry
            let host = head.host
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { try await Self.pipe(from: client, to: upstream, host: host, registry: registry) }
                group.addTask { try await Self.pipe(from: upstream, to: client, host: host, registry: registry) }
                try await group.waitForAll()
            }
        } catch {
            // The browser or Surge closed the connection; both sides are released with this task.
        }
    }

    /// Copies bytes until end of stream, then half-closes the other side.
    private static func pipe(from source: NetworkConnection<TCP>, to sink: NetworkConnection<TCP>, host: String, registry: ProbeRegistry) async throws {
        while true {
            let message = try await source.receive(atLeast: 1, atMost: 65_536)
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
