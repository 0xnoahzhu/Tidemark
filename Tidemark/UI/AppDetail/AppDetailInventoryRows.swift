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
    /// Where a pane goes, or which row holds it, through a reorder.
    enum ScrollTarget: Equatable {
        /// The pane's top.
        case top
        /// A row at the pane's top edge, under the pinned column header.
        case row(AppDetailInventoryRowID)
        /// A row on screen, kept where it is (`AppDetailPaneScroll.anchor(keeping:)`) with the rows around it.
        case keep(AppDetailInventoryRowID)
    }

    /// How a pane keeps its place through a reorder of its rows from `old` to `new`, with `visible` the rows at least
    /// half on screen. A row that moves goes up, to the front of its list (its domain, IP or site got a request), and the
    /// others keep their order, so the topmost row on screen that doesn't move up holds the rows on screen where they
    /// are (`keep`); a pane at its top stays there instead (`top`), with the newest activity. A selected row on screen
    /// that moves above that row would leave the screen upwards: the pane goes to `front`, the start of the list the row
    /// moves to. Nil when every row on screen moves up and none of them is selected.
    static func reorderTarget(from old: [AppDetailInventoryRowID], to new: [AppDetailInventoryRowID],
                              visible: Set<AppDetailInventoryRowID>, atTop: Bool, selected: AppDetailInventoryRowID?,
                              front: ScrollTarget) -> ScrollTarget? {
        var index: [AppDetailInventoryRowID: Int] = [:]
        index.reserveCapacity(new.count)
        for (position, id) in new.enumerated() where index[id] == nil { index[id] = position }
        let kept = old.enumerated().first { position, id in
            visible.contains(id) && index[id].map { $0 >= position } == true
        }?.element
        if let selected, visible.contains(selected), let place = index[selected],
           kept.flatMap({ index[$0] }).map({ place < $0 }) ?? true {
            return front
        }
        if atTop { return .top }
        return kept.map(ScrollTarget.keep)
    }

    /// How the Domains pane keeps its place through a reorder from `previous` to this summary, with `domain` selected
    /// (`reorderTarget`). A domain that moves goes to the top of the list with its site, so the pane goes to its top
    /// with a selected one that moves above the rows on screen: it got a request, or another domain of its site did.
    func domainsTarget(keeping domain: String?, from previous: AppDetailInventorySummary, visible: Set<AppDetailInventoryRowID>,
                       atTop: Bool) -> ScrollTarget? {
        Self.reorderTarget(from: previous.domainRows(opening: domain).map(\.id), to: domainRows(opening: domain).map(\.id),
                           visible: visible, atTop: atTop, selected: domain.map { .host(.domain, $0) }, front: .top)
    }

    /// How the IP pane keeps its place through a reorder from `previous` to this summary, with `ip` selected
    /// (`reorderTarget`). An IP that moves goes to the front of the list it is in, so a selected one that moves above
    /// the rows on screen takes the pane there: its top, or, below the Direct group, the group's last row at the top
    /// edge, under the pinned column header, so the Resolved from domains header shows.
    func ipsTarget(keeping ip: String?, domain: String?, filter: Navigation.IPFilter, from previous: AppDetailInventorySummary,
                   visible: Set<AppDetailInventoryRowID>, atTop: Bool) -> ScrollTarget? {
        let belowDirect = domain == nil && filter == .all && resolvedIPs.contains { $0.value == ip }
        return Self.reorderTarget(from: previous.ipRows(filter: filter, domain: domain, opening: ip).map(\.id),
                                  to: ipRows(filter: filter, domain: domain, opening: ip).map(\.id),
                                  visible: visible, atTop: atTop, selected: ip.map { .host(.ip, $0) },
                                  front: belowDirect ? .row(directIPs.last.map { .host(.ip, $0.value) } ?? .note) : .top)
    }

    /// The row the tab brings into view for an alert's View (`Navigation.HostArrival`): the domain in the Domains pane,
    /// or the IP in the IP pane as it lists every IP, through `filter` (no domain is selected with it). Nil until the tab
    /// lists the row: its hosts are still being read, the alert is newer than the last read, or a search typed since
    /// hides it.
    func row(arriving arrival: Navigation.HostArrival, filter: Navigation.IPFilter) -> AppDetailInventoryRowID? {
        let id = AppDetailInventoryRowID.host(arrival.kind, arrival.value)
        let listed = switch arrival.kind {
        case .domain: groups.contains { $0.hosts.contains { $0.value == arrival.value } }
        case .ip: ipRows(filter: filter, domain: nil, opening: nil).contains { $0.id == id }
        }
        return listed ? id : nil
    }
}

