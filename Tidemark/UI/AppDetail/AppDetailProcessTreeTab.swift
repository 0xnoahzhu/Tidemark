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

    static let columns = columns(factor: UIScale.factor)

    /// The columns at any UI scale. Domains, Requests and State are fixed to the longest of their text (`1,234,567` in
    /// 11.5 px SF Mono, the Running chip in 11 px), which grows with the scale as the widths do.
    static func columns(factor: CGFloat) -> [AnalyzeColumnsLayout.Column] {
        func px(_ value: CGFloat) -> CGFloat { UIScale.length(value, factor: factor) }
        return [.flexible(weight: 1, min: px(200)), .fixed(px(70)), .fixed(px(80)), .fixed(px(84))]
    }

    var body: some View {
        let onlyThisMac = pageShowsOnlyThisMac
        ScrollView {
            VStack(alignment: .leading, spacing: 12.px) {
                Text(AnalyzeFormat.emphasized(
                    tr("Surge reports each request's process and its parent. Tidemark walks up that chain until it reaches a monitored app, so everything below rolls up to %@, including processes that have already exited. Process IDs get reused, so each one is stored together with its start time.", "AppDetail"),
                    app.name, size: 12))
                    .font(.design(12))
                    .foregroundStyle(Theme.ink2)
                    // The design's paragraph line-height.
                    .lineHeight(.multiple(factor: 1.55))
                    .frame(maxWidth: 780.px, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)

                // Lazy, so a big tree only builds and measures the rows on screen.
                LazyVStack(spacing: 0) {
                    AnalyzeColumnsLayout(columns: Self.columns, spacing: 12.px) {
                        Text(tr("Process", "AppDetail"))
                        Text(tr("Domains", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(tr("Requests", "AppDetail")).frame(maxWidth: .infinity, alignment: .trailing)
                        Text(tr("State", "AppDetail"))
                    }
                    .font(.design(11, .semibold))
                    .foregroundStyle(Theme.ink2)
                    .padding(.horizontal, 14.px)
                    .frame(height: 28.px)

                    if nodes.isEmpty {
                        Text(loaded ? tr("No processes recorded yet.", "AppDetail") : tr("Loading…", "AppDetail"))
                            .font(.design(12))
                            .foregroundStyle(Theme.ink3)
                            .frame(maxWidth: .infinity, minHeight: 60.px)
                            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
                    }
                    ForEach(nodes) { node in
                        AppDetailProcessRow(node: node, appPath: app.path, running: isRunning(node, pageShowsOnlyThisMac: onlyThisMac))
                    }
                }
                .padding(.vertical, 2.px)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 12.px, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 12.px, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
            }
            .padding(.horizontal, 20.px)
            .padding(.top, 14.px)
            .padding(.bottom, 20.px)
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
        AnalyzeColumnsLayout(columns: AppDetailProcessTreeTab.columns, spacing: 12.px) {
            HStack(spacing: 7.px) {
                if node.depth > 0 {
                    Text(verbatim: "└─").font(Theme.mono(11)).foregroundStyle(Theme.ink3)
                }
                VStack(alignment: .leading, spacing: 1.px) {
                    HStack(alignment: .firstTextBaseline, spacing: 7.px) {
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
            .padding(.leading, CGFloat(node.depth) * 22.px)

            Text(Fmt.count(node.domainCount)).font(Theme.mono(11.5)).frame(maxWidth: .infinity, alignment: .trailing)
            Text(Fmt.count(node.requestCount)).font(Theme.mono(11.5)).frame(maxWidth: .infinity, alignment: .trailing)
            stateChip
        }
        .font(.design(12))
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 14.px)
        .padding(.vertical, 4.px)
        .frame(minHeight: 40.px)
        .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private var stateChip: some View {
        let ok = Theme.tint(150)
        return Text(running ? tr("Running", "AppDetail") : tr("Exited", "AppDetail"))
            .font(.design(11, .medium))
            .padding(.horizontal, 7.px)
            .padding(.vertical, 1.px)
            .background(running ? ok.background : Theme.fill, in: RoundedRectangle(cornerRadius: 5.px, style: .continuous))
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

    /// The outermost app bundle an executable lives in (`/Applications/Docker.app`), nil for one outside any bundle.
    static func bundle(of path: String) -> String? {
        guard let end = path.range(of: ".app/") else { return nil }
        return String(path[..<end.lowerBound]) + ".app"
    }
}
