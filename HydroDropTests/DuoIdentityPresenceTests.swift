#if DUO_V2
import Combine
import XCTest
@testable import HydroDrop

private final class PresenceSecrets: DuoSecretStore, @unchecked Sendable {
    let memory = DuoMemorySecretStore()
    private let lock = NSLock()
    private var reads = 0
    private var locked = true
    var isLocked: Bool {
        get { lock.lock(); defer { lock.unlock() }; return locked }
        set { lock.lock(); locked = newValue; lock.unlock() }
    }
    var deviceReads: Int { lock.lock(); defer { lock.unlock() }; return reads }
    func read(service: String, account: String) throws -> Data? {
        if account == DuoSecrets.deviceAccount {
            lock.lock(); reads += 1; let unavailable = locked; lock.unlock()
            if unavailable { throw NSError(domain: "PresenceSecrets", code: 1) }
        }
        return try memory.read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try memory.write(data, service: service, account: account, accessibility: accessibility)
    }
    func deleteAll(service: String) throws { try memory.deleteAll(service: service) }
    func delete(service: String, account: String) throws { try memory.delete(service: service, account: account) }
}

@MainActor
final class DuoIdentityPresenceTests: XCTestCase {
    func testRenderingDoesNotRetryALockedKeychainAndRecoveryPublishes() async throws {
        let kit = DuoTestKit()
        let secrets = PresenceSecrets()
        try DuoSecrets(store: secrets.memory).save(DuoFixtures.credential())
        let dependencies = DuoDependencies(host: kit.store, cache: kit.store.cache, secrets: DuoSecrets(store: secrets),
            clock: kit.clock, random: kit.random, client: kit.dependencies.client,
            attester: kit.attester, deviceCheck: FakeDuoDeviceCheck())
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = DuoIdentity(dependencies: dependencies, directory: directory)
        dependencies.identity = identity
        kit.store.install(dependencies)
        let initialReads = secrets.deviceReads
        for _ in 0..<100 { XCTAssertFalse(kit.store.hasIdentity) }
        XCTAssertEqual(secrets.deviceReads, initialReads, "rendering never retries an unreadable Keychain")
        let changed = expectation(description: "identity recovery redraws the screen")
        var reported = false
        let watch = kit.store.objectWillChange.sink {
            XCTAssertTrue(Thread.isMainThread)
            if !reported { reported = true; changed.fulfill() }
        }
        secrets.isLocked = false
        XCTAssertNotNil(identity.credential, "an explicit service read can recover after unlock")
        await fulfillment(of: [changed], timeout: 3)
        XCTAssertTrue(kit.store.hasIdentity)
        identity.discard()
        XCTAssertFalse(kit.store.hasIdentity)
        try identity.store(DuoFixtures.credential())
        XCTAssertTrue(kit.store.hasIdentity)
        watch.cancel()
    }
}
#endif
