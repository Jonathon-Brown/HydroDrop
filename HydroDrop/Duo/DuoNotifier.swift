#if DUO_V2
import Foundation

// STUB (foundation). Stage F replaces this whole file; the initialiser is the one
// `DuoComposition` calls.

@MainActor
final class DuoNotifier: DuoAnnouncing {
    private let dependencies: DuoDependencies

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    func deliver(_ announcements: [DuoAnnouncement], now: Date) async -> [String] { [] }
    func hasDeliveredRemote(forKey key: String) async -> Bool { false }
    func removeDelivered(for duoID: UUID) {}
    func removeAllDelivered() {}
}
#endif
