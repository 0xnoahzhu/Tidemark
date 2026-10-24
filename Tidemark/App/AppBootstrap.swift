import AppKit
import SwiftUI

/// Composition root: builds the concrete services and starts capture.
@MainActor
enum AppBootstrap {
    static func start(_ model: AppModel) {
        Localizer.shared.preference = model.preferences.language
        applyAppearance(model.preferences.appearance)
        applyActivationPolicy(model.preferences.showIn)
    }

    static func stop(_ model: AppModel) {}

    static func applyAppearance(_ appearance: Preferences.Appearance) {
        switch appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    static func applyActivationPolicy(_ showIn: Preferences.ShowIn) {
        NSApp.setActivationPolicy(showIn == .menuBarAndDock ? .regular : .accessory)
    }
}
