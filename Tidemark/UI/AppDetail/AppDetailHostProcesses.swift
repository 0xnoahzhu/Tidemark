import AppKit
import SwiftUI

/// The processes listed under the selected domain and the selected IP of an app's Domains & IPs tab (`HostProcess`),
/// read as a selection opens and every 10 s while it stays open. An address opened before shows the list it had
/// (`AppDetailCache`) at once while it is read again, and a failed read keeps the list shown. Each selection is a property
/// of its own, so a list that arrives redraws only the rows under its address, not the tab.
@MainActor
@Observable
final class AppDetailHostProcesses {
    /// What the rows under a selection show.
    struct Shown: Equatable {
        var key: AppDetailCache.HostKey
        /// Nil until the first read answers.
        var processes: [HostProcess]?
        /// Why the last read failed, while there is no list to show.
        var failure: String?
    }

    private(set) var domain: Shown?
    private(set) var ip: Shown?
    /// Bumped by Try Again, which starts a selection's reads over.
    private(set) var domainAttempt = 0
    private(set) var ipAttempt = 0

    /// What the rows under the selected domain or IP show.
    func shown(_ kind: HostKind) -> Shown? { kind == .domain ? domain : ip }

    func attempt(_ kind: HostKind) -> Int { kind == .domain ? domainAttempt : ipAttempt }

    func retry(_ kind: HostKind) {
        switch kind {
        case .domain: domainAttempt &+= 1
        case .ip: ipAttempt &+= 1
        }
    }

    /// Shows the processes of `key` under the selection and reads them again every 10 s until the task is cancelled (the
    /// selection changed); clears the selection's list for no key.
    func follow(_ key: AppDetailCache.HostKey?, in kind: HostKind, model: AppModel, cache: AppDetailCache) async {
        guard let key else {
            set(nil, in: kind)
            return
        }
        // The address shown already keeps its list while it is read again; another starts from the cache, or from nothing.
        if shown(kind)?.key != key || shown(kind)?.processes == nil {
            set(Shown(key: key, processes: cache.processes(key)), in: kind)
        }
        while !Task.isCancelled {
            do {
                let fresh = try await model.database.hostProcesses(kind: key.kind, value: key.value, appID: key.appID, scope: key.scope)
                if Task.isCancelled { return }
                cache.setProcesses(fresh, for: key)
                set(Shown(key: key, processes: fresh), in: kind)
            } catch {
                if Task.isCancelled { return }
                if shown(kind)?.processes == nil { set(Shown(key: key, failure: CaptureEngine.message(for: error)), in: kind) }
            }
            try? await Task.sleep(for: .seconds(10))
        }
    }

    private func set(_ shown: Shown?, in kind: HostKind) {
        switch kind {
        case .domain: if domain != shown { domain = shown }
        case .ip: if ip != shown { ip = shown }
        }
    }
}

/// The processes that reached a selected domain or IP, nested under its row like the children of the process tree: a
/// caption with their number, then a row each in the columns of the domain rows (`AppDetailInventoryTab.domainColumns`).
/// The caption comes with the selection; "Loading…" only once a read takes a moment, so an answer that comes at once
/// never flashes it.
struct AppDetailHostProcessList: View {
    @Environment(AppModel.self) private var model
    var processes: AppDetailHostProcesses
    /// Whether it lists the selected domain's processes or the selected IP's.
    var kind: HostKind
    var app: MonitoredApp
    /// The domain or IP.
    var host: String
    var requests: AppDetailRequestsLink
    var showsFirstSeen: Bool
    /// Where the rows' tree glyph starts: under the domain's name, or in from the IP.
    var indent: CGFloat
    /// The caption names the date columns, which the IP pane's header does not.
    var labelsDates: Bool

