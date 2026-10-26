import Foundation

extension Navigation {
    /// Opens the Requests page's History on every stored request to exactly `host` (a domain or an IP literal), the
    /// host shown as a removable chip beside the filters.
    ///
    /// `app` limits History to that app's requests, shown in the App menu, and `range`, when given, replaces the time
    /// range (Domains & IPs count every request a host has had, so they open all time); otherwise the time range stays
    /// as it is. The Mac stays as it is; the other filters and the search are cleared, so nothing else hides the host's
    /// requests. A request selected in History stays selected; one from elsewhere does not.
    func openRequests(forHost host: String, app: AppID? = nil, range: HistoryRange? = nil) {
        let normalized = RequestsHostFilter.normalized(host)
        guard !normalized.isEmpty else { return }
        openHistory(host: normalized, remoteIP: nil, app: app, range: range)
    }

    /// Opens History on every stored request that reached `ip` (`RequestQuery.remoteIP`): the requests to the domains
    /// that resolved to it as well as those to it as an IP literal, as Domains & IPs count an IP. The address is shown
    /// as a removable chip; `app`, `range` and the other filters are set as `openRequests(forHost:app:range:)` sets them.
    func openRequests(reaching ip: String, app: AppID? = nil, range: HistoryRange? = nil) {
        let normalized = RequestsHostFilter.normalized(ip)
        guard !normalized.isEmpty else { return }
        openHistory(host: nil, remoteIP: normalized, app: app, range: range)
    }

    private func openHistory(host: String?, remoteIP: String?, app: AppID?, range: HistoryRange?) {
        if page != .requests || requestsLive { selectedRequest = nil }
        history.host = host
        history.remoteIP = remoteIP
        history.appID = app
        if let range { history.range = range }
        history.policy = nil
        history.status = .any
        history.endedWithError = false
        requestSearch = ""
        requestsLive = false
        open(.requests)
    }
}

/// The exact host or IP History filters on.
enum RequestsHostFilter {
    /// A host as requests store it: trimmed, lowercased, an IPv6 literal without brackets.
    static func normalized(_ host: String) -> String {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.hasPrefix("[") && trimmed.hasSuffix("]") ? String(trimmed.dropFirst().dropLast()) : trimmed
    }
}
