#if DUO_V2
import Foundation

// STUB (foundation). Stage E replaces this whole file; the initialiser is the one
// `DuoComposition` calls.

@MainActor
final class DuoExitService: DuoExiting {
    private let dependencies: DuoDependencies

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    func leave(_ duo: DuoState) async {}
    func block(_ duo: DuoState) async {}
    func clear(_ duo: DuoState) {}
    func deleteMyData() async -> Bool { false }
    func startFresh() {}
}
#endif
