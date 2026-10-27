import AppKit
import SwiftUI

/// Keeps the request table's place while the inspector opens.
///
/// As the inspector opens, SwiftUI lays the page out a few times at no height at all. AppKit's table, seeing none of
/// itself then, scrolls its rows back to the top, so the selected row and the reader's place would be gone once the
/// inspector is in. `Table` has no API for its scroll position, so this invisible view sits in the first row's cell,
/// finds its table and has a `RequestsTablePlaceKeeper` watch it. It also hands the table to its `RequestsTable`'s
/// `handle`, which scrolls a row into view.
struct RequestsTablePlace: NSViewRepresentable {
    var handle: RequestsTableHandle?

    func makeNSView(context: Context) -> RequestsTablePlaceAnchor {
        let anchor = RequestsTablePlaceAnchor()
        anchor.handle = handle
        return anchor
    }

    func updateNSView(_ anchor: RequestsTablePlaceAnchor, context: Context) {
        anchor.handle = handle
    }
}

/// The invisible marker inside a cell.
final class RequestsTablePlaceAnchor: NSView {
    weak var handle: RequestsTableHandle? {
        didSet { if let table { handle?.table = table } }
    }
    private weak var table: NSTableView?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil else { return }
        var view = superview
        while let current = view, !(current is NSTableView) { view = current.superview }
        guard let table = view as? NSTableView else { return }
        self.table = table
        RequestsTablePlaceKeeper.watch(table)
        handle?.table = table
    }
}

/// Puts a table's rows back where they were after a layout at no height scrolled them.
///
/// Its clip view tells each scroll: while the table shows some of itself, the scroll is remembered; one made while it
/// shows none is AppKit's, and the rows go back to the remembered place once the table shows again.
@MainActor
final class RequestsTablePlaceKeeper: NSObject {
    /// Associates a keeper with its clip view, which keeps it for as long as it lives.
    private static var keeperKey: UInt8 = 0

    private weak var table: NSTableView?
    private weak var clip: NSClipView?
    /// The rows' place (the clip view's vertical origin) when the table last showed.
    private var kept: CGFloat?
    /// The place to go back to once the table shows again.
    private var pending: CGFloat?

    /// Watches `table` from now on; a table already watched keeps its keeper.
    static func watch(_ table: NSTableView) {
        guard let clip = table.enclosingScrollView?.contentView, keeper(of: clip) == nil else { return }
        objc_setAssociatedObject(clip, &keeperKey, RequestsTablePlaceKeeper(table: table, clip: clip), .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
    }

    static func keeper(of clip: NSClipView) -> RequestsTablePlaceKeeper? {
        objc_getAssociatedObject(clip, &keeperKey) as? RequestsTablePlaceKeeper
    }

    init(table: NSTableView, clip: NSClipView) {
        self.table = table
        self.clip = clip
        super.init()
        clip.postsBoundsChangedNotifications = true
        clip.postsFrameChangedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(clipChanged), name: NSView.boundsDidChangeNotification, object: clip)
        center.addObserver(self, selector: #selector(clipChanged), name: NSView.frameDidChangeNotification, object: clip)
        if !table.visibleRect.isEmpty { kept = clip.bounds.origin.y }
    }

    @objc private func clipChanged() {
        guard let table, let clip else { return }
        let y = clip.bounds.origin.y
        if table.visibleRect.isEmpty {
            // Laid out at no height: a scroll now is AppKit's, not the reader's.
            if pending == nil, let kept, kept != y {
                pending = kept
                // A layout that shows the table again usually resizes the clip view, which restores the place;
                // otherwise the next turn of the run loop does.
                Task { @MainActor [weak self] in self?.restore() }
            }
        } else if pending != nil {
            restore()
        } else {
            kept = y
        }
    }

    /// Scrolls back to the pending place once the table shows again.
    private func restore() {
        guard let place = pending, let table, let clip, !table.visibleRect.isEmpty else { return }
        pending = nil
        if clip.bounds.origin.y != place {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: place))
            clip.enclosingScrollView?.reflectScrolledClipView(clip)
        }
        kept = clip.bounds.origin.y
    }
}
