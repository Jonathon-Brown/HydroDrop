import SwiftUI
import SwiftData

@main
struct HydroDropApp: App {
    let container: ModelContainer

    init() {
        do {
            if ProcessInfo.processInfo.arguments.contains("-UITestSeedHistory") {
                let configuration = ModelConfiguration(isStoredInMemoryOnly: true)
                container = try ModelContainer(for: WaterEntry.self, configurations: configuration)
                Self.seedHistory(into: container)
            } else {
                container = try ModelContainer(for: WaterEntry.self)
            }
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        WatchSessionManager.shared.activate(modelContainer: container)
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
