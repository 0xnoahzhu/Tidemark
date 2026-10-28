import AppKit
import SwiftUI

/// Gives the request table's header the design's height, 28 px like its rows, and a solid background.
///
/// AppKit keeps a table header 28 pt tall whatever the size of the labels SwiftUI puts in it, so at a larger UI
/// scale the header would crowd its labels and look shorter than the rows. It also draws the header see-through, so
/// rows scrolling under it showed through; its clip view draws the list's background beneath it instead, as the
/// Domains & IPs header has. `Table` has no API for the header, so this invisible view sits in the first row's cell,
/// finds its table and sets both, after the update that added the cell, never from inside the table's own row
/// loading.
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

    /// Has the header's clip view draw the list's background beneath the header.
    static func fillBackground(of table: NSTableView) {
        guard let clip = headerClip(of: table) else { return }
        clip.backgroundColor = .controlBackgroundColor
        clip.drawsBackground = true
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
