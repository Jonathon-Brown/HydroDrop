import AppIntents

/// The phrases Siri and the Shortcuts app offer without the user building anything.
///
/// Both shortcuts run on their defaults, so neither asks a question before doing the
/// thing: "log water" logs the first quick-add size, which is the one-tap amount the
/// user already chose on the Today screen.
struct HydroDropShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogWaterIntent(),
            phrases: [
                "Log water in \(.applicationName)",
                "Log a drink in \(.applicationName)",
                "Add water to \(.applicationName)",
            ],
            shortTitle: "Log Water",
            systemImageName: "drop.fill"
        )
        AppShortcut(
            intent: GetTodayProgressIntent(),
            phrases: [
                "How much water have I had in \(.applicationName)",
                "Check my hydration in \(.applicationName)",
            ],
            shortTitle: "Today's Hydration",
            systemImageName: "chart.bar.fill"
        )
    }
}
