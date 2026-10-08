#if DUO_V2
import Foundation

// STUB (foundation). Stage F replaces this whole file; the initialiser is the one
// `DuoComposition` calls.

@MainActor
final class DuoBackground: DuoBackgrounding {
    private let dependencies: DuoDependencies

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    func scheduleRefresh() {}
}
#endif
