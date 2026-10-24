import Foundation
import Network
import Synchronization
import Testing
@testable import Tidemark

/// A stand-in for Surge's HTTP proxy on loopback: answers CONNECT with 200 and then echoes, answers
/// absolute-URI requests with `ok` and closes. Records each request head and the client's source port.
final class ProbeFakeUpstream: Sendable {
    struct Seen: Sendable {
        var head: String
        var sourcePort: Int
    }

    private let seen = Mutex<[Seen]>([])
    private let task = Mutex<Task<Void, Never>?>(nil)

    var requests: [Seen] { seen.withLock { $0 } }

    func start() async throws -> UInt16 {
        let listener = try NetworkListener(using: .parameters { TCP() }.localEndpoint(.hostPort(host: "127.0.0.1", port: .any)))
        let ready = ProbeOnce<UInt16>()
        return try await withCheckedThrowingContinuation { continuation in
            ready.set(continuation)
            listener.onStateUpdate { listener, state in
                if case .ready = state, let port = listener.port?.rawValue { ready.resume(returning: port) }
                if case .failed(let error) = state { ready.resume(throwing: error) }
            }
            let run = Task { [self] in
                do { try await listener.run { connection in await self.serve(connection) } } catch {}
            }
            task.withLock { $0 = run }
        }
    }

    func stop() { task.withLock { $0?.cancel() } }

