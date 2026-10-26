import AppKit

/// Shows Tidemark in the Dock only while one of its windows is open.
///
/// Tidemark is an agent app (`LSUIElement`), so it starts with no Dock icon and nothing flashes in the Dock at
/// launch. While the main window, Settings or the Site Probe window is open, minimized ones included (they live
/// in the Dock), the activation policy is `.regular`: Tidemark has a Dock icon, an app switcher entry and its menus
/// in the menu bar. When the last of them closes it goes back to `.accessory`. The menu bar panel, the status item,
/// sheets, popovers and alerts never count (`keepsDockIcon(_:)`).
///
/// Windows are followed without polling. Each window's `isVisible` is observed: opening, closing, ordering out and
/// hiding all change it, also for a window that opens behind other apps, where no occlusion change is posted.
/// Notifications about windows (framed as they are set up, becoming key or main, a new occlusion state, minimized
/// or restored) and the app becoming active, unhiding or restoring its windows bring new windows under that watch
/// and decide again. Leaving the Dock waits a moment, so moving from one window to another never takes the icon
/// away and brings it back.
@MainActor
final class DockPresence {
    private static var shared: DockPresence?

    /// Starts following Tidemark's windows. Call once at launch, from `AppBootstrap.start`.
    static func start(model: AppModel) {
        guard shared == nil else { return }
        let presence = DockPresence(icon: DockIconUpdater(model: model))
        shared = presence
        presence.start()
    }

    /// Stops following them, before quitting closes the windows; the policy and the Dock tile stay as they are.
    static func stop() {
        shared?.tearDown()
        shared = nil
    }

    /// What the policy decision needs to know about one window.
    struct WindowTraits: Equatable, Sendable {
        var isVisible: Bool
        var isMiniaturized: Bool
        /// Has a title bar: the status item, the menu bar panel, popovers and tool tips are borderless.
        var isTitled: Bool
        /// An `NSPanel`: alerts, open and save panels, the menu bar panel.
        var isPanel: Bool
        /// A sheet or a child window, which goes with the window it belongs to.
        var isAttached: Bool
    }

    /// Whether `window` keeps Tidemark in the Dock: an ordinary window, on screen or minimized into the Dock.
    static func keepsDockIcon(_ window: WindowTraits) -> Bool {
        guard window.isTitled, !window.isPanel, !window.isAttached else { return false }
        return window.isVisible || window.isMiniaturized
    }

    /// `.regular` while at least one of `windows` keeps Tidemark in the Dock, `.accessory` otherwise.
    static func policy(for windows: some Sequence<WindowTraits>) -> NSApplication.ActivationPolicy {
        windows.contains(where: keepsDockIcon) ? .regular : .accessory
    }

    /// How long the last window has to stay closed before the icon goes.
    static let leaveDelay: Duration = .milliseconds(250)

    private static let dockBundleIdentifier = "com.apple.dock"

    private struct WatchedWindow {
        weak var window: NSWindow?
        var visibility: NSKeyValueObservation
    }

    private let icon: DockIconUpdater
    private var watched: [ObjectIdentifier: WatchedWindow] = [:]
    private var tokens: [NotificationCenter.ObservationToken] = []
    private var workspaceToken: NotificationCenter.ObservationToken?
    /// The app that was active before Tidemark, to hand the focus back to when the last window closes.
    private var previousApp: NSRunningApplication?
    /// Until when the activation lent to the Dock by `reclaimMenuBar()` is taken back as Tidemark resigns.
    private var reclaimDeadline: ContinuousClock.Instant?
    private var updateScheduled = false
    private var pendingLeave: Task<Void, Never>?

    private init(icon: DockIconUpdater) {
        self.icon = icon
    }

    private func start() {
        let center = NotificationCenter.default
        tokens = [
            center.addObserver(of: NSWindow.self, for: .didResize) { [weak self] message in self?.watchNew(message.window) },
            center.addObserver(of: NSWindow.self, for: .didMove) { [weak self] message in self?.watchNew(message.window) },
            center.addObserver(of: NSWindow.self, for: .didBecomeKey) { [weak self] _ in self?.scheduleUpdate() },
            center.addObserver(of: NSWindow.self, for: .didBecomeMain) { [weak self] _ in self?.scheduleUpdate() },
            center.addObserver(of: NSWindow.self, for: .didChangeOcclusionState) { [weak self] _ in self?.scheduleUpdate() },
            center.addObserver(of: NSWindow.self, for: .didMiniaturize) { [weak self] _ in self?.scheduleUpdate() },
            center.addObserver(of: NSWindow.self, for: .didDeminiaturize) { [weak self] _ in self?.scheduleUpdate() },
            center.addObserver(of: NSWindow.self, for: .willClose) { [weak self] _ in self?.scheduleUpdate() },
            center.addObserver(of: NSApplication.shared, for: .didBecomeActive) { [weak self] _ in self?.scheduleUpdate() },
            center.addObserver(of: NSApplication.shared, for: .didResignActive) { [weak self] _ in self?.takeBackActivation() },
            center.addObserver(of: NSApplication.shared, for: .didUnhide) { [weak self] _ in self?.scheduleUpdate() },
            center.addObserver(of: NSApplication.shared, for: .didFinishRestoringWindows) { [weak self] _ in self?.scheduleUpdate() },
        ]
        let workspace = NSWorkspace.shared
        notePrevious(workspace.frontmostApplication)
        workspaceToken = workspace.notificationCenter.addObserver(of: workspace, for: .didActivateApplication) { [weak self] message in
            self?.notePrevious(message.application)
        }
        // The window opened at launch is already on screen.
        update()
    }

