import SwiftUI

/// What identifies a row of an app's Domains & IPs panes, the same on every read: a row that moves keeps its identity,
/// so it slides to its new place rather than being replaced, its selection and process list go with it, and a pane can
/// keep it where it is on screen (`AppDetailPaneScroll`).
enum AppDetailInventoryRowID: Hashable, Sendable {
    case site(String)
    case host(HostKind, String)
    /// The processes under a selected domain or IP.
    case processes(HostKind, String)
    /// The Direct or Resolved from domains header of the IP pane.
    case section(Navigation.IPFilter)
    /// The line of an IP pane with nothing to list.
    case note
}

extension AppDetailInventorySummary {
    /// A row of the Domains pane.
    enum DomainRow: Identifiable {
        case site(SiteGroup)
        case domain(AppHost)
        /// The processes under the selected domain.
        case processes(String)

        var id: AppDetailInventoryRowID {
            switch self {
            case .site(let group): .site(group.site)
            case .domain(let host): .host(.domain, host.value)
            case .processes(let domain): .processes(.domain, domain)
            }
        }
    }

    /// A row of the IP pane.
    enum IPRow: Identifiable {
        /// The Direct (`.direct`) or Resolved from domains (`.resolved`) header, with its count.
        case section(Navigation.IPFilter, count: Int)
        /// Under a Direct header with no IP.
        case nothingDirect
        /// The selected domain has no IP to list.
        case noIPs
        case ip(AppHost)
        /// The processes under the selected IP.
        case processes(String)

        var id: AppDetailInventoryRowID {
            switch self {
            case .section(let group, _): .section(group)
            case .nothingDirect, .noIPs: .note
            case .ip(let ip): .host(.ip, ip.value)
            case .processes(let ip): .processes(.ip, ip)
            }
        }
    }

    /// The Domains pane's rows: each site, then its domains, in their order, with the processes under `selected`.
    func domainRows(opening selected: String?) -> [DomainRow] {
        var rows: [DomainRow] = []
        rows.reserveCapacity(groups.count + domainCount + 1)
        for group in groups {
            rows.append(.site(group))
            for host in group.hosts {
                rows.append(.domain(host))
                if host.value == selected { rows.append(.processes(host.value)) }
            }
        }
        return rows
    }

    /// The IP pane's rows: with `domain` selected the IPs it resolved to, in one list; otherwise the groups `filter`
    /// keeps, each under its header. The processes follow `selectedIP`.
    func ipRows(filter: Navigation.IPFilter, domain: String?, opening selectedIP: String?) -> [IPRow] {
        var rows: [IPRow] = []
        func add(_ ips: [AppHost]) {
            for ip in ips {
                rows.append(.ip(ip))
                if ip.value == selectedIP { rows.append(.processes(ip.value)) }
            }
        }
        if let domain {
            let ips = ips(usedBy: domain)
            if ips.isEmpty { rows.append(.noIPs) }
            add(ips)
            return rows
        }
        if filter != .resolved {
            rows.append(.section(.direct, count: directIPs.count))
            if directIPs.isEmpty { rows.append(.nothingDirect) }
            add(directIPs)
        }
        if filter != .direct {
            rows.append(.section(.resolved, count: resolvedIPs.count))
            add(resolvedIPs)
        }
        return rows
    }
}

extension AppDetailInventorySummary {
    /// Where a pane goes with a reorder to keep its selected row in view.
    enum ScrollTarget: Equatable {
        case top
        case row(AppDetailInventoryRowID)
    }

    /// Where the Domains pane goes with a reorder from `previous` to this summary to keep `domain` in view: its top when
    /// the domain's site moves there (the domain, or another of its site, got a request), which takes the domain above
    /// the rows on screen. Nil otherwise: SwiftUI keeps the rows on screen where they are, the domain with them.
    func domainsTarget(keeping domain: String?, from previous: AppDetailInventorySummary) -> ScrollTarget? {
        guard let domain, let first = groups.first, first.hosts.contains(where: { $0.value == domain }),
              previous.groups.first?.site != first.site else { return nil }
        return .top
    }

