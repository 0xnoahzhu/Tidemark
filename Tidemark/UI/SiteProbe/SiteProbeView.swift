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
                Button(tr("New Probe", "SiteProbe"), systemImage: "plus") { newProbe() }
                    .labelStyle(.titleAndIcon)
                    .disabled(model.probe.isRunning || web.isStarting)
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
            .disabled(running || web.isStarting)
            .onSubmit { if !running { start() } }

            if running {
                Button(tr("Stop", "SiteProbe")) { stop() }
                    .buttonStyle(.glassProminent)
                    .tint(Color(oklch: 0.62, 0.19, 27))
                    .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(tr("Start Probe", "SiteProbe")) { start() }
                    .buttonStyle(.glassProminent)
                    .tint(Theme.accent)
                    .disabled(ProbeWebSession.normalizedURL(web.urlDraft) == nil || web.isStarting)
            }
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 8)
    }

    private var optionsRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 18) {
                isolationToggle
                recordsUntilStop
                modePicker
                ownWindowToggle
                privacyToggle
                Spacer(minLength: 8)
                proxyCaption
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 18) {
                    isolationToggle
                    recordsUntilStop
                    Spacer(minLength: 8)
                    proxyCaption
                }
                HStack(spacing: 18) {
                    modePicker
                    ownWindowToggle
                    privacyToggle
                }
            }
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
    }

    private var modePicker: some View {
        Picker(tr("Device", "SiteProbe"), selection: Binding(
            get: { model.preferences.probeMode },
            set: { web.switchMode(to: $0, model: model) }
        )) {
            Text(tr("Desktop", "SiteProbe")).tag(ProbeDeviceMode.desktop)
            Text(tr("iPhone", "SiteProbe")).tag(ProbeDeviceMode.iphone)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
    }

    private var ownWindowToggle: some View {
        @Bindable var preferences = model.preferences
        return Toggle(tr("Open in its own window", "SiteProbe"), isOn: $preferences.probeOwnWindow)
            .toggleStyle(.checkbox)
            .fixedSize()
    }

    private var privacyToggle: some View {
        @Bindable var web = web
        return Toggle(tr("Send Global Privacy Control", "SiteProbe"), isOn: $web.sendsGlobalPrivacyControl)
            .toggleStyle(.checkbox)
            .help(tr("Tells sites not to sell or share your data (the Sec-GPC header), like Safari's privacy setting. Applies from the next page load.", "SiteProbe"))
            .fixedSize()
    }

    @ViewBuilder
    private var proxyCaption: some View {
        if let port = model.probe.proxyPort ?? web.port {
            Text(verbatim: "127.0.0.1:\(port) → Surge")
                .font(Theme.mono(11))
                .foregroundStyle(Theme.ink3)
                .fixedSize()
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
                if running { StatusDot(color: Theme.recording, size: 7, pulsing: true) }
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
                                     openWindow: { openWindow(id: WindowID.probeBrowser) },
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
                                      tr("How attribution works.", "SiteProbe")))
            .font(.system(size: 11.5))
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
                try await web.start(model: model)
                if model.preferences.probeOwnWindow { openWindow(id: WindowID.probeBrowser) }
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
        .frame(width: 232)
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
        .contextMenu {
            Button(tr("Probe Again", "SiteProbe")) {
                model.probe.selectedID = session.id
                ProbeWebSession.shared.urlDraft = session.url
            }
            Divider()
            Button(tr("Delete", "SiteProbe"), role: .destructive) {
                Task { await model.probeActions.deleteProbe(session.id) }
            }
        }
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
                .disabled(!running || web.isPoppedOut)
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
        } else if running, let page = web.page {
            WebView(page)
                .webViewBackForwardNavigationGestures(.enabled)
                .webViewMagnificationGestures(.enabled)
        } else {
            ProbeEndedView(snapshot: web.snapshot(for: session.id), compact: true)
        }
    }
}

/// An ended (or never seen) session: its last picture, blurred, or a placeholder, under a note.
struct ProbeEndedView: View {
    var snapshot: ProbeEndedSnapshot?
    var compact: Bool

    var body: some View {
        ZStack {
            if let snapshot {
                Image(nsImage: snapshot.image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .clipped()
                    .blur(radius: 3)
                    .opacity(0.7)
            } else {
                ProbeStripes()
            }
            Text(tr("This session has ended. Start a new probe to keep browsing.", "SiteProbe"))
                .font(.system(size: compact ? 12 : 13, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .padding(compact ? 20 : 40)
        }
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
