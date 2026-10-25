import Darwin
import Foundation
import Synchronization

/// IP facts that Surge's GeoIP database doesn't have: reverse DNS (system resolver) and the network type
/// (hosting / residential / business / mobile) from an IP info service.
///
/// The service is proxycheck.io (`https://proxycheck.io/v2/<ip>?vpn=1&asn=1`): HTTPS, no API key needed for
/// light use (about 100 lookups a day), and its `type` field distinguishes hosting/datacenter networks
/// from residential, business and wireless ones. It is always on (there is no setting for it) and asked only
/// for Tidemark's own egress IPs and for IPs the user looks up, never for private, loopback,
/// link-local, shared (CGNAT), Surge fake-IP, documentation, multicast or reserved addresses. Requests time
/// out after 5 s and failures simply leave the type empty.
enum EgressIPInfo {
    /// What the IP info service reports.
    struct ServiceInfo: Hashable, Sendable {
        /// `Hosting`, `Residential`, `Business`, `Wireless`, optionally with ` · proxy` (display text).
        var networkType: String?
        /// The service's type as a stable lowercase token: `hosting`, `residential`, `business`, `mobile`…
        var kind: String?
        var hostname: String?
        var countryCode: String?
        var asn: Int?
        var organization: String?
    }

    static func serviceURL(for ip: String) -> URL? {
        var components = URLComponents(string: "https://proxycheck.io/v2/")
        components?.path += ip
        components?.queryItems = [URLQueryItem(name: "vpn", value: "1"), URLQueryItem(name: "asn", value: "1")]
        return components?.url
    }

    /// Queries the service (5 s timeout, best effort). Callers check `isPublic(_:)` first.
    static func service(_ ip: String, session: URLSession = .shared) async -> ServiceInfo? {
        guard isPublic(ip), let url = serviceURL(for: ip) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let finalRequest = request
        let reply = try? await CaptureTimeout.run(.seconds(6)) { try await session.data(for: finalRequest) }
        guard let (data, response) = reply, (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parseService(data, ip: ip)
    }

    /// Parses `{"status":"ok","1.1.1.1":{"asn":"AS13335","organisation":"…","isocode":"AU","proxy":"no","type":"Business"}}`.
    static func parseService(_ data: Data, ip: String) -> ServiceInfo? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entry = root[ip] as? [String: Any] else { return nil }
        var info = ServiceInfo()
        if let type = (entry["type"] as? String)?.trimmingCharacters(in: .whitespaces), !type.isEmpty {
            info.networkType = (entry["proxy"] as? String)?.lowercased() == "yes" ? "\(type) · proxy" : type
            info.kind = networkKind(type)
        }
        info.hostname = (entry["hostname"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        info.countryCode = (entry["isocode"] as? String).flatMap { $0.isEmpty ? nil : $0.uppercased() }
        if let asn = entry["asn"] as? String { info.asn = Int(asn.uppercased().replacingOccurrences(of: "AS", with: "")) }
        info.organization = (entry["organisation"] as? String) ?? (entry["provider"] as? String)
        return info
    }

    /// `hosting`, `residential`, `business`, `mobile`, `education`, `vpn`, `tor`… from the service's `type`
    /// (`Hosting`, `Data Center`, `Wireless`…), so the UI can translate a known set of values.
    static func networkKind(_ serviceType: String?) -> String? {
        guard let type = serviceType?.trimmingCharacters(in: .whitespaces).lowercased(), !type.isEmpty else { return nil }
        if type.contains("hosting") || type.contains("data center") || type.contains("datacenter") { return "hosting" }
        if type.contains("residential") { return "residential" }
        if type.contains("wireless") || type.contains("mobile") || type.contains("cellular") { return "mobile" }
        if type.contains("business") { return "business" }
        if type.contains("education") { return "education" }
        if type == "vpn" { return "vpn" }
        if type == "tor" { return "tor" }
        return type
    }

    // MARK: Addresses

    /// Whether `ip` is a public unicast address. Private (10/8, 172.16/12, 192.168/16, fc00::/7), loopback,
    /// link-local, shared CGNAT (100.64/10), Surge's fake-IP range (198.18/15), documentation, multicast,
    /// reserved and unspecified addresses are not.
    static func isPublic(_ ip: String) -> Bool {
        var address = ip.trimmingCharacters(in: CharacterSet(charactersIn: "[] "))
        if let percent = address.firstIndex(of: "%") { address = String(address[..<percent]) }
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let value = UInt32(bigEndian: v4.s_addr)
            return isPublicIPv4([UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)])
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        if bytes[0..<10].allSatisfy({ $0 == 0 }), bytes[10] == 0xFF, bytes[11] == 0xFF {
            return isPublicIPv4(Array(bytes[12..<16]))   // ::ffff:a.b.c.d
        }
        if bytes[0..<15].allSatisfy({ $0 == 0 }) { return false }              // :: and ::1
        if bytes[0] & 0xFE == 0xFC { return false }                              // fc00::/7 unique local
        if bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { return false }            // fe80::/10 link-local
        if bytes[0] == 0xFF { return false }                                     // ff00::/8 multicast
        if bytes[0] == 0x20, bytes[1] == 0x01, bytes[2] == 0x0D, bytes[3] == 0xB8 { return false } // 2001:db8::/32
        return true
    }

    private static func isPublicIPv4(_ b: [UInt8]) -> Bool {
        switch (b[0], b[1], b[2]) {
        case (0, _, _), (10, _, _), (127, _, _): return false
        case (100, 64...127, _): return false                 // shared address space (CGNAT)
        case (169, 254, _): return false
        case (172, 16...31, _): return false
        case (192, 0, 0), (192, 0, 2), (192, 168, _): return false
        case (198, 18...19, _): return false                  // benchmarking range, Surge's fake IPs
        case (198, 51, 100), (203, 0, 113): return false
        default: return b[0] < 224                            // multicast and reserved
        }
    }

    // MARK: Reverse DNS

    /// PTR name via `getnameinfo`, resolved off the main actor. Returns nil after `timeout` even though the
    /// blocking lookup cannot be cancelled; its late result is dropped.
    static func reverseDNS(_ ip: String, timeout: Duration = .seconds(5)) async -> String? {
        let once = ResumeOnce()
        return await withCheckedContinuation { (continuation: CheckedContinuation<String?, Never>) in
            once.set(continuation)
            let timer = Task.detached {
                try? await Task.sleep(for: timeout)
                once.resume(nil)
            }
            Task.detached(priority: .utility) {
                let name = lookupName(ip)
                timer.cancel()
                once.resume(name)
            }
        }
    }

    /// Resumes a continuation at most once, from whichever of the lookup and the timer gets there first.
    private final class ResumeOnce: Sendable {
        private let continuation = Mutex<CheckedContinuation<String?, Never>?>(nil)

        func set(_ continuation: CheckedContinuation<String?, Never>) {
            self.continuation.withLock { $0 = continuation }
        }

        func resume(_ value: String?) {
            continuation.withLock { $0.take() }?.resume(returning: value)
        }
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
