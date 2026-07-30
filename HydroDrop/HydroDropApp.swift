import SwiftUI
import SwiftData

@main
struct HydroDropApp: App {
    let container: ModelContainer

    init() {
        container = Self.makeContainer()
        WatchSessionManager.shared.activate(modelContainer: container)
    }

    /// Prefers an iCloud-backed store, but degrades to a local one rather than
    /// refusing to launch.
    ///
    /// CloudKit can be unavailable for reasons that are not the user's fault and
    /// that we cannot fix at runtime — a build signed without the iCloud
    /// entitlement, a container that hasn't been provisioned yet. None of those
    /// are worth trading a working offline app for, so local storage is the
    /// fallback and sync is the enhancement.
    private static func makeContainer() -> ModelContainer {
        if ProcessInfo.processInfo.arguments.contains("-UITestSeedHistory") {
            let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
            guard let container = try? ModelContainer(for: WaterEntry.self, configurations: configuration) else {
                fatalError("Failed to create in-memory ModelContainer for UI tests")
            }
            seedHistory(into: container)
            return container
        }

        do {
            return try ModelContainer(
                for: WaterEntry.self,
                configurations: ModelConfiguration(cloudKitDatabase: .automatic)
            )
        } catch {
            Diagnostics.log("iCloud store unavailable, falling back to local: \(error)")
        }

        do {
            return try ModelContainer(for: WaterEntry.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
        }
        .modelContainer(container)
    }

    /// Populates a week of realistic sample entries for App Store screenshot automation only.
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
}
