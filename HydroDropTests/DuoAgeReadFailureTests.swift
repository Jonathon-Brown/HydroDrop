#if DUO_V2
import XCTest
@testable import HydroDrop

/// Only the age-service read fails. Other Keychain operations retain their real fake behavior.
private final class AgeReadFailureStore: DuoSecretStore, @unchecked Sendable {
    let memory = DuoMemorySecretStore()
    private let lock = NSLock()
    private var blocked = true
    func allowReads() { lock.lock(); blocked = false; lock.unlock() }
    func read(service: String, account: String) throws -> Data? {
        lock.lock(); let fails = blocked; lock.unlock()
        if service == DuoSecrets.ageService && fails { throw CocoaError(.fileReadNoPermission) }
        return try memory.read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try memory.write(data, service: service, account: account, accessibility: accessibility)
    }
    func delete(service: String, account: String) throws { try memory.delete(service: service, account: account) }
    func deleteAll(service: String) throws { try memory.deleteAll(service: service) }
}

@MainActor
final class DuoAgeReadFailureTests: XCTestCase {
    private func install(_ secretStore: AgeReadFailureStore, on kit: DuoTestKit) {
        let original = kit.dependencies
        let dependencies = DuoDependencies(host: kit.store, cache: original.cache,
            secrets: DuoSecrets(store: secretStore), clock: kit.clock, random: kit.random,
            client: original.client, attester: kit.attester, deviceCheck: FakeDuoDeviceCheck())
        dependencies.joining = kit.joining
        kit.store.install(dependencies)
    }

    func testUnreadableRefusalCannotBeReplacedByAnAllowedAnswer() async throws {
        let secretStore = AgeReadFailureStore()
        try DuoSecrets(store: secretStore).markAgeRefused()
        let kit = DuoTestKit()
        install(secretStore, on: kit)
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1), .unknown)
        XCTAssertEqual(kit.dependencies.cache.ageStatus, .unknown)
        _ = await kit.store.createDuo(named: nil)
        XCTAssertTrue(kit.joining.calls.isEmpty)
        secretStore.allowReads()
        kit.store.recheckAge()
        XCTAssertEqual(kit.store.ageStatus, .refused)
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1), .refused)
    }

    func testReadFailureDoesNotCreateAPermanentRefusal() {
        let secretStore = AgeReadFailureStore()
        let kit = DuoTestKit()
        install(secretStore, on: kit)
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1), .unknown)
        XCTAssertTrue(secretStore.memory.accounts(service: DuoSecrets.ageService).isEmpty)
        secretStore.allowReads()
        kit.store.recheckAge()
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1), .allowed)
    }

    func testCachedAllowedAnswerCannotBypassAnUnreadableRefusal() {
        let secretStore = AgeReadFailureStore()
        let kit = DuoTestKit()
        kit.store.recordBirthYear(1990, month: 1)
        install(secretStore, on: kit)
        XCTAssertEqual(kit.store.ageStatus, .unknown)
        XCTAssertEqual(kit.dependencies.cache.ageStatus, .allowed, "temporary failure does not rewrite consent")
        secretStore.allowReads()
        kit.store.recheckAge()
        XCTAssertEqual(kit.store.ageStatus, .allowed)
    }
    func testKnownRefusalClearsPendingInviteEvenWhenKeychainCannotBeRead() {
        let secretStore = AgeReadFailureStore()
        let kit = DuoTestKit()
        kit.dependencies.cache.ageStatus = .refused
        kit.store.pendingInvite = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: kit.clock.now)
        install(secretStore, on: kit)
        XCTAssertEqual(kit.store.ageStatus, .refused)
        XCTAssertNil(kit.store.pendingInvite)
        XCTAssertNil(kit.dependencies.cache.loadPendingInvite())
        XCTAssertTrue(kit.store.ageCheckUnavailable)
    }

}
#endif
