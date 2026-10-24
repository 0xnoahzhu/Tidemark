import Foundation
import Observation

/// Runtime language switching (Settings › General › Language) on top of String Catalogs.
///
/// Each UI area keeps its strings in its own catalog table (`Sidebar.xcstrings`, `Requests.xcstrings`, …)
/// with English keys and `zh-Hans` translations. `tr` looks keys up in the bundle of the selected
/// language; reading `bundle` inside a view body registers an observation, so views re-render when
/// the language changes.
@MainActor
@Observable
final class Localizer {
    static let shared = Localizer()

    /// Language codes with a translation bundle.
    static let supported = ["en", "zh-Hans"]

    var preference: Preferences.Language = .system {
        didSet { resolve() }
    }

    private(set) var languageCode = "en"
    private(set) var bundle: Bundle = .main
    private(set) var locale = Locale(identifier: "en")

    var isChinese: Bool { languageCode == "zh-Hans" }

    private init() { resolve() }

    private func resolve() {
        let code: String
        switch preference {
        case .english: code = "en"
        case .chinese: code = "zh-Hans"
        case .system:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "en"
            code = preferred.hasPrefix("zh") ? "zh-Hans" : "en"
        }
        languageCode = code
        locale = Locale(identifier: code)
        if let path = Bundle.main.path(forResource: code, ofType: "lproj"), let b = Bundle(path: path) {
            bundle = b
        } else {
            bundle = .main
        }
    }
}

/// Localized string for `key` from catalog `table`, in the language chosen in Settings.
@MainActor
func tr(_ key: String, _ table: String) -> String {
    Localizer.shared.bundle.localizedString(forKey: key, value: key, table: table)
}

/// Localized format string for `key`, filled with `args` (`%@`, `%lld`, `%d`, positional `%1$@` supported).
@MainActor
func trf(_ key: String, _ table: String, _ args: any CVarArg...) -> String {
    String(format: tr(key, table), locale: Localizer.shared.locale, arguments: args)
}

/// Picks the singular or plural English key by `count` (Chinese translations usually share one form),
/// then formats it with `count` as the first argument, e.g. `trn("%lld host", "%lld hosts", n, "AppDetail")`.
@MainActor
func trn(_ singular: String, _ plural: String, _ count: Int, _ table: String, _ extra: any CVarArg...) -> String {
    let key = count == 1 ? singular : plural
    return String(format: tr(key, table), locale: Localizer.shared.locale, arguments: [count as any CVarArg] + extra)
}
