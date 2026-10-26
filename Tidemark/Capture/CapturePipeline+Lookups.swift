import Foundation

/// Remote IPs of proxied hostnames (through Surge's DNS) and GeoIP data for every remote IP.
///
/// A request's address records where it came from (`RemoteIPSource`): Surge's cache is used only while Surge's own
/// expiry says its answer holds, and every other hostname is looked up (`dns lookup`), so no request is given an
/// address that expired hours ago.
extension CapturePipeline {
    /// Reads Surge's DNS cache (`dump dns`) and fills waiting requests. An answer counts until Surge's `expiresTime`
    /// (Surge keeps expired answers listed for hours); a static mapping of its profile never expires. An answer of
    /// Tidemark's own lookup keeps its label while Surge reports the same addresses, and a cached answer keeps the time
    /// Tidemark first saw it until Surge resolves it again (a new expiry).
    func refreshDNSCache(now: Date = .now) async {
        guard let records = try? await surge.dnsCache() else { return }
        for record in records {
            let expires = record.expires ?? .distantFuture
            guard expires > now else { continue }
            if let current = dnsCache[record.domain], current.expires > now, Set(current.ips) == Set(record.addresses),
               current.source != .surgeCache || abs(current.expires.timeIntervalSince(expires)) < 1 {
                continue
            }
            dnsCache[record.domain] = ResolvedHost(ips: record.addresses, expires: expires, source: .surgeCache,
                                                  resolvedAt: record.isLocal ? nil : now)
        }
        dnsCache = dnsCache.filter { $0.value.expires > now }
        for host in Array(waitingForHost.keys) {
            if let resolved = dnsCache[host] { applyResolved(host: host, resolved, now: now) }
        }
    }

    func resolveAddress(_ entry: inout Entry, id: Int64, now: Date) {
        let host = entry.record.host
        if entry.record.remoteIP == nil, !host.isEmpty, !HostName.isIPAddress(host) {
            if let cached = dnsCache[host], cached.expires > now, let ip = Self.preferredIP(cached.ips) {
                entry.record.remoteIP = ip
                entry.record.remoteIPSource = cached.source
                entry.record.remoteIPResolvedAt = cached.resolvedAt
                if entry.probeMatched, let port = entry.sourcePort { probes.addIP(ip, sourcePort: port, sourceAddress: entry.sourceAddress) }
            } else if (dnsFailures[host] ?? .distantPast) <= now {
                waitingForHost[host, default: []].insert(id)
                if !dnsInFlight.contains(host), !dnsQueue.contains(host) {
                    if dnsQueue.count >= 512 {
                        // The oldest lookup is dropped with the requests waiting for it.
                        waitingForHost[dnsQueue.removeFirst()] = nil
                    }
                    dnsQueue.append(host)
                }
                pumpDNS()
            }
        }
        if let ip = entry.record.remoteIP, entry.record.geo == nil {
            if let geo = geoCache[ip] {
                entry.record.geo = geo
            } else if !Self.isPrivate(ip), (geoFailures[ip] ?? .distantPast) <= now {
                waitingForGeo[ip, default: []].insert(id)
                if !geoInFlight.contains(ip), !geoQueue.contains(ip) {
                    if geoQueue.count >= 512 { waitingForGeo[geoQueue.removeFirst()] = nil }
                    geoQueue.append(ip)
                }
                pumpGeo()
            }
        }
    }

    private func pumpDNS() {
        while dnsInFlight.count < maxConcurrentLookups, !dnsQueue.isEmpty {
            let host = dnsQueue.removeFirst()
            dnsInFlight.insert(host)
            let surge = self.surge
            Task {
                let result = try? await surge.dnsLookup(host)
                self.didLookup(host: host, result: result)
            }
        }
    }

