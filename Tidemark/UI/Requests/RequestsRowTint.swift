import AppKit
import SwiftUI

/// Paints the prototype's "fresh" tint behind a whole live-table row as one band, then fades it out (0.9 s).
///
/// SwiftUI's `Table` has no row background API, and tinting each cell leaves seams in the column gaps. This
/// invisible view sits in the row's first cell, finds the hosting `NSTableRowView` and keeps one
/// `RequestsRowBand` there, below the cells and above the system's zebra stripe. Row views are reused for
/// other requests, so the band is looked up on every update and only fades out when the same request ages.
struct RequestsRowTint: NSViewRepresentable {
    var key: RequestKey
    var isFresh: Bool
    /// Selected rows show the system selection; their band disappears at once instead of fading.
    var isSelected: Bool

    func makeNSView(context: Context) -> RequestsRowTintAnchor {
        RequestsRowTintAnchor()
    }

    func updateNSView(_ anchor: RequestsRowTintAnchor, context: Context) {
        anchor.apply(key: key, isFresh: isFresh && !isSelected, animated: !isSelected)
    }
}

/// The invisible marker inside the first cell of a row.
final class RequestsRowTintAnchor: NSView {
    private var key: RequestKey?
    private var isFresh = false

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func apply(key: RequestKey, isFresh: Bool, animated: Bool) {
        self.key = key
        self.isFresh = isFresh
        band()?.show(isFresh, for: key, animated: animated)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let key else { return }
        band()?.show(isFresh, for: key, animated: false)
    }

    /// The band of the enclosing row view, created on first use.
    private func band() -> RequestsRowBand? {
        var cell: NSView = self
        while let parent = cell.superview, !(parent is NSTableRowView) { cell = parent }
        guard let row = cell.superview as? NSTableRowView else { return nil }
        if let band = row.subviews.lazy.compactMap({ $0 as? RequestsRowBand }).first { return band }
        let band = RequestsRowBand(rowBounds: row.bounds)
        // Below every cell, but above the row's own zebra and separator drawing.
        let lowestCell = row.subviews.first { $0 is NSTableCellView } ?? cell
        row.addSubview(band, positioned: .below, relativeTo: lowestCell)
        return band
    }
}

/// The tinted band, shaped like the system's zebra stripes and selection in an inset-style table.
final class RequestsRowBand: NSView {
    /// Measured on macOS 27: inset-style rows draw their background 10 pt in from each side with
    /// continuous 8 pt corners.
    static let horizontalInset: CGFloat = 10
    static let cornerRadius: CGFloat = 8

    private(set) var key: RequestKey?

    init(rowBounds: NSRect) {
        super.init(frame: rowBounds.insetBy(dx: Self.horizontalInset, dy: 0))
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.cornerRadius = Self.cornerRadius
        layer?.cornerCurve = .continuous
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor(Theme.fresh).cgColor
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Shows or hides the tint for `key`. Only the request that owned the band fades out; a row reused for
    /// another request (or a selected one) switches at once.
    func show(_ tinted: Bool, for key: RequestKey, animated: Bool) {
        let target: CGFloat = tinted ? 1 : 0
        let sameRequest = key == self.key
        self.key = key
        let fades = animated && sameRequest && !tinted && alphaValue > 0
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if fades {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.9
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                animator().alphaValue = target
            }
        } else if !sameRequest || alphaValue != target {
            layer?.removeAllAnimations()
            alphaValue = target
        }
    }
}
