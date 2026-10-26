import SwiftUI

/// Search field inside a page's sub-header, drawn like the design's: a magnifier and the text on the
/// fill, 28 px high. Escape clears it.
struct FilterField: View {
    var prompt: String
    @Binding var text: String
    /// The field's width in design px.
    var width: CGFloat
    /// The narrowest the field gets in a row short of room, in design px; nil to keep `width`.
    var minWidth: CGFloat? = nil

    var body: some View {
        let field = HStack(spacing: 6.px) {
            Image(systemName: "magnifyingglass")
                .font(.design(10.5, .semibold))
                .foregroundStyle(Theme.ink3)
            TextField(prompt, text: $text, prompt: Text(prompt))
                .autocorrectionDisabled()
                .onExitCommand { text = "" }
        }
        if let minWidth {
            field.designField().frame(minWidth: minWidth.px, idealWidth: width.px, maxWidth: width.px)
        } else {
            field.designField(width: width)
        }
    }
}
