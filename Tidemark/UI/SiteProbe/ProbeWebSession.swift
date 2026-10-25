import AppKit
import Network
import Observation
import os
import SwiftUI
import WebKit

/// Owns the probe browser — a WebKit `WebPage` whose only network path is the probe's loopback
/// CONNECT proxy — and shares it between the Site Probe page and the pop-out window.
///
/// Exactly one `WebView` may show the page at a time: WebKit traps when a page that is still bound to one
/// `WebView` is given to another. `host` names the view allowed to show it; moving the page between the
/// Site Probe page and the pop-out window first clears `host`, waits until the old `WebView` is gone, and
/// only then names the new one. Navigations after the first page load are recorded as click steps;
/// switching between desktop and iPhone records a step and reloads with the other user agent.
@MainActor
@Observable
final class ProbeWebSession {
    static let shared = ProbeWebSession()

    /// A view that can show the probe page.
    enum Host: Hashable, Sendable {
        /// The browser card of the Site Probe page.
        case inline
        /// The pop-out window.
        case window
    }

    /// URL typed in the Site Probe page; the window's Start button probes it too.
    var urlDraft = ""
    /// The probe browser of the running (or last) probe.
    private(set) var page: WebPage?
    /// Where the page is shown, or is being moved to.
    private(set) var hostTarget: Host = .inline
    /// The view allowed to show the page right now; nil while the page moves between views.
    private(set) var host: Host? = .inline
    /// The pop-out window is open.
    private(set) var isWindowOpen = false
    /// Loopback port of the running probe's proxy.
    private(set) var port: UInt16?
    private(set) var mode: ProbeDeviceMode = .desktop
    private(set) var isStarting = false
    /// Stop was pressed and the probe is still finishing: waiting for the tail after the first load,
    /// letting the last Surge records arrive and saving the session. A new probe can't start meanwhile.
    private(set) var isStopping = false
    /// Start Probe, Stop and New Probe are unavailable while a probe starts or stops.
    var isBusy: Bool { isStarting || isStopping }
    /// The first page load finished (or failed); later navigations count as clicks.
    private(set) var firstLoadFinished = false
    /// Why the last navigation failed, shown in the status line.
    private(set) var loadFailure: String?
    /// Picture of the page taken when its probe stopped, shown under the "session ended" veil.
    private(set) var endedSnapshot: ProbeEndedSnapshot?

    /// The page lives in (or is moving to) the pop-out window.
    var isPoppedOut: Bool { hostTarget == .window }

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private var runningSessionID: UUID?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lastStepURL: URL?
    /// Set while a reload or redirect chain we started is in flight, so it is not taken for a click.
    @ObservationIgnored private var suppressSteps = false
    /// Views whose `WebView` is currently on screen.
    @ObservationIgnored private var mounted: Set<Host> = []
    @ObservationIgnored private var moveTask: Task<Void, Never>?

