import AppIntents
import AppKit
import Foundation

/// A monitored app as Shortcuts, Spotlight and Siri see it.
struct MonitoredAppEntity: AppEntity, Identifiable, Hashable, Sendable {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(
        name: LocalizedStringResource("Monitored App", table: "Intents"),
        synonyms: [LocalizedStringResource("Monitored Application", table: "Intents")]
    )

    static let defaultQuery = MonitoredAppQuery()

    let id: AppID
    let name: String
    /// Bundle path, e.g. `/Applications/Cursor.app`.
    let path: String
    let bundleID: String?
    let isArchived: Bool

    init(app: MonitoredApp) {
        id = app.id
        name = app.name
        path = app.path
        bundleID = app.bundleID
        isArchived = app.isArchived
    }

    var displayRepresentation: DisplayRepresentation {
        let path = path
        // The icon is rendered only when the system shows it (macOS 27 lazy image).
        return DisplayRepresentation(title: "\(name)", subtitle: "\(path)", synonyms: []) {
            await MonitoredAppEntity.iconImage(bundlePath: path)
        }
    }

    /// The real app icon as PNG, when the bundle exists on this Mac.
    @MainActor
    static func iconImage(bundlePath: String) -> DisplayRepresentation.Image? {
        guard let icon = AppIconCache.shared.icon(for: bundlePath), let data = pngData(icon, side: 64) else { return nil }
        return DisplayRepresentation.Image(data: data)
    }

    @MainActor
    private static func pngData(_ image: NSImage, side: CGFloat) -> Data? {
        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        return NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:])
    }

    /// `true` when `query` matches the app's name, bundle ID, the bundle's display name (`AppNaming`: the name
    /// Finder shows) or its file name (a localized system app's English name, "Calendar" for "日历"), ignoring case.
    func matches(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        let bundleName = AppNaming.displayName(forBundlePath: path)
        let fileName = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        return [name, bundleID ?? "", bundleName, fileName].contains { $0.localizedCaseInsensitiveContains(needle) }
    }
}

/// Looks monitored apps up for intents and parameters.
struct MonitoredAppQuery: EntityStringQuery {
    static let allowedExecutionTargets: IntentExecutionTargets = .main

    @Dependency private var model: AppModel

    @MainActor
    func entities(for identifiers: [AppID]) async throws -> [MonitoredAppEntity] {
        let wanted = Set(identifiers)
        return await TidemarkIntents.apps(model).filter { wanted.contains($0.id) }.map(MonitoredAppEntity.init(app:))
    }

    @MainActor
    func suggestedEntities() async throws -> [MonitoredAppEntity] {
        Self.suggested(from: await TidemarkIntents.apps(model))
    }

    @MainActor
    func entities(matching string: String) async throws -> [MonitoredAppEntity] {
        Self.suggested(from: await TidemarkIntents.apps(model)).filter { $0.matches(string) }
    }

    /// Apps offered in pickers: active ones first (oldest monitored first), archived ones last.
    static func suggested(from apps: [MonitoredApp]) -> [MonitoredAppEntity] {
        let active = apps.filter { !$0.isArchived }.sorted { $0.createdAt < $1.createdAt }
        let archived = apps.filter(\.isArchived).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        return (active + archived).map(MonitoredAppEntity.init(app:))
    }
}
