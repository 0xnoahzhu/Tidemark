import AppKit
import QuartzCore
import SwiftUI
import Testing
@testable import Tidemark

/// The pulsing status dot runs its pulse in Core Animation, on its own layer, rather than as a SwiftUI animation,
/// which would update the page around it on the main thread every frame for as long as it is shown.
@MainActor
struct StatusDotTests {
    @Test func pulsesInCoreAnimation() throws {
        let (window, host) = Self.host(StatusDot(color: Theme.recording, size: 8, pulsing: true))
        defer { window.close() }
        let dot = try #require(Self.pulseView(in: host))
        #expect(dot.frame.size == CGSize(width: 8, height: 8))
        let pulse = try #require(dot.layer?.animation(forKey: StatusDotPulseView.animationKey) as? CABasicAnimation)
        #expect(pulse.keyPath == "opacity")
        #expect(pulse.fromValue as? Double == 1)
        #expect(pulse.toValue as? Double == 0.3)
        #expect(pulse.duration == 0.7)
        #expect(pulse.autoreverses)
        #expect(pulse.repeatCount == .infinity)
        #expect(pulse.timingFunction == CAMediaTimingFunction(name: .easeInEaseOut))
    }

    /// A still dot (Reduce Motion, reduced resource usage, or a status that does not pulse) stays a plain shape.
    @Test func stillDotDoesNotAnimate() {
        let (window, host) = Self.host(StatusDot(color: Theme.live, size: 6))
        defer { window.close() }
        #expect(Self.pulseView(in: host) == nil)
    }

    private static func host(_ dot: StatusDot) -> (NSWindow, NSView) {
        let host = NSHostingView(rootView: dot.padding(10))
        // Never ordered in: the dot is laid out off screen.
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        return (window, host)
    }

    private static func pulseView(in view: NSView) -> StatusDotPulseView? {
        if let dot = view as? StatusDotPulseView { return dot }
        return view.subviews.lazy.compactMap { pulseView(in: $0) }.first
    }
}
