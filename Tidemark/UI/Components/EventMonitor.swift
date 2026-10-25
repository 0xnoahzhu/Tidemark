import AppKit
import SwiftUI

/// Hands AppKit events to SwiftUI while this view is in a window, for overlays that act like menus and dialogs.
///
/// `onKeyDown` sees the key presses of this view's window before any keyboard shortcut does and returns whether
/// it consumed one. `onMouseDown` learns of every mouse-down, in Tidemark's windows or another app, and whether
/// it landed inside this view's frame; clicks always go on to their target. The view never takes a click itself.
struct EventMonitor: NSViewRepresentable {
    var onKeyDown: (@MainActor (NSEvent) -> Bool)?
    var onMouseDown: (@MainActor (_ inside: Bool) -> Void)?

    init(onKeyDown: (@MainActor (NSEvent) -> Bool)? = nil, onMouseDown: (@MainActor (_ inside: Bool) -> Void)? = nil) {
        self.onKeyDown = onKeyDown
        self.onMouseDown = onMouseDown
    }

    func makeNSView(context: Context) -> MonitorView { MonitorView() }

    func updateNSView(_ view: MonitorView, context: Context) {
        view.onKeyDown = onKeyDown
        view.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ view: MonitorView, coordinator: ()) {
        view.stopMonitoring()
    }

    /// Escape and Return, as `NSEvent.keyCode` reports them.
    static let escapeKey: UInt16 = 53
    static let returnKeys: Set<UInt16> = [36, 76]

    final class MonitorView: NSView {
        var onKeyDown: (@MainActor (NSEvent) -> Bool)?
        var onMouseDown: (@MainActor (_ inside: Bool) -> Void)?
        private var monitors: [Any] = []

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stopMonitoring()
            guard window != nil else { return }
            let clicks: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
            if let local = NSEvent.addLocalMonitorForEvents(matching: clicks.union(.keyDown), handler: { [weak self] event in
                let consumed = MainActor.assumeIsolated { self?.handle(event) ?? false }
                return consumed ? nil : event
            }) {
                monitors.append(local)
            }
            if let global = NSEvent.addGlobalMonitorForEvents(matching: clicks, handler: { [weak self] _ in
                MainActor.assumeIsolated { self?.onMouseDown?(false) }
            }) {
                monitors.append(global)
            }
        }

        func stopMonitoring() {
            for monitor in monitors { NSEvent.removeMonitor(monitor) }
            monitors.removeAll()
        }

        private func handle(_ event: NSEvent) -> Bool {
            if event.type == .keyDown {
                guard event.window === window, let onKeyDown else { return false }
                return onKeyDown(event)
            }
            let inside = event.window === window && bounds.contains(convert(event.locationInWindow, from: nil))
            onMouseDown?(inside)
            return false
        }
    }
}
