#if DUO_V2
import XCTest
@testable import HydroDrop

private final class MigrationReadStore: DuoSecretStore, @unchecked Sendable {
    let memory = DuoMemorySecretStore()
    var failCredentialRead = true
    func read(service: String, account: String) throws -> Data? {
        if service == DuoSecrets.service && account == DuoSecrets.deviceAccount && failCredentialRead {
            throw CocoaError(.fileReadNoPermission)
        }
        return try memory.read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try memory.write(data, service: service, account: account, accessibility: accessibility)
    }
    func delete(service: String, account: String) throws { try memory.delete(service: service, account: account) }
    func deleteAll(service: String) throws { try memory.deleteAll(service: service) }
}

@MainActor
final class DuoAgePolicyMigrationTests: XCTestCase {
    private func legacy(_ kit: DuoTestKit) {
        kit.defaults.set("allowed", forKey: DuoCache.ageStatusKey)
        kit.defaults.removeObject(forKey: DuoCache.agePolicyKey)
    }
    func testLegacyApprovalPausesNetworkAcrossWipeAndRecreation() {
        let kit = DuoTestKit()
        legacy(kit)
        XCTAssertTrue(kit.store.cache.needsAgeRecheck)
        XCTAssertEqual(kit.store.cache.ageStatus, .unknown)
        XCTAssertFalse(kit.dependencies.ageNetworkAllowed)
        XCTAssertEqual(kit.dependencies.ageNetworkGate.state, .unavailable)
        kit.store.cache.clearEverything()
        kit.store.forgetAnAllowedAge()
        XCTAssertTrue(DuoCache(defaults: kit.defaults).needsAgeRecheck)
        XCTAssertFalse(kit.dependencies.ageNetworkAllowed)
        XCTAssertFalse(kit.dependencies.cache.ageCheckUnavailable, "policy recheck is not a Keychain failure")
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1), .allowed)
        XCTAssertFalse(kit.store.needsAgeRecheck)
        XCTAssertTrue(kit.dependencies.ageNetworkAllowed)
        XCTAssertEqual(kit.defaults.integer(forKey: DuoCache.agePolicyKey), 2)
    }
    func testLegacyApprovalAlreadyPresentAtLaunchRequestsWidgetReload() throws {
        let suite = "DuoAgeMigration.\(UUID().uuidString)"
        DuoSuiteJanitor.shared.track(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set("allowed", forKey: DuoCache.ageStatusKey)
        let cache = DuoCache(defaults: defaults)
        var reloads = 0
        let store = DuoStore(cache: cache, reloadWidget: { reloads += 1 })
        let d = DuoDependencies(host: store, cache: cache, secrets: DuoSecrets(store: DuoMemorySecretStore()), client: DuoClientInfo(marketingVersion: "2.0", build: "57"), attester: FakeDuoAttester(), deviceCheck: FakeDuoDeviceCheck())
        d.identity = FakeDuoIdentity()
        store.install(d)
        XCTAssertTrue(store.needsAgeRecheck)
        XCTAssertGreaterThan(reloads, 0, "invalidate an older widget timeline even if the gate started unavailable")
    }

    func testLegacyApprovalCannotExposePartnerInWidgetBeforeAppLaunch() {
        let kit = DuoTestKit()
        legacy(kit)
        let cache = DuoCache(defaults: kit.defaults)
        let now = Date()
        let duo = DuoState(id: UUID(), myRole: .owner, createdAt: now, ownerDisplayName: "Jo", partnerDisplayName: "Private partner", ownerSkin: "classic", partnerSkin: "classic", statuses: [], partnerHasJoined: true)
        cache.saveDuos([duo])
        let model = DuoWidgetModel.make(duos: cache.loadDuos(), ageStatus: cache.ageStatus, ageCheckUnavailable: false, now: now, snapshotDay: DayKey.key(for: now), snapshotTotalML: 0, snapshotGoalML: 2000)
        XCTAssertEqual(model.state, .unavailable, "neutral, never \"No duo yet\" over a running duo")
        XCTAssertEqual(model.partnerName, "")
    }
    func testRefusalAlwaysWinsOverPolicyAndLaterAdultAnswer() throws {
        let kit = DuoTestKit()
        legacy(kit)
        try kit.dependencies.secrets.markAgeRefused()
        kit.store.recheckAge()
        XCTAssertEqual(kit.store.ageStatus, .refused)
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1), .refused)
        XCTAssertEqual(kit.dependencies.ageNetworkGate.state, .refused)
        XCTAssertEqual(kit.defaults.integer(forKey: DuoCache.agePolicyKey), 0)
    }
    func testRetainedCredentialWithLostDefaultsStopsBeforeIdentityLaunch() async throws {
        let suite = "DuoAgeMigration.\(UUID().uuidString)"
        DuoSuiteJanitor.shared.track(suite)
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let secrets = DuoMemorySecretStore()
        try DuoSecrets(store: secrets).save(DuoFixtures.credential())
        let session = RecordingSession()
        let attester = FakeDuoAttester()
        let deviceCheck = DuoReviewCountingDeviceCheck()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = DuoComposition.makeLiveStore(session: session, secretStore: secrets, cache: DuoCache(defaults: defaults), attester: attester, deviceCheck: deviceCheck, identityDirectory: folder)
        XCTAssertTrue(store.needsAgeRecheck)
        XCTAssertEqual(store.ageStatus, .unknown)
        _ = await store.dependencies?.identity.prepare()
        XCTAssertTrue(session.requests.isEmpty)
        XCTAssertEqual(attester.attestedNewKeys, 0)
        XCTAssertTrue(attester.assertions.isEmpty)
        XCTAssertEqual(deviceCheck.calls, 0)
        XCTAssertEqual(store.dependencies?.ageNetworkGate.state, .unavailable)
    }

    func testCredentialReadFailureCannotApproveAndRecoveryStillRechecks() throws {
        let kit = DuoTestKit()
        legacy(kit)
        let secrets = MigrationReadStore()
        try DuoSecrets(store: secrets).save(DuoFixtures.credential())
        let d = DuoDependencies(host: kit.store, cache: kit.store.cache, secrets: DuoSecrets(store: secrets), clock: kit.clock, random: kit.random, client: kit.dependencies.client, attester: kit.attester, deviceCheck: FakeDuoDeviceCheck())
        d.identity = kit.identity
        kit.store.install(d)
        XCTAssertTrue(kit.store.ageCheckUnavailable)
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1), .unknown)
        XCTAssertEqual(kit.defaults.integer(forKey: DuoCache.agePolicyKey), 0)
        secrets.failCredentialRead = false
        kit.store.recheckAge()
        XCTAssertFalse(kit.store.ageCheckUnavailable)
        XCTAssertTrue(kit.store.needsAgeRecheck)
        XCTAssertFalse(d.ageNetworkAllowed)
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1), .allowed)
        XCTAssertTrue(d.ageNetworkAllowed)
    }

    func testRealDeleteUsesHeldCredentialWithoutPreparationOrDeviceCheck() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        legacy(kit)
        let check = DuoReviewCountingDeviceCheck()
        kit.dependencies.deviceCheck = check
        kit.transport.onDeleteMe = { _, _ in }
        let service = DuoExitService(dependencies: kit.dependencies)
        let deleted = await service.deleteMyData()
        XCTAssertTrue(deleted)
        XCTAssertEqual(kit.identity.prepared, 0)
        XCTAssertEqual(check.calls, 0)
        XCTAssertEqual(kit.transport.calls.count, 1)
        guard case .deleteMe(let request, _) = kit.transport.calls.first else { return XCTFail("only DELETE") }
        XCTAssertNil(request.deviceCheckToken)
    }

    func testExplicitRecheckRestartsExistingWorkWithoutPermissionReason() async {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        legacy(kit)
        XCTAssertFalse(kit.dependencies.ageNetworkAllowed)
        await kit.store.resumeAfterAgeRecheck()
        XCTAssertTrue(kit.sync.calls.isEmpty)
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1), .allowed)
        await kit.store.resumeAfterAgeRecheck()
        XCTAssertEqual(kit.identity.prepared, 1)
        XCTAssertTrue(kit.sync.calls.contains("refresh"))
        XCTAssertEqual(kit.ops.drains, 1)
        XCTAssertEqual(kit.push.reasons, [.launch])
        XCTAssertEqual(kit.background.scheduled, 1)
    }

    func testPendingRecheckStillAllowsOnlyDeletionAtTransportGate() async throws {
        let kit = DuoTestKit()
        legacy(kit)
        XCTAssertFalse(kit.dependencies.ageNetworkAllowed)
        do {
            _ = try await kit.dependencies.ageNetworkGate.run { true }
            XCTFail("ordinary request must not start")
        } catch is CancellationError {} catch { XCTFail("unexpected error: \(error)") }
        let deleted = try await kit.dependencies.ageNetworkGate.run(deletion: true) { true }
        XCTAssertTrue(deleted)
    }
}
#endif
