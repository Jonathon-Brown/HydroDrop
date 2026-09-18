import SwiftUI
import SwiftData

@main
struct HydroDropApp: App {
    let container: ModelContainer

    init() {
        container = Self.makeContainer()
        // Started here, not from AppSettings' own initialiser: the change handler calls
        // back into AppSettings.shared, which must already exist by then.
        AppSettings.shared.startCloudSync()
        // The settings initialiser can only see preferences; anyone with water already
        // logged (an iCloud restore onto a new phone, say) is recognised here instead.
        AppSettings.shared.completeOnboardingIfExistingUser(entryCount: Self.entryCount(in: container))
        WatchSessionManager.shared.activate(modelContainer: container)
        // Installed before the first scene exists, so a "Log a glass" tap that launches
        // the app in the background is handled rather than dropped.
        NotificationActionHandler.shared.activate(modelContainer: container)
        ReminderManager.shared.registerCategories()
        // Published before any view appears, so a widget added while the app was
        // uninstalled has something true to draw as soon as the app is opened again.
        WidgetPublisher.publish(
            context: ModelContext(container),
            isShared: SharedModelContainer.isShared(container)
        )
        AdManager.start()
    }

    private static func entryCount(in container: ModelContainer) -> Int {
        let context = ModelContext(container)
        do {
            return try context.fetchCount(FetchDescriptor<WaterEntry>())
        } catch {
            Diagnostics.log("could not count entries at launch: \(error)")
            return 0
        }
    }

    /// Opens the store, moving it into the App Group on the way if that has not
    /// happened yet. See `SharedModelContainer` for the order it tries, and
    /// `StoreMigration` for what happens to the user's existing data.
    private static func makeContainer() -> ModelContainer {
        // Release builds must never be able to swap the user's real store for a seeded
        // in-memory one, however they are launched. The matching hooks in `AppSettings`
        // and `StoreManager` are already compiled out; this one was not.
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-UITestSeedHistory") {
            // A previous run may have left a cached entitlement behind, and the paywall
            // tests need to start from a known one.
            EntitlementCache.isPlusActive = false
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            guard let container = try? ModelContainer(for: WaterEntry.self, configurations: configuration) else {
                fatalError("Failed to create in-memory ModelContainer for UI tests")
            }
            seedHistory(into: container)
            return container
        }
        #endif

        return SharedModelContainer.makeForApp()
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(container)
    }

    /// Populates a week of realistic sample entries for App Store screenshot automation only.
    #if DEBUG
    private static func seedHistory(into container: ModelContainer) {
        let context = ModelContext(container)
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let amountsByDayOffset: [Int: [Int]] = [
            6: [400, 500, 600],
            5: [500, 600, 500, 450],
            4: [300, 400],
            3: [600, 500, 500, 450],
            2: [500, 600, 500, 500],
            1: [400, 500, 600, 550],
        ]
        for (offset, amounts) in amountsByDayOffset {
            guard let day = calendar.date(byAdding: .day, value: -offset, to: today) else { continue }
            for (index, amount) in amounts.enumerated() {
                let timestamp = calendar.date(byAdding: .hour, value: 8 + index * 3, to: day) ?? day
                context.insert(WaterEntry(amountML: amount, timestamp: timestamp))
            }
        }
        try? context.save()
    }
    #endif
}
