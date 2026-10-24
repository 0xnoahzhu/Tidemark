import AppKit
import ServiceManagement
import SwiftUI

/// Settings › General: where Tidemark shows up, appearance, Liquid Glass, language and login item.
struct SettingsGeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?

    var body: some View {
        Form {
            Section {
                showInPicker
                appearancePicker
                glassSlider
                languagePicker
            } header: {
                brandHeader
            }

            Section {
                ipInfoServicePicker
            }

            Section {
                Toggle(isOn: loginBinding) {
                    Text(tr("Open at login", "Settings"))
                    Text(tr("Starts recording right away and monitors every app except archived ones.", "Settings"))
                }
                if loginStatus == .requiresApproval {
                    HStack(alignment: .firstTextBaseline) {
                        Text(tr("Allow Tidemark in System Settings › General › Login Items to finish turning this on.", "Settings"))
                            .font(.system(size: 11.5))
                            .foregroundStyle(Theme.amberInk)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button(tr("Open Login Items…", "Settings")) {
                            SMAppService.openSystemSettingsLoginItems()
                        }
                    }
                }
                if let loginError {
                    Text(loginError)
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.failed)
                        .textSelection(.enabled)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: SettingsLayout.width, height: 470)
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    // MARK: Header

    private var brandHeader: some View {
        HStack(spacing: 12) {
            Image("BrandIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 56, height: 56)
                .padding(-4)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: "Tidemark")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Theme.ink)
                Text(trf("Version %@ · keeps every Surge request in PostgreSQL", "Settings", Self.version))
                    .font(.system(size: 11.5, weight: .regular))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.bottom, 8)
        .textCase(nil)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    // MARK: Rows

    // The segmented pickers put their label in LabeledContent and size only the control to fit, so they end
    // at the row's trailing edge like the slider, the menus and the switch (a fixed-size Picker shrinks the
    // whole row, label included, and stops short of the edge).

    private var showInPicker: some View {
        LabeledContent(tr("Show in", "Settings")) {
            Picker(tr("Show in", "Settings"), selection: Binding(
                get: { model.preferences.showIn },
                set: { value in
                    model.preferences.showIn = value
                    AppBootstrap.applyActivationPolicy(value)
                    // Changing the activation policy can deactivate the app; keep Settings in front.
                    Task { @MainActor in NSApp.activate() }
                }
            )) {
                Text(tr("Menu Bar & Dock", "Settings")).tag(Preferences.ShowIn.menuBarAndDock)
                Text(tr("Menu Bar Only", "Settings")).tag(Preferences.ShowIn.menuBarOnly)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var appearancePicker: some View {
        LabeledContent(tr("Appearance", "Settings")) {
            Picker(tr("Appearance", "Settings"), selection: Binding(
                get: { model.preferences.appearance },
                set: { value in
                    model.preferences.appearance = value
                    AppBootstrap.applyAppearance(value)
                }
            )) {
                Text(tr("System", "Settings")).tag(Preferences.Appearance.system)
                Text(tr("Light", "Settings")).tag(Preferences.Appearance.light)
                Text(tr("Dark", "Settings")).tag(Preferences.Appearance.dark)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }

    private var glassSlider: some View {
        @Bindable var preferences = model.preferences
        return LabeledContent {
            // A plain 150 pt track between the two end labels, as in the design (no tick marks).
            HStack(spacing: 8) {
                Text(tr("Clear", "Settings"))
                Slider(value: $preferences.glass, in: 0...100) {
                    Text(tr("Liquid Glass", "Settings"))
                }
                .labelsHidden()
                .frame(width: 150)
                Text(tr("Tinted", "Settings"))
            }
            .font(.system(size: 11))
            .foregroundStyle(Theme.ink2)
        } label: {
            Text(tr("Liquid Glass", "Settings"))
            Text(tr("Follows System Settings › Appearance until you move it here.", "Settings"))
        }
    }

    /// Where the network type (hosting, residential…) of egress and looked-up IPs comes from.
    private var ipInfoServicePicker: some View {
        @Bindable var preferences = model.preferences
        return Picker(selection: $preferences.ipInfoService) {
            ForEach(Preferences.IPInfoService.allCases, id: \.self) { service in
                Text(Self.ipInfoServiceName(service)).tag(service)
            }
        } label: {
            Text(tr("IP info service", "Settings"))
            Text(tr("Adds the network type (hosting, residential…) to egress IPs and IPs you look up. Only those addresses are sent. Off keeps lookups to Surge's own GeoIP data.", "Settings"))
        }
        .pickerStyle(.menu)
    }

    static func ipInfoServiceName(_ service: Preferences.IPInfoService) -> String {
        switch service {
        case .proxycheck: "proxycheck.io"
        case .off: tr("Off", "Settings")
        }
    }

    /// A form menu row like the IP info service: not fixed-size, so its pop-up ends at the trailing edge.
    private var languagePicker: some View {
        Picker(tr("Language", "Settings"), selection: Binding(
            get: { model.preferences.language },
            set: { value in
                model.preferences.language = value
                Localizer.shared.preference = value
            }
        )) {
            Text(tr("System", "Settings")).tag(Preferences.Language.system)
            Divider()
            Text(verbatim: "English").tag(Preferences.Language.english)
            Text(verbatim: "简体中文").tag(Preferences.Language.chinese)
        }
        .pickerStyle(.menu)
    }

    // MARK: Login item

    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled || loginStatus == .requiresApproval },
            set: { setOpenAtLogin($0) }
        )
    }

    private func setOpenAtLogin(_ on: Bool) {
        loginError = nil
        do {
            try SettingsLoginItem.set(on)
            model.preferences.openAtLogin = on
        } catch {
            loginError = error.localizedDescription
        }
        loginStatus = SMAppService.mainApp.status
    }
}

/// Registers Tidemark as a login item with `SMAppService`.
@MainActor
enum SettingsLoginItem {
    static var isEnabled: Bool {
        let status = SMAppService.mainApp.status
        return status == .enabled || status == .requiresApproval
    }

    static func set(_ on: Bool) throws {
        let service = SMAppService.mainApp
        if on {
            guard service.status != .enabled else { return }
            try service.register()
        } else {
            guard service.status == .enabled || service.status == .requiresApproval else { return }
            try service.unregister()
        }
    }
}
