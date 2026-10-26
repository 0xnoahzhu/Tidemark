import Foundation

/// Stable identifier of a monitored app (row in `apps`).
typealias AppID = UUID

/// Stable identifier of a Mac writing to the database (row in `devices`).
typealias DeviceID = UUID

/// Whether a host or IP inventory entry is a domain name or an IP address.
enum HostKind: String, Codable, Sendable, CaseIterable, Hashable {
    case domain
    case ip
}

/// One hop in a process ancestry chain, ordered root → leaf when stored in an array.
struct ProcessLink: Codable, Hashable, Sendable {
    var name: String
    var pid: Int32
    var path: String?
    /// Process start time; PIDs are reused, so `(pid, startTime)` identifies a process.
    var startTime: Date?
}

/// Country / ASN information for an IP address, as reported by Surge's GeoIP and ASN databases.
struct GeoInfo: Codable, Hashable, Sendable {
    var countryCode: String?
    var asn: Int?
    var organization: String?

    /// Display form used across the design, e.g. `US · AS13335 Cloudflare`.
    var display: String {
        var parts: [String] = []
        if let countryCode, !countryCode.isEmpty { parts.append(countryCode.uppercased()) }
        var network: [String] = []
        if let asn { network.append("AS\(asn)") }
        if let organization, !organization.isEmpty { network.append(GeoInfo.shortOrganization(organization)) }
        if !network.isEmpty { parts.append(network.joined(separator: " ")) }
        return parts.joined(separator: " · ")
    }

    /// Trims legal suffixes so `Cloudflare, Inc.` reads as `Cloudflare`.
    static func shortOrganization(_ name: String) -> String {
        // ASN names may carry a legal form or an address after a comma: `Anthropic, PBC`, `Tencent Building, …`.
        var s = name.components(separatedBy: ", ").first ?? name
        for suffix in [" Inc.", " Inc", " LLC", " Ltd.", " Ltd", " Co.,Ltd.", " Co., Ltd", " Limited", " Corporation", " Corp.", " GmbH", " S.A.", " SRL", " B.V.", " PBC"] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        // `Amazon.com, Inc.` → `Amazon`
        if s.lowercased().hasSuffix(".com"), !s.contains(" ") { s = String(s.dropLast(4)) }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Generic connection state for an external dependency (Surge controller, PostgreSQL).
enum LinkStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected(detail: String)
    /// Why the link is down. The error itself is kept and described where it is shown
    /// (`CaptureEngine.message(for:)`), so the text follows the UI language when it changes later.
    case failed(any Error)
    case paused

    var isHealthy: Bool {
        if case .connected = self { return true }
        return false
    }

    /// Failures are equal when their errors are: equal values of an `Equatable` error type, otherwise errors
    /// of the same type that describe themselves the same way.
    static func == (lhs: LinkStatus, rhs: LinkStatus) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.connecting, .connecting), (.paused, .paused): true
        case (.connected(let a), .connected(let b)): a == b
        case (.failed(let a), .failed(let b)): sameError(a, b)
        default: false
        }
    }

    private static func sameError(_ a: any Error, _ b: any Error) -> Bool {
        if let a = (a as Any) as? any Equatable { return a.isEqual(to: b) }
        return type(of: a) == type(of: b) && String(describing: a) == String(describing: b)
    }
}

private extension Equatable {
    func isEqual(to other: Any) -> Bool { (other as? Self) == self }
}
