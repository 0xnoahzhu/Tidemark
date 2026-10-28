import AppKit
import SwiftUI

/// Gives the request table's header the design's height, 28 px like its rows, and a solid background.
///
/// AppKit keeps a table header 28 pt tall whatever the size of the labels SwiftUI puts in it, so at a larger UI
/// scale the header would crowd its labels and look shorter than the rows. It also draws the header see-through, so
/// rows scrolling under it showed through; its clip view draws the page's background beneath it instead, as the
/// Domains & IPs header has, and so do the table and its scroll view in place of the window's. `Table` has no API
/// for the header, so this invisible view sits in the first row's cell, finds its table and sets both, after the
/// update that added the cell, never from inside the table's own row loading.
struct RequestsTableHeaderStyle: NSViewRepresentable {
    func makeNSView(context: Context) -> RequestsTableHeaderAnchor {
        RequestsTableHeaderAnchor()
    }

    func updateNSView(_ anchor: RequestsTableHeaderAnchor, context: Context) {}
}

/// The invisible marker inside a cell.
final class RequestsTableHeaderAnchor: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, let table = enclosingTable else { return }
        // While the first rows load, the header may not be in its clip view yet, so the background is set again with
        // the height, once the update is done.
        Self.fillBackground(of: table)
        Task { @MainActor [weak table] in
            guard let table else { return }
            Self.fillBackground(of: table)
            Self.setHeight(of: table)
            // Not from inside the table's row loading either: the table would load no rows.
            if let scroll = table.enclosingScrollView, let corner = table.cornerView { RequestsTableCornerFill.cover(corner, in: scroll) }
        }
    }

    private var enclosingTable: NSTableView? {
        var view = superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        return view as? NSTableView
    }

    /// The clip view that holds the header, which the scroll view lays out above the rows.
    static func headerClip(of table: NSTableView) -> NSClipView? {
        table.headerView?.superview as? NSClipView
    }

    /// Has the table, its scroll view (beneath the scrollers) and the header's clip view draw the page's background.
    static func fillBackground(of table: NSTableView) {
        table.backgroundColor = Theme.pageBackground
        if let scroll = table.enclosingScrollView {
            scroll.backgroundColor = Theme.pageBackground
            scroll.drawsBackground = true
        }
        if let clip = headerClip(of: table) {
            clip.backgroundColor = Theme.pageBackground
            clip.drawsBackground = true
        }
    }

    static func needsHeight(_ table: NSTableView) -> Bool {
        guard let header = table.headerView else { return false }
        return header.frame.height != RequestsTable.headerHeight
    }

    /// Sets the header's height and lets the scroll view lay out its header and rows again.
    static func setHeight(of table: NSTableView) {
        guard needsHeight(table), let header = table.headerView else { return }
        header.frame.size.height = RequestsTable.headerHeight
        table.enclosingScrollView?.tile()
    }
}

/// Covers the header's corner above an always-visible vertical scroller with the header's background and bottom line,
/// where AppKit draws the toolbar's tinted material and no line. It sits on top of the scroll view's own views and
/// follows the corner as the scroll view lays it out. A layer rather than `draw(_:)`, which would keep the scroll view
/// from drawing its rows.
final class RequestsTableCornerFill: NSView {
    /// The header's bottom line as AppKit draws it (and the Domains & IPs header copies, `InventoryTableMetrics`), 1.25 pt
    /// tall and its bottom a quarter point below the header's.
    static let lineColor = NSColor.dynamic(light: .black(0.1), dark: .white(0.115))

    private weak var corner: NSView?
    private let line = CALayer()

    /// Covers `corner` in `scroll`, once.
    static func cover(_ corner: NSView, in scroll: NSScrollView) {
        guard !scroll.subviews.contains(where: { $0 is RequestsTableCornerFill }) else { return }
        let fill = RequestsTableCornerFill(frame: corner.frame)
        fill.wantsLayer = true
        fill.corner = corner
        scroll.addSubview(fill, positioned: .above, relativeTo: nil)
        corner.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(fill, selector: #selector(follow), name: NSView.frameDidChangeNotification, object: corner)
        fill.follow()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    @objc private func follow() {
        guard let corner else { return removeFromSuperview() }
        frame = corner.frame
        isHidden = corner.isHidden
        needsLayout = true
    }

    override var wantsUpdateLayer: Bool { true }

    /// Also called when the appearance changes.
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = Theme.pageBackground.cgColor
            line.backgroundColor = Self.lineColor.cgColor
        }
        if line.superlayer == nil { layer?.addSublayer(line) }
    }

    override func layout() {
        super.layout()
        line.frame = CGRect(x: 0, y: -0.25, width: bounds.width, height: 1.25)
    }
}
