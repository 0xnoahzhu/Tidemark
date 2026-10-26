import Foundation

extension Navigation {
    /// Opens the Requests page's History on every stored request to exactly `host` (a domain or an IP literal), the
    /// host shown as a removable chip beside the filters.
    ///
    /// The time range and the Mac stay as they are; the app, policy and status filters and the search are cleared, so
    /// nothing else hides the host's requests. A request selected in History stays selected; one from elsewhere
    /// does not.
    func openRequests(forHost host: String) {
        let normalized = RequestsHostFilter.normalized(host)
        guard !normalized.isEmpty else { return }
        if page != .requests || requestsLive { selectedRequest = nil }
        history.host = normalized
        history.appID = nil
        history.policy = nil
        history.status = .any
        history.endedWithError = false
        requestSearch = ""
        requestsLive = false
        open(.requests)
    }
}

/// The exact host History filters on.
enum RequestsHostFilter {
    /// A host as requests store it: trimmed, lowercased, an IPv6 literal without brackets.
    static func normalized(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : trimmed
    }
}
