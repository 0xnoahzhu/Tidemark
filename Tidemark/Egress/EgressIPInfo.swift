import Darwin
import Foundation

/// IP facts that Surge's GeoIP database doesn't have: reverse DNS (system resolver) and the network type
/// (hosting / residential / business / wireless) from an IP info service.
///
/// The service is proxycheck.io (`https://proxycheck.io/v2/<ip>?vpn=1&asn=1`): HTTPS, no API key needed for
/// light use (about 100 lookups a day), and its `type` field distinguishes hosting/datacenter networks
/// from residential, business and wireless ones. Only the IP the user looks up is sent, only when they
/// press Look Up; requests time out after 5 s and failures simply leave the type empty.
enum EgressIPInfo {
    /// What the IP info service reports.
    struct ServiceInfo: Hashable, Sendable {
        /// `Hosting`, `Residential`, `Business`, `Wireless`, optionally with ` · proxy`.
        var networkType: String?
        var hostname: String?
        var countryCode: String?
        var asn: Int?
        var organization: String?
    }

    static let serviceName = "proxycheck.io"

    static func serviceURL(for ip: String) -> URL? {
        var components = URLComponents(string: "https://proxycheck.io/v2/")
        components?.path += ip
        components?.queryItems = [URLQueryItem(name: "vpn", value: "1"), URLQueryItem(name: "asn", value: "1")]
        return components?.url
    }

    /// Queries the service (5 s timeout, best effort).
    static func service(_ ip: String, session: URLSession = .shared) async -> ServiceInfo? {
        guard let url = serviceURL(for: ip) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseService(data, ip: ip)
    }

    /// Parses `{"status":"ok","1.1.1.1":{"asn":"AS13335","organisation":"…","isocode":"AU","proxy":"no","type":"Business"}}`.
    static func parseService(_ data: Data, ip: String) -> ServiceInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[ip] as? [String: Any] else { return nil }
        var info = ServiceInfo()
        if let type = (entry["type"] as? String)?.trimmingCharacters(in: .whitespaces), !type.isEmpty {
            info.networkType = (entry["proxy"] as? String)?.lowercased() == "yes" ? "\(type) · proxy" : type
        }
        info.hostname = (entry["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        info.countryCode = entry["isocode"] as? String
        if let asn = entry["asn"] as? String { info.asn = Int(asn.uppercased().replacingOccurrences(of: "AS", with: "")) }
        info.organization = (entry["organisation"] as? String) ?? (entry["provider"] as? String)
        return info
    }

    /// PTR name via `getnameinfo`, resolved off the main actor.
    static func reverseDNS(_ ip: String) async -> String? {
        await Task.detached(priority: .utility) { lookupName(ip) }.value
    }

    /// Blocking `getnameinfo(NI_NAMEREQD)`.
    nonisolated static func lookupName(_ ip: String) -> String? {
        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status: Int32
        if ip.contains(":") {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            guard inet_pton(AF_INET6, ip, &address.sin6_addr) == 1 else { return nil }
            status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in6>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        } else {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            guard inet_pton(AF_INET, ip, &address.sin_addr) == 1 else { return nil }
            status = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    getnameinfo($0, socklen_t(MemoryLayout<sockaddr_in>.size), &host, socklen_t(host.count), nil, 0, NI_NAMEREQD)
                }
            }
        }
        guard status == 0 else { return nil }
        let name = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        return name.isEmpty || name == ip ? nil : name
    }
}