    private func serve(_ connection: NetworkConnection<TCP>) async {
        do {
            var buffer = Data()
            var end: Int?
            while end == nil {
                let message = try await connection.receive(atLeast: 1, atMost: 65_536)
                buffer.append(message.content)
                end = ProbeHTTPHead.headEnd(in: buffer)
                if end == nil, message.metadata.endOfStream { return }
            }
            let head = String(decoding: buffer.prefix(end!), as: UTF8.self)
            var port = 0
            if case .hostPort(_, let remote)? = connection.remoteEndpoint { port = Int(remote.rawValue) }
            seen.withLock { $0.append(Seen(head: head, sourcePort: port)) }
            if head.hasPrefix("CONNECT") {
                try await connection.send(Data("HTTP/1.1 200 Connection established\r\n\r\n".utf8))
                var pending = buffer.dropFirst(end!)
                while true {
                    if !pending.isEmpty { try await connection.send(Data(pending)) }
                    let message = try await connection.receive(atLeast: 1, atMost: 65_536)
                    pending = message.content[...]
                    if message.metadata.endOfStream {
                        if !pending.isEmpty { try await connection.send(Data(pending)) }
                        try await connection.send(Data(), endOfStream: true)
                        return
                    }
                }
            } else {
                try await connection.send(Data("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8), endOfStream: true)
            }
        } catch {}
    }
}

/// A browser-side client of the probe proxy.
struct ProbeTestClient {
    let connection: NetworkConnection<TCP>

    init(port: UInt16) {
        connection = NetworkConnection(to: .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)) { TCP() }
    }

    func send(_ text: String) async throws { try await connection.send(Data(text.utf8)) }

    /// Reads until `marker` arrived or the stream ended.
    func read(until marker: String, timeout: Duration = .seconds(5)) async throws -> String {
        let connection = self.connection
        return try await CaptureTimeout.run(timeout) {
            var data = Data()
            while !String(decoding: data, as: UTF8.self).contains(marker) {
                let message = try await connection.receive(atLeast: 1, atMost: 65_536)
                data.append(message.content)
                if message.metadata.endOfStream { break }
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}

struct ProbeHTTPHeadTests {
    @Test func parsesConnect() throws {
        let head = try #require(ProbeHTTPHead.parse(Data("CONNECT GitHub.com:443 HTTP/1.1\r\nHost: github.com:443\r\nUser-Agent: Safari\r\n\r\n".utf8)))
        #expect(head.kind == .connect)
        #expect(head.host == "github.com" && head.port == 443)
        #expect(head.headers.count == 2)
        #expect(String(decoding: head.forwardedData(), as: UTF8.self) == "CONNECT GitHub.com:443 HTTP/1.1\r\nHost: github.com:443\r\nUser-Agent: Safari\r\n\r\n")
    }

    @Test func parsesAbsoluteURIsAndClosesThem() throws {
        let raw = "GET http://example.com:8080/a?b=1 HTTP/1.1\r\nHost: example.com:8080\r\nProxy-Connection: keep-alive\r\nConnection: keep-alive\r\nAccept: */*\r\n\r\n"
        let head = try #require(ProbeHTTPHead.parse(Data(raw.utf8)))
        #expect(head.kind == .absolute)
        #expect(head.host == "example.com" && head.port == 8080)
        let forwarded = String(decoding: head.forwardedData(), as: UTF8.self)
        #expect(forwarded == "GET http://example.com:8080/a?b=1 HTTP/1.1\r\nHost: example.com:8080\r\nAccept: */*\r\nConnection: close\r\n\r\n")
    }

    @Test func rejectsWhatIsNotAProxyRequest() {
        #expect(ProbeHTTPHead.parse(Data("GET / HTTP/1.1\r\nHost: a\r\n\r\n".utf8)) == nil, "origin-form")
        #expect(ProbeHTTPHead.parse(Data("CONNECT nohost HTTP/1.1\r\n\r\n".utf8)) == nil)
        #expect(ProbeHTTPHead.parse(Data("garbage".utf8)) == nil)
        #expect(ProbeHTTPHead.parse(Data("GET https://a.com/ HTTP/1.1\r\n\r\n".utf8)) == nil)
    }

    @Test func findsTheEndOfTheHead() {
        #expect(ProbeHTTPHead.headEnd(in: Data("CONNECT a:1 HTTP/1.1\r\n\r\nrest".utf8)) == 24)
        #expect(ProbeHTTPHead.headEnd(in: Data("CONNECT a:1 HTTP/1.1\r\n".utf8)) == nil)
    }
}

struct ProbeProxyTests {
    @Test func tunnelsConnectThroughSurgeAndReportsTheSourcePort() async throws {
        let upstream = ProbeFakeUpstream()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let registry = ProbeRegistry()
        let session = UUID()
        registry.begin(sessionID: session, startedAt: .now)
        let proxy = ProbeProxyServer(upstreamPort: upstreamPort, registry: registry)
        let port = try await proxy.start()
        defer { proxy.stop() }
        #expect(port != 0 && port != upstreamPort)

        let client = ProbeTestClient(port: port)
        try await client.send("CONNECT GitHub.com:443 HTTP/1.1\r\nHost: github.com:443\r\n\r\n")
        let established = try await client.read(until: "\r\n\r\n")
        #expect(established.hasPrefix("HTTP/1.1 200 Connection established"))
        try await client.send("hello through the tunnel")
        let echoed = try await client.read(until: "tunnel")
        #expect(echoed == "hello through the tunnel")

        let seen = try #require(upstream.requests.first)
        #expect(seen.head.hasPrefix("CONNECT GitHub.com:443 HTTP/1.1\r\n"))
        #expect(registry.match(sourcePort: seen.sourcePort) == ProbeRegistry.Match(sessionID: session, host: "github.com"))

        let hosts = registry.snapshot().hosts
        #expect(hosts.map(\.host) == ["github.com"])
        #expect(hosts.first?.requestCount == 1)
        #expect((hosts.first?.lastAt ?? -1) >= (hosts.first?.firstAt ?? 0))
    }

    @Test func forwardsPlainHTTPOneRequestPerConnection() async throws {
        let upstream = ProbeFakeUpstream()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let registry = ProbeRegistry()
        registry.begin(sessionID: UUID(), startedAt: .now)
        registry.setStep(2)
        let proxy = ProbeProxyServer(upstreamPort: upstreamPort, registry: registry)
        let port = try await proxy.start()
        defer { proxy.stop() }

        let client = ProbeTestClient(port: port)
        try await client.send("GET http://plain.test/x HTTP/1.1\r\nHost: plain.test\r\nProxy-Connection: keep-alive\r\n\r\n")
        let response = try await client.read(until: "ok")
        #expect(response.hasSuffix("\r\n\r\nok"))
        let head = try #require(upstream.requests.first?.head)
        #expect(head.contains("Connection: close\r\n"))
        #expect(!head.contains("Proxy-Connection"))
        #expect(registry.snapshot().hosts.first?.step == 2)
    }

    @Test func answersBadGatewayWhenSurgeIsDown() async throws {
        let closed = ProbeFakeUpstream()
        let closedPort = try await closed.start()
        closed.stop()
        try await Task.sleep(for: .milliseconds(100))

        let registry = ProbeRegistry()
        registry.begin(sessionID: UUID(), startedAt: .now)
        let proxy = ProbeProxyServer(upstreamPort: closedPort, registry: registry, connectTimeout: .seconds(1))
        let port = try await proxy.start()
        defer { proxy.stop() }
        let client = ProbeTestClient(port: port)
        try await client.send("CONNECT example.com:443 HTTP/1.1\r\n\r\n")
        let response = try await client.read(until: "\r\n\r\n")
        #expect(response.hasPrefix("HTTP/1.1 502"))
    }

    @Test func rejectsMalformedRequests() async throws {
        let registry = ProbeRegistry()
        registry.begin(sessionID: UUID(), startedAt: .now)
        let proxy = ProbeProxyServer(upstreamPort: 9, registry: registry)
        let port = try await proxy.start()
        defer { proxy.stop() }
        let client = ProbeTestClient(port: port)
        try await client.send("GET / HTTP/1.1\r\nHost: x\r\n\r\n")
        #expect(try await client.read(until: "\r\n\r\n").hasPrefix("HTTP/1.1 400"))
        #expect(registry.snapshot().hosts.isEmpty)
    }
}

@MainActor
struct ProbeControllerTests {
    @Test func runsASessionAndSavesIt() async throws {
        let upstream = ProbeFakeUpstream()
        let upstreamPort = try await upstream.start()
        defer { upstream.stop() }
        let surge = CaptureFakeSurge()
        surge.update { $0.httpPort = Int(upstreamPort) }
        let database = CaptureFakeDatabase()
        let model = AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: "tidemark-tests-\(UUID().uuidString)")!))
        model.surge = surge
        model.database = database
        let registry = ProbeRegistry()
        let controller = ProbeController(model: model, registry: registry, loadingWindow: .milliseconds(100), stopGrace: .milliseconds(10))

        let port = try await controller.startProbe(url: "github.com", mode: .iphone, tail: true)
        #expect(model.probe.proxyPort == port)
        #expect(model.probe.phase == .loading)
        let running = try #require(model.probe.running)
        #expect(running.url == "https://github.com")
        #expect(running.host == "github.com")
        #expect(running.steps.map(\.label) == ["Page load · iPhone"])
        #expect(model.probe.selectedID == running.id)

        let client = ProbeTestClient(port: port)
        try await client.send("CONNECT avatars.githubusercontent.com:443 HTTP/1.1\r\n\r\n")
        _ = try await client.read(until: "\r\n\r\n")
        controller.recordStep(label: "Click · Open a repo", url: "github.com/apple/swift")
        let other = ProbeTestClient(port: port)
        try await other.send("CONNECT api.github.com:443 HTTP/1.1\r\n\r\n")
        _ = try await other.read(until: "\r\n\r\n")
        try await Task.sleep(for: .milliseconds(400))
        #expect(model.probe.phase == .recording)
        #expect(model.probe.running?.hosts.map(\.host) == ["avatars.githubusercontent.com", "api.github.com"])
        #expect(model.probe.running?.hosts.map(\.step) == [0, 1])

        let session = try #require(await controller.stopProbe())
        #expect(session.endedAt != nil)
        #expect(session.steps.count == 2)
        #expect(session.hosts.count == 2)
        #expect(model.probe.running == nil && model.probe.phase == .idle && model.probe.proxyPort == nil)
        #expect(model.probe.sessions.first?.id == session.id)
        #expect(await database.probeSessionsSaved.map(\.id) == [session.id])
        let sources = await database.sources
        #expect(sources.count == 2)
        #expect(sources.allSatisfy { $0.sourcePath == "probe:\(session.id.uuidString.lowercased())" && $0.sourceTitle == "Probe · github.com" })

        await controller.deleteProbe(session.id)
        #expect(model.probe.sessions.isEmpty)
        #expect(await database.probeSessionsSaved.isEmpty)
    }

    @Test func rejectsAnInvalidURL() async {
        let model = AppModel(preferences: Preferences(defaults: UserDefaults(suiteName: "tidemark-tests-\(UUID().uuidString)")!))
        let controller = ProbeController(model: model, registry: ProbeRegistry())
        await #expect(throws: URLError.self) { try await controller.startProbe(url: "   ", mode: .desktop, tail: true) }
        #expect(model.probe.running == nil)
    }
}
