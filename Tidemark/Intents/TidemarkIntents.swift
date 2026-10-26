import AppIntents
import AppKit
import Observation
import SwiftUI

/// Wires Tidemark's App Intents (Shortcuts, Spotlight, Siri) to the running app.
///
/// Intents run in the main app process (`allowedExecutionTargets = .main`) and reach `AppModel`
/// through `AppDependencyManager`.
@MainActor
enum TidemarkIntents {
    /// Opens (or brings forward) the main window; set by `TidemarkIntentsWindowBridge`.
    static var mainWindowOpener: (@MainActor () -> Void)?

    private static var catalogWatch: Task<Void, Never>?
    /// The model handed to `AppDependencyManager`; registering it again is a no-op.
    private(set) static var registeredModel: AppModel?

    /// Registers `model` as the intents' `@Dependency`. Call as early as possible at launch
    /// (`applicationWillFinishLaunching`), before the system can resolve an intent or entity query.
    /// Later calls with the same model do nothing.
    static func register(model: AppModel) {
        guard registeredModel !== model else { return }
        registeredModel = model
        AppDependencyManager.shared.add(dependency: model)
        TidemarkShortcuts.updateAppShortcutParameters()
        catalogWatch?.cancel()
        // Siri and Spotlight learn app names for the "Open <app> in Tidemark" phrases.
        catalogWatch = Task { @MainActor in
            let names = Observations { model.catalog.apps.filter { !$0.isArchived }.map { "\($0.id)|\($0.name)" } }
            var last: [String]?
            for await current in names where current != last {
                last = current
                TidemarkShortcuts.updateAppShortcutParameters()
            }
        }
    }

    /// Activates Tidemark and shows the main window.
    static func showMainWindow() {
        DockPresence.willShowWindow()
        NSApp.activate()
        if let mainWindowOpener {
            mainWindowOpener()
        } else if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix(WindowID.main) == true }) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    /// Monitored apps from the catalog, or straight from the database when the catalog has not loaded yet
    /// (an intent can launch Tidemark).
    static func apps(_ model: AppModel) async -> [MonitoredApp] {
        if !model.catalog.apps.isEmpty { return model.catalog.apps }
        return (try? await model.database.apps()) ?? []
    }
}

/// Lets intents open the main window through SwiftUI's `openWindow`. Attached to the main window and the
/// Settings window: whichever appears first captures an `openWindow` action that keeps working after its
/// window closes. `showMainWindow()` falls back to an existing main window when neither has appeared.
struct TidemarkIntentsWindowBridge: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.task {
            let openWindow = openWindow
            TidemarkIntents.mainWindowOpener = { openWindow(id: WindowID.main) }
        }
    }
}

/// An intent failure with a message already localized in Tidemark's language.
struct TidemarkIntentError: Error, CustomAppIntentErrorConvertible, Equatable {
    enum Kind: Equatable, Sendable {
        case invalidIP
        case appNotFound
    }

    var kind: Kind
    var message: String

    var appIntentError: AppIntentError {
        switch kind {
        case .appNotFound: AppIntentError(predefinedError: AppIntentError.Unrecoverable.entityNotFound, description: "\(message)")
        case .invalidIP: AppIntentError(description: "\(message)")
        }
    }

    @MainActor static func invalidIP(_ value: String) -> TidemarkIntentError {
        TidemarkIntentError(kind: .invalidIP, message: trf("“%@” isn't an IP address.", "Intents", value))
    }

    @MainActor static var appNotFound: TidemarkIntentError {
        TidemarkIntentError(kind: .appNotFound, message: tr("That app is no longer monitored.", "Intents"))
    }
}
