#if DUO_V2
import Security
import XCTest
@testable import HydroDrop

/// `KeychainDuoSecretStore` against the test host's real Keychain. Every item lives under a
/// service of its own, `us.hydrodrop.duo.tests.<uuid>`, deleted afterwards; nothing here reads
/// or writes Duo's real services.
final class DuoKeychainTests: XCTestCase {
    private let store = KeychainDuoSecretStore()
    private var services: [String] = []

    private func makeService(_ suffix: String = "") -> String {
        let service = "us.hydrodrop.duo.tests.\(UUID().uuidString)\(suffix)"
        services.append(service)
        return service
    }

    override func tearDown() {
        for service in services {
            try? store.deleteAll(service: service)
            XCTAssertTrue(attributes(service: service).isEmpty, "the test left an item under \(service)")
        }
        services = []
        super.tearDown()
    }

    /// Every item under `service`, synchronizable or not, as the Keychain describes it.
    private func attributes(service: String) -> [[String: Any]] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrSynchronizable as String: kSecAttrSynchronizableAny,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { return [] }
        return (result as? [[String: Any]]) ?? []
    }

    private func attributes(service: String, account: String) -> [String: Any]? {
        attributes(service: service).first { ($0[kSecAttrAccount as String] as? String) == account }
    }

    // MARK: - Round trip

    func testAnItemRoundTripsIsOverwrittenAndDeleted() throws {
        let service = makeService()
        XCTAssertNil(try store.read(service: service, account: "device"), "a missing item is nil, not an error")

        try store.write(Data("first".utf8), service: service, account: "device", accessibility: .afterFirstUnlock)
        XCTAssertEqual(try store.read(service: service, account: "device"), Data("first".utf8))

        try store.write(Data("second".utf8), service: service, account: "device", accessibility: .afterFirstUnlock)
        XCTAssertEqual(try store.read(service: service, account: "device"), Data("second".utf8), "a write is add-or-update")
        XCTAssertEqual(attributes(service: service).count, 1, "and an update, not a second item")

        try store.delete(service: service, account: "device")
        XCTAssertNil(try store.read(service: service, account: "device"))
        XCTAssertNoThrow(try store.delete(service: service, account: "device"), "deleting what is not there is not an error")
    }

    func testAccountsUnderOneServiceAreSeparate() throws {
        let service = makeService()
        try store.write(Data([1]), service: service, account: "device", accessibility: .afterFirstUnlock)
        try store.write(Data([2]), service: service, account: "install-marker", accessibility: .afterFirstUnlockThisDeviceOnly)
        try store.delete(service: service, account: "device")
        XCTAssertNil(try store.read(service: service, account: "device"))
        XCTAssertEqual(try store.read(service: service, account: "install-marker"), Data([2]))
    }

    func testTheSameAccountUnderAnotherServiceIsAnotherItem() throws {
        let first = makeService()
        let second = makeService()
        try store.write(Data([1]), service: first, account: "device", accessibility: .afterFirstUnlock)
        XCTAssertNil(try store.read(service: second, account: "device"))
    }

    // MARK: - Attributes

    func testEachAccessibilityIsKeptAsAskedAndNothingIsSynchronizable() throws {
        let service = makeService()
        try store.write(Data([1]), service: service, account: "device", accessibility: .afterFirstUnlock)
        try store.write(Data([2]), service: service, account: "install-marker", accessibility: .afterFirstUnlockThisDeviceOnly)

        let credential = try XCTUnwrap(attributes(service: service, account: "device"))
        let marker = try XCTUnwrap(attributes(service: service, account: "install-marker"))
        XCTAssertEqual(credential[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String,
                       "the credential comes back with a restore, so a reinstall can notice it (§3.2)")
        XCTAssertEqual(marker[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String,
                       "the marker never leaves this phone")
        for item in [credential, marker] {
            XCTAssertEqual((item[kSecAttrSynchronizable as String] as? NSNumber)?.boolValue ?? false, false,
                           "an iCloud Keychain copy would make two phones one member")
        }
    }

    func testAnOverwriteTakesTheNewAccessibility() throws {
        let service = makeService()
        try store.write(Data([1]), service: service, account: "device", accessibility: .afterFirstUnlockThisDeviceOnly)
        try store.write(Data([2]), service: service, account: "device", accessibility: .afterFirstUnlock)
        let item = try XCTUnwrap(attributes(service: service, account: "device"))
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
    }

    func testTheStoreAsksForNoAccessGroupAndNoAccessControl() {
        let query = KeychainDuoSecretStore.itemQuery(service: "s", account: "a")
        XCTAssertNil(query[kSecAttrAccessGroup as String])
        XCTAssertNil(query[kSecAttrAccessControl as String])
        XCTAssertEqual(query[kSecAttrSynchronizable as String] as? Bool, false, "said in every query, not left to a default")
    }

    // MARK: - deleteAll

    /// The age refusal lives under `us.hydrodrop.duo.age`, whose name starts with the wiped
    /// service's. A prefix match would take the refusal with every wipe, and deleting and
    /// reinstalling the app would then undo it (SC §3.6 item 5, D60).
    func testDeleteAllMatchesTheServiceExactlyNeverAsAPrefix() throws {
        XCTAssertTrue(DuoSecrets.ageService.hasPrefix(DuoSecrets.service), "the real names share a prefix, which is why this matters")

        let service = makeService()
        let ageLike = service + ".age"
        let longer = service + "x"
        services.append(contentsOf: [ageLike, longer])
        try store.write(Data([1]), service: service, account: "device", accessibility: .afterFirstUnlock)
        try store.write(Data([2]), service: service, account: "k.6d2a0000-0000-4000-8000-000000000001", accessibility: .afterFirstUnlock)
        try store.write(Data([3]), service: service, account: "attest.6d2a0000-0000-4000-8000-0000000000bb",
                        accessibility: .afterFirstUnlockThisDeviceOnly)
        try store.write(Data([1]), service: ageLike, account: DuoSecrets.ageRefusedAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        try store.write(Data([4]), service: longer, account: "device", accessibility: .afterFirstUnlock)

        try store.deleteAll(service: service)

        XCTAssertTrue(attributes(service: service).isEmpty, "every account under the service, whatever it is called")
        XCTAssertEqual(try store.read(service: ageLike, account: DuoSecrets.ageRefusedAccount), Data([1]), "the refusal survives the wipe")
        XCTAssertEqual(try store.read(service: longer, account: "device"), Data([4]))
        XCTAssertNoThrow(try store.deleteAll(service: service), "wiping an empty service is not an error")
    }

    /// Through `DuoSecrets`, as Delete my Duo data and "Start fresh" call it, with the two real
    /// service names swapped for test ones by a store that maps them (the real names are never
    /// touched by a test).
    func testDeleteEverythingLeavesTheAgeRefusal() throws {
        let wiped = makeService()
        let kept = wiped + ".age"
        services.append(kept)
        let secrets = DuoSecrets(store: BServiceMappingStore(base: store, map: [DuoSecrets.service: wiped, DuoSecrets.ageService: kept]))
        try secrets.save(DuoFixtures.credential())
        try secrets.writeInstallMarker(random: TestRandom())
        try secrets.saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: DuoFixtures.duoID)
        try secrets.markAgeRefused()

        try secrets.deleteEverything()

        XCTAssertNil(secrets.credential())
        XCTAssertFalse(secrets.hasInstallMarker())
        XCTAssertNil(secrets.linkSecret(forDuo: DuoFixtures.duoID))
        XCTAssertTrue(attributes(service: wiped).isEmpty)
        XCTAssertTrue(secrets.isAgeRefused(), "neither Delete my Duo data nor Start fresh removes it (D60)")
        let refusal = try XCTUnwrap(attributes(service: kept, account: DuoSecrets.ageRefusedAccount))
        XCTAssertEqual(refusal[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }

    /// Simulator only: on a phone signed in to iCloud Keychain a synchronizable item would reach
    /// every other device of the account, and stay there if the run stopped before the delete.
    func testDeleteAllAlsoTakesASynchronizableItemThatReadsNeverSee() throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("adds a synchronizable item, which a real phone could sync to iCloud Keychain")
        #else
        let service = makeService()
        let add: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: "device",
            kSecAttrSynchronizable as String: true,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock,
            kSecValueData as String: Data([9]),
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw XCTSkip("this Keychain does not take synchronizable items (\(status))") }

        XCTAssertNil(try store.read(service: service, account: "device"), "this store never reads an iCloud Keychain item as Duo's")
        try store.deleteAll(service: service)
        XCTAssertTrue(attributes(service: service).isEmpty, "but a wipe leaves nothing under the name")
        #endif
    }

    func testACredentialRoundTripsThroughDuoSecrets() throws {
        let service = makeService()
        let secrets = DuoSecrets(store: BServiceMappingStore(base: store, map: [DuoSecrets.service: service]))
        XCTAssertNil(secrets.credential())
        try secrets.save(DuoFixtures.credential())
        XCTAssertEqual(secrets.credential(), DuoFixtures.credential())
        let item = try XCTUnwrap(attributes(service: service, account: DuoSecrets.deviceAccount))
        XCTAssertEqual(item[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlock as String)
        try secrets.writeInstallMarker(random: TestRandom())
        XCTAssertTrue(secrets.hasInstallMarker())
        let marker = try XCTUnwrap(attributes(service: service, account: DuoSecrets.installMarkerAccount))
        XCTAssertEqual(marker[kSecAttrAccessible as String] as? String, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly as String)
    }
}

/// Sends Duo's real service names to test ones, so `DuoSecrets` can be driven against the real
/// Keychain without ever touching an item the app keeps.
fileprivate final class BServiceMappingStore: DuoSecretStore, @unchecked Sendable {
    let base: DuoSecretStore
    let map: [String: String]

    init(base: DuoSecretStore, map: [String: String]) {
        self.base = base
        self.map = map
    }

    private struct Unmapped: Error {}

    private func mapped(_ service: String) throws -> String {
        guard let target = map[service] else {
            XCTFail("a test touched an unmapped service: \(service)")
            throw Unmapped()
        }
        return target
    }

    func read(service: String, account: String) throws -> Data? { try base.read(service: try mapped(service), account: account) }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try base.write(data, service: try mapped(service), account: account, accessibility: accessibility)
    }
    func delete(service: String, account: String) throws { try base.delete(service: try mapped(service), account: account) }
    func deleteAll(service: String) throws { try base.deleteAll(service: try mapped(service)) }
}
#endif