    private static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "probe-browser")

    /// Data store shared by non-isolated probes, so cookies and caches carry over between them.
    private static let sharedStoreID = UUID(uuidString: "6A0F6E52-6C0B-4C55-9F57-7D1E3C2B9A41")!

    // MARK: Lifecycle

    /// Opens the probe's proxy through the engine, then loads `urlDraft` in a fresh page behind it.
    ///
    /// The page is shown in the pop-out window when `inWindow` is true; by default when "Open in its own
    /// window" is on or the window is already open. The caller opens the window.
    func start(model: AppModel, inWindow: Bool? = nil) async throws {
        // The probe controller clears `running` before it saves the stopped session, so `isStopping` is what
        // keeps a new probe from starting while the old `stop()` can still tear the browser down.
        guard !isBusy, !model.probe.isRunning else { return }
        guard let url = Self.normalizedURL(urlDraft) else {
            throw ProbeWebError(errorDescription: trf("“%@” is not a web address.", "SiteProbe", urlDraft))
        }
        isStarting = true
        defer { isStarting = false }
        tearDown()
        self.model = model
        urlDraft = url.absoluteString
        loadFailure = nil
        endedSnapshot = nil

        let mode = model.preferences.probeMode
        let port = try await model.probeActions.startProbe(url: url.absoluteString, mode: mode, tail: model.preferences.probeTail)
        guard port != 0, let endpointPort = NWEndpoint.Port(rawValue: port) else {
            await model.probeActions.stopProbe()
            throw ProbeWebError(errorDescription: tr("The probe's proxy did not open a port.", "SiteProbe"))
        }
        self.port = port
        self.mode = mode
        runningSessionID = model.probe.running?.id

        // Choose the view before the page exists, so it is never shown in one view and then taken by another.
        moveTask?.cancel()
        moveTask = nil
        hostTarget = (inWindow ?? (model.preferences.probeOwnWindow || isWindowOpen)) ? .window : .inline
        host = hostTarget

        let page = makePage(port: endpointPort, isolated: model.preferences.probeIsolated)
        page.customUserAgent = Self.userAgent(for: mode)
        self.page = page
        firstLoadFinished = false
        lastStepURL = nil
        observeNavigations(of: page, model: model)
        load(page, request: URLRequest(url: url), isFirstLoad: true)
    }

    /// Stops recording; keeps a snapshot of the last page for the "session ended" view.
    ///
    /// Stopping can take a while (the rest of the tail after the first load, the grace for Surge's last
    /// records, saving to PostgreSQL); `isStopping` is set throughout and further presses are ignored. Only
    /// the page this call stopped is torn down.
    func stop(model: AppModel) async {
        guard !isStopping else { return }
        isStopping = true
        defer { isStopping = false }
        let stoppingPage = page
        let sessionID = runningSessionID ?? model.probe.running?.id
        if let stoppingPage, let sessionID, let image = await Self.snapshot(of: stoppingPage, mode: mode) {
            endedSnapshot = ProbeEndedSnapshot(sessionID: sessionID, image: image, mode: mode)
        }
        let saved = await model.probeActions.stopProbe()
        guard page === stoppingPage else { return }
        if let saved, endedSnapshot?.sessionID != saved.id, let snapshot = endedSnapshot {
            endedSnapshot = ProbeEndedSnapshot(sessionID: saved.id, image: snapshot.image, mode: snapshot.mode)
        }
        tearDown()
    }

    /// Switches the browser profile; while a probe runs this records a step and reloads the page.
    func switchMode(to newMode: ProbeDeviceMode, model: AppModel) {
        model.preferences.probeMode = newMode
        guard newMode != mode else { return }
        mode = newMode
        guard let page, model.probe.isRunning, !isStopping else { return }
        page.customUserAgent = Self.userAgent(for: newMode)
        model.probeActions.recordStep(label: newMode == .iphone ? "Switched to iPhone" : "Switched to desktop",
                                      url: page.url?.absoluteString)
        suppressSteps = true
        let task = Task { [weak self] in
            do {
                for try await _ in page.reload() {}
            } catch {
                self?.navigationFailed(error)
            }
            self?.suppressSteps = false
            self?.lastStepURL = page.url
        }
        tasks.append(task)
    }

    func goBack() {
        guard !isStopping, let page, let item = page.backForwardList.backList.last else { return }
        load(page, item: item)
    }

    func goForward() {
        guard !isStopping, let page, let item = page.backForwardList.forwardList.first else { return }
        load(page, item: item)
    }

    var canGoBack: Bool { !isStopping && !(page?.backForwardList.backList.isEmpty ?? true) }
    var canGoForward: Bool { !isStopping && !(page?.backForwardList.forwardList.isEmpty ?? true) }

    /// Snapshot of `sessionID`'s page, if it was the last probe stopped in this run of the app.
    func snapshot(for sessionID: UUID) -> ProbeEndedSnapshot? {
        endedSnapshot?.sessionID == sessionID ? endedSnapshot : nil
    }

    private func tearDown() {
        tasks.forEach { $0.cancel() }
        tasks.removeAll()
        page?.stopLoading()
        page = nil
        port = nil
        runningSessionID = nil
        suppressSteps = false
    }

    // MARK: Hosting

    /// Pop Out: hands the page to the window, then opens it (`open` calls `openWindow`).
    func popOut(open: () -> Void) {
        move(to: .window)
        open()
    }

    /// The pop-out window appeared. Opened from the Window menu while a probe runs inline, it takes the page.
    func windowDidOpen() {
        isWindowOpen = true
        if page != nil, hostTarget == .inline { move(to: .window) }
    }

    /// The pop-out window closed: the page goes back to the Site Probe page once the window's view is gone.
    func windowDidClose() {
        isWindowOpen = false
        if hostTarget == .window { move(to: .inline) }
    }

    /// A `WebView` showing the page appeared in `view`.
    func webViewDidAppear(in view: Host) {
        mounted.insert(view)
    }

    /// A `WebView` showing the page disappeared from `view`.
    func webViewDidDisappear(from view: Host) {
        mounted.remove(view)
    }

    /// Moves the page to `target`: no view may show it until the `WebView` that showed it is gone.
    private func move(to target: Host) {
        hostTarget = target
        // A move in flight hands the page to the latest target when it ends.
        guard moveTask == nil, host != target else { return }
        host = nil
        moveTask = Task { [weak self] in
            // Up to a second for the old view to go away (a closing window tears its views down late),
            // then one more beat so WebKit has released the page. The views drop their `WebView` in the
            // SwiftUI update right after `host` became nil, so the cap is only reached when a view
            // registered without reporting its disappearance; nothing is bound to the page then.
            for _ in 0..<40 {
                guard let self, !self.mounted.isEmpty else { break }
                try? await Task.sleep(for: .milliseconds(25))
            }
            if let self, !self.mounted.isEmpty {
                let views = self.mounted.map { "\($0)" }.sorted().joined(separator: ",")
                let destination = "\(self.hostTarget)"
                Self.log.notice("Probe page handed to \(destination, privacy: .public) while still registered in \(views, privacy: .public)")
            }
            try? await Task.sleep(for: .milliseconds(60))
            guard !Task.isCancelled, let self else { return }
            self.host = self.hostTarget
            self.moveTask = nil
        }
    }

    // MARK: Page

    private func makePage(port: NWEndpoint.Port, isolated: Bool) -> WebPage {
        var configuration = WebPage.Configuration()
        let store: WKWebsiteDataStore = isolated ? .nonPersistent() : WKWebsiteDataStore(forIdentifier: Self.sharedStoreID)
        var proxy = ProxyConfiguration(httpCONNECTProxy: .hostPort(host: "127.0.0.1", port: port))
        // Never fall back to a direct connection: everything the page does must be attributable.
        proxy.allowFailover = false
        store.proxyConfigurations = [proxy]
        configuration.websiteDataStore = store
        configuration.defaultNavigationPreferences = navigationPreferences()
        let page = WebPage(configuration: configuration, navigationDecider: ProbeNavigationDecider(session: self))
        page.isInspectable = true
        return page
    }

    /// Per-navigation preferences: content mode for the profile, Global Privacy Control (macOS 27, from
    /// Preferences), and maximum compatibility so the page behaves as it would in Safari.
    func navigationPreferences(base: WebPage.NavigationPreferences = WebPage.NavigationPreferences()) -> WebPage.NavigationPreferences {
        var preferences = base
        preferences.preferredContentMode = mode == .iphone ? .mobile : .desktop
        preferences.securityRestrictionMode = .maximizeCompatibility
        preferences.isGlobalPrivacyControlEnabled = model?.preferences.probeGlobalPrivacyControl ?? false
        return preferences
    }

    private func load(_ page: WebPage, request: URLRequest, isFirstLoad: Bool) {
        let task = Task { [weak self] in
            do {
                for try await _ in page.load(request) {}
            } catch {
                self?.navigationFailed(error)
            }
            if isFirstLoad, !Task.isCancelled { self?.firstLoadDidFinish(page) }
        }
        tasks.append(task)
    }

    private func load(_ page: WebPage, item: WebPage.BackForwardList.Item) {
        let task = Task { [weak self] in
            do {
                for try await _ in page.load(item) {}
            } catch {
                self?.navigationFailed(error)
            }
        }
        tasks.append(task)
    }

    /// Opens a link that asked for a new window in the probe page itself.
    fileprivate func openInPlace(_ request: URLRequest) {
        guard let page else { return }
        let task = Task { [weak self] in
            do {
                for try await _ in page.load(request) {}
            } catch {
                self?.navigationFailed(error)
            }
        }
        tasks.append(task)
    }

    private func firstLoadDidFinish(_ page: WebPage) {
        guard page === self.page else { return }
        firstLoadFinished = true
        lastStepURL = page.url
        // The engine switches the probe from "loading" to "recording".
        if let model, model.probe.isRunning { model.probeActions.pageDidFinishLoading() }
    }

    private func navigationFailed(_ error: any Error) {
        if case WebPage.NavigationError.pageClosed = error { return }
        if error is CancellationError { return }
        if case WebPage.NavigationError.failedProvisionalNavigation(let underlying) = error {
            let nsError = underlying as NSError
            if nsError.domain == NSURLErrorDomain, nsError.code == NSURLErrorCancelled { return }
            loadFailure = underlying.localizedDescription
        } else {
            loadFailure = error.localizedDescription
        }
    }

    /// Records every URL change after the first load — link clicks, form posts, and single-page-app
    /// route changes alike — as a click step.
    private func observeNavigations(of page: WebPage, model: AppModel) {
        let task = Task { [weak self] in
            for await url in Observations({ page.url }) {
                guard let self, !Task.isCancelled else { return }
                self.urlDidChange(url, model: model)
            }
        }
        tasks.append(task)
    }

    private func urlDidChange(_ url: URL?, model: AppModel) {
        guard let url else { return }
        guard firstLoadFinished, !suppressSteps, model.probe.isRunning else {
            lastStepURL = url
            return
        }
        guard url != lastStepURL else { return }
        lastStepURL = url
        loadFailure = nil
        model.probeActions.recordStep(label: "Click · " + Self.stepTitle(for: url), url: url.absoluteString)
    }

    /// The page's first screen (one viewport, not the whole document, which can be thousands of points tall).
    private static func snapshot(of page: WebPage, mode: ProbeDeviceMode) async -> NSImage? {
        let fallback = mode == .iphone ? iPhoneViewport : CGSize(width: 1280, height: 800)
        var viewport = fallback
        let script = "return [window.innerWidth, window.innerHeight];"
        if let values = try? await page.callJavaScript(script, contentWorld: .defaultClient) as? [NSNumber], values.count == 2,
           values[0].doubleValue > 0, values[1].doubleValue > 0 {
            viewport = CGSize(width: values[0].doubleValue, height: values[1].doubleValue)
        }
        let region = WebPage.ExportedContentConfiguration.Region.rect(CGRect(origin: .zero, size: viewport))
        guard let data = try? await page.exported(as: .image(region: region)) else { return nil }
        return NSImage(data: data)
    }

    // MARK: Helpers

    /// Adds `https://` when the scheme is missing; nil when there is no host.
    nonisolated static func normalizedURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let candidate = trimmed.contains("://") ? trimmed : "https://" + trimmed
        guard let url = URL(string: candidate), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https", let host = url.host(), !host.isEmpty else { return nil }
        return url
    }

    /// `/apple/swift?tab=readme`, or the host for a site's home page.
    nonisolated static func stepTitle(for url: URL) -> String {
        var path = url.path(percentEncoded: false)
        if let query = url.query(percentEncoded: false), !query.isEmpty { path += "?" + query }
        if let fragment = url.fragment(percentEncoded: false), !fragment.isEmpty { path += "#" + fragment }
        if path.isEmpty || path == "/" { return url.host() ?? url.absoluteString }
        return path.count > 72 ? String(path.prefix(71)) + "…" : path
    }

    nonisolated static func userAgent(for mode: ProbeDeviceMode) -> String {
        switch mode {
        case .desktop:
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Safari/605.1.15"
        case .iphone:
            "Mozilla/5.0 (iPhone; CPU iPhone OS 18_6 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0 Mobile/15E148 Safari/604.1"
        }
    }

    /// The iPhone viewport the probe emulates.
    static let iPhoneViewport = CGSize(width: 393, height: 852)
}

