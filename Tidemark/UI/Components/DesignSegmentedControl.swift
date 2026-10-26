import SwiftUI

/// The app's segmented control, "icon + count": the choices sit on a rounded fill track with no dividers, each an
/// SF Symbol, its title and (where a number is at hand) a count in a small capsule, and the selected one is raised
/// on a white cell (20% white in dark mode) with a hairline border, its title in ink rather than ink2.
///
/// It comes in two sizes of the same look: `.regular()` (40 px tall) for page tabs and filters in page content,
/// `.compact()` (32 px) where that is too tall, such as the window toolbar and Settings rows. Both are drawn at the
/// UI scale, the compact one no taller than a toolbar item holds. The control sizes to its content; a control with
/// counts, in a place too narrow for it, drops the counts and then the icons.
///
/// Every choice is a button, so keyboard navigation reaches each one; VoiceOver reads the control as a
/// segmented picker with its selected choice, and a toolbar's overflow menu lists the choices.
struct DesignSegmentedControl<Value: Hashable>: View {
    /// The metrics of one of the two sizes, in design px, and the factor they are drawn at.
    struct Size {
        var fontSize: CGFloat
        var iconSize: CGFloat
        var badgeFontSize: CGFloat
        /// Height of a choice's icon, title and badge row, whatever the symbol's own height.
        var contentHeight: CGFloat
        var verticalPadding: CGFloat
        var horizontalPadding: CGFloat
        /// Between the icon, the title and the badge.
        var spacing: CGFloat
        var cornerRadius: CGFloat
        var trackPadding: CGFloat
        var trackCornerRadius: CGFloat
        /// The UI scale these px are drawn at.
        var factor: CGFloat

        /// The control's height in points.
        var height: CGFloat {
            points(contentHeight) + 2 * points(verticalPadding) + 2 * points(trackPadding)
        }

        /// `px` at this size's factor, rounded to half a point.
        func points(_ px: CGFloat) -> CGFloat {
            UIScale.length(px, factor: factor)
        }

        func font(_ px: CGFloat, _ weight: Font.Weight) -> Font {
            .system(size: px * factor, weight: weight)
        }

        /// 14 px titles, 15 px icons and 12 px counts; `padding: 8px 14px; border-radius: 9px` in a 4 px track with
        /// 12 px corners: 40 px tall.
        static func regular(factor: CGFloat = UIScale.factor) -> Size {
            Size(fontSize: 14, iconSize: 15, badgeFontSize: 12, contentHeight: 16, verticalPadding: 8,
                 horizontalPadding: 14, spacing: 6, cornerRadius: 9, trackPadding: 4, trackCornerRadius: 12, factor: factor)
        }

        /// 13 px titles, 13 px icons and 11 px counts; `padding: 5px 11px; border-radius: 7px` in a 3 px track with
        /// 10 px corners: 32 px tall. It grows with the UI scale only as far as `toolbarItemHeight`, so a toolbar item
        /// still holds it without clipping.
        static func compact(factor: CGFloat = UIScale.factor) -> Size {
            var size = Size(fontSize: 13, iconSize: 13, badgeFontSize: 11, contentHeight: 16, verticalPadding: 5,
                            horizontalPadding: 11, spacing: 5, cornerRadius: 7, trackPadding: 3, trackCornerRadius: 10, factor: 1)
            size.factor = min(factor, toolbarItemHeight / size.height)
            return size
        }

        /// The tallest control a toolbar item's glass capsule holds, which the system draws the same at every scale.
        static var toolbarItemHeight: CGFloat { UIScale.toolbarItemHeight }
    }

    /// One choice: its value, (localized) title, and optionally an SF Symbol and a count.
    struct Segment: Identifiable {
        var id: Value
        var title: String
        var systemImage: String?
        var count: Int?

        init(_ value: Value, _ title: String, systemImage: String? = nil, count: Int? = nil) {
            id = value
            self.title = title
            self.systemImage = systemImage
            self.count = count
        }
    }

    private let title: String
    @Binding private var selection: Value
    private let size: Size
    private let segments: [Segment]

    @Environment(\.displayScale) private var displayScale

    /// - Parameters:
    ///   - title: What the choice is about; VoiceOver reads it as the control's label.
    ///   - segments: Each choice, in order.
    init(_ title: String, selection: Binding<Value>, size: Size = .regular(), segments: [Segment]) {
        self.title = title
        _selection = selection
        self.size = size
        self.segments = segments
    }

    var body: some View {
        Group {
            if segments.contains(where: { $0.count != nil }) {
                // Laid out at its ideal width wherever that fits (a toolbar, a row with room); a narrower place
                // gets the choices without their counts, and then without their icons.
                ViewThatFits(in: .horizontal) {
                    track(showsCounts: true, showsIcons: true)
                    track(showsCounts: false, showsIcons: true)
                    track(showsCounts: false, showsIcons: false)
                }
            } else {
                track(showsCounts: false, showsIcons: true)
            }
        }
        .background { overflowMenu }
        .accessibilityRepresentation { accessibilityPicker }
    }

