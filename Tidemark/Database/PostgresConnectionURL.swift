import Foundation

/// A parsed `postgres://` / `postgresql://` connection URL.
///
/// Supported form: `postgres://user:password@host:port/database?sslmode=…`
///
/// * User and password are percent-decoded. A missing user falls back to the macOS account name (as
///   libpq does); a missing database lets the server use the user name.
/// * The port defaults to 5432. IPv6 hosts are written in brackets (`[::1]`).
/// * libpq query parameters: `user`, `password`, `dbname` and `port` fill in what the URL itself leaves
///   out; `host` replaces the URL's host, and `?host=/path/to/socket/dir` connects through the Unix domain
///   socket `.s.PGSQL.<port>` in that directory. Other libpq parameters are ignored.
/// * `sslmode` — as in libpq, the default is `prefer` (TLS when the server offers it). Connections to this
///   Mac (`localhost`, `127.0.0.1`, `::1`, Unix sockets) default to `disable`, since nothing leaves the Mac.
///   Values: `disable` / `allow` → no TLS; `prefer` → TLS when the server offers it, without certificate
///   checks; `require` → TLS required, without certificate checks; `verify-ca` → TLS with a trusted chain;
///   `verify-full` → TLS with a trusted chain and matching host name.
/// * `sslrootcert` — PEM file (or directory) of the CA certificates to trust instead of the system's, for a
///   server with a private CA. As in libpq, `require` together with a root certificate verifies the chain
///   (`verify-ca`), and `sslrootcert=system` trusts the system roots and implies `verify-full`.
struct PostgresConnectionURL: Hashable, Sendable {
    /// Transport security requested by `sslmode`.
    enum TLSMode: String, Hashable, Sendable, CaseIterable {
        case disable
        case prefer
        case require
        case verifyCA = "verify-ca"
        case verifyFull = "verify-full"
    }

    var host: String
    var port: Int
    /// Directory of the server's Unix domain socket, when `?host=/…` is used instead of TCP.
    var socketDirectory: String?
    var username: String
    var password: String?
    var database: String?
    var tls: TLSMode
    /// CA certificates (`sslrootcert`) trusted instead of the system roots; nil uses the system roots.
    var rootCertificatePath: String?

    /// The Unix domain socket path (`<dir>/.s.PGSQL.<port>`), if the URL asked for one.
    var socketPath: String? {
        guard let socketDirectory else { return nil }
        let dir = socketDirectory.hasSuffix("/") ? String(socketDirectory.dropLast()) : socketDirectory
        return "\(dir)/.s.PGSQL.\(port)"
    }

    /// `host:port/database` without credentials, for logs and error messages.
    var redacted: String {
        let target = socketDirectory ?? (host.contains(":") ? "[\(host)]:\(port)" : "\(host):\(port)")
        return "\(target)/\(database ?? username)"
    }

    /// Parses a connection URL. Throws `DatabaseError.invalidURL` with the URL's password removed.
    init(_ string: String) throws(DatabaseError) {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "postgres" || scheme == "postgresql" else {
            throw .invalidURL(Self.redact(trimmed))
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            if !value.isEmpty { query[item.name.lowercased()] = value }
        }

        var host = components.host ?? ""
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        var socketDirectory: String?
        if let value = query["host"] {
            if value.hasPrefix("/") { socketDirectory = value } else { host = value }
        }
        if host.isEmpty, socketDirectory == nil { host = "localhost" }

        var port = components.port
        if port == nil, let value = query["port"] {
            guard let parsed = Int(value) else { throw .invalidURL(Self.redact(trimmed)) }
            port = parsed
        }
        guard (1...65_535).contains(port ?? 5432) else { throw .invalidURL(Self.redact(trimmed)) }

        var rootCertificate = query["sslrootcert"]
        var tls: TLSMode?
        if let value = query["sslmode"] {
            switch value.lowercased() {
            case "disable", "allow": tls = .disable
            case "prefer": tls = .prefer
            case "require": tls = rootCertificate == nil ? .require : .verifyCA
            case "verify-ca": tls = .verifyCA
            case "verify-full": tls = .verifyFull
            default: throw .invalidURL(Self.redact(trimmed))
            }
        }
        if rootCertificate == "system" {
            rootCertificate = nil
            if tls == nil || tls == .prefer || tls == .require || tls == .verifyCA { tls = .verifyFull }
        }
        let isLocal = socketDirectory != nil || Self.isLoopback(host)

        var database = components.path
        if database.hasPrefix("/") { database.removeFirst() }
        guard !database.contains("/") else { throw .invalidURL(Self.redact(trimmed)) }
        if database.isEmpty { database = query["dbname"] ?? "" }

        let user = components.user.flatMap { $0.isEmpty ? nil : $0 } ?? query["user"] ?? NSUserName()
        let password = components.password.flatMap { $0.isEmpty ? nil : $0 } ?? query["password"]

        self.host = host
        self.port = port ?? 5432
        self.socketDirectory = socketDirectory
        self.username = user
        self.password = password
        self.database = database.isEmpty ? nil : database
        self.tls = tls ?? (isLocal ? .disable : .prefer)
        self.rootCertificatePath = rootCertificate
    }

    /// `localhost`, `127.0.0.0/8` or `::1`: traffic that never leaves this Mac.
    static func isLoopback(_ host: String) -> Bool {
        let lower = host.lowercased()
        if lower == "localhost" || lower.hasSuffix(".localhost") || lower == "::1" { return true }
        return HostName.isIPv4(lower) && lower.hasPrefix("127.")
    }

    /// Removes the password (in the user info or a `password` query parameter) from a URL string so it
    /// can be shown or logged.
    static func redact(_ string: String) -> String {
        guard var components = URLComponents(string: string) else {
            // Not parseable: drop everything between "://" and "@" to be safe.
            guard let scheme = string.range(of: "://"), let at = string.range(of: "@", range: scheme.upperBound..<string.endIndex) else {
                return string.contains("password=") ? "(invalid URL)" : string
            }
            return String(string[..<scheme.upperBound]) + "…" + String(string[at.lowerBound...])
        }
        if components.password != nil { components.password = "•••" }
        if let items = components.queryItems, items.contains(where: { $0.name.lowercased() == "password" }) {
            components.queryItems = items.map { $0.name.lowercased() == "password" ? URLQueryItem(name: $0.name, value: "•••") : $0 }
        }
        return components.string ?? string
    }
}
