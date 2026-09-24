import SwiftUI
import SwiftData

@main
struct HydroDropApp: App {
    let container: ModelContainer
    @Environment(\.scenePhase) private var scenePhase

    /// Collapses the duplicates a store migration leaves behind the moment CloudKit
    /// mirrors the legacy rows back down, rather than waiting for the next launch. Held
    /// for the app's lifetime so its notification observer stays registered.
    private let remoteChangeObserver: StoreRemoteChangeObserver

    init() {
        container = Self.makeContainer()
        remoteChangeObserver = StoreRemoteChangeObserver(container: container)
        remoteChangeObserver.start()
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
        // TestFlight builds 29 to 31 had an iCloud version of Duo Streaks that never
        // shipped. Clears what it left on a tester's phone; does nothing for anyone else.
        LegacyDuoCleanup.runOnce()
        ReminderManager.shared.registerCategories()
        // Published before any view appears, so a widget added while the app was
        // uninstalled has something true to draw as soon as the app is opened again.
        Self.publishWidgetSnapshot(from: container)
        AdManager.start()
    }

    /// Recomputes and publishes the widget snapshot from the store. Runs at launch and
    /// again every time the app returns to the foreground, so a widget that fell back to
    /// an empty view while the app was away is corrected the moment the app is active.
    private static func publishWidgetSnapshot(from container: ModelContainer) {
        WidgetPublisher.publish(
            context: ModelContext(container),
            isShared: SharedModelContainer.isShared(container)
        )
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
            // On disk rather than in memory. On iOS 27 a save into an in-memory store
            // raises an Objective-C exception that no Swift `catch` can intercept, and the
            // app dies partway through a UI test. Wiped on every launch, so each run still
            // starts from the same seeded state an in-memory store used to guarantee. This
            // lives in the app's own temporary directory and never touches the App Group
            // store the user's real data is in.
            let directory = URL.temporaryDirectory.appending(path: "HydroDropUITestStore")
            try? FileManager.default.removeItem(at: directory)
            // An in-memory store could not carry anything over from a previous launch. A
            // file can, so if the wipe did not take, say so instead of seeding on top of
            // a stale store and quietly capturing the wrong screenshot.
            if FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) {
                fatalError("Could not clear the seeded UI-test store at \(directory.path(percentEncoded: false))")
            }
            let configuration = ModelConfiguration(
                schema: SharedModelContainer.schema,
                url: directory.appending(path: "store.sqlite"),
                cloudKitDatabase: .none
            )
            guard (try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)) != nil,
                  let container = try? ModelContainer(for: SharedModelContainer.schema, configurations: configuration) else {
                fatalError("Failed to create the seeded ModelContainer for UI tests")
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
        // A widget can fall back to an empty view while the app is backgrounded (the day
        // rolled over, or the shared snapshot was never reached). Returning to the
        // foreground republishes the current state so the widget catches up without the
        // user having to log anything.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Self.publishWidgetSnapshot(from: container)
        }
        // Does nothing on purpose. A tester's phone can still hold a refresh scheduled
        // by the iCloud Duo in TestFlight builds 29 to 31, and a launch for a task with
        // no handler is a crash. See `LegacyDuoCleanup.refreshIdentifier`.
        .backgroundTask(.appRefresh(LegacyDuoCleanup.refreshIdentifier)) {}
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
