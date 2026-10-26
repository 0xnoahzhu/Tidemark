import SwiftUI

/// The design's button in page content: the label on a rounded fill (the accent, or red for an action that stops or
/// deletes something), a little darker while pressed. Native bordered buttons keep the system's size, which is
/// shorter than the design's and does not follow the UI scale. Sizes are in design px.
struct DesignButtonStyle: ButtonStyle {
    enum Kind {
        /// Ink on the faint fill (Copy as JSON).
        case fill
        /// Ink on the stronger fill, which still reads on glass (a dialog's Cancel).
        case strongFill
        /// White on the accent (Monitor Spotify, Resume).
        case accent
        /// White on red (Pause, Stop Monitoring, Delete).
        case destructive
    }

    var kind: Kind = .fill
    var height: CGFloat = 28
    var fontSize: CGFloat = 12
    var cornerRadius: CGFloat = 8
    var horizontalPadding: CGFloat = 11
    /// Takes the width it is offered (a dialog's two equal buttons) instead of hugging its label.
    var fillsWidth = false

    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius.px, style: .continuous)
        configuration.label
            .font(.design(fontSize, isFilled ? .medium : .semibold))
            .lineLimit(1)
            .foregroundStyle(isFilled ? Theme.ink : Theme.onAccent)
            .padding(.horizontal, horizontalPadding.px)
            .frame(maxWidth: fillsWidth ? .infinity : nil)
            .frame(height: height.px)
            .background(background, in: shape)
            .overlay {
                if configuration.isPressed { shape.fill(.black.opacity(0.1)) }
            }
            .opacity(isEnabled ? 1 : 0.5)
            .contentShape(shape)
    }

    /// Ink on a fill rather than white on a color.
    private var isFilled: Bool { kind == .fill || kind == .strongFill }

    private var background: Color {
        switch kind {
        case .fill: Theme.fill
        case .strongFill: Theme.fill2
        case .accent: Theme.accent
        case .destructive: Theme.destructive
        }
    }
}

/// The design's text field: no bezel, the text and any glyph before it on a rounded fill. A native field keeps the
/// system's size and bezel, which do not follow the UI scale. Sizes are in design px.
struct DesignFieldStyle: ViewModifier {
    var height: CGFloat = 28
    var fontSize: CGFloat = 12
    var cornerRadius: CGFloat = 8
    var horizontalPadding: CGFloat = 9
    /// The field's width; nil to take the width offered.
    var width: CGFloat?

    func body(content: Content) -> some View {
        content
            .textFieldStyle(.plain)
            .font(.design(fontSize))
            .padding(.horizontal, horizontalPadding.px)
            .frame(width: width?.px, height: height.px)
            .background(Theme.fill, in: RoundedRectangle(cornerRadius: cornerRadius.px, style: .continuous))
    }
}

extension View {
    /// Draws this text field, or a glyph and a field in a row, as the design's field (`DesignFieldStyle`).
    func designField(height: CGFloat = 28, cornerRadius: CGFloat = 8, horizontalPadding: CGFloat = 9, width: CGFloat? = nil) -> some View {
        modifier(DesignFieldStyle(height: height, cornerRadius: cornerRadius, horizontalPadding: horizontalPadding, width: width))
    }
}
