import SwiftUI
import SwiftData

@main
struct HydroDropApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: WaterEntry.self)
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
}
