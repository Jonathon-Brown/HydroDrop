#if DUO_V2
import Foundation

// STUB (foundation). Stage D replaces this whole file; the initialiser is the one
// `DuoComposition` calls.

@MainActor
final class DuoJoiningService: DuoJoining {
    private let dependencies: DuoDependencies

    init(dependencies: DuoDependencies) { self.dependencies = dependencies }

    func createDuo(named: String?, skin: String) async -> DuoState? { nil }
    func peek(code: String) async -> DuoPeek? { nil }
    func receive(_ invite: DuoParsedInvite, now: Date) {}
    func discardPendingInvite() {}
    func join(_ invite: DuoPendingInvite, named: String?, skin: String) async -> DuoState? { nil }
    func newInvite(for duo: DuoState) async -> DuoInvite? { nil }
    func createReconnectCode(for duo: DuoState) async -> DuoInvite? { nil }
    func createLinkCode() async -> DuoInvite? { nil }
    func reconnect(code: String) async -> Bool { false }
    func changeMyName(_ name: String?) async {}
    func acceptTerms() async -> Bool { true }
}
#endif
