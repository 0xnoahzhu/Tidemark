import AppKit
import SwiftUI

/// A search field for a `ToolbarItem`, for pages whose design puts the field between other toolbar items.
///
/// `searchable` always adds the window's search field after every other item on macOS 27, even with a
/// `DefaultToolbarItem(kind: .search)` in between. This is an `NSSearchField` without its own bezel, so it sits
/// on the toolbar item's glass like the system field and keeps its clear button, Escape to clear, the keyboard
/// focus ring and the search field role for VoiceOver. ⌘F focuses it while its window is key. Its toolbar item
/// should outlast the page's other items when the window narrows (`visibilityPriority`): a custom view has no
/// usable form in the toolbar's overflow menu.
struct ToolbarSearchField: NSViewRepresentable {
    @Binding var text: String
    var prompt: String

    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.isBezeled = false
        field.isBordered = false
        field.drawsBackground = false
        field.sendsSearchStringImmediately = true
        field.target = context.coordinator
        field.action = #selector(Coordinator.searchChanged(_:))
        field.setContentHuggingPriority(.defaultLow, for: .horizontal)
        context.coordinator.installFindShortcut(for: field)
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.text = $text
        if field.stringValue != text { field.stringValue = text }
        if field.placeholderString != prompt {
            field.placeholderString = prompt
            field.setAccessibilityLabel(prompt)
        }
    }

    static func dismantleNSView(_ field: NSSearchField, coordinator: Coordinator) {
        coordinator.removeFindShortcut()
    }

    /// ⌘F with no other modifier (Caps Lock aside).
    static func isFindShortcut(_ event: NSEvent) -> Bool {
        event.type == .keyDown
            && event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock) == .command
            && event.charactersIgnoringModifiers?.lowercased() == "f"
    }

    @MainActor
    final class Coordinator: NSObject {
        var text: Binding<String>
        private var findMonitor: Any?

        init(text: Binding<String>) {
            self.text = text
        }

        /// Sent on every edit and when the clear button or Escape empties the field.
        @objc func searchChanged(_ sender: NSSearchField) {
            if text.wrappedValue != sender.stringValue { text.wrappedValue = sender.stringValue }
        }

        /// ⌘F in the field's window focuses the field (and selects its text), as it does for the system
        /// search field. The window has no Find menu item that could handle it instead.
        func installFindShortcut(for field: NSSearchField) {
            removeFindShortcut()
            findMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak field] event in
                let handled = MainActor.assumeIsolated {
                    guard ToolbarSearchField.isFindShortcut(event), let field, let window = field.window,
                          event.window === window else { return false }
                    return window.makeFirstResponder(field)
                }
                return handled ? nil : event
            }
        }

        func removeFindShortcut() {
            if let findMonitor { NSEvent.removeMonitor(findMonitor) }
            findMonitor = nil
        }
    }
}
