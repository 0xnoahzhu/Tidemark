import Foundation

/// The head of a request the probe browser sends to its proxy: `CONNECT host:port` for TLS (and
/// WebSocket) tunnels, or an absolute-URI request (`GET http://host/path`) for plain HTTP.
struct ProbeHTTPHead: Hashable, Sendable {
    struct Header: Hashable, Sendable {
        var name: String
        var value: String
    }

    enum Kind: Hashable, Sendable {
        case connect
        case absolute
    }

    var method: String
    var target: String
    var version: String
    var headers: [Header]
    var kind: Kind
    /// Destination host (lowercased, without brackets).
    var host: String
    var port: Int

    /// Largest head the proxy accepts.
    static let maxLength = 64 * 1024

    private static let terminator = Data("\r\n\r\n".utf8)

    /// Offset just past the blank line that ends the head, if it arrived.
    static func headEnd(in data: Data) -> Int? {
        data.range(of: terminator).map { $0.upperBound - data.startIndex }
    }

    /// Parses a head (request line and headers, with or without the final blank line).
    static func parse(_ data: Data) -> ProbeHTTPHead? {
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        var lines = text.components(separatedBy: "\r\n")
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].uppercased().hasPrefix("HTTP/") else { return nil }
        let method = parts[0].uppercased()
        let target = parts[1]
        var headers: [Header] = []
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { headers.append(Header(name: name, value: value)) }
        }

        if method == "CONNECT" {
            let (host, port) = HostName.splitHostPort(target)
            guard !host.isEmpty, let port, (1...65_535).contains(port) else { return nil }
            return ProbeHTTPHead(method: method, target: target, version: parts[2], headers: headers, kind: .connect,
                                 host: host.lowercased(), port: port)
        }
        guard let components = URLComponents(string: target), components.scheme?.lowercased() == "http",
              var host = components.host, !host.isEmpty else { return nil }
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        return ProbeHTTPHead(method: method, target: target, version: parts[2], headers: headers, kind: .absolute,
                             host: host.lowercased(), port: components.port ?? 80)
    }

    /// The head forwarded to Surge. Absolute-URI requests are sent with `Connection: close` so every
    /// connection carries one request, and therefore one host the probe can account for.
    func forwardedData() -> Data {
        var lines = ["\(method) \(target) \(version)"]
        let hopByHop: Set<String> = ["proxy-connection", "connection", "keep-alive"]
        for header in headers where kind == .connect || !hopByHop.contains(header.name.lowercased()) {
            lines.append("\(header.name): \(header.value)")
        }
        if kind == .absolute { lines.append("Connection: close") }
        return Data((lines.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    /// A minimal response the proxy sends itself (errors only).
    static func response(status: Int, reason: String) -> Data {
        Data("HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
    }
}
