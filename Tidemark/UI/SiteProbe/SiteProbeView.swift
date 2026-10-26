import AppKit
import SwiftUI
import WebKit

/// Site Probe page: sessions list, URL bar, browser preview and host waterfall.
///
/// The browser is a WebKit `WebPage` (see `ProbeWebSession`) whose only route to the network is a
/// loopback proxy the probe controller opens for the session, so every host it reaches belongs to
/// the probed URL. The page shows it inline, or hands it to the pop-out window.
struct SiteProbeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow
    @Environment(\.dismissWindow) private var dismissWindow
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.systemPrefersReducedResourceUsage) private var reducedResources

    @State private var startError: (any Error)?
    @FocusState private var urlFocused: Bool

    private var web: ProbeWebSession { .shared }

    var body: some View {
        HStack(spacing: 0) {
            if !model.probe.isRunning {
                ProbeSessionsColumn()
                Rectangle().fill(Theme.line).frame(width: 0.5)
            }
            VStack(spacing: 0) {
                urlBar
                optionsRow
                if let session = model.probe.selected {
                    TimelineView(.animation(minimumInterval: 0.25, paused: !model.probe.isRunning)) { context in
                        sessionDetail(session, now: context.date)
                    }
                } else {
                    emptyState
                }
                footer
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg)
        .navigationTitle(tr("Site Probe", "SiteProbe"))
        .navigationSubtitle(tr("Open a URL in an isolated browser and record every host it touches", "SiteProbe"))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button(tr("New Probe", "SiteProbe")) { newProbe() }
                    .disabled(model.probe.isRunning || web.isBusy)
            }
        }
        .alert(error: $startError) {
            Button(tr("OK", "SiteProbe")) {}
        }
        .onAppear {
            if model.probe.selected == nil && web.urlDraft.isEmpty { urlFocused = true }
        }
    }

    // MARK: URL bar and options

    private var urlBar: some View {
        @Bindable var web = web
        let running = model.probe.isRunning
        return HStack(spacing: 8) {
            TextField(text: $web.urlDraft, prompt: Text(verbatim: "https://example.com")) {
                Text(tr("Address", "SiteProbe"))
            }
            .textFieldStyle(.bordered)
            .textInputBorderShape(.capsule)
            .font(Theme.mono(12.5))
            .autocorrectionDisabled()
            .focused($urlFocused)
            .disabled(running || web.isBusy)
            .onSubmit { if !running, !web.isBusy { start() } }

            if web.isStopping {
                ProbeStoppingButton()
            } else if running {
                Button(tr("Stop", "SiteProbe")) { stop() }
                    .buttonStyle(.glassProminent)
                    .tint(ProbeStoppingButton.tint)
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(tr("Start Probe", "SiteProbe")) { start() }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(ProbeWebSession.normalizedURL(web.urlDraft) == nil || web.isBusy)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    /// The design's row: isolation, "Records until you press Stop", Desktop / iPhone, own window, proxy port. When the
    /// page is too narrow for one line, Desktop / iPhone and own window go to a second line.
    private var optionsRow: some View {
        ProbeOptionsLayout(spacing: 18, lineSpacing: 8, minimumGap: 8) {
            isolationToggle
            recordsUntilStop
            modePicker
                .layoutValue(key: ProbeOptionsLayout.Wraps.self, value: true)
            ownWindowToggle
                .layoutValue(key: ProbeOptionsLayout.Wraps.self, value: true)
            proxyCaption
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20)
        .padding(.bottom, 10)
    }

    private var isolationToggle: some View {
        @Bindable var preferences = model.preferences
        return Toggle(tr("Isolated session, no cache or cookies", "SiteProbe"), isOn: $preferences.probeIsolated)
            .toggleStyle(.checkbox)
            .disabled(model.probe.isRunning)
            .fixedSize()
    }

    private var recordsUntilStop: some View {
        HStack(spacing: 7) {
            Circle().fill(Theme.live).frame(width: 7, height: 7)
            Text(tr("Records until you press Stop", "SiteProbe")).foregroundStyle(Theme.ink2)
        }
        .fixedSize()
        .help(tr("A Stop pressed right after the page loaded keeps recording until 6 s after the load, so the page's late requests are still caught.", "SiteProbe"))
    }

    private var modePicker: some View {
        DesignSegmentedControl(tr("Device", "SiteProbe"), selection: Binding(
            get: { model.preferences.probeMode },
            set: { web.switchMode(to: $0, model: model) }
        ), segments: [
            .init(.desktop, tr("Desktop", "SiteProbe"), systemImage: "desktopcomputer"),
            .init(.iphone, tr("iPhone", "SiteProbe"), systemImage: "iphone"),
        ])
    }

    private var ownWindowToggle: some View {
        @Bindable var preferences = model.preferences
        return Toggle(tr("Open in its own window", "SiteProbe"), isOn: $preferences.probeOwnWindow)
            .toggleStyle(.checkbox)
            .fixedSize()
    }

    @ViewBuilder
    private var proxyCaption: some View {
        if let port = model.probe.proxyPort ?? web.port {
            Text(verbatim: "127.0.0.1:\(port) → Surge")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink3)
                .fixedSize()
                .layoutValue(key: ProbeOptionsLayout.Trailing.self, value: true)
        }
    }

    // MARK: Session

    private func sessionDetail(_ session: ProbeSession, now: Date) -> some View {
        let running = model.probe.running?.id == session.id
        let elapsed = running ? max(0, now.timeIntervalSince(session.startedAt)) : session.duration
        let waterfall = ProbeWaterfallModel(session: session, elapsed: elapsed, site: { model.classifier.site(for: $0) })
        let hostCount = waterfall.steps.reduce(0) { $0 + $1.rows.count }
        let ipCount = waterfall.steps.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.ipCount } }
        let requestCount = waterfall.steps.reduce(0) { $0 + $1.rows.reduce(0) { $0 + $1.requests } }
        return VStack(spacing: 0) {
            HStack(spacing: 8) {
                if running { StatusDot(color: Theme.recording, size: 7, pulsing: !reduceMotion && !reducedResources) }
                Text(status(session, running: running))
                    .fontWeight(.semibold)
                    .foregroundStyle(Theme.ink)
                separator
                Text(Fmt.seconds(elapsed)).font(Theme.mono(12)).monospacedDigit()
                separator
                Text(trn("%lld step", "%lld steps", session.steps.count, "SiteProbe"))
                separator
                Text(trn("%lld host", "%lld hosts", hostCount, "SiteProbe"))
                separator
                Text(verbatim: "\(ipCount) IP")
                separator
                Text(trn("%lld request", "%lld requests", requestCount, "SiteProbe"))
                if running, let failure = web.loadFailure {
                    separator
                    Text(failure).foregroundStyle(Theme.failed).lineLimit(1).truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
            .padding(.horizontal, 20)
            .padding(.top, 2)
            .padding(.bottom, 12)

            GeometryReader { geometry in
                HStack(alignment: .top, spacing: 16) {
                    ProbePreviewPane(session: session, running: running,
                                     openWindow: { web.popOut { openWindow(id: WindowID.probeBrowser) } },
                                     closeWindow: { dismissWindow(id: WindowID.probeBrowser) })
                        .frame(width: previewWidth(total: geometry.size.width))
                    ProbeWaterfall(model: waterfall, running: running)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
    }

    private var separator: some View { Text(verbatim: "·") }

    private func status(_ session: ProbeSession, running: Bool) -> String {
        guard running else { return trf("Completed · %@", "SiteProbe", AnalyzeFormat.seen(session.startedAt)) }
        if web.isStopping { return tr("Stopping · catching the page's last requests", "SiteProbe") }
        if web.firstLoadFinished || model.probe.phase == .recording {
            return tr("Recording · click around in the page", "SiteProbe")
        }
        return tr("Loading page…", "SiteProbe")
    }

    /// The inline browser gets enough room to be usable: an iPhone-width page, or 40 % for desktop.
    private func previewWidth(total: CGFloat) -> CGFloat {
        if model.preferences.probeMode == .iphone {
            return min(ProbeWebSession.iPhoneViewport.width, max(256, total * 0.45))
        }
        return min(560, max(256, total * 0.4))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text(tr("Enter a URL to start a probe", "SiteProbe"))
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(Theme.ink)
            Text(tr("The page loads in a fresh, isolated browser. Its traffic goes through a proxy port opened only for this session, so every host listed belongs to this URL and nothing else.", "SiteProbe"))
                .font(.system(size: 12.5))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        Text(AnalyzeFormat.emphasized("%@ " + tr("The probe browser is a WKWebView with its own proxy setting (macOS 14+). Load the page, then click around: everything it does goes only to a port Tidemark opens for this session and on to Surge, so every connection belongs to this URL until you press Stop. Surge's records fill in the IP, policy and rule.", "SiteProbe"),
                                      tr("How attribution works.", "SiteProbe"), size: 11.5))
            .font(.design(11.5))
            .foregroundStyle(Theme.ink2)
            .lineSpacing(3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 14)
            .overlay(alignment: .top) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    // MARK: Actions

    private func start() {
        urlFocused = false
        Task {
            do {
                // The session hands the page to the window before it exists, so the inline preview never shows it.
                try await web.start(model: model)
                if web.isPoppedOut { openWindow(id: WindowID.probeBrowser) }
            } catch {
                startError = error
            }
        }
    }

    private func stop() {
        Task { await web.stop(model: model) }
    }

    private func newProbe() {
        model.probe.selectedID = nil
        web.urlDraft = ""
        urlFocused = true
    }
}

/// Saved probe sessions, newest first.
private struct ProbeSessionsColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: tr("Sessions", "SiteProbe"))
                .padding(.horizontal, 16)
                .padding(.top, 12)
                .padding(.bottom, 6)
            if model.probe.sessions.isEmpty {
                Text(tr("Probes you run are kept here.", "SiteProbe"))
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 16)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.probe.sessions) { session in
                            row(session)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
            }
        }
        // Leading, so the header stays 16 pt in when the column has no sessions yet.
        .frame(width: 232, alignment: .leading)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg2)
    }

    private func row(_ session: ProbeSession) -> some View {
        let selected = model.probe.selectedID == session.id
        let bare = session.host.hasPrefix("www.") ? String(session.host.dropFirst(4)) : session.host
        return Button {
            model.probe.selectedID = session.id
            ProbeWebSession.shared.urlDraft = session.url
        } label: {
            HStack(spacing: 10) {
                Text(verbatim: String(bare.prefix(1)).uppercased())
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28, height: 28)
                    .background(Theme.tileProbe, in: Circle())
                VStack(alignment: .leading, spacing: 1) {
                    Text(session.host)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text([trn("%lld host", "%lld hosts", session.hosts.count, "SiteProbe"),
                          trn("%lld IP", "%lld IPs", session.ipCount, "SiteProbe"),
                          Fmt.seconds(session.duration)].joined(separator: " · "))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    Text(AnalyzeFormat.seen(session.startedAt))
                        .font(.system(size: 10.5))
                        .foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(8)
            .background(selected ? Theme.accentTint : .clear, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

/// The options row's layout: the controls `spacing` apart on one line and the `Trailing` caption at its far end, at
/// least `minimumGap` (and `spacing` on either side) after them, as an `HStack` with a `Spacer` would place them.
/// When that line is wider than the row, the `Wraps` controls move to a second line, `lineSpacing` below. Each line
/// centers its controls vertically.
///
/// One layout rather than a `ViewThatFits` of both arrangements, which would build and measure every control twice.
private struct ProbeOptionsLayout: Layout {
    /// Controls that move to the second line when the row is too narrow.
    struct Wraps: LayoutValueKey {
        static let defaultValue = false
    }

    /// The caption at the far end of the first line.
    struct Trailing: LayoutValueKey {
        static let defaultValue = false
    }

    var spacing: CGFloat
    var lineSpacing: CGFloat
    var minimumGap: CGFloat

    private struct Line {
        var items: [Int] = []
        var trailing: Int?
        var height: CGFloat = 0
        /// Width of the controls, the gap and the caption, with the gap at its minimum.
        var minimumWidth: CGFloat = 0
        /// Whether the line ends in the flexible gap (and the caption, if there is one).
        var hasGap = false
    }

    private struct Arrangement {
        var lines: [Line]
        var sizes: [CGSize]
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let arrangement = arrange(subviews, width: proposal.width)
        let width = arrangement.lines.map { $0.hasGap ? max(proposal.width ?? $0.minimumWidth, $0.minimumWidth) : $0.minimumWidth }.max() ?? 0
        let heights = arrangement.lines.map(\.height)
        return CGSize(width: width, height: heights.reduce(0, +) + lineSpacing * CGFloat(max(0, heights.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(subviews, width: proposal.width)
        var y = bounds.minY
        for line in arrangement.lines {
            let center = y + line.height / 2
            var x = bounds.minX
            for index in line.items {
                let size = arrangement.sizes[index]
                subviews[index].place(at: CGPoint(x: x, y: center), anchor: .leading, proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            if let index = line.trailing {
                // The gap takes what the proposal leaves, so the caption ends at the line's end.
                let size = arrangement.sizes[index]
                let end = bounds.minX + max(proposal.width ?? line.minimumWidth, line.minimumWidth)
                subviews[index].place(at: CGPoint(x: end - size.width, y: center), anchor: .leading, proposal: ProposedViewSize(size))
            }
            y += line.height + lineSpacing
        }
    }

    /// Everything on one line when it fits in `width` (or `width` is unknown), else two lines.
    private func arrange(_ subviews: Subviews, width: CGFloat?) -> Arrangement {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let trailing = subviews.indices.first { subviews[$0][Trailing.self] }
        let controls = subviews.indices.filter { $0 != trailing }
        let single = line(controls, trailing: trailing, gap: true, sizes: sizes)
        if width.map({ single.minimumWidth <= $0 }) ?? true {
            return Arrangement(lines: [single], sizes: sizes)
        }
        let first = line(controls.filter { !subviews[$0][Wraps.self] }, trailing: trailing, gap: true, sizes: sizes)
        let second = line(controls.filter { subviews[$0][Wraps.self] }, trailing: nil, gap: false, sizes: sizes)
        return Arrangement(lines: [first, second], sizes: sizes)
    }

    private func line(_ items: [Int], trailing: Int?, gap: Bool, sizes: [CGSize]) -> Line {
        var line = Line(items: items, trailing: trailing, hasGap: gap)
        let widths = items.map { sizes[$0].width }
        line.minimumWidth = widths.reduce(0, +) + spacing * CGFloat(max(0, widths.count - 1))
        if gap {
            line.minimumWidth += (widths.isEmpty ? 0 : spacing) + minimumGap
            if let trailing { line.minimumWidth += spacing + sizes[trailing].width }
        }
        line.height = (items + [trailing].compactMap { $0 }).map { sizes[$0].height }.max() ?? 0
        return line
    }
}

/// The browser card left of the waterfall: the live page, a note when it is popped out, or the
/// last picture of an ended session under a veil.
private struct ProbePreviewPane: View {
    @Environment(AppModel.self) private var model
    var session: ProbeSession
    var running: Bool
    var openWindow: () -> Void
    var closeWindow: () -> Void

    private var web: ProbeWebSession { .shared }

    var body: some View {
        VStack(spacing: 0) {
            miniToolbar
            ZStack {
                Theme.bg
                content
            }
            .clipped()
        }
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }

    private var miniToolbar: some View {
        HStack(spacing: 7) {
            Button { web.goBack() } label: { Image(systemName: "chevron.left") }
                .disabled(!running || !web.canGoBack)
            Button { web.goForward() } label: { Image(systemName: "chevron.right") }
                .disabled(!running || !web.canGoForward)
            HStack(spacing: 5) {
                Circle().fill(running ? Theme.live : Theme.ink3).frame(width: 6, height: 6)
                Text(currentAddress)
                    .font(Theme.mono(10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
            Button(tr("Pop Out", "SiteProbe")) { openWindow() }
                .font(.system(size: 10.5, weight: .semibold))
                .disabled(!running || web.isPoppedOut || web.isStopping)
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .foregroundStyle(Theme.ink2)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
    }

    private var currentAddress: String {
        if running, let url = web.page?.url { return ProbePreviewPane.shortAddress(url) }
        if let last = session.steps.last?.url, let url = URL(string: last) { return ProbePreviewPane.shortAddress(url) }
        return session.host
    }

    /// `github.com/apple/swift` without the scheme.
    static func shortAddress(_ url: URL) -> String {
        let host = url.host() ?? ""
        let path = url.path(percentEncoded: false)
        return host + (path == "/" ? "/" : path)
    }

    @ViewBuilder
    private var content: some View {
        if running, web.isPoppedOut {
            ProbeVeil {
                VStack(spacing: 9) {
                    Image(systemName: "macwindow")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.ink3)
                    Text(tr("Browsing in its own window", "SiteProbe"))
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(ProbeViewport.caption(mode: model.preferences.probeMode, size: nil))
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.ink2)
                        .multilineTextAlignment(.center)
                    Button(tr("Close Window", "SiteProbe")) { closeWindow() }
                        .controlSize(.small)
                }
            }
            .background(Theme.bg2)
        } else if running, let page = web.page, web.host == .inline {
            WebView(page)
                .webViewBackForwardNavigationGestures(.enabled)
                .webViewMagnificationGestures(.enabled)
                // Clicks after Stop would start steps the stopped session never shows.
                .allowsHitTesting(!web.isStopping)
                .modifier(ProbeWebViewMount(view: .inline))
        } else if running {
            // The page is coming back from the pop-out window.
            ProgressView().controlSize(.small)
        } else {
            ProbeEndedView(snapshot: web.snapshot(for: session.id), compact: true)
        }
    }
}

/// An ended (or never seen) session: its last picture, or a placeholder, under a veil with a note.
struct ProbeEndedView: View {
    var snapshot: ProbeEndedSnapshot?
    var compact: Bool

    var body: some View {
        ZStack {
            if let snapshot {
                // `Color.clear` takes the proposed size and the picture is drawn into it from the top, so a
                // tall page can never make the card grow.
                Color.clear
                    .overlay(alignment: .top) {
                        Image(nsImage: snapshot.image)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    }
                    .clipped()
                    .blur(radius: compact ? 2 : 3)
            } else {
                ProbeStripes()
            }
            // The veil dims the page; the note sits on its own opaque card so no page text can run through it.
            Theme.bg.opacity(0.62)
            Text(tr("This session has ended. Start a new probe to keep browsing.", "SiteProbe"))
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, compact ? 14 : 18)
                .padding(.vertical, compact ? 10 : 12)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, y: 2)
                .frame(maxWidth: compact ? 300 : 380)
                .padding(compact ? 16 : 32)
        }
        .clipped()
    }
}

/// Stands in for Stop while the probe finishes: the rest of the tail after the first load, the last Surge
/// records, then saving the session.
struct ProbeStoppingButton: View {
    static let tint = Color(oklch: 0.62, 0.19, 27)

    var body: some View {
        Button {} label: {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text(tr("Stopping…", "SiteProbe"))
            }
        }
        .buttonStyle(.glassProminent)
        .tint(Self.tint)
        .disabled(true)
        .help(tr("Recording the page's last requests, then saving the session", "SiteProbe"))
    }
}

/// Centered content on the pane's background.
private struct ProbeVeil<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Diagonal hatching standing in for a page that is not loaded.
struct ProbeStripes: View {
    var body: some View {
        Canvas { context, size in
            let spacing: CGFloat = 16
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(Theme.fill), lineWidth: 8)
        }
    }
}

/// Captions describing the probe browser's viewport.
@MainActor
enum ProbeViewport {
    /// `Desktop · 1280 × 800 · Safari user agent` (with the live size when known) or the iPhone profile.
    static func caption(mode: ProbeDeviceMode, size: CGSize?) -> String {
        switch mode {
        case .iphone:
            return tr("iPhone · 393 × 852 · mobile Safari user agent", "SiteProbe")
        case .desktop:
            let size = size ?? CGSize(width: 1280, height: 800)
            return trf("Desktop · %1$@ × %2$@ · Safari user agent", "SiteProbe",
                       String(Int(size.width.rounded())), String(Int(size.height.rounded())))
        }
    }
}
