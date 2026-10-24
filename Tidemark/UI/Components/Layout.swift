import SwiftUI

/// White rounded card with a hairline border (Egress page, settings groups, inspector blocks).
struct Card<Content: View>: View {
    var padding: CGFloat = 16
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Theme.line, lineWidth: 0.5))
    }
}

/// Uppercase grey section label (`PROCESS CHAIN`, `CONNECTION`, `TODAY`).
struct SectionLabel: View {
    var text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10.5, weight: .semibold))
            .tracking(0.4)
            .foregroundStyle(Theme.ink2)
    }
}

/// `Label      value` row of the inspector and egress cards.
struct KeyValueRow<Value: View>: View {
    var label: String
    var labelWidth: CGFloat = 76
    @ViewBuilder var value: Value

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink2)
                .frame(width: labelWidth, alignment: .leading)
            value
                .font(.system(size: 12))
                .foregroundStyle(Theme.ink)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .frame(minHeight: 20)
    }
}

extension KeyValueRow where Value == Text {
    init(_ label: String, _ value: String, mono: Bool = false, labelWidth: CGFloat = 76) {
        self.label = label
        self.labelWidth = labelWidth
        self.value = Text(value).font(mono ? Theme.mono(12) : .system(size: 12))
    }
}

/// Page header used by every main-window page: title + subtitle on the left, accessories on the right.
struct PageHeader<Accessory: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var accessory: Accessory

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                if let subtitle {
                    Text(subtitle).font(.system(size: 11.5)).foregroundStyle(Theme.ink2).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            accessory
        }
        .padding(.horizontal, 20)
        .frame(height: 52)
    }
}

extension PageHeader where Accessory == EmptyView {
    init(title: String, subtitle: String?) {
        self.init(title: title, subtitle: subtitle) { EmptyView() }
    }
}

/// Centered placeholder for empty lists.
struct EmptyState: View {
    var systemImage: String
    var title: String
    var message: String?

    var body: some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let message { Text(message) }
        }
        .foregroundStyle(Theme.ink2)
    }
}
