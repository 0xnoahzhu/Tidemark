import AppKit
import Network
import Observation
import SwiftUI
import WebKit

/// Owns the probe browser — a WebKit `WebPage` whose only network path is the probe's loopback
/// CONNECT proxy — and shares it between the Site Probe page and the pop-out window.
///
/// Only one `WebView` may show the page at a time: the window while it is open (`isPoppedOut`),
/// otherwise the inline preview. Navigations after the first page load are recorded as click steps;
/// switching between desktop and iPhone records a step and reloads with the other user agent.
@MainActor
@Observable
final class ProbeWebSession {
    static let shared = ProbeWebSession()

    /// URL typed in the Site Probe page; the window's Start button probes it too.
    var urlDraft = ""
    /// The probe browser of the running (or last) probe.
    private(set) var page: WebPage?
    /// The pop-out window is open and shows the page.
    var isPoppedOut = false
    /// Loopback port of the running probe's proxy.
    private(set) var port: UInt16?
    private(set) var mode: ProbeDeviceMode = .desktop
    private(set) var isStarting = false
    /// The first page load finished (or failed); later navigations count as clicks.
    private(set) var firstLoadFinished = false
    /// Why the last navigation failed, shown in the status line.
    private(set) var loadFailure: String?
    /// Picture of the page taken when its probe stopped, shown under the "session ended" veil.
    private(set) var endedSnapshot: ProbeEndedSnapshot?
    /// Ask sites not to sell or share data (`Sec-GPC: 1`, `navigator.globalPrivacyControl`).
    var sendsGlobalPrivacyControl: Bool {
        didSet { UserDefaults.standard.set(sendsGlobalPrivacyControl, forKey: Self.gpcDefaultsKey) }
    }

    @ObservationIgnored private var runningSessionID: UUID?
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    @ObservationIgnored private var lastStepURL: URL?
    /// Set while a reload or redirect chain we started is in flight, so it is not taken for a click.
    @ObservationIgnored private var suppressSteps = false

    private static let gpcDefaultsKey = "probe.globalPrivacyControl"
    /// Data store shared by non-isolated probes, so cookies and caches carry over between them.
    private static let sharedStoreID = UUID(uuidString: "6A0F6E52-6C0B-4C55-9F57-7D1E3C2B9A41")!

    init() {
        sendsGlobalPrivacyControl = UserDefaults.standard.bool(forKey: Self.gpcDefaultsKey)
    }

    // MARK: Lifecycle

    /// Opens the probe's proxy through the engine, then loads `urlDraft` in a fresh page behind it.
    func start(model: AppModel) async throws {
        guard !isStarting, !model.probe.isRunning else { return }
        guard let url = Self.normalizedURL(urlDraft) else {
            throw ProbeWebError(errorDescription: trf("“%@” is not a web address.", "SiteProbe", urlDraft))
        }
        isStarting = true
        defer { isStarting = false }
        tearDown()
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

        let page = makePage(port: endpointPort, isolated: model.preferences.probeIsolated)
        page.customUserAgent = Self.userAgent(for: mode)
        self.page = page
        firstLoadFinished = false
        lastStepURL = nil
        observeNavigations(of: page, model: model)
        load(page, request: URLRequest(url: url), isFirstLoad: true)
    }

    /// Stops recording; keeps a snapshot of the last page for the "session ended" view.
    func stop(model: AppModel) async {
        let sessionID = runningSessionID ?? model.probe.running?.id
        if let page, let sessionID, let data = try? await page.exported(as: .image()), let image = NSImage(data: data) {
            endedSnapshot = ProbeEndedSnapshot(sessionID: sessionID, image: image, mode: mode)
        }
        let saved = await model.probeActions.stopProbe()
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
        guard let page, model.probe.isRunning else { return }
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
        guard let page, let item = page.backForwardList.backList.last else { return }
        load(page, item: item)
    }

    func goForward() {
        guard let page, let item = page.backForwardList.forwardList.first else { return }
        load(page, item: item)
    }

    var canGoBack: Bool { !(page?.backForwardList.backList.isEmpty ?? true) }
    var canGoForward: Bool { !(page?.backForwardList.forwardList.isEmpty ?? true) }

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

    /// Per-navigation preferences: content mode for the profile, Global Privacy Control (macOS 27),
    /// and maximum compatibility so the page behaves as it would in Safari.
    func navigationPreferences(base: WebPage.NavigationPreferences = WebPage.NavigationPreferences()) -> WebPage.NavigationPreferences {
        var preferences = base
        preferences.preferredContentMode = mode == .iphone ? .mobile : .desktop
        preferences.securityRestrictionMode = .maximizeCompatibility
        preferences.isGlobalPrivacyControlEnabled = sendsGlobalPrivacyControl
        return preferences
    }

    private func load(_ page: WebPage, request: URLRequest, isFirstLoad: Bool) {
        let task = Task { [weak self] in
            do {
                for try await _ in page.load(request) {}
            } catch {
                self?.navigationFailed(error)
            }
            if isFirstLoad { self?.firstLoadDidFinish(page) }
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
        firstLoadFinished = true
        lastStepURL = page.url
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
