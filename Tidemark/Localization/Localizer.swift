import Foundation
import Observation

/// The UI language on top of String Catalogs: the first of the system's preferred languages that Tidemark has a
/// translation for, else English, as macOS picked it for the app at launch.
///
/// Each UI area keeps its strings in its own catalog table (`Sidebar.xcstrings`, `Requests.xcstrings`, …)
/// with English keys and `zh-Hans` translations. `tr` looks keys up in the bundle of the language in use;
/// reading `bundle` inside a view body registers an observation, so views re-render when the language changes.
@MainActor
@Observable
final class Localizer {
    static let shared = Localizer()

    /// Language codes with a translation bundle, as the app bundle's `.lproj` folders name them.
    nonisolated static let supported = ["en", "zh-Hans"]

    #if DEBUG
    /// A language from `supported` used in place of the system's, for the debug tour and tests; nil follows the system.
    var override: String? {
        didSet { resolve() }
    }
    #endif

    private(set) var languageCode = "en"
    /// Translation bundle; nil for English, whose catalog keys are the English text.
    private(set) var bundle: Bundle?
    private(set) var locale = Locale(identifier: "en")

    private init() { resolve() }

    /// The language Tidemark shows for `preferred`, languages most wanted first: matched against `supported` the way
    /// macOS picks an app's localization (so `zh-Hans-CN` gives `zh-Hans`), and English when none of them has a
    /// translation.
    nonisolated static func language(for preferred: [String]) -> String {
        Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
    }

    private func resolve() {
        // The app bundle's localization, which macOS picked at launch from the user's preferred languages (a language
        // chosen for Tidemark alone in System Settings › General › Language & Region comes first). AppKit's menus
        // and alerts keep it until Tidemark quits, so a new language list reaches them and Tidemark's views together
        // at the next launch.
        var code = Self.language(for: Bundle.main.preferredLocalizations)
        #if DEBUG
        if let override { code = override }
        #endif
        languageCode = code
        locale = Locale(identifier: code)
        bundle = code == "en" ? nil : Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:))
    }
}

/// Localized string for `key` from catalog `table`, in the UI language.
@MainActor
func tr(_ key: String, _ table: String) -> String {
    guard let bundle = Localizer.shared.bundle else { return key }
    return bundle.localizedString(forKey: key, value: key, table: table)
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
