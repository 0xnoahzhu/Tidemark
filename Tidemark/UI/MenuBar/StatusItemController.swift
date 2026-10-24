import AppKit
import Observation
import SwiftUI

/// Owns Tidemark's menu bar item and its Liquid Glass panel.
///
/// The item uses the macOS 27 expanded-interface contract: the menu bar system starts a session when the
/// item is clicked (`statusItem(_:didBegin:)`) and ends it when the user clicks the item again, opens
/// another menu or navigates away (`statusItemDidEndExpandedInterfaceSession(_:animated:)`). The panel is
/// shown and hidden in those callbacks; anything else that should close it (an action inside it, a click in
/// another window, Escape) cancels the session, which then ends through the delegate.
@MainActor
final class StatusItemController: NSObject {
    private static var shared: StatusItemController?

    /// Creates the status item. Call once at launch, after `AppBootstrap.start`.
    static func install(model: AppModel) {
        guard shared == nil else { return }
        shared = StatusItemController(model: model)
    }

    /// Removes the status item.
    static func uninstall() {
        shared?.tearDown()
        shared = nil
    }

    private let model: AppModel
    private let statusItem: NSStatusItem
    private var panel: MenuBarPanelWindow?
    private var glassView: NSGlassEffectView?
    private var observation: ObservationTracking.Token?
    private var eventMonitors: [Any] = []
    /// Incremented on every show, so a stale fade-out never hides a panel that was shown again.
    private var presentation = 0
    /// Time of the last session begin / end, used to ignore the button action of the same click.
    private var lastSessionChange = Date.distantPast