    /// Where the IP pane goes with a reorder from `previous` to this summary to keep `ip` in view: the start of the list
    /// it is in when it moves to the front of that list (it got a request), which takes it above the rows on screen. That
    /// is the pane's top, or, below the Direct group, the group's last row at the top edge, under the pinned column
    /// header, so the Resolved from domains header shows. Nil otherwise.
    func ipsTarget(keeping ip: String?, domain: String?, filter: Navigation.IPFilter, from previous: AppDetailInventorySummary)
        -> ScrollTarget? {
        guard let ip else { return nil }
        if let domain {
            guard ips(usedBy: domain).first?.value == ip, previous.ips(usedBy: domain).first?.value != ip else { return nil }
            return .top
        }
        if directIPs.first?.value == ip, previous.directIPs.first?.value != ip, filter != .resolved { return .top }
        guard resolvedIPs.first?.value == ip, previous.resolvedIPs.first?.value != ip, filter != .direct else { return nil }
        guard filter == .all else { return .top }
        return .row(directIPs.last.map { .host(.ip, $0.value) } ?? .note)
    }
}

/// Keeps an app's Domains & IPs pane on its selected row while the pane's rows reorder.
///
/// SwiftUI keeps the rows on screen where they are when rows above them change, and a pane at its top at its top, so
/// the newest activity shows there. A selected row moves with them, except when it moves to the front of its list
/// itself: its domain or IP got a request. If it was on screen, its pane goes to that front just before the rows move
/// (`AppDetailInventorySummary.domainsTarget`), in the layout it still has, where the place is exact (scrolling there
/// as the rows move lands where SwiftUI estimates the rows above to be), and the row then slides into view there. The
/// pane's scroll position is set only for such a move, and emptied before every reorder and again once the rows have
/// moved: a position that kept a row or an edge (also the row SwiftUI writes into it as the user scrolls) would hold the
/// pane on it through later updates.
///
/// The pane reports which rows are on screen here; nothing is observed, so scrolling redraws nothing.
@MainActor
final class AppDetailPaneScroll {
    /// The rows at least half on screen.
    var visible: Set<AppDetailInventoryRowID> = []
    /// Bumped by each change of the scroll position, so only the latest one's end empties it.
    private var moves = 0

    /// Starts a change of the scroll position; `isLatest` tells its end whether another one followed.
    func move() -> Int {
        moves &+= 1
        return moves
    }

    func isLatest(_ move: Int) -> Bool { move == moves }
}

/// Marks the update that reorders an app's Domains & IPs rows, the only one whose animation moves the panes' rows.
private struct AppDetailInventoryReorderKey: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    var reordersAppInventory: Bool {
        get { self[AppDetailInventoryReorderKey.self] }
        set { self[AppDetailInventoryReorderKey.self] = newValue }
    }
}

/// The app's requests in the live stream, which tell an app's Domains & IPs tab to read its hosts again: a domain that
/// got a request then takes its site to the top within seconds rather than at the next 10 s read.
@MainActor
enum AppDetailInventoryActivity {
    /// When the app's newest request in the live stream started, of the Macs `scope` keeps. The stream is newest first,
    /// so only its rows down to the app's newest are looked at.
    static func latestRequest(of appID: AppID, scope: DeviceScope, in rows: [RequestRecord]) -> Date? {
        rows.first { $0.appID == appID && scope.includes($0.deviceID) }?.startedAt
    }

    /// Returns true once the live stream shows a request of the app that started after `date`, or false when the task is
    /// cancelled first. It looks at the stream as the engine updates it, a few times a second at most.
    static func request(of key: AppDetailCache.Key, after date: Date, in live: LiveState) async -> Bool {
        for await latest in Observations({ latestRequest(of: key.appID, scope: key.scope, in: live.rows) }) {
            if let latest, latest > date { return true }
        }
        return false
    }
}
