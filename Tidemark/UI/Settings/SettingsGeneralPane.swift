import AppKit
import os
import ServiceManagement
import SwiftUI

/// Settings › General: appearance, Liquid Glass, language and login item.
struct SettingsGeneralPane: View {
    @Environment(AppModel.self) private var model
    @Environment(Localizer.self) private var localizer

    @State private var loginStatus = SMAppService.mainApp.status

    var body: some View {
        SettingsPage {
            brandHeader
            SettingsCard {
                SettingsRow(title: tr("Appearance", "Settings"), verticalPadding: 9) { appearancePicker }
                SettingsRow(title: tr("Liquid Glass", "Settings"),
                            note: tr("Follows System Settings › Appearance until you move it here.", "Settings"),
                            verticalPadding: 9) { glassSlider }
                SettingsRow(title: tr("Language", "Settings"), verticalPadding: 9) { languagePicker }
            }
            SettingsCard {
                SettingsRow(title: tr("Open at login", "Settings"),
                            note: tr("Starts recording right away and monitors every app except archived ones.", "Settings")) {
                    Toggle(tr("Open at login", "Settings"), isOn: loginBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }
            }
        }
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
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.top, 2)
        .padding(.bottom, 4)
    }

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.1"
    }

    // MARK: Rows

    private var appearancePicker: some View {
        DesignSegmentedControl(tr("Appearance", "Settings"), selection: Binding(
            get: { model.preferences.appearance },
            set: { value in
                model.preferences.appearance = value
                AppBootstrap.applyAppearance(value)
            }
        ), size: .regular(horizontalPadding: 10), segments: [
            (.system, tr("System", "Settings")),
            (.light, tr("Light", "Settings")),
            (.dark, tr("Dark", "Settings")),
        ])
    }

    /// A plain 150 pt track between the two end labels, as in the design (no tick marks).
    private var glassSlider: some View {
        @Bindable var preferences = model.preferences
        return HStack(spacing: 8) {
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
        .fixedSize()
    }

    /// English or 简体中文, as in the design. Until one is picked Tidemark follows the system's language, and the
    /// pop-up shows the one that gives.
    private var languagePicker: some View {
        Picker(tr("Language", "Settings"), selection: Binding(
            get: { Self.shownLanguage(model.preferences.language, isChinese: localizer.isChinese) },
            set: { value in
                model.preferences.language = value
                Localizer.shared.preference = value
            }
        )) {
            Text(verbatim: "English").tag(Preferences.Language.english)
            Text(verbatim: "简体中文").tag(Preferences.Language.chinese)
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .frame(width: 128)
    }

    /// The pop-up's choice for the stored preference: following the system shows the language in use.
    static func shownLanguage(_ preference: Preferences.Language, isChinese: Bool) -> Preferences.Language {
        switch preference {
        case .system: isChinese ? .chinese : .english
        case .english, .chinese: preference
        }
    }

    // MARK: Login item

    /// On only while macOS will open Tidemark at login: an item still waiting for approval reads off.
    private var loginBinding: Binding<Bool> {
        Binding(
            get: { loginStatus == .enabled },
            set: { setOpenAtLogin($0) }
        )
    }

    /// A failure leaves the switch where the system has it (the design shows no message for it). An item that
    /// needs approval opens System Settings › Login Items, where the user approves it; the switch turns on when
    /// Tidemark becomes active again.
    private func setOpenAtLogin(_ on: Bool) {
        do {
            try SettingsLoginItem.set(on)
            model.preferences.openAtLogin = on
        } catch {
            SettingsLoginItem.log.error("Changing the login item failed: \(error.localizedDescription, privacy: .public)")
        }
        loginStatus = SMAppService.mainApp.status
        if on, loginStatus == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }
}

/// Registers Tidemark as a login item with `SMAppService`.
@MainActor
enum SettingsLoginItem {
    static let log = Logger(subsystem: "io.tidemark.Tidemark", category: "settings")

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
