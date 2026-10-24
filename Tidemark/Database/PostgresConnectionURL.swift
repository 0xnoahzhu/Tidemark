import Foundation

/// A parsed `postgres://` / `postgresql://` connection URL.
///
/// Supported form: `postgres://user:password@host:port/database?sslmode=…`
///
/// * User and password are percent-decoded. A missing user falls back to the macOS account name (as
///   libpq does); a missing database lets the server use the user name.
/// * The port defaults to 5432. IPv6 hosts are written in brackets (`[::1]`).
/// * `?host=/path/to/socket/dir` connects through a Unix domain socket (`.s.PGSQL.<port>` in that
///   directory), like libpq.
/// * `sslmode` — Tidemark defaults to **no TLS** when the URL does not ask for it, because the typical
///   setup is a PostgreSQL server on the local network or on this Mac. Values:
///   `disable` / `allow` → no TLS; `prefer` → TLS when the server offers it, without certificate checks;
///   `require` → TLS required, without certificate checks (libpq semantics);
///   `verify-ca` → TLS with a trusted chain; `verify-full` → TLS with a trusted chain and matching host name.
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

        var host = components.host ?? ""
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        let port = components.port ?? 5432
        guard (1...65_535).contains(port) else { throw .invalidURL(Self.redact(trimmed)) }

        var socketDirectory: String?
        var tls = TLSMode.disable
        for item in components.queryItems ?? [] {
            let value = item.value ?? ""
            switch item.name.lowercased() {
            case "sslmode":
                switch value.lowercased() {
                case "disable", "allow": tls = .disable
                case "prefer": tls = .prefer
                case "require": tls = .require
                case "verify-ca": tls = .verifyCA
                case "verify-full": tls = .verifyFull
                default: throw .invalidURL(Self.redact(trimmed))
                }
            case "host":
                if value.hasPrefix("/") { socketDirectory = value } else if !value.isEmpty { host = value }
            default:
                continue
            }
        }
        if host.isEmpty, socketDirectory == nil { host = "localhost" }

        let user = components.user.flatMap { $0.isEmpty ? nil : $0 }
            ?? components.queryItems?.first(where: { $0.name.lowercased() == "user" })?.value.flatMap { $0.isEmpty ? nil : $0 }
            ?? NSUserName()

        var database = components.path
        if database.hasPrefix("/") { database.removeFirst() }
        guard !database.contains("/") else { throw .invalidURL(Self.redact(trimmed)) }

        self.host = host
        self.port = port
        self.socketDirectory = socketDirectory
        self.username = user
        self.password = components.password
        self.database = database.isEmpty ? nil : database
        self.tls = tls
    }

    /// Removes the password from a URL string so it can be shown or logged.
    static func redact(_ string: String) -> String {
        guard var components = URLComponents(string: string) else {
            // Not parseable: drop everything between "://" and "@" to be safe.
            guard let scheme = string.range(of: "://"), let at = string.range(of: "@", range: scheme.upperBound..<string.endIndex) else {
                return string
            }
            return String(string[..<scheme.upperBound]) + "…" + String(string[at.lowerBound...])
        }
        if components.password != nil { components.password = "•••" }
        return components.string ?? string
    }
}
