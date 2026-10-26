import AppKit
import SwiftUI

/// Gives the request table's header the design's height, 28 px like its rows.
///
/// AppKit keeps a table header 28 pt tall whatever the size of the labels SwiftUI puts in it, so at a larger UI
/// scale the header would crowd its labels and look shorter than the rows. `Table` has no API for the header, so
/// this invisible view sits in the first row's cell, finds its table and sets the header's height. It does so after
/// the update that added the cell, never from inside the table's own row loading. Where the design's height is
/// AppKit's own (at a factor of 1.0) the table goes without it.
struct RequestsTableHeaderHeight: NSViewRepresentable {
    /// Whether the header needs a height other than the one AppKit gives it.
    static let isNeeded = RequestsTable.headerHeight != NSTableHeaderView().frame.height

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
        guard window != nil, let table = enclosingTable, Self.needsHeight(table) else { return }
        Task { @MainActor [weak table] in
            if let table { Self.setHeight(of: table) }
        }
    }

    private var enclosingTable: NSTableView? {
        var view = superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        return view as? NSTableView
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
