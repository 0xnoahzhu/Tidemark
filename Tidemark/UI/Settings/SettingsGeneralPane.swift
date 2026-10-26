import AppKit
import os
import ServiceManagement
import SwiftUI

/// Settings › General: appearance, Liquid Glass and login item. The language follows the system's (`Localizer`).
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
            }
            SettingsCard {
                SettingsRow(title: tr("Open at login", "Settings"),
                            note: tr("Starts recording right away and monitors every app except archived ones.", "Settings")) {
                    Toggle(tr("Open at login", "Settings"), isOn: loginBinding)
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .controlSize(SettingsLayout.controlSize)
                }
            }
        }
        .onAppear { loginStatus = SMAppService.mainApp.status }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            loginStatus = SMAppService.mainApp.status
        }
    }

    // MARK: Header

    /// The icon takes the design's 56 px box, its tile about 45 px inside the margin the asset keeps, as the design's
    /// icon does; the name and version stack at the window's line height.
    private var brandHeader: some View {
        HStack(spacing: 12.px) {
            Image("BrandIcon")
                .resizable()
                .interpolation(.high)
                .frame(width: 56.px, height: 56.px)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: "Tidemark")
                    .font(.design(15, .bold))
                    .foregroundStyle(Theme.ink)
                Text(trf("Version %@ · keeps every Surge request in PostgreSQL", "Settings", Self.version))
                    .font(.design(11.5))
                    .foregroundStyle(Theme.ink2)
            }
        }
        .padding(.top, 2.px)
        .padding(.bottom, 4.px)
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
        ), size: .compact(), segments: [
            .init(.system, tr("System", "Settings"), systemImage: "circle.lefthalf.filled"),
            .init(.light, tr("Light", "Settings"), systemImage: "sun.max"),
            .init(.dark, tr("Dark", "Settings"), systemImage: "moon"),
        ])
    }

    /// A plain 150 px track between the two end labels, as in the design (no tick marks).
    private var glassSlider: some View {
        @Bindable var preferences = model.preferences
        return HStack(spacing: 8.px) {
            Text(tr("Clear", "Settings"))
            Slider(value: $preferences.glass, in: 0...100) {
                Text(tr("Liquid Glass", "Settings"))
            }
            .labelsHidden()
            .controlSize(SettingsLayout.controlSize)
            .frame(width: 150.px)
            Text(tr("Tinted", "Settings"))
        }
        .font(.design(11))
        .foregroundStyle(Theme.ink2)
        .fixedSize()
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
