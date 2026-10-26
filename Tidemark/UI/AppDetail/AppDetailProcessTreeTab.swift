import SwiftUI

/// "Process Tree" tab of a monitored app: every process whose requests roll up to the app, indented
/// under its parent, with its domains, requests and whether it still runs. It shows the tree it showed last for
/// the app (`AppDetailCache`) right after its first frame and reads it again in the background.
struct AppDetailProcessTreeTab: View {
    @Environment(AppModel.self) private var model
    var app: MonitoredApp
    /// Whose processes are listed: the sidebar's Mac, or every Mac when the app is not on that one.
    var scope: DeviceScope
    var cache: AppDetailCache

    @State private var nodes: [ProcessNode] = []
    @State private var loaded = false

    fileprivate static let columns: [AnalyzeColumnsLayout.Column] = [.flexible(weight: 1, min: 200), .fixed(70), .fixed(80), .fixed(84)]

    var body: some View {
        let onlyThisMac = pageShowsOnlyThisMac
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text(AnalyzeFormat.emphasized(
                    tr("Surge reports each request's process and its parent. Tidemark walks up that chain until it reaches a monitored app, so everything below rolls up to %@, including processes that have already exited. Process IDs get reused, so each one is stored together with its start time.", "AppDetail"),
                    app.name))
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.ink2)
                    .lineSpacing(3)
                    .frame(maxWidth: 780, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Lazy, so a big tree only builds and measures the rows on screen.
                LazyVStack(spacing: 0) {
                    AnalyzeColumnsLayout(columns: Self.columns, spacing: 12) {
                        Text(tr("Process", "AppDetail"))
                        Text(tr("Domains", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(tr("Requests", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(tr("State", "AppDetail"))
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 14)
                    .frame(height: 28)

                    if nodes.isEmpty {
                        Text(loaded ? tr("No processes recorded yet.", "AppDetail") : tr("Loading…", "AppDetail"))
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity, minHeight: 60)
                            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
                    }
                    ForEach(nodes) { node in
                        AppDetailProcessRow(node: node, appPath: app.path, running: isRunning(node, pageShowsOnlyThisMac: onlyThisMac))
                    }
                }
                .padding(.vertical, 2)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            }
            .padding(.horizontal, 20)
            .padding(.top, 14)
            .padding(.bottom, 20)
        }
        .task(id: AppDetailCache.Key(appID: app.id, scope: scope)) {
            await refresh()
        }
    }

    private func isRunning(_ node: ProcessNode, pageShowsOnlyThisMac: Bool) -> Bool {
        AppDetailProcessTree.isRunning(node, thisDeviceID: model.devices.thisDeviceID, pageShowsOnlyThisMac: pageShowsOnlyThisMac,
                                       check: model.processes.isRunning(pid:startTime:))
    }

    /// Nodes without a Mac (older rows) can still be checked when the page shows only this Mac.
    private var pageShowsOnlyThisMac: Bool {
        scope.deviceID == model.devices.thisDeviceID || model.devices.devices.count <= 1
    }

    private func refresh() async {
        let key = AppDetailCache.Key(appID: app.id, scope: scope)
        // What the tab last showed for the app and scope (the tab stays when the sidebar's Mac changes), while it
        // reads the database. SwiftUI can start this task while it draws the tab, so the rows wait for the next turn
        // of the run loop: the switch to the tab draws as fast as an empty tab, and the rows follow in the next frame.
        if let cached = cache.tree(key) {
            await Task.yield()
            if Task.isCancelled { return }
            if cached != nodes { nodes = cached }
            if !loaded { loaded = true }
        }
        while !Task.isCancelled {
            if let fresh = try? await model.database.processTree(appID: key.appID, scope: key.scope), !Task.isCancelled {
                if fresh != nodes { nodes = fresh }
                cache.setTree(fresh, for: key)
            }
            if !loaded { loaded = true }
            try? await Task.sleep(for: .seconds(10))
        }
    }
}

/// One process of the tree. It takes plain values (no model), so an update elsewhere on the page leaves it alone.
private struct AppDetailProcessRow: View {
    var node: ProcessNode
    var appPath: String
    var running: Bool

    var body: some View {
        AnalyzeColumnsLayout(columns: AppDetailProcessTreeTab.columns, spacing: 12) {
            HStack(spacing: 7) {
                if node.depth > 0 {
                    Text(verbatim: "└─").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text(node.name)
                            .fontWeight(node.depth == 0 ? .semibold : .medium)
                            .lineLimit(1)
                        Text(verbatim: "pid \(node.pid)")
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.ink3)
                            .fixedSize()
                    }
                    if let path = node.path {
                        Text(AppDetailProcessPath.display(path, depth: node.depth, appPath: appPath))
                            .font(Theme.mono(10.5))
                            .foregroundStyle(Theme.ink3)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(path)
                    }
                }
            }
            .padding(.leading, CGFloat(node.depth) * 22)

            Text(Fmt.count(node.domainCount)).font(Theme.mono(11.5)).frame(maxWidth: .infinity, alignment: .trailing)
            Text(Fmt.count(node.requestCount)).font(Theme.mono(11.5)).frame(maxWidth: .infinity, alignment: .trailing)
            stateChip
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14)
        .padding(.vertical, 4)
        .frame(minHeight: 40)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private var stateChip: some View {
        let ok = Theme.tint(150)
        return Text(running ? tr("Running", "AppDetail") : tr("Exited", "AppDetail"))
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(running ? ok.background : Theme.fill, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
            .foregroundStyle(running ? ok.foreground : Theme.ink2)
            .fixedSize()
    }
}

/// Running state of process tree rows (pure, so it can be tested).
enum AppDetailProcessTree {
    /// libproc can only confirm processes of this Mac: a node whose latest PID ran here is checked live
    /// (the stored PID and start time must still name a running process) in any scope; other Macs' nodes
    /// keep the state stored with them.
    static func isRunning(_ node: ProcessNode, thisDeviceID: DeviceID, pageShowsOnlyThisMac: Bool,
                          check: (Int32, Date) -> Bool) -> Bool {
        let onThisMac = node.deviceID.map { $0 == thisDeviceID } ?? pageShowsOnlyThisMac
        guard onThisMac, let start = node.startTime else { return node.isRunning }
        return check(node.pid, start)
    }
}

/// Shortens executable paths for the process tree, like the design: helpers inside the app's bundle
/// read `…/Frameworks/Cursor Helper (Renderer).app` (the innermost bundle and its folder, however deeply
/// it is nested), the home folder reads `~`.
enum AppDetailProcessPath {
    static func display(_ path: String, depth: Int, appPath: String, home: String = NSHomeDirectory()) -> String {
        let root = appPath.hasSuffix("/") ? String(appPath.dropLast()) : appPath
        let contents = root + "/Contents/"
        if depth > 0, path.hasPrefix(contents) {
            var relative = String(path.dropFirst(contents.count))
            if let innermost = relative.range(of: ".app/Contents/MacOS/", options: .backwards) {
                relative = String(relative[..<innermost.lowerBound]) + ".app"
            }
            return "…/" + relative.split(separator: "/").suffix(2).joined(separator: "/")
        }
        if !home.isEmpty, path.hasPrefix(home + "/") {
            return "~/" + path.dropFirst(home.count + 1)
        }
        return path
    }
}
