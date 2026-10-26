import SwiftUI

/// The page's centered glass dialog: an icon, a bold title, a secondary message and two equal buttons, Cancel and
/// the confirming one (red when it stops something, accent otherwise). Return confirms and Escape cancels, ahead
/// of any shortcut of the window beneath (the Requests inspector closes on Escape).
///
/// Present it with `glassDialog(isPresented:onCancel:dialog:)`, which lays it over the whole window.
struct GlassDialog<Icon: View>: View {
    enum Tone { case destructive, accent }

    @Environment(AppModel.self) private var model
    /// The dialog's width in design px.
    var width: CGFloat
    var surface: GlassSurface
    var title: String
    var message: String
    var cancelTitle: String
    var confirmTitle: String
    var tone: Tone
    var onCancel: () -> Void
    var onConfirm: () -> Void
    @ViewBuilder var icon: Icon

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 18.px, style: .continuous)
        VStack(spacing: 10.px) {
            icon
                .accessibilityHidden(true)
            Text(title)
                .font(.design(13.5, .bold))
                .accessibilityAddTraits(.isHeader)
            Text(message)
                .font(.design(12))
                .lineHeight(Theme.noteLineHeight)
                .foregroundStyle(Theme.ink2)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8.px) {
                Button(cancelTitle, action: onCancel)
                    .buttonStyle(Self.buttonStyle(.strongFill))
                Button(confirmTitle, action: onConfirm)
                    .buttonStyle(Self.buttonStyle(tone == .destructive ? .destructive : .accent))
            }
            .padding(.top, 6.px)
        }
        .multilineTextAlignment(.center)
        .foregroundStyle(Theme.ink)
        .padding(EdgeInsets(top: 20.px, leading: 18.px, bottom: 16.px, trailing: 18.px))
        .frame(width: width.px)
        .background(surface.tint(preference: model.preferences.glass), in: shape)
        .glassEffect(.regular, in: shape)
        .overlay { shape.strokeBorder(.black.opacity(0.22), lineWidth: 0.5) }
        .shadow(color: .black.opacity(0.32), radius: 30, y: 24)
        .background {
            EventMonitor(onKeyDown: { event in
                if event.keyCode == EventMonitor.escapeKey {
                    onCancel()
                } else if EventMonitor.returnKeys.contains(event.keyCode) {
                    onConfirm()
                } else {
                    return false
                }
                return true
            })
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
    }

    /// A dialog button: half the row, 30 px high, radius 9.
    private static func buttonStyle(_ kind: DesignButtonStyle.Kind) -> DesignButtonStyle {
        DesignButtonStyle(kind: kind, height: 30, fontSize: 12.5, cornerRadius: 9, fillsWidth: true)
    }
}

extension View {
    /// Lays `dialog` over this view while `isPresented`: on the page's light dim, centered across and a quarter of
    /// the way down. A click on the dim cancels.
    func glassDialog<Dialog: View>(
        isPresented: Bool,
        onCancel: @escaping () -> Void,
        @ViewBuilder dialog: @escaping () -> Dialog
    ) -> some View {
        overlay {
            if isPresented {
                GeometryReader { proxy in
                    ZStack(alignment: .top) {
                        Color.black.opacity(0.12)
                            .contentShape(.rect)
                            .onTapGesture(perform: onCancel)
                        dialog()
                            .padding(.top, (proxy.size.height * 0.25).rounded())
                    }
                    .frame(width: proxy.size.width, height: proxy.size.height)
                }
                .ignoresSafeArea()
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.15), value: isPresented)
    }
}
