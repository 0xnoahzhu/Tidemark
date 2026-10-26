import AppKit
import SwiftUI

extension View {
    /// Lets the toolbar item this view is in get narrower than the view's ideal width, down to its minimum width,
    /// before the toolbar drops the spaces between items or moves items to the overflow menu, as the system's title
    /// does. The view shortens its text where it is offered less than its ideal width.
    func toolbarItemCompressible() -> some View {
        background(ToolbarItemCompression())
    }
}

/// The toolbar narrows an item no further than its view's fitting size, which a view that resists compression at
/// the default priority keeps at its ideal width: the view SwiftUI hosts an item's content in does, so the toolbar
/// would drop the spaces and the items after it before it shortened its content. This invisible view finds the
/// toolbar item it is in and lowers the horizontal compression resistance of that item's view below the fitting
/// size's, so the item fits down to the content's own minimum.
private struct ToolbarItemCompression: NSViewRepresentable {
    func makeNSView(context: Context) -> ToolbarItemCompressionAnchor {
        ToolbarItemCompressionAnchor()
    }

    func updateNSView(_ anchor: ToolbarItemCompressionAnchor, context: Context) {}
}

/// The invisible marker inside a toolbar item's content.
final class ToolbarItemCompressionAnchor: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let items = window?.toolbar?.items,
              let itemView = items.lazy.compactMap(\.view).first(where: { self.isDescendant(of: $0) }) else { return }
        Self.makeCompressible(itemView)
    }

    /// Lets the toolbar narrow `itemView` to its fitting size, and has it measure the item again.
    static func makeCompressible(_ itemView: NSView) {
        let priority = NSLayoutConstraint.Priority(NSLayoutConstraint.Priority.fittingSizeCompression.rawValue - 1)
        guard itemView.contentCompressionResistancePriority(for: .horizontal) != priority else { return }
        itemView.setContentCompressionResistancePriority(priority, for: .horizontal)
        itemView.invalidateIntrinsicContentSize()
    }
}
