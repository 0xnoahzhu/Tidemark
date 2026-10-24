import AppIntents

/// App Shortcuts offered in Spotlight, Siri and the Shortcuts app with no setup.
/// Phrase translations live in `AppShortcuts.xcstrings`.
struct TidemarkShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TodaySummaryIntent(),
            phrases: [
                "What did \(.applicationName) record today",
                "Today in \(.applicationName)",
                "\(.applicationName) summary",
            ],
            shortTitle: LocalizedStringResource("Today's Summary", table: "Intents"),
            systemImageName: "chart.bar.xaxis"
        )
        AppShortcut(
            intent: ToggleRecordingIntent(),
            phrases: [
                "Pause or resume \(.applicationName)",
                "Toggle recording in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Pause or Resume Recording", table: "Intents"),
            systemImageName: "record.circle"
        )
        AppShortcut(
            intent: LookUpIPIntent(),
            phrases: [
                "Look up an IP in \(.applicationName)",
                "Look up an IP address with \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Look Up IP", table: "Intents"),
            systemImageName: "network"
        )
        AppShortcut(
            intent: OpenMonitoredAppIntent(),
            phrases: [
                "Open \(\.$target) in \(.applicationName)",
                "Show \(\.$target) in \(.applicationName)",
            ],
            shortTitle: LocalizedStringResource("Open Monitored App", table: "Intents"),
            systemImageName: "app.badge"
        )
    }

    static var shortcutTileColor: ShortcutTileColor { .lightBlue }
}