    var body: some View {
        let shown = processes.shown(kind)
        VStack(spacing: 0) {
            caption(shown)
            if let list = shown?.processes {
                if list.isEmpty {
                    note(Text(tr("No process on record for it.", "AppDetail")))
                }
                ForEach(list) { process in
                    AppDetailHostProcessRow(process: process, app: app, macs: macs(of: process), showsFirstSeen: showsFirstSeen,
                                            indent: indent, host: host, open: openRequests)
                }
            } else if let failure = shown?.failure {
                note(HStack(spacing: 8.px) {
                    Text(tr("Couldn't load the processes.", "AppDetail")).help(failure)
                    Button(tr("Try Again", "AppDetail")) { processes.retry(kind) }
                        .buttonStyle(.link)
                })
            }
        }
        .padding(.bottom, 4.px)
        .background(Theme.accentTint.opacity(0.4))
    }

    private func caption(_ shown: AppDetailHostProcesses.Shown?) -> some View {
        AnalyzeColumnsLayout(columns: AppDetailInventoryTab.domainColumns(showsFirstSeen: showsFirstSeen)) {
            HStack(alignment: .firstTextBaseline, spacing: 7.px) {
                Text(tr("Processes", "AppDetail")).foregroundStyle(Theme.ink2).fixedSize()
                if let list = shown?.processes {
                    Text(verbatim: String(list.count)).fontWeight(.medium).foregroundStyle(Theme.ink3).fixedSize()
                } else if shown?.failure == nil {
                    AppDetailDelayedText(text: tr("Loading…", "AppDetail"))
                }
            }
            .padding(.leading, indent)
            if showsFirstSeen { dateLabel(tr("First seen", "AppDetail")) }
            dateLabel(tr("Last seen", "AppDetail"))
            Color.clear.frame(width: 0, height: 0)
        }
        .font(.design(11, .semibold))
        .lineLimit(1)
        .padding(.horizontal, 16.px)
        .padding(.top, 6.px)
        .padding(.bottom, 3.px)
    }

    @ViewBuilder
    private func dateLabel(_ title: String) -> some View {
        if labelsDates {
            Text(title).foregroundStyle(Theme.ink3)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }

    /// A line under the caption, in from the tree glyph.
    private func note(_ content: some View) -> some View {
        content
            .font(.design(11.5))
            .foregroundStyle(Theme.ink3)
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 16.px + indent)
            .padding(.trailing, 16.px)
            .padding(.vertical, 6.px)
    }

    /// The badges of a process's Macs, when it ran on more than one, in the Mac menu's order so every row reads alike.
    private func macs(of process: HostProcess) -> [AppDetailMacBadge] {
        guard process.deviceIDs.count > 1 else { return [] }
        let devices = model.devices
        let order = Dictionary(devices.devices.enumerated().map { ($1.id, $0) }, uniquingKeysWith: { first, _ in first })
        let sorted = process.deviceIDs.enumerated()
            .sorted { (order[$0.element] ?? .max, $0.offset) < (order[$1.element] ?? .max, $1.offset) }
            .map(\.element)
        return sorted.map { id in
            AppDetailMacBadge(id: id, shortName: devices.shortName(id), name: devices.device(id)?.name ?? devices.shortName(id), hue: devices.hue(id))
        }
    }

    private func openRequests(_ value: String) {
        requests.open(value, in: model.nav)
    }
}

/// A Mac a process ran on, drawn as its badge.
struct AppDetailMacBadge: Identifiable, Equatable {
    var id: DeviceID
    var shortName: String
    var name: String
    var hue: Double
}

/// One process under a selected domain or IP: its tile, name and path, when it first and last reached the address, its
/// requests and, when it ran on several Macs, their badges. It takes plain values, so an update elsewhere on the page
/// leaves it alone. Its context menu opens the app's requests to the address in History (History has no filter for a
/// process) and copies the path.
struct AppDetailHostProcessRow: View {
    var process: HostProcess
    var app: MonitoredApp
    var macs: [AppDetailMacBadge]
    var showsFirstSeen: Bool
    var indent: CGFloat
    var host: String
    var open: (String) -> Void

