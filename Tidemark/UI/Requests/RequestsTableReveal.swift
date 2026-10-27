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

    /// How often the page's layout is checked while it settles.
    static let tick: Duration = .milliseconds(20)
    /// Checks in a row, a tenth of a second, that find the table's frame and the row's place unchanged before the row is
    /// scrolled into view, and again before it lights up: at the end of its slide the inspector holds still for a few
    /// frames before the page takes its final layout.
    static let settledTicks = 5
    /// Checks in all, two and a half seconds: the inspector slides in for about half a second.
    static let ticks = 125

    /// The table's frame and the row's place in it, as one check finds them.
    private struct Layout: Equatable {
        var frame: NSRect
        var row: NSRect
    }

    /// Set by a scroll or click of the reader's over the table, or a key pressed in it, while a row is revealed.
    private var readerActed = false

    /// Scrolls `row` into the middle of the table once the page has settled and makes the table first responder, so its
    /// selection is drawn in the accent color and the arrow keys move on from it; the row lights up once it has been
    /// still for a moment, unless Reduce Motion is on.
    ///
    /// The selection may just have opened the inspector, whose column slides in, resizing the table in every frame, lays
    /// the page out at no height on the way (`RequestsTablePlaceKeeper`) and narrows the filters above the table onto a
    /// second line at the end. So the row is scrolled once the table's frame and the row's place in it have stopped
    /// changing, and only again should a later change of the layout take it out of the rows shown. A scroll or click of
    /// the reader's over the table, or a key pressed in it, ends it, so their own place stands.
    func reveal(row: Int) async {
        readerActed = false
        let actions: NSEvent.EventTypeMask = [.scrollWheel, .leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
        let monitor = NSEvent.addLocalMonitorForEvents(matching: actions) { [weak self] event in
            MainActor.assumeIsolated { self?.note(event) }
            return event
        }
        defer { if let monitor { NSEvent.removeMonitor(monitor) } }
        var last: Layout?
        var steady = 0
        var placed = false
        var lit = false
        for _ in 0..<Self.ticks {
            try? await Task.sleep(for: Self.tick)
            guard !Task.isCancelled, !readerActed, let table, row < table.numberOfRows, let clip = table.enclosingScrollView?.contentView else { return }
            if let window = table.window, window.firstResponder !== table, !lit { window.makeFirstResponder(table) }
            let now = Layout(frame: clip.frame, row: table.rect(ofRow: row))
            steady = table.visibleRect.isEmpty || now != last ? 0 : steady + 1
            last = now
            if !placed || !Self.shows(row: row, in: table) {
                guard steady >= Self.settledTicks else { continue }
                Self.place(row: row, in: table)
                placed = true
                steady = 0
                last = Layout(frame: clip.frame, row: table.rect(ofRow: row))
            } else if steady >= Self.settledTicks, !lit {
                lit = true
                if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { RequestsRowFlash.flash(row: row, in: table) }
            }
        }
    }

    /// Notes whether `event` is the reader's doing in the table: a scroll or click over it, or a key pressed while it has
    /// the focus.
    private func note(_ event: NSEvent) {
        guard let table, let scroll = table.enclosingScrollView, let window = event.window, window === table.window else { return }
        if event.type == .keyDown {
            if window.firstResponder === table { readerActed = true }
        } else if scroll.bounds.contains(scroll.convert(event.locationInWindow, from: nil)) {
            readerActed = true
        }
    }

    /// Centers `row` (`center`), then again for as long as the rows that came into view move it as they take their measured
    /// height, all before the table is drawn: rows the table has not shown yet count at its default height until then.
    static func place(row: Int, in table: NSTableView) {
        for _ in 0..<4 {
            let before = table.rect(ofRow: row)
            center(row: row, in: table)
            table.enclosingScrollView?.layoutSubtreeIfNeeded()
            if table.rect(ofRow: row) == before { return }
        }
    }

    /// Whether all of `row` is among the rows `table` shows, below its header.
    static func shows(row: Int, in table: NSTableView) -> Bool {
        guard let clip = table.enclosingScrollView?.contentView else { return false }
        var shown = clip.bounds
        shown.origin.y += clip.contentInsets.top
        shown.size.height -= clip.contentInsets.top + clip.contentInsets.bottom
        let rect = clip.documentView.map { table.convert(table.rect(ofRow: row), to: $0) } ?? table.rect(ofRow: row)
        return shown.contains(rect)
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
