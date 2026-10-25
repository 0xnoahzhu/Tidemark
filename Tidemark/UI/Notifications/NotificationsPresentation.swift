import Foundation

/// View-independent logic of the Notifications page: filtering, day grouping and card wording.
enum NotificationsPresentation {
    /// Alerts matching the design's All / Unread switch, newest first.
    static func filter(_ items: [AlertItem], by filter: AlertFilter) -> [AlertItem] {
        let matching: [AlertItem] = switch filter {
        case .all: items
        case .unread: items.filter(\.isUnread)
        }
        return matching.sorted { $0.createdAt > $1.createdAt }
    }

    /// Splits alerts into TODAY and EARLIER (yesterday and older).
    static func group(_ items: [AlertItem], now: Date = .now, calendar: Calendar = .current) -> (today: [AlertItem], earlier: [AlertItem]) {
        var today: [AlertItem] = []
        var earlier: [AlertItem] = []
        for item in items {
            if calendar.isDate(item.createdAt, inSameDayAs: now) { today.append(item) } else { earlier.append(item) }
        }
        return (today, earlier)
    }

    /// What the card's title says, before localization.
    enum Headline: Equatable {
        /// "Raycast reached a new site, linear.app"
        case newSite(app: String, site: String)
        /// "Cursor contacted raw.githubusercontent.com"
        case newHost(app: String, host: String)
        /// "Docker connected to 104.16.98.215"
        case newIP(app: String, ip: String)
        /// "WeChat connected straight to 157.148.69.80"
        case directIP(app: String, ip: String)
    }

    static func headline(for alert: AlertItem, appName: String, site: (String) -> String) -> Headline {
        switch alert.scope {
        case .site:
            .newSite(app: appName, site: alert.site ?? site(alert.value))
        case .host:
            .newHost(app: appName, host: alert.value)
        case .ip:
            alert.isDirect ? .directIP(app: appName, ip: alert.value) : .newIP(app: appName, ip: alert.value)
        }
    }

    /// Pieces of the card's subtitle after the Mac name, before localization.
    enum Detail: Equatable {
        case firstHost(String)
        case via(String)
        case text(String)
        case noHostname
    }

    /// site: `First host api.linear.app · via node · US · AS13335 Cloudflare`
    /// host: `via node · 104.16.98.215 · US · AS13335 Cloudflare`
    /// ip:   `production.cloudflare.docker.com · via com.docker.backend · US · AS13335 Cloudflare` (or `No hostname`)
    ///
    /// "via …" is left out when Surge reported no process for the request.
    static func details(for alert: AlertItem) -> [Detail] {
        var parts: [Detail] = []
        let geo = alert.geo?.display ?? ""
        let via: [Detail] = isUnknownProcessName(alert.processName) ? [] : [.via(alert.processName)]
        switch alert.scope {
        case .site:
            parts.append(.firstHost(alert.value))
            parts += via
        case .host:
            parts += via
            if let ip = alert.ip, !ip.isEmpty { parts.append(.text(ip)) }
        case .ip:
            if let host = alert.host, !host.isEmpty, !alert.isDirect { parts.append(.text(host)) } else { parts.append(.noHostname) }
            parts += via
        }
        if !geo.isEmpty { parts.append(.text(geo)) }
        return parts
    }

    /// An empty process name, or the model's untranslated "Unknown" placeholder stored with older alerts.
    static func isUnknownProcessName(_ name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty || trimmed == "Unknown"
    }
}
