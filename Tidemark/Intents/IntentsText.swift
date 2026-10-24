import Foundation

/// Dialog text of Tidemark's intents, in the language chosen in Settings.
@MainActor
enum IntentsText {
    static func recordingDialog(isOn: Bool) -> String {
        isOn
            ? tr("Recording resumed. Every request Surge sees will be saved to PostgreSQL again, and alerts turn back on.", "Intents")
            : tr("Recording paused. Requests Surge handles from now on won't be saved to PostgreSQL, and no new-site alerts will fire until you resume.", "Intents")
    }

    /// `12,345 requests today · 7 new destinations`
    static func summary(_ figures: IntentsTodayFigures) -> String {
        let requests = trf(figures.requests == 1 ? "%@ request today" : "%@ requests today", "Intents", Fmt.count(figures.requests))
        let destinations: String = switch figures.newDestinations {
        case 0: tr("no new destinations", "Intents")
        case 1: tr("1 new destination", "Intents")
        default: trf("%@ new destinations", "Intents", Fmt.count(figures.newDestinations))
        }
        return "\(requests) · \(destinations)"
    }

    /// `104.16.27.34 · US · AS13335 Cloudflare · Hosting · anycast`
    static func lookupLine(_ result: IPLookupResult) -> String {
        let geo = GeoInfo(countryCode: result.country, asn: result.asn, organization: result.organization).display
        let details = [geo, result.networkType, result.reverseDNS]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !details.isEmpty else { return trf("No details found for %@.", "Intents", result.ip) }
        return ([result.ip] + details).joined(separator: " · ")
    }

    /// The trimmed address when `value` is an IPv4 or IPv6 literal (brackets and zone allowed), else nil.
    nonisolated static func normalizedIP(_ value: String) -> String? {
        var address = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if address.hasPrefix("["), address.hasSuffix("]") { address = String(address.dropFirst().dropLast()) }
        guard !address.isEmpty, HostName.isIPAddress(address) else { return nil }
        if !HostName.isIPv4(address) {
            // `isIPAddress` accepts any hex-and-colon string; require a plausible IPv6 shape.
            let groups = address.split(separator: "%").first.map { $0.split(separator: ":", omittingEmptySubsequences: false) } ?? []
            guard address.contains(":"), (3...8).contains(groups.count), groups.allSatisfy({ $0.count <= 4 || $0.contains(".") }) else { return nil }
        }
        return address
    }
}
