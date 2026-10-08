#if DUO_V2
import Foundation

// STUB (foundation). Stage F replaces this whole file; the initialiser is the one
// `DuoComposition` calls.

@MainActor
final class DuoPushService: DuoPushRegistering {
    private let dependencies: DuoDependencies

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    func tokenArrived(_ token: Data, environment: DuoAPNsEnvironment) {}
    func reevaluate(_ reason: DuoPushUploadReason) {}
    func noLiveDuoRemains() {}
    func opFinished(_ op: DuoQueuedOp, succeeded: Bool) {}
}
#endif
