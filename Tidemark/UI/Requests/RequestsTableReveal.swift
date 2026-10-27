import AppKit
import SwiftUI

/// A row a `RequestsTable` is to scroll into view and light up once: History showing the request an alert is about. Each
/// value is a new ask, even for the same request.
struct RequestsTableReveal: Equatable {
    var key: RequestKey
    let id = UUID()
}

/// The AppKit table behind a `RequestsTable`, handed over by its first row's cell (`RequestsTablePlace`), for what
/// `Table` has no API for: scrolling a row into view.
@MainActor
final class RequestsTableHandle {
    weak var table: NSTableView?

    /// How often the row's place is checked while the page settles.
    static let tick: Duration = .milliseconds(50)
    /// Checks that find the table's frame unchanged before the row lights up.
    static let settledTicks = 4
    /// Checks in all: the inspector the selection opens takes about half a second to settle into its column, and the
    /// filters above the table can wrap onto another line after that.
    static let ticks = 40

    /// Scrolls `row` into the middle of the table and makes the table first responder, so its selection is drawn in the
    /// accent color and the arrow keys move on from it; the row lights up once it has settled, unless Reduce Motion is on.
    ///
    /// The selection has just opened the inspector, whose column resizes the table and lays the page out at no height
    /// on the way (`RequestsTablePlaceKeeper`), and the rows that come into view take their measured height, which moves
    /// the rows below them. So for two seconds the row is placed again whenever the table's frame or the row's place in
    /// it has changed (or the table shows nothing). A scroll of the reader's own meanwhile stands.
    func reveal(row: Int) async {
        var placed: (frame: NSRect, row: NSRect)?
        var steady = 0
        for _ in 0..<Self.ticks {
            try? await Task.sleep(for: Self.tick)
            guard !Task.isCancelled, let table, row < table.numberOfRows, let clip = table.enclosingScrollView?.contentView else { return }
            if let window = table.window, window.firstResponder !== table, steady < Self.settledTicks { window.makeFirstResponder(table) }
            if placed?.frame != clip.frame || placed?.row != table.rect(ofRow: row) || table.visibleRect.isEmpty {
                Self.center(row: row, in: table)
                placed = (clip.frame, table.rect(ofRow: row))
                if steady < Self.settledTicks { steady = 0 }
            } else if steady < Self.settledTicks {
                steady += 1
                if steady == Self.settledTicks, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
                    RequestsRowFlash.flash(row: row, in: table)
                }
            }
        }
    }

    /// Scrolls `table` so that `row` sits in the middle of the rows it shows, below the header, as near as the table's
    /// ends allow.
    static func center(row: Int, in table: NSTableView) {
        guard let scroll = table.enclosingScrollView else { return }
        let clip = scroll.contentView
        let rect = clip.documentView.map { table.convert(table.rect(ofRow: row), to: $0) } ?? table.rect(ofRow: row)
        let insets = clip.contentInsets
        let shown = clip.bounds.height - insets.top - insets.bottom
        var proposed = clip.bounds
        proposed.origin.y = rect.midY - insets.top - shown / 2
        let origin = clip.constrainBoundsRect(proposed).origin
        guard origin != clip.bounds.origin else { return }
        clip.scroll(to: origin)
        scroll.reflectScrolledClipView(clip)
    }
}

/// Lights a row up and fades back to how it was drawn: a band shaped like the row's selection, below its cells and above
/// the selection itself.
final class RequestsRowFlash: NSView {
    /// Fades in this fast, holds, then fades out.
    static let fadeIn: Duration = .milliseconds(150)
    static let hold: Duration = .milliseconds(350)
    static let fadeOut: Duration = .milliseconds(900)

    static func flash(row: Int, in table: NSTableView) {
        guard let rowView = table.rowView(atRow: row, makeIfNecessary: false) else { return }
        for old in rowView.subviews where old is RequestsRowFlash { old.removeFromSuperview() }
        let flash = RequestsRowFlash(frame: rowView.bounds.insetBy(dx: RequestsRowBand.horizontalInset, dy: 0))
        let lowestCell = rowView.subviews.first { $0 is NSTableCellView }
        rowView.addSubview(flash, positioned: .below, relativeTo: lowestCell)
        Task { @MainActor in
            animate(flash, to: 1, over: fadeIn)
            try? await Task.sleep(for: fadeIn + hold)
            animate(flash, to: 0, over: fadeOut)
            try? await Task.sleep(for: fadeOut)
            flash.removeFromSuperview()
        }
    }

    private static func animate(_ flash: RequestsRowFlash, to alpha: CGFloat, over duration: Duration) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration / .seconds(1)
            context.timingFunction = CAMediaTimingFunction(name: alpha > 0 ? .easeIn : .easeOut)
            flash.animator().alphaValue = alpha
        }
    }

    override init(frame: NSRect) {
        super.init(frame: frame)
        autoresizingMask = [.width, .height]
        wantsLayer = true
        layer?.cornerRadius = RequestsRowBand.cornerRadius
        layer?.cornerCurve = .continuous
        alphaValue = 0
    }

    required init?(coder: NSCoder) { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        layer?.backgroundColor = NSColor.white.withAlphaComponent(dark ? 0.3 : 0.45).cgColor
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
