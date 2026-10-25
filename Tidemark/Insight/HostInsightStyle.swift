import Foundation

/// Labels and chip hues for host categories.
enum HostInsightStyle {
    /// OKLCH hue for the category chip (`Theme.tint`); nil renders the neutral chip.
    static func hue(for category: HostCategory) -> Double? {
        switch category {
        case .aiInference: 295
        case .api: 240
        case .cdn: 200
        case .telemetry: 55
        case .analytics: 330
        case .ads: 27
        case .auth: 150
        case .update: 175
        case .storage: 265
        case .messaging: 215
        case .media: 350
        case .web: 250
        case .unknown: nil
        }
    }

    /// Localized chip label.
    @MainActor
    static func label(for category: HostCategory) -> String {
        switch category {
        case .aiInference: tr("AI inference", "Insight")
        case .api: tr("API", "Insight")
        case .cdn: tr("CDN", "Insight")
        case .telemetry: tr("Telemetry", "Insight")
        case .analytics: tr("Analytics", "Insight")
        case .ads: tr("Ads", "Insight")
        case .auth: tr("Sign-in", "Insight")
        case .update: tr("Updates", "Insight")
        case .storage: tr("Storage", "Insight")
        case .messaging: tr("Messaging", "Insight")
        case .media: tr("Media", "Insight")
        case .web: tr("Website", "Insight")
        case .unknown: tr("Unknown", "Insight")
        }
    }
}
