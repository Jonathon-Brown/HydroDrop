#if DUO_V2
import Foundation
import SwiftData

// STUB (foundation). Stage C replaces this whole file with the SwiftData reader. `HydroDropApp`
// (stage F's seam) calls `DuoStore.shared.activate(logReader: SwiftDataDuoLogReader(container: container))`.

@MainActor
final class SwiftDataDuoLogReader: DuoLogReading {
    init(container: ModelContainer) {}
    func read(now: Date) -> DuoLogSummary { .empty }
}
#endif
