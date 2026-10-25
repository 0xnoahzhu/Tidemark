import SwiftUI

/// The design's segmented control (the page's `segF`): the choices sit on the fill track with no dividers, and
/// the selected one is raised on a white cell (grey in dark mode) with a small shadow, its title in ink rather
/// than ink2.
///
/// Every choice is a button, so keyboard navigation reaches each one; VoiceOver reads the control as a
/// segmented picker with its selected choice, and a toolbar's overflow menu lists the choices.
struct DesignSegmentedControl<Value: Hashable>: View {
    /// The page's segment metrics. Its instances share two sizes and vary the horizontal padding (and the small
    /// size's font) a little; each call site passes its instance's numbers.
    struct Size {
        var fontSize: CGFloat
        var verticalPadding: CGFloat
        var horizontalPadding: CGFloat
        var cornerRadius: CGFloat
        var trackCornerRadius: CGFloat

        /// `padding:3px 12px; border-radius:6px; font-size:12px` on an 8 pt track.
        static func regular(horizontalPadding: CGFloat = 12) -> Size {
            Size(fontSize: 12, verticalPadding: 3, horizontalPadding: horizontalPadding, cornerRadius: 6, trackCornerRadius: 8)
        }

        /// `padding:2px 9px; border-radius:5px; font-size:11px` on a 7 pt track.
        static func small(fontSize: CGFloat = 11, horizontalPadding: CGFloat = 9) -> Size {
            Size(fontSize: fontSize, verticalPadding: 2, horizontalPadding: horizontalPadding, cornerRadius: 5, trackCornerRadius: 7)
        }
    }

    private struct Segment: Identifiable {
        var id: Value
        var title: String
    }

    private let title: String
    @Binding private var selection: Value
    private let size: Size
    private let segments: [Segment]

    /// - Parameters:
    ///   - title: What the choice is about; VoiceOver reads it as the control's label.
    ///   - segments: Each choice's value and its (localized) title, in order.
    init(_ title: String, selection: Binding<Value>, size: Size = .regular(), segments: [(value: Value, title: String)]) {
        self.title = title
        _selection = selection
        self.size = size
        self.segments = segments.map { Segment(id: $0.value, title: $0.title) }
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                Button(segment.title) { selection = segment.id }
                    .buttonStyle(SegmentStyle(isSelected: segment.id == selection, size: size))
            }
        }
        .padding(2)
        .background(Theme.fill, in: RoundedRectangle(cornerRadius: size.trackCornerRadius, style: .continuous))
        .fixedSize()
        .background { overflowMenu }
        .accessibilityRepresentation { picker.pickerStyle(.segmented) }
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(segments) { Text($0.title).tag($0.id) }
        }
    }

    /// A toolbar that runs out of room lists the item in its overflow menu, built from the item's first control.
    /// This invisible picker comes before the segments' buttons, so the menu offers every choice, the selected one
    /// checked, rather than only the first segment.
    private var overflowMenu: some View {
        picker
            .labelsHidden()
            .opacity(0)
            .frame(width: 0, height: 0)
            .focusable(false)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

extension DesignSegmentedControl {
    /// One choice: medium text, ink2 on the bare track, ink on the raised cell (`T.seg` with `T.segSh`).
    private struct SegmentStyle: ButtonStyle {
        var isSelected: Bool
        var size: Size

        func makeBody(configuration: Configuration) -> some View {
            let cell = RoundedRectangle(cornerRadius: size.cornerRadius, style: .continuous)
            configuration.label
                .font(.system(size: size.fontSize, weight: .medium))
                .lineLimit(1)
                .foregroundStyle(isSelected ? Theme.ink : Theme.ink2)
                .padding(.vertical, size.verticalPadding)
                .padding(.horizontal, size.horizontalPadding)
                .background {
                    if isSelected {
                        cell
                            .fill(Theme.segment)
                            .shadow(color: Theme.segmentShadow, radius: 1, y: 1)
                            .background {
                                // The light shadow's second layer, a half-point ring (`0 0 0 .5px`).
                                RoundedRectangle(cornerRadius: size.cornerRadius + 0.5, style: .continuous)
                                    .fill(Theme.segmentRing)
                                    .padding(-0.5)
                            }
                    }
                }
                .contentShape(cell)
        }
    }
}