    private func track(showsCounts: Bool, showsIcons: Bool) -> some View {
        HStack(spacing: size.points(2)) {
            ForEach(segments) { segment in
                Button {
                    selection = segment.id
                } label: {
                    SegmentLabel(segment: segment, isSelected: segment.id == selection, showsCount: showsCounts,
                                 showsIcon: showsIcons, size: size)
                }
                .buttonStyle(SegmentStyle(isSelected: segment.id == selection, size: size, hairline: 1 / max(displayScale, 1)))
            }
        }
        .padding(size.points(size.trackPadding))
        .background(Theme.segmentTrack, in: RoundedRectangle(cornerRadius: size.points(size.trackCornerRadius), style: .continuous))
        .fixedSize()
    }

    /// What VoiceOver sees: a segmented picker whose choices read their counts too.
    private var accessibilityPicker: some View {
        Picker(title, selection: $selection) {
            ForEach(segments) { segment in
                Text(verbatim: segment.count.map { "\(segment.title), \(Fmt.count($0))" } ?? segment.title)
                    .tag(segment.id)
            }
        }
        .pickerStyle(.segmented)
    }

    /// A toolbar that runs out of room lists the item in its overflow menu, built from the item's first control.
    /// This invisible picker comes before the segments' buttons, so the menu offers every choice, the selected one
    /// checked, rather than only the first segment.
    private var overflowMenu: some View {
        Picker(title, selection: $selection) {
            ForEach(segments) { segment in
                if let systemImage = segment.systemImage {
                    Label(segment.title, systemImage: systemImage).tag(segment.id)
                } else {
                    Text(segment.title).tag(segment.id)
                }
            }
        }
        .labelsHidden()
        .opacity(0)
        .frame(width: 0, height: 0)
        .focusable(false)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

extension DesignSegmentedControl {
    /// A choice's icon, title and count. The title keeps the width of its selected (medium) weight, so selecting
    /// another choice doesn't move the others.
    private struct SegmentLabel: View {
        var segment: Segment
        var isSelected: Bool
        var showsCount: Bool
        var showsIcon: Bool
        var size: Size

        var body: some View {
            HStack(spacing: size.points(size.spacing)) {
                if showsIcon, let systemImage = segment.systemImage {
                    Image(systemName: systemImage)
                        .font(size.font(size.iconSize, .medium))
                        .imageScale(.medium)
                        .accessibilityHidden(true)
                }
                Text(segment.title)
                    .font(size.font(size.fontSize, .medium))
                    .hidden()
                    .overlay {
                        Text(segment.title)
                            .font(size.font(size.fontSize, isSelected ? .medium : .regular))
                    }
                if showsCount, let count = segment.count {
                    CountCapsule(count: count, isSelected: isSelected, size: size)
                }
            }
            .lineLimit(1)
            .frame(height: size.points(size.contentHeight))
            // A toolbar offers a button's label a little less than its ideal width, which would cut the last count.
            .fixedSize()
        }
    }

    /// `12`, `9,412`, `1.28M`: the count in monospaced digits on a faint capsule, at least as wide as it is tall, so
    /// a count that changes keeps the capsule (and the choices after it) in place until it gains a digit. On the
    /// raised cell, which is light grey in dark mode, the capsule darkens it rather than lightening it further.
    private struct CountCapsule: View {
        var count: Int
        var isSelected: Bool
        var size: Size

        var body: some View {
            Text(Fmt.short(count))
                .font(size.font(size.badgeFontSize, .medium))
                .monospacedDigit()
                .foregroundStyle(isSelected ? Theme.segmentCount : Theme.ink2)
                .padding(.horizontal, size.points(size.badgeFontSize / 2))
                .frame(minWidth: size.points(size.contentHeight), minHeight: size.points(size.contentHeight))
                .background(isSelected ? Theme.segmentCountFill : Theme.fill, in: Capsule())
        }
    }

    /// One choice: ink2 on the bare track, ink on the raised cell with its hairline border.
    private struct SegmentStyle: ButtonStyle {
        var isSelected: Bool
        var size: Size
        var hairline: CGFloat

        func makeBody(configuration: Configuration) -> some View {
            let cell = RoundedRectangle(cornerRadius: size.points(size.cornerRadius), style: .continuous)
            configuration.label
                .foregroundStyle(isSelected ? Theme.ink : Theme.ink2)
                .opacity(configuration.isPressed && !isSelected ? 0.65 : 1)
                .padding(.vertical, size.points(size.verticalPadding))
                .padding(.horizontal, size.points(size.horizontalPadding))
                .background {
                    if isSelected {
                        cell
                            .fill(Theme.segment)
                            .strokeBorder(Theme.segmentBorder, lineWidth: hairline)
                            .shadow(color: Theme.segmentShadow, radius: 1.5, y: 1)
                    }
                }
                .contentShape(cell)
        }
    }
}
