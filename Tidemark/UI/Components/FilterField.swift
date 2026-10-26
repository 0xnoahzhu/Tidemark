import SwiftUI

/// Search field inside a page's sub-header, drawn like the design's: a magnifier and the text on the
/// fill, 28 px high. Escape clears it.
struct FilterField: View {
    var prompt: String
    @Binding var text: String
    /// The field's width in design px.
    var width: CGFloat

    var body: some View {
        HStack(spacing: 6.px) {
            Image(systemName: "magnifyingglass")
                .font(.design(10.5, .semibold))
                .foregroundStyle(Theme.ink3)
            TextField(prompt, text: $text, prompt: Text(prompt))
                .autocorrectionDisabled()
                .onExitCommand { text = "" }
        }
        .designField(width: width)
    }
}
