#if DUO_V2
import Foundation

// STUB (foundation). Stage E replaces this whole file; the initialiser is the one
// `DuoComposition` calls.

@MainActor
final class DuoOpQueueService: DuoOpQueueing {
    private let dependencies: DuoDependencies

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    var pending: [DuoQueuedOp] { [] }
    func enqueue(_ op: DuoQueuedOp) {}
    func drain() async {}
    func startMonitoring() {}
    func discardAll() {}
}
#endif