    private func didLookup(host: String, result: SurgeDNSLookup?, now: Date = .now) {
        dnsInFlight.remove(host)
        if let result, !result.addresses.isEmpty {
            let ttl = min(3600, max(60, result.expiresIn ?? 0))
            let resolved = ResolvedHost(ips: result.addresses, expires: now.addingTimeInterval(ttl), source: .tidemarkLookup, resolvedAt: now)
            dnsCache[host] = resolved
            applyResolved(host: host, resolved, now: now)
        } else {
            dnsFailures[host] = now.addingTimeInterval(120)
            waitingForHost[host] = nil
        }
        pumpDNS()
    }

    func applyResolved(host: String, _ resolved: ResolvedHost, now: Date) {
        guard let ids = waitingForHost.removeValue(forKey: host), let ip = Self.preferredIP(resolved.ips) else { return }
        for id in ids {
            guard var entry = entries[id], entry.record.remoteIP == nil else { continue }
            entry.record.remoteIP = ip
            entry.record.remoteIPSource = resolved.source
            entry.record.remoteIPResolvedAt = resolved.resolvedAt
            entry.record.geo = geoCache[ip]
            entry.dirty = true
            entry.urgent = true
            if entry.probeMatched, let port = entry.sourcePort { probes.addIP(ip, sourcePort: port, sourceAddress: entry.sourceAddress) }
            resolveAddress(&entry, id: id, now: now)
            recordSources(&entry, now: now)
            entries[id] = entry
            markChanged(entry.record, fresh: false)
            lateIPContact(id: id, now: now)
        }
    }

    private func pumpGeo() {
        while geoInFlight.count < maxConcurrentLookups, !geoQueue.isEmpty {
            let ip = geoQueue.removeFirst()
            geoInFlight.insert(ip)
            let surge = self.surge
            let database = self.database
            let useDatabase = online
            Task {
                let geo = await Self.lookupGeo(ip: ip, surge: surge, database: database, useDatabase: useDatabase)
                self.didLookupGeo(ip: ip, geo: geo)
            }
        }
    }

    /// GeoIP from the shared `ip_info` cache, else from Surge (and saved for every Mac).
    private static func lookupGeo(ip: String, surge: any SurgeClient, database: any TidemarkDatabase, useDatabase: Bool) async -> GeoInfo? {
        if useDatabase, let cached = try? await database.ipInfo(ip) { return cached }
        guard let result = try? await surge.geoIP(ip) else { return nil }
        let geo = GeoInfo(countryCode: result.country, asn: result.asn, organization: result.organization)
        if useDatabase { try? await database.saveIPInfo(ip, geo: geo) }
        return geo
    }

    private func didLookupGeo(ip: String, geo: GeoInfo?, now: Date = .now) {
        geoInFlight.remove(ip)
        let ids = waitingForGeo.removeValue(forKey: ip) ?? []
        if let geo {
            if geoCache.count > 50_000 { geoCache.removeAll(keepingCapacity: true) }
            geoCache[ip] = geo
            for id in ids {
                guard var entry = entries[id], entry.record.remoteIP == ip, entry.record.geo == nil else { continue }
                entry.record.geo = geo
                entry.dirty = true
                entry.urgent = true
                entries[id] = entry
                markChanged(entry.record, fresh: false)
            }
        } else {
            geoFailures[ip] = now.addingTimeInterval(600)
        }
        pumpGeo()
    }

    /// Prefers an IPv4 address.
    static func preferredIP(_ ips: [String]) -> String? {
        ips.first(where: HostName.isIPv4) ?? ips.first
    }

    /// Loopback, link-local, private, CGNAT and Surge's fake-IP ranges carry no GeoIP data.
    static func isPrivate(_ ip: String) -> Bool {
        if ip.contains(":") {
            let lower = ip.lowercased()
            return lower == "::1" || lower.hasPrefix("fe80") || lower.hasPrefix("fc") || lower.hasPrefix("fd")
        }
        let parts = ip.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        switch (parts[0], parts[1]) {
        case (10, _), (127, _), (0, _), (169, 254), (192, 168): return true
        case (172, 16...31), (198, 18...19), (100, 64...127): return true
        default: return false
        }
    }
}
