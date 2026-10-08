#if DUO_V2
import Foundation

// STUB (foundation). Stage C replaces this whole file; the initialiser is the one
// `DuoComposition` calls.

@MainActor
final class DuoSyncEngine: DuoSyncing {
    private let dependencies: DuoDependencies

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    func activate(logReader: DuoLogReading) {}
    func logChanged(_ summary: DuoLogSummary) {}
    func refresh() async {}
    func flush() async {}
    func backgroundRefresh() async -> Bool { false }
    func pushArrived(_ payload: DuoPushPayload) async {}
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async {}
}
#endif
