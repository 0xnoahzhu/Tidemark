import SwiftUI

/// Search field inside a page's sub-header, drawn like the design's: a magnifier and the text on the
/// fill, 28 pt high. Escape clears it.
struct FilterField: View {
    var prompt: String
    @Binding var text: String
    var width: CGFloat

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(Theme.ink3)
            TextField(prompt, text: $text, prompt: Text(prompt))
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .autocorrectionDisabled()
                .onExitCommand { text = "" }
        }
        .padding(.horizontal, 9)
        .frame(width: width, height: 28)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