    /// The executable's whole path, the home folder as `~`: where it lives is what tells two processes of the same name
    /// apart, and a narrow row shortens it in the middle, keeping that start.
    private var path: String {
        AppDetailProcessPath.display(process.path, depth: 0, appPath: app.path)
    }

    var body: some View {
        AnalyzeColumnsLayout(columns: AppDetailInventoryTab.domainColumns(showsFirstSeen: showsFirstSeen)) {
            HStack(spacing: 6.px) {
                Text(verbatim: "└").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                AppDetailProcessTile(process: process, app: app, size: 16.px)
                VStack(alignment: .leading, spacing: 1.px) {
                    HStack(spacing: 6.px) {
                        Text(process.isUnreported ? tr("Process not reported by Surge", "Inventory") : process.name)
                            .fontWeight(.medium)
                            .foregroundStyle(process.isUnreported ? Theme.ink2 : Theme.ink)
                            .lineLimit(1)
                        if process.isNew() { TagBadge(text: tr("NEW", "AppDetail"), style: .new) }
                    }
                    // The path gives way to the Macs, and shortens in the middle.
                    HStack(spacing: 6.px) {
                        if !process.isUnreported {
                            Text(path)
                                .font(Theme.mono(10.5))
                                .foregroundStyle(Theme.ink3)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .help(process.path)
                        }
                        if !macs.isEmpty {
                            HStack(spacing: 3.px) {
                                ForEach(macs) { mac in DeviceBadge(shortName: mac.shortName, hue: mac.hue) }
                            }
                            .help(trf("Reported by %@", "AppDetail", macs.map(\.name).joined(separator: ", ")))
                        }
                    }
                }
            }
            .padding(.leading, indent)
            if showsFirstSeen {
                Text(AnalyzeFormat.seen(process.firstSeen)).foregroundStyle(Theme.ink2).lineLimit(1)
            }
            Text(AppDetailInventoryFormat.lastSeen(process.lastSeen))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .help(showsFirstSeen ? "" : trf("First seen %@", "AppDetail", AnalyzeFormat.seen(process.firstSeen)))
            // Not a link like the address's count: History cannot list one process's requests.
            Text(Fmt.count(process.requestCount))
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink2)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.design(12))
        .padding(.horizontal, 16.px)
        .padding(.vertical, 4.px)
        .frame(minHeight: 34.px)
        .contentShape(.rect)
        .contextMenu {
            Button(trf("Show Requests to %@", "Inventory", host)) { open(host) }
            if !process.isUnreported {
                Button(tr("Copy Path", "AppDetail")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(process.path, forType: .string)
                }
            }
        }
    }
}

/// A process's tile: the app's own for a process inside its bundle, the icon of another app bundle it lives in, a grey
/// letter tile for a command-line tool, and a `?` for requests whose process Surge never named.
struct AppDetailProcessTile: View {
    var process: HostProcess
    var app: MonitoredApp
    var size: CGFloat

    var body: some View {
        if process.isUnreported {
            LetterTile(letter: "?", color: Theme.tileNeutral, size: size)
        } else if app.contains(processPath: process.path) {
            AppTile(app: app, size: size)
        } else {
            AppTile(identity: AppIdentity(name: process.name, bundlePath: AppDetailProcessPath.bundle(of: process.path),
                                          letter: String(process.name.prefix(1)), hue: nil, isMonitored: false, appID: nil),
                    size: size)
        }
    }
}

/// Text that shows only once it has been on screen for a moment, so a read that answers at once never flashes it.
private struct AppDetailDelayedText: View {
    var text: String
    @State private var shows = false

    var body: some View {
        Text(text)
            .fontWeight(.medium)
            .foregroundStyle(Theme.ink3)
            .opacity(shows ? 1 : 0)
            .task {
                try? await Task.sleep(for: .milliseconds(300))
                shows = true
            }
    }
}