/// The last picture of a probe's page, kept after it stopped.
struct ProbeEndedSnapshot {
    var sessionID: UUID
    var image: NSImage
    var mode: ProbeDeviceMode
}

/// A Site Probe failure with its message already in the UI language.
struct ProbeWebError: LocalizedError {
    var errorDescription: String?
}

/// Applies the session's profile to every navigation and keeps new-window links inside the probe page.
private struct ProbeNavigationDecider: WebPage.NavigationDeciding {
    weak var session: ProbeWebSession?

    @MainActor
    mutating func decidePolicy(for action: WebPage.NavigationAction, preferences: inout WebPage.NavigationPreferences) async -> WKNavigationActionPolicy {
        guard let session else { return .allow }
        preferences = session.navigationPreferences(base: preferences)
        if action.target == nil {
            // A probe has a single page; links that ask for a new window open in place.
            session.openInPlace(action.request)
            return .cancel
        }
        return .allow
    }
}

/// Registers a `WebView` showing the probe page with the session while it is on screen.
struct ProbeWebViewMount: ViewModifier {
    var view: ProbeWebSession.Host

    func body(content: Content) -> some View {
        content
            .onAppear { ProbeWebSession.shared.webViewDidAppear(in: view) }
            .onDisappear { ProbeWebSession.shared.webViewDidDisappear(from: view) }
    }
}
