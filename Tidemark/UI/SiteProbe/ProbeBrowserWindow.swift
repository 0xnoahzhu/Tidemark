import SwiftUI
import WebKit

/// Pop-out browser window of a running site probe: back / forward, the address with a recording dot,
/// the Desktop / iPhone switch and Stop, over a caption naming the proxy port everything goes through.
struct ProbeBrowserWindow: View {
    @Environment(AppModel.self) private var model

    @State private var startError: (any Error)?
    @State private var viewport: CGSize?

    private var web: ProbeWebSession { .shared }

    var body: some View {
        let running = model.probe.isRunning
        VStack(spacing: 0) {
            captionStrip(running: running)
            ZStack {
                content(running: running)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: model.preferences.probeMode == .iphone ? 480 : 760, idealWidth: 1280,
               minHeight: model.preferences.probeMode == .iphone ? 640 : 520, idealHeight: 824)
        .background(Theme.bg)
        .navigationTitle(model.probe.running?.host ?? tr("Site Probe", "SiteProbe"))
        .toolbar { toolbar(running: running) }
        .onAppear { web.isPoppedOut = true }
        .onDisappear { web.isPoppedOut = false }
        .alert(error: $startError) {
            Button(tr("OK", "SiteProbe")) {}
        }
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private func toolbar(running: Bool) -> some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button(tr("Back", "SiteProbe"), systemImage: "chevron.left") { web.goBack() }
                .disabled(!running || !web.canGoBack)
            Button(tr("Forward", "SiteProbe"), systemImage: "chevron.right") { web.goForward() }
                .disabled(!running || !web.canGoForward)
        }

        ToolbarItem(placement: .principal) {
            HStack(spacing: 7) {
                if running { StatusDot(color: Theme.recording, size: 7, pulsing: true) }
                Text(address)
                    .font(Theme.mono(12))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .frame(minWidth: 200, idealWidth: 420, maxWidth: 560)
        }

        ToolbarSpacer(.flexible)

        ToolbarItem(placement: .primaryAction) {
            Picker(tr("Device", "SiteProbe"), selection: Binding(
                get: { model.preferences.probeMode },
                set: { web.switchMode(to: $0, model: model) }
            )) {
                Text(tr("Desktop", "SiteProbe")).tag(ProbeDeviceMode.desktop)
                Text(tr("iPhone", "SiteProbe")).tag(ProbeDeviceMode.iphone)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }

        ToolbarSpacer(.fixed, placement: .primaryAction)

        ToolbarItem(placement: .primaryAction) {
            if running {
                Button(tr("Stop", "SiteProbe")) {
                    Task { await web.stop(model: model) }
                }
                .buttonStyle(.glassProminent)
                .tint(Color(oklch: 0.62, 0.19, 27))
                .keyboardShortcut(".", modifiers: .command)
            } else {
                Button(tr("Start Probe", "SiteProbe")) {
                    Task {
                        do { try await web.start(model: model) } catch { startError = error }
                    }
                }
                .buttonStyle(.glassProminent)
                .tint(Theme.accent)
                .disabled(ProbeWebSession.normalizedURL(web.urlDraft) == nil || web.isStarting)
            }
        }
    }

    private var address: String {
        if let url = web.page?.url {
            return url.absoluteString.replacingOccurrences(of: "https://", with: "")
        }
        return web.urlDraft.isEmpty ? tr("No page", "SiteProbe") : web.urlDraft
    }

    // MARK: Caption

    private func captionStrip(running: Bool) -> some View {
        let session = model.probe.running
        return HStack(spacing: 8) {
            Text(tr("All traffic from this window goes to", "SiteProbe"))
            Text(verbatim: "127.0.0.1:\((model.probe.proxyPort ?? web.port).map(String.init) ?? "—") → Surge")
                .font(Theme.mono(11))
            Text(verbatim: "·")
            Text(ProbeViewport.caption(mode: model.preferences.probeMode, size: viewport))
            Spacer(minLength: 8)
            if let session {
                Text([trn("%lld step", "%lld steps", session.steps.count, "SiteProbe"),
                      trn("%lld host", "%lld hosts", session.hosts.count, "SiteProbe")].joined(separator: " · "))
            }
        }
        .font(.system(size: 11))
        .foregroundStyle(Theme.ink2)
        .lineLimit(1)
        .padding(.horizontal, 14)
        .frame(height: 24)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Rectangle().fill(Theme.line).frame(height: 0.5) }
        .opacity(running ? 1 : 0.6)
    }

    // MARK: Content

    @ViewBuilder
    private func content(running: Bool) -> some View {
        if running, let page = web.page {
            switch model.preferences.probeMode {
            case .desktop:
                WebView(page)
                    .webViewBackForwardNavigationGestures(.enabled)
                    .webViewMagnificationGestures(.enabled)
                    .onGeometryChange(for: CGSize.self, of: \.size) { viewport = $0 }
            case .iphone:
                phone(page)
            }
        } else if let last = model.probe.sessions.first, let snapshot = web.snapshot(for: last.id) {
            ProbeEndedView(snapshot: snapshot, compact: false)
        } else {
            Text(tr("Enter a URL in the Site Probe page and press Start Probe.", "SiteProbe"))
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.ink2)
                .multilineTextAlignment(.center)
                .padding(40)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.bg2)
        }
    }

    /// The page at iPhone size inside a device outline.
    private func phone(_ page: WebPage) -> some View {
        let screen = ProbeWebSession.iPhoneViewport
        return ZStack {
            Theme.bg3
            WebView(page)
                .frame(width: screen.width)
                .frame(maxHeight: screen.height)
                .clipShape(RoundedRectangle(cornerRadius: 37, style: .continuous))
                .padding(10)
                .background(Color(hex: 0x111111), in: RoundedRectangle(cornerRadius: 46, style: .continuous))
                .shadow(color: .black.opacity(0.3), radius: 25, y: 20)
                .padding(.vertical, 24)
        }
    }
}
