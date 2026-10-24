import Foundation

/// Stable identifier of a monitored app (row in `apps`).
typealias AppID = UUID

/// Stable identifier of a Mac (or a remote Surge instance) writing to the database (row in `devices`).
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
        var s = name
        for suffix in [", Inc.", ", Inc", " Inc.", " Inc", ", LLC", " LLC", " Ltd.", " Ltd", ", Ltd.", " Co., Ltd.", " Corporation", " Corp.", " GmbH", " S.A.", " SRL", " B.V."] where s.hasSuffix(suffix) {
            s = String(s.dropLast(suffix.count))
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}

/// Generic connection state for an external dependency (Surge controller, PostgreSQL).
enum LinkStatus: Equatable, Sendable {
    case idle
    case connecting
    case connected(detail: String)
    case failed(message: String)
    case paused

    var isHealthy: Bool {
        if case .connected = self { return true }
        return false
    }
}
