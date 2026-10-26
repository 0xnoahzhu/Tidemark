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
        GeometryReader { page in
            // While a probe runs the session takes the page; a page too narrow for the sessions beside a session
            // shows them only until one is picked (`SiteProbeLayout`).
            let showsSessions = !model.probe.isRunning
                && (model.probe.selected == nil || SiteProbeLayout.current.showsSessions(pageWidth: page.size.width))
            HStack(spacing: 0) {
                if showsSessions {
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
        }
        .background(Theme.bg)
        .pageToolbar(tr("Site Probe", "SiteProbe"), subtitle: tr("Open a URL in an isolated browser and record every host it touches", "SiteProbe")) {
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
        return HStack(spacing: 8.px) {
            HStack(spacing: 8.px) {
                Circle()
                    .strokeBorder(Theme.ink3, lineWidth: 1.5.px)
                    .frame(width: 11.px, height: 11.px)
                TextField(text: $web.urlDraft, prompt: Text(verbatim: "https://example.com")) {
                    Text(tr("Address", "SiteProbe"))
                }
                .font(Theme.mono(12.5))
                .autocorrectionDisabled()
                .focused($urlFocused)
                .disabled(running || web.isBusy)
                .onSubmit { if !running, !web.isBusy { start() } }
            }
            .designField(height: 32, cornerRadius: 9, horizontalPadding: 12)

            if web.isStopping {
                ProbeStoppingButton()
                    .buttonStyle(Self.buttonStyle(.destructive))
            } else if running {
                Button(tr("Stop", "SiteProbe")) { stop() }
                    .buttonStyle(Self.buttonStyle(.destructive))
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(tr("Start Probe", "SiteProbe")) { start() }
                    .buttonStyle(Self.buttonStyle(.accent))
                    .disabled(ProbeWebSession.normalizedURL(web.urlDraft) == nil || web.isBusy)
            }
        }
        .padding(.horizontal, 20.px)
        .padding(.top, 14.px)
        .padding(.bottom, 8.px)
    }

    /// Start Probe and Stop: the design's 32 px buttons beside the field, on the accent or red.
    private static func buttonStyle(_ kind: DesignButtonStyle.Kind) -> DesignButtonStyle {
        DesignButtonStyle(kind: kind, height: 32, fontSize: 12.5, cornerRadius: 9, horizontalPadding: 16)
    }

    /// The design's row: isolation, "Records until you press Stop", Desktop / iPhone, own window, proxy port. When the
    /// page is too narrow for one line, Desktop / iPhone and own window go to a second line.
    private var optionsRow: some View {
        ProbeOptionsLayout(spacing: 18.px, lineSpacing: 8.px, minimumGap: 8.px) {
            isolationToggle
            recordsUntilStop
            modePicker
                .layoutValue(key: ProbeOptionsLayout.Wraps.self, value: true)
            ownWindowToggle
                .layoutValue(key: ProbeOptionsLayout.Wraps.self, value: true)
            proxyCaption
        }
        .font(.design(12))
        .padding(.horizontal, 20.px)
        .padding(.bottom, 10.px)
    }

    private var isolationToggle: some View {
        @Bindable var preferences = model.preferences
        return Toggle(tr("Isolated session, no cache or cookies", "SiteProbe"), isOn: $preferences.probeIsolated)
            .toggleStyle(.checkbox)
            .controlSize(Self.checkboxSize)
            .disabled(model.probe.isRunning)
            .fixedSize()
    }

    /// The native checkboxes do not follow the UI scale; from 1.2 on they go one size up, beside their larger labels.
    private static let checkboxSize: ControlSize = UIScale.factor >= 1.2 ? .large : .regular

    private var recordsUntilStop: some View {
        HStack(spacing: 7.px) {
            Circle().fill(Theme.live).frame(width: 7.px, height: 7.px)
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
            .controlSize(Self.checkboxSize)
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
            HStack(spacing: 8.px) {
                if running { StatusDot(color: Theme.recording, size: 8.px, pulsing: !reduceMotion && !reducedResources) }
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
            .font(.design(12))
            .foregroundStyle(Theme.ink2)
            .lineLimit(1)
            .padding(.horizontal, 20.px)
            .padding(.top, 2.px)
            .padding(.bottom, 12.px)

            GeometryReader { geometry in
                let layout = SiteProbeLayout.current
                HStack(alignment: .top, spacing: layout.gap) {
                    ProbePreviewPane(session: session, running: running,
                                     openWindow: { web.popOut { openWindow(id: WindowID.probeBrowser) } },
                                     closeWindow: { dismissWindow(id: WindowID.probeBrowser) })
                        .frame(width: layout.cardWidth(total: geometry.size.width, mode: model.preferences.probeMode))
                    ProbeWaterfall(model: waterfall, running: running)
                }
            }
            .padding(.horizontal, SiteProbeLayout.current.padding)
            .padding(.bottom, 12.px)
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

    private var emptyState: some View {
        VStack(spacing: 8.px) {
            Text(tr("Enter a URL to start a probe", "SiteProbe"))
                .font(.design(15, .semibold))
                .foregroundStyle(Theme.ink)
            Text(tr("The page loads in a fresh, isolated browser. Its traffic goes through a proxy port opened only for this session, so every host listed belongs to this URL and nothing else.", "SiteProbe"))
                .font(.design(12.5))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 430.px)
        }
        .padding(40.px)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        Text(AnalyzeFormat.emphasized("%@ " + tr("The probe browser is a WKWebView with its own proxy setting (macOS 14+). Load the page, then click around: everything it does goes only to a port Tidemark opens for this session and on to Surge, so every connection belongs to this URL until you press Stop. Surge's records fill in the IP, policy and rule.", "SiteProbe"),
                                      tr("How attribution works.", "SiteProbe"), size: 11.5))
            .font(.design(11.5))
            .foregroundStyle(Theme.ink2)
            // The design's `line-height: 1.55` for this note.
            .lineHeight(.multiple(factor: 1.55))
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)
            .padding(.horizontal, 20.px)
            .padding(.top, 10.px)
            .padding(.bottom, 14.px)
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

/// The widths of the Site Probe page at a UI scale: the saved sessions, and a session's browser card beside its
/// waterfall.
///
/// The minimum window holds the card and the waterfall at their minimums, but not the sessions column too. So as the
/// page narrows, the card gives way first, from the design's 256 px down to 200 px, which keeps the saved sessions in
/// reach. Then the column gives way to a session, as it does while a probe runs (with no session picked it has the
/// room), and the card has 256 px again, or less only beside a sidebar dragged wider, so the waterfall keeps its
/// minimum.
@MainActor
struct SiteProbeLayout: Equatable {
    /// The layout at the app's factor.
    static let current = SiteProbeLayout()

    /// The sessions column.
    var sessionsWidth: CGFloat
    /// The page's padding at either side of the URL bar and the session.
    var padding: CGFloat
    /// Between the card and the waterfall.
    var gap: CGFloat
    /// The card's width for a desktop page: 256 px, growing with the page up to 560 px.
    var cardWidths: ClosedRange<CGFloat>
    /// The narrowest the card gets so the sessions and the waterfall keep their room.
    var cardMinimum: CGFloat
    var waterfallMinimum: CGFloat

    init(factor: CGFloat = UIScale.factor) {
        sessionsWidth = UIScale.length(232, factor: factor)
        padding = UIScale.length(20, factor: factor)
        gap = UIScale.length(16, factor: factor)
        cardWidths = UIScale.length(256, factor: factor)...UIScale.length(560, factor: factor)
        cardMinimum = UIScale.length(200, factor: factor)
        waterfallMinimum = ProbeWaterfall.minimumWidth(factor: factor)
    }

    /// Whether a page `pageWidth` wide has room for the sessions beside a session: the card and the waterfall at
    /// their minimums still fit next to them.
    func showsSessions(pageWidth: CGFloat) -> Bool {
        pageWidth - sessionsWidth - 0.5 - 2 * padding >= cardMinimum + gap + waterfallMinimum
    }

    /// The card's width in a row `total` wide. A desktop page gets 40 % of the row within `cardWidths`; an iPhone
    /// page 45 %, up to the iPhone's viewport, which is web content and does not scale. Where the waterfall would
    /// lack its minimum, the card gives it the room, down to `cardMinimum`.
    func cardWidth(total: CGFloat, mode: ProbeDeviceMode) -> CGFloat {
        let preferred = switch mode {
        case .iphone: min(ProbeWebSession.iPhoneViewport.width, max(cardWidths.lowerBound, total * 0.45))
        case .desktop: min(cardWidths.upperBound, max(cardWidths.lowerBound, total * 0.4))
        }
        return max(cardMinimum, min(preferred, total - gap - waterfallMinimum))
    }
}

/// Saved probe sessions, newest first.
private struct ProbeSessionsColumn: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            SectionLabel(text: tr("Sessions", "SiteProbe"))
                .padding(.horizontal, 16.px)
                .padding(.top, 12.px)
                .padding(.bottom, 6.px)
            if model.probe.sessions.isEmpty {
                Text(tr("Probes you run are kept here.", "SiteProbe"))
                    .font(.design(11.5))
                    .foregroundStyle(Theme.ink3)
                    .padding(.horizontal, 16.px)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    LazyVStack(spacing: 2.px) {
                        ForEach(model.probe.sessions) { session in
                            row(session)
                        }
                    }
                    .padding(.horizontal, 8.px)
                    .padding(.bottom, 8.px)
                }
            }
        }
        // Leading, so the header stays 16 px in when the column has no sessions yet.
        .frame(width: SiteProbeLayout.current.sessionsWidth, alignment: .leading)
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
            HStack(spacing: 10.px) {
                Text(verbatim: String(bare.prefix(1)).uppercased())
                    .font(.design(12, .bold))
                    .foregroundStyle(.white)
                    .frame(width: 28.px, height: 28.px)
                    .background(Theme.tileProbe, in: Circle())
                VStack(alignment: .leading, spacing: 1.px) {
                    Text(session.host)
                        .font(.design(12.5, .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text([trn("%lld host", "%lld hosts", session.hosts.count, "SiteProbe"),
                          trn("%lld IP", "%lld IPs", session.ipCount, "SiteProbe"),
                          Fmt.seconds(session.duration)].joined(separator: " · "))
                        .font(.design(11))
                        .foregroundStyle(Theme.ink2)
                        .lineLimit(1)
                    Text(AnalyzeFormat.seen(session.startedAt))
                        .font(.design(10.5))
                        .foregroundStyle(Theme.ink3)
                }
                Spacer(minLength: 0)
            }
            .padding(8.px)
            .background(selected ? Theme.accentTint : .clear, in: RoundedRectangle(cornerRadius: 9.px, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 9.px, style: .continuous))
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
        .clipShape(RoundedRectangle(cornerRadius: 12.px, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12.px, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.06), radius: 4.px, y: 2.px)
    }

    private var miniToolbar: some View {
        HStack(spacing: 7.px) {
            Group {
                Button { web.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(!running || !web.canGoBack)
                Button { web.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(!running || !web.canGoForward)
            }
            .font(.design(13))
            HStack(spacing: 5.px) {
                Circle().fill(running ? Theme.live : Theme.ink3).frame(width: 6.px, height: 6.px)
                Text(currentAddress)
                    .font(Theme.mono(10.5))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8.px)
            .frame(height: 20.px)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: 6.px, style: .continuous))
            // The design's 20 px pill on the fill, its label semibold.
            Button { openWindow() } label: { Text(tr("Pop Out", "SiteProbe")).fontWeight(.semibold) }
                .buttonStyle(DesignButtonStyle(height: 20, fontSize: 10.5, cornerRadius: 5, horizontalPadding: 7))
                .disabled(!running || web.isPoppedOut || web.isStopping)
        }
        .buttonStyle(.borderless)
        .font(.design(11))
        .foregroundStyle(Theme.ink2)
        .padding(.horizontal, 10.px)
        .frame(height: 30.px)
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
                VStack(spacing: 9.px) {
                    Image(systemName: "macwindow")
                        .font(.design(30, .light))
                        .foregroundStyle(Theme.ink3)
                    Text(tr("Browsing in its own window", "SiteProbe"))
                        .font(.design(12.5, .semibold))
                        .foregroundStyle(Theme.ink)
                    Text(ProbeViewport.caption(mode: model.preferences.probeMode, size: nil))
                        .font(.design(11))
                        .foregroundStyle(Theme.ink2)
                        .multilineTextAlignment(.center)
                    // The design's 24 px pill on the fill.
                    Button(tr("Close Window", "SiteProbe")) { closeWindow() }
                        .buttonStyle(DesignButtonStyle(height: 24, fontSize: 11.5, cornerRadius: 7, horizontalPadding: 10))
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
                .font(.design(compact ? 12 : 13, .medium))
                .foregroundStyle(Theme.ink)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, (compact ? 14 : 18).px)
                .padding(.vertical, (compact ? 10 : 12).px)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 10.px, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10.px, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8.px, y: 2.px)
                .frame(maxWidth: (compact ? 300 : 380).px)
                .padding((compact ? 16 : 32).px)
        }
        .clipped()
    }
}

/// Stands in for Stop while the probe finishes: the rest of the tail after the first load, the last Surge
/// records, then saving the session. It takes the button style of the Stop it replaces.
struct ProbeStoppingButton: View {
    static let tint = Color(oklch: 0.62, 0.19, 27)

    var body: some View {
        Button {} label: {
            HStack(spacing: 6.px) {
                ProgressView().controlSize(.mini)
                Text(tr("Stopping…", "SiteProbe"))
            }
        }
        .disabled(true)
        .help(tr("Recording the page's last requests, then saving the session", "SiteProbe"))
    }
}

/// Centered content on the pane's background.
private struct ProbeVeil<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(20.px)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Diagonal hatching standing in for a page that is not loaded.
struct ProbeStripes: View {
    var body: some View {
        Canvas { context, size in
            let spacing = 16.px
            var path = Path()
            var x: CGFloat = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += spacing
            }
            context.stroke(path, with: .color(Theme.fill), lineWidth: 8.px)
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