    private func notePrevious(_ app: NSRunningApplication?) {
        guard let app, app != .current, app.bundleIdentifier != Self.dockBundleIdentifier else { return }
        previousApp = app
    }

    private func tearDown() {
        pendingLeave?.cancel()
        tokens.forEach(NotificationCenter.default.removeObserver)
        tokens = []
        if let workspaceToken { NSWorkspace.shared.notificationCenter.removeObserver(workspaceToken) }
        workspaceToken = nil
        watched = [:]
    }

    // MARK: Windows

    /// Observes `window`'s visibility from now on. Returns whether it was new.
    @discardableResult
    private func watch(_ window: NSWindow) -> Bool {
        let id = ObjectIdentifier(window)
        guard watched[id]?.window !== window else { return false }
        let visibility = window.observe(\.isVisible, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scheduleUpdate() }
        }
        watched[id] = WatchedWindow(window: window, visibility: visibility)
        return true
    }

    /// A window being framed may be one that is about to open for the first time.
    private func watchNew(_ window: NSWindow) {
        if watch(window) { scheduleUpdate() }
    }

    /// Decides on the next turn of the main actor, once whatever is opening or closing a window has finished, and
    /// once for any number of changes until then.
    private func scheduleUpdate() {
        guard !updateScheduled else { return }
        updateScheduled = true
        Task { [weak self] in
            guard let self else { return }
            updateScheduled = false
            update()
        }
    }

    // MARK: Policy

    private func update() {
        watched = watched.filter { $0.value.window != nil }
        for window in NSApp.windows { watch(window) }
        // A hidden app's windows come back when it unhides; keep the icon to unhide it from.
        guard !NSApp.isHidden else { return }
        if Self.policy(for: NSApp.windows.map(WindowTraits.init)) == .regular {
            pendingLeave?.cancel()
            pendingLeave = nil
            if NSApp.activationPolicy() != .regular { enter() }
        } else if NSApp.activationPolicy() == .regular, pendingLeave == nil {
            pendingLeave = Task { [weak self] in
                try? await Task.sleep(for: Self.leaveDelay)
                guard !Task.isCancelled, let self else { return }
                pendingLeave = nil
                leave()
            }
        }
    }

    private func enter() {
        NSApp.setActivationPolicy(.regular)
        // A window that opened behind other apps leaves the focus where it is.
        if NSApp.isActive, !NSRunningApplication.current.ownsMenuBar { reclaimMenuBar() }
        // The Dock tile is new: give the switch a turn to bring it up before writing its icon and badge.
        Task { [icon] in
            guard NSApp.activationPolicy() == .regular else { return }
            icon.start()
        }
    }

    /// An app that turns regular while it is active leaves the menu bar to the app before it, and activating an
    /// app that is already active does nothing. Lends the activation to the Dock, which has no windows or menus
    /// to show, and takes it back as soon as Tidemark resigns.
    private func reclaimMenuBar() {
        guard let dock = NSRunningApplication.runningApplications(withBundleIdentifier: Self.dockBundleIdentifier).first else { return }
        NSApp.yieldActivation(to: dock)
        if dock.activate(from: .current, options: []) {
            reclaimDeadline = .now + .milliseconds(500)
        }
    }

    private func takeBackActivation() {
        guard let deadline = reclaimDeadline else { return }
        reclaimDeadline = nil
        if ContinuousClock.now < deadline { NSApp.activate() }
    }

    private func leave() {
        guard !NSApp.isHidden, Self.policy(for: NSApp.windows.map(WindowTraits.init)) == .accessory,
              NSApp.activationPolicy() == .regular else { return }
        // An active app that turns into an agent hands the focus to whichever app the system picks. Hand it to
        // the app that was in front before Tidemark instead, while Tidemark still has it to give.
        if NSApp.isActive, let previousApp, !previousApp.isTerminated {
            NSApp.yieldActivation(to: previousApp)
            previousApp.activate(from: .current, options: [])
        }
        NSApp.setActivationPolicy(.accessory)
        icon.stop()
    }
}

extension DockPresence.WindowTraits {
    @MainActor
    init(_ window: NSWindow) {
        self.init(isVisible: window.isVisible, isMiniaturized: window.isMiniaturized,
                  isTitled: window.styleMask.contains(.titled), isPanel: window is NSPanel,
                  isAttached: window.isSheet || window.parent != nil)
    }
}