/// Keeps an app's Domains & IPs pane in place while the pane's rows reorder.
///
/// Just before the rows move, the pane holds its topmost row on screen that doesn't move where it is, through its
/// scroll position, so the rows on screen stay put while rows above them change (SwiftUI on its own keeps them only
/// some of the time); a pane at its top holds its top, so the newest activity shows there
/// (`AppDetailInventorySummary.reorderTarget`). A selected row moves with the rows on screen, except when it moves to
/// the front of its list itself: its domain or IP got a request. If it was on screen, its pane goes to that front
/// instead, in the layout it still has, where the place is exact (scrolling there as the rows move lands where SwiftUI
/// estimates the rows above to be), and the row then slides into view there. The pane's scroll position is set only
/// for a reorder, an alert's View or a change of the IP pane's filter, and emptied again once the rows have moved: a
/// position that kept a row or an edge (also the row SwiftUI writes into it as the user scrolls) would hold the pane on
/// it through later updates, such as a process list opening above it.
///
/// The pane reports here which rows are on screen, where the rows it has laid out are, and which part of its content
/// is on screen; nothing is observed, so scrolling redraws nothing.
@MainActor
final class AppDetailPaneScroll {
    /// The rows at least half on screen.
    var visible: Set<AppDetailInventoryRowID> = []
    /// The frames of the rows the pane has laid out, in its content (`content`). They change only when its rows do.
    var frames: [AppDetailInventoryRowID: CGRect] = [:]
    /// The part of the pane's content on screen.
    var visibleRect = CGRect.zero
    /// Bumped by each change of the scroll position, so only the latest one's end empties it.
    private var moves = 0

    /// The coordinate space of a pane's content, which its rows' frames are in.
    nonisolated static let content = "AppDetailPaneContent"

    /// The pane shows the start of its list.
    var isAtTop: Bool { visibleRect.minY <= 0.5 }

    /// The scroll position that puts the pane at `target`, or that holds nothing.
    func position(_ target: AppDetailInventorySummary.ScrollTarget?) -> ScrollPosition {
        var position = ScrollPosition(idType: AppDetailInventoryRowID.self)
        switch target {
        case .top: position.scrollTo(edge: .top)
        case .row(let id): position.scrollTo(id: id, anchor: .top)
        case .keep(let id): if let anchor = anchor(keeping: id) { position.scrollTo(id: id, anchor: anchor) }
        case nil: break
        }
        return position
    }

    /// The anchor that leaves the row `id` where it is on screen: the point of the row that is at the same point of the
    /// pane. Nil for a row the pane hasn't laid out, or exactly as tall as the pane.
    func anchor(keeping id: AppDetailInventoryRowID) -> UnitPoint? {
        guard let frame = frames[id], abs(visibleRect.height - frame.height) >= 1 else { return nil }
        return UnitPoint(x: 0, y: (frame.minY - visibleRect.minY) / (visibleRect.height - frame.height))
    }

    /// Starts a change of the scroll position; `isLatest` tells its end whether another one followed.
    func move() -> Int {
        moves &+= 1
        return moves
    }

    func isLatest(_ move: Int) -> Bool { move == moves }

    /// Where a row an alert's View opens the tab on goes in its pane: a quarter of the way down, under the pinned column
    /// header, with room below it for its processes.
    static let arrivalAnchor = UnitPoint(x: 0.5, y: 0.25)
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