    private init(model: AppModel) {
        self.model = model
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()
        statusItem.autosaveName = "io.tidemark.status-item"
        statusItem.expandedInterfaceDelegate = self
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(buttonAction(_:))
        }
        observation = withContinuousObservation(options: [.didSet]) { [weak self] _ in
            self?.refresh()
        }
    }

    private func tearDown() {
        observation = nil
        closePanel(animated: false)
        statusItem.expandedInterfaceDelegate = nil
        NSStatusBar.system.removeStatusItem(statusItem)
    }

    // MARK: Status item

    /// Reads the observed state (registering it with `withContinuousObservation`) and redraws the item.
    private func refresh() {
        let state = MenuBarGlyph.state(for: model)
        let label = MenuBarStatusText.accessibilityLabel(for: state, unread: model.alerts.unreadCount)
        applyGlass(model.preferences.glass)
        guard let button = statusItem.button else { return }
        button.image = MenuBarGlyph.image(for: state)
        button.toolTip = label
        button.setAccessibilityLabel(label)
    }

    /// Fallback for a click delivered as a plain button action rather than as an expanded-interface session.
    @objc private func buttonAction(_ sender: Any?) {
        let clickedAt = Date.now
        Task { @MainActor [weak self] in
            await Task.yield()
            guard let self else { return }
            // The same click already began or ended a system session.
            if statusItem.expandedInterfaceSession != nil || lastSessionChange > clickedAt.addingTimeInterval(-0.6) { return }
            if panel?.isVisible == true {
                closePanel(animated: true)
            } else {
                showPanel()
            }
        }
    }

    /// Closes the panel: cancels the session (the delegate then hides the panel) or hides it directly.
    func dismiss() {
        if let session = statusItem.expandedInterfaceSession {
            session.cancel()
        } else {
            closePanel(animated: true)
        }
    }

    // MARK: Panel

    private func makePanel() -> MenuBarPanelWindow {
        let root = MenuBarPanel(onDismiss: { [weak self] in self?.dismiss() })
            .fixedSize()
            .onGeometryChange(for: CGSize.self, of: { $0.size }) { [weak self] size in
                self?.contentSizeChanged(size)
            }
            .environment(model)
            .environment(Localizer.shared)
        let hosting = NSHostingView(rootView: root)
        hosting.sizingOptions = [.intrinsicContentSize]

        let glass = NSGlassEffectView()
        glass.cornerRadius = 18
        glass.effectIsInteractive = true
        glass.contentView = hosting
        glassView = glass
        applyGlass(model.preferences.glass)

        let panel = MenuBarPanelWindow(contentRect: NSRect(origin: .zero, size: hosting.fittingSize))
        panel.contentView = glass
        panel.onCancel = { [weak self] in self?.dismiss() }
        panel.delegate = self
        return panel
    }

    /// Settings › General › Liquid Glass: nearly clear glass at 0, a window-colored frost at 100.
    private func applyGlass(_ amount: Double) {
        guard let glassView else { return }
        let t = min(max(amount, 0), 100) / 100
        glassView.style = .regular
        glassView.tintColor = NSColor.windowBackgroundColor.withAlphaComponent(0.1 + 0.5 * t)
    }

    private func contentSizeChanged(_ size: CGSize) {
        guard let panel, size.width > 0, size.height > 0 else { return }
        let target = NSSize(width: size.width.rounded(.up), height: size.height.rounded(.up))
        guard panel.contentLayoutRect.size != target else { return }
        panel.setContentSize(target)
        if panel.isVisible { position(panel) }
    }

    private func showPanel() {
        let panel = panel ?? makePanel()
        self.panel = panel
        presentation += 1
        // Like a menu, the panel appears at once; it may already be up when a fallback action raced the session.
        if !panel.isVisible {
            if let hosting = glassView?.contentView {
                let size = hosting.fittingSize
                if size.width > 0, size.height > 0 { panel.setContentSize(size) }
            }
            position(panel)
        }
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        panel.makeKey()
        installEventMonitors()
    }

    private func closePanel(animated: Bool) {
        removeEventMonitors()
        guard let panel, panel.isVisible else { return }
        guard animated else {
            panel.orderOut(nil)
            return
        }
        // Fade out like a menu. The window is ordered out on a timer rather than in the animation's
        // completion handler, so it never lingers when the animation is skipped.
        let closing = presentation
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            panel.animator().alphaValue = 0
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(170))
            guard let self, presentation == closing else { return }
            panel.orderOut(nil)
            panel.alphaValue = 1
        }
    }

    /// Places the panel under the status item, left-aligned with it and kept on screen.
    private func position(_ panel: NSWindow) {
        guard let buttonWindow = statusItem.button?.window else { return }
        let anchor = buttonWindow.frame
        let visible = (buttonWindow.screen ?? NSScreen.main)?.visibleFrame ?? anchor
        let width = panel.frame.width
        var x = min(anchor.minX, visible.maxX - width - 8)
        x = max(x, visible.minX + 8)
        let top = min(anchor.minY, visible.maxY) - 6
        panel.setFrameTopLeftPoint(NSPoint(x: x.rounded(), y: top.rounded()))
    }

    // MARK: Outside clicks

    private func installEventMonitors() {
        removeEventMonitors()
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        // Clicks in Tidemark's other windows. Clicks on the status item itself end the session through the system.
        if let local = NSEvent.addLocalMonitorForEvents(matching: mask, handler: { [weak self] event in
            MainActor.assumeIsolated {
                guard let self, let window = event.window else { return }
                if window !== self.panel, window !== self.statusItem.button?.window { self.dismiss() }
            }
            return event
        }) {
            eventMonitors.append(local)
        }
        // Clicks in other apps.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: mask, handler: { [weak self] _ in
            MainActor.assumeIsolated { self?.dismiss() }
        }) {
            eventMonitors.append(global)
        }
    }

    private func removeEventMonitors() {
        for monitor in eventMonitors { NSEvent.removeMonitor(monitor) }
        eventMonitors.removeAll()
    }
}

// MARK: - Expanded interface

extension StatusItemController: @MainActor NSStatusItemExpandedInterfaceDelegate {
    func statusItem(_ statusItem: NSStatusItem, didBegin expandedInterfaceSession: NSStatusItemExpandedInterfaceSession) {
        lastSessionChange = .now
        showPanel()
    }

    func statusItemDidEndExpandedInterfaceSession(_ statusItem: NSStatusItem, animated: Bool) {
        lastSessionChange = .now
        closePanel(animated: animated)
    }
}

extension StatusItemController: @MainActor NSWindowDelegate {
    /// Keeps the panel's top edge under the menu bar when its content grows or shrinks.
    func windowDidResize(_ notification: Notification) {
        guard let panel, panel.isVisible else { return }
        position(panel)
    }

    /// Another app or window took key status: the user moved on.
    func windowDidResignKey(_ notification: Notification) {
        guard panel?.isVisible == true else { return }
        dismiss()
    }
}

/// Borderless, non-activating panel that hosts the glass content. It can become key (for the switch,
/// buttons and Escape) without activating Tidemark, like a menu.
final class MenuBarPanelWindow: NSPanel {
    var onCancel: (@MainActor () -> Void)?

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        isFloatingPanel = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        becomesKeyOnlyIfNeeded = false
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
