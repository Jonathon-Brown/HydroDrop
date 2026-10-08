#if DUO_V2
import Foundation

// STUB (foundation). Stage B replaces this whole file; the initialiser is the one
// `DuoComposition` calls. The credential accessor is what the API client reads.

final class DuoIdentity: DuoIdentityProviding, @unchecked Sendable {
    private let dependencies: DuoDependencies

    @MainActor init(dependencies: DuoDependencies) { self.dependencies = dependencies }
    /// Stage B's initialiser takes the folder its files live in; the composition passes one in a test.
    @MainActor init(dependencies: DuoDependencies, directory: URL) { self.dependencies = dependencies }

    var credential: DuoCredential? { nil }
    var installDay: String { DayKey.key(for: Date()) }
    func store(_ credential: DuoCredential) throws {}
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() {}
    func prepare() async -> DuoIdentityLaunch { .none }
    func continueAsRestored() async {}
}
#endif
