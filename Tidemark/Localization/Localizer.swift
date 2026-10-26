import Foundation
import Observation

/// The UI language on top of String Catalogs: the first of the system's preferred languages that Tidemark has a
/// translation for, else English.
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

    @ObservationIgnored private var localeChange: NotificationCenter.ObservationToken?

    private init() {
        resolve()
        // The preferred languages can change while Tidemark runs (System Settings › General › Language & Region).
        localeChange = NotificationCenter.default.addObserver(of: Locale.self, for: .currentLocaleDidChange) { [weak self] _ in
            self?.resolve()
        }
    }

    /// The language Tidemark shows for `preferred`, the user's languages most wanted first (`Locale.preferredLanguages`,
    /// which holds a language chosen for Tidemark alone in System Settings): matched against `supported` the way macOS
    /// picks an app's localization (so `zh-Hans-CN` gives `zh-Hans`), and English when none of them has a translation.
    nonisolated static func language(for preferred: [String]) -> String {
        Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
    }

    private func resolve() {
        var code = Self.language(for: Locale.preferredLanguages)
        #if DEBUG
        if let override { code = override }
        #endif
        // The notification also comes for region and format changes, which leave the language as it is.
        guard code != languageCode else { return }
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
