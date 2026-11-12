#if DUO_V2
import XCTest
@testable import HydroDrop

private final class ToggleAgeSecretStore: DuoSecretStore, @unchecked Sendable {
    let memory = DuoMemorySecretStore()
    private let lock = NSLock()
    private var unreadable = false
    private var readCount = 0
    var reads: Int { lock.withLock { readCount } }
    func setUnreadable(_ value: Bool) { lock.withLock { unreadable = value } }
    func read(service: String, account: String) throws -> Data? {
        lock.withLock { readCount += 1 }
        if service == DuoSecrets.ageService, lock.withLock({ unreadable }) { throw CocoaError(.fileReadNoPermission) }
        return try memory.read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try memory.write(data, service: service, account: account, accessibility: accessibility)
    }
    func delete(service: String, account: String) throws { try memory.delete(service: service, account: account) }
    func deleteAll(service: String) throws { try memory.deleteAll(service: service) }
}

private final class CountingAgeDeviceCheck: DuoDeviceCheckProviding, @unchecked Sendable {
    let isSupported = true
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }
    func token() async -> String? { lock.withLock { count += 1 }; return "token" }
}

@MainActor
private final class DeadOwnerBackgroundProbe: DuoBackgrounding, DuoAgeNetworkStopping {
    var calls = 0
    func scheduleRefresh() { calls += 1 }
    func stopForAgeNetwork(refused: Bool) { calls += 1 }
}

@MainActor
final class DuoAgeNetworkTests: XCTestCase {
    func testADeadOwnerClosesAnOpenAgeGateWithoutReadingStorage() throws {
        try checkDeadOwnerAgeGate(refused: false, unreadable: false)
    }

    func testADeadOwnerDoesNotPublishALaterRefusal() throws {
        try checkDeadOwnerAgeGate(refused: true, unreadable: false)
        try checkDeadOwnerAgeGate(refused: true, unreadable: false, alreadyRefused: true)
    }

    func testADeadOwnerDoesNotPublishALaterStorageFailure() throws {
        try checkDeadOwnerAgeGate(refused: false, unreadable: true)
    }

    private func checkDeadOwnerAgeGate(refused: Bool, unreadable: Bool, alreadyRefused: Bool = false) throws {
        let backing = ToggleAgeSecretStore()
        let secrets = DuoSecrets(store: backing)
        let probe = DeadOwnerBackgroundProbe()
        var widgetReloads = 0
        var dependencies: DuoDependencies!
        weak var dropped: DuoStore?
        do {
            let store = DuoStore(cache: DuoCache(defaults: UserDefaults(suiteName: "DuoAgeNetworkTests.\(UUID().uuidString)")!),
                                 usesServer: true, reloadWidget: { widgetReloads += 1 })
            store.cache.recordConfirmedAgeStatus(.allowed)
            dependencies = DuoDependencies(host: store, cache: store.cache, secrets: secrets,
                                           client: DuoClientInfo(marketingVersion: "2.0", build: "1"),
                                           attester: FakeDuoAttester(), deviceCheck: FakeDuoDeviceCheck())
            XCTAssertTrue(dependencies.ageNetworkAllowed)
            dependencies.background = probe
            if alreadyRefused {
                _ = dependencies.ageNetworkGate.transition(to: .refused)
                store.cache.ageStatus = .refused
            }
            dropped = store
        }
        XCTAssertNil(dropped)
        if refused { try secrets.markAgeRefused() }
        backing.setUnreadable(unreadable)
        let reads = backing.reads
        let reloads = widgetReloads
        XCTAssertFalse(dependencies.ageNetworkAllowed, "no service may send after its store is gone")
        XCTAssertNotEqual(dependencies.ageNetworkGate.state, .open)
        XCTAssertEqual(backing.reads, reads, "orphaned services must not read storage")
        XCTAssertEqual(dependencies.cache.ageStatus, alreadyRefused ? .refused : .allowed, "the dead store's cache must not be rewritten")
        XCTAssertFalse(dependencies.cache.ageCheckUnavailable)
        XCTAssertEqual(probe.calls, 0)
        XCTAssertEqual(widgetReloads, reloads)
        if alreadyRefused { XCTAssertEqual(dependencies.ageNetworkGate.state, .refused) }
    }

    func testRefusalStopsEveryStoreSyncAndMembershipEntryPoint() async {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.recordBirthYear(Calendar.current.component(.year, from: Date()), month: 1)
        let duo = DuoFixtures.duo()
        kit.store.activate(logReader: FakeLogReader())
        kit.store.logChanged(entries: [], goalML: 2000)
        kit.store.scheduleBackgroundRefresh()
        kit.store.pushTokenArrived(Data([1]), environment: .sandbox)
        await kit.store.pushArrived(DuoPushPayload(duoID: duo.id, seq: 1, kind: .joined))
        await kit.store.refresh()
        await kit.store.flush()
        _ = await kit.store.backgroundRefresh()
        await kit.store.duoScreenOpened()
        await kit.store.sendNudge(.waterBreak, in: duo)
        _ = await kit.store.newInvite(for: duo)
        _ = await kit.store.createReconnectCode(for: duo)
        _ = await kit.store.createLinkCode()
        await kit.store.changeMyName("Name")
        await kit.store.leave(duo)
        await kit.store.block(duo)
        await kit.store.continueAsRestored()
        await kit.store.refusalDeletionTask?.value
        // Activating sends nothing and is not gated (finding 9).
        XCTAssertEqual(kit.sync.calls, ["activate"])
        XCTAssertTrue(kit.joining.calls.isEmpty)
        // The refusal's one DELETE /me (decision a), and no leave or block.
        XCTAssertEqual(kit.exiting.calls, ["deleteMyData"])
        XCTAssertTrue(kit.push.tokens.isEmpty)
        XCTAssertEqual(kit.background.scheduled, 0)
        XCTAssertEqual(kit.identity.prepared, 0)
        XCTAssertEqual(kit.identity.continued, 0)
    }

    func testTemporaryFailurePausesQueueAndWidgetWhileKnownRefusalDiscardsQueue() throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let secrets = ToggleAgeSecretStore()
        let d = DuoDependencies(host: kit.store, cache: kit.dependencies.cache, secrets: DuoSecrets(store: secrets),
                                clock: kit.clock, random: kit.random, client: kit.dependencies.client,
                                attester: kit.attester, deviceCheck: FakeDuoDeviceCheck())
        d.identity = kit.identity
        let ops = DuoOpQueueService(dependencies: d)
        d.ops = ops
        kit.store.install(d)
        d.cache.recordConfirmedAgeStatus(.allowed)
        let op = try DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: .value("Name")),
                                          key: UUID().uuidString.lowercased(), now: kit.clock.now)
        ops.enqueue(op)
        XCTAssertEqual(ops.pending.count, 1)
        secrets.setUnreadable(true)
        kit.store.recheckAge()
        XCTAssertEqual(d.ageNetworkGate.state, .unavailable)
        XCTAssertTrue(d.cache.ageCheckUnavailable)
        XCTAssertEqual(d.cache.ageStatus, .allowed)
        XCTAssertEqual(ops.pending.count, 1, "unreadable storage must not erase queued work")
        secrets.setUnreadable(false)
        kit.store.recheckAge()
        XCTAssertEqual(d.ageNetworkGate.state, .open)
        XCTAssertFalse(d.cache.ageCheckUnavailable)
        XCTAssertEqual(ops.pending.count, 1)
        try d.secrets.markAgeRefused()
        kit.store.recheckAge()
        XCTAssertEqual(d.ageNetworkGate.state, .refused)
        XCTAssertEqual(d.cache.ageStatus, .refused)
        XCTAssertTrue(ops.pending.isEmpty)
    }

    func testRefusedDeleteUsesHeldCredentialWithoutPreparingOrCallingApple() async {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let token = CountingAgeDeviceCheck()
        kit.dependencies.deviceCheck = token
        kit.dependencies.exiting = DuoExitService(dependencies: kit.dependencies)
        kit.identity.launch = .unavailable
        kit.transport.onDeleteMe = { request, _ in XCTAssertNil(request.deviceCheckToken) }
        // The refusal itself sends it now (decision a), once.
        kit.store.recordBirthYear(Calendar.current.component(.year, from: Date()), month: 1)
        XCTAssertEqual(kit.store.refusalDeletion, .deleting)
        await kit.store.refusalDeletionTask?.value
        XCTAssertEqual(kit.store.refusalDeletion, .deleted)
        XCTAssertNil(kit.store.notice)
        XCTAssertTrue(kit.store.duos.isEmpty)
        XCTAssertEqual(kit.identity.prepared, 0)
        XCTAssertEqual(token.calls, 0)
        XCTAssertEqual(kit.transport.calls.count, 1)
        guard case .deleteMe = kit.transport.calls.first else { return XCTFail("only DELETE may be sent") }
        XCTAssertEqual(kit.store.ageStatus, .refused)
        XCTAssertEqual(kit.dependencies.cache.ageStatus, .refused)
    }

    /// Decision a: no identity, nothing to delete and nothing sent; a refusal already kept is not
    /// answered again, so the request goes once.
    func testARefusalWithNoIdentitySendsNothingAndARefusalIsAnsweredOnce() async {
        let fresh = DuoTestKit()
        fresh.store.recordBirthYear(Calendar.current.component(.year, from: Date()), month: 1)
        XCTAssertNil(fresh.store.refusalDeletionTask)
        XCTAssertNil(fresh.store.refusalDeletion)
        XCTAssertTrue(fresh.exiting.calls.isEmpty)
        XCTAssertNil(DuoAgeGateView.refusalDeletionLine(fresh.store.refusalDeletion, holdsIdentity: fresh.store.hasIdentity),
                     "the refusal screen says nothing about data a phone never held")

        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.store.recordBirthYear(Calendar.current.component(.year, from: Date()), month: 1)
        await kit.store.refusalDeletionTask?.value
        kit.store.recordBirthYear(Calendar.current.component(.year, from: Date()) - 3, month: 1)
        await kit.store.refusalDeletionTask?.value
        XCTAssertEqual(kit.exiting.calls, ["deleteMyData"])
    }

    /// Decision a: a delete that fails is said on the refusal screen with the way to try again, and
    /// not again in an alert once the sheet has gone.
    func testAFailedRefusalDeleteSaysWhereToDeleteByHand() async {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.dependencies.exiting = DuoExitService(dependencies: kit.dependencies)
        kit.transport.onDeleteMe = { _, _ in throw DuoTransportError.offline }
        kit.store.recordBirthYear(Calendar.current.component(.year, from: Date()), month: 1)
        await kit.store.refusalDeletionTask?.value
        XCTAssertEqual(kit.store.refusalDeletion, .failed)
        XCTAssertNil(kit.store.notice)
        XCTAssertTrue(kit.store.hasIdentity)
        XCTAssertEqual(DuoAgeGateView.refusalDeletionLine(.failed, holdsIdentity: true), DuoConsentFlow.NewCopy.refusalDataRemains)
        XCTAssertEqual(DuoAgeGateView.refusalDeletionLine(.deleted, holdsIdentity: false), DuoConsentFlow.NewCopy.refusalDeleted)
        XCTAssertEqual(DuoAgeGateView.refusalDeletionLine(.removedFromThisPhone, holdsIdentity: false), DuoUserMessage.removedFromThisPhoneOnly)
        XCTAssertFalse(kit.store.ageAllowsSharing)
    }

    /// Finding 2: a refusal takes back the Duo notifications already delivered, not only the ones
    /// still waiting.
    func testARefusalRemovesDeliveredDuoNotificationsToo() {
        let kit = DuoTestKit()
        kit.store.recordBirthYear(Calendar.current.component(.year, from: Date()), month: 1)
        XCTAssertGreaterThanOrEqual(kit.announcer.removedAll, 1)
        XCTAssertGreaterThanOrEqual(kit.announcer.removedPending, 1)
    }

    /// Finding 9: a launch whose Keychain the age check cannot read yet still activates the sync
    /// engine, which sends nothing, so the rest of the run reads the widget's and the Watch's drinks.
    func testActivationIsNotSkippedWhileTheAgeAnswerCannotBeRead() {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        let secrets = ToggleAgeSecretStore()
        secrets.setUnreadable(true)
        let d = DuoDependencies(host: kit.store, cache: kit.dependencies.cache, secrets: DuoSecrets(store: secrets),
                                clock: kit.clock, random: kit.random, client: kit.dependencies.client,
                                attester: kit.attester, deviceCheck: FakeDuoDeviceCheck())
        d.identity = kit.identity
        d.sync = kit.sync
        kit.store.install(d)
        XCTAssertTrue(kit.store.ageCheckUnavailable)
        kit.store.activate(logReader: FakeLogReader())
        XCTAssertEqual(kit.sync.calls, ["activate"])
    }

    /// Decision b: the thirteenth-birthday month records nothing, in the defaults or the Keychain,
    /// and sends nothing; the answer can be given again.
    func testTheThirteenthBirthdayMonthIsKeptNowhere() throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = .current
        let now = Date()
        let parts = gregorian.dateComponents([.year, .month], from: now)
        let year = try XCTUnwrap(parts.year) - 13, month = try XCTUnwrap(parts.month)
        XCTAssertEqual(kit.store.recordBirthYear(year, month: month, now: now), .unknown)
        XCTAssertEqual(kit.store.ageStatus, .unknown)
        XCTAssertEqual(kit.dependencies.cache.ageStatus, .unknown)
        XCTAssertFalse(try kit.dependencies.secrets.readAgeRefused())
        XCTAssertNil(kit.store.refusalDeletionTask)
        XCTAssertTrue(kit.exiting.calls.isEmpty)
        XCTAssertEqual(kit.store.recordBirthYear(1990, month: 1, now: now), .allowed, "not a refusal: asked again, it can pass")
    }

    /// Finding 5: a phone holding an identity without the rules (a reinstall clears them) is asked
    /// for them; accepting clears the question.
    func testAnIdentityWithoutTheRulesIsAskedForThem() async {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        XCTAssertEqual(kit.store.acceptedTermsVersion, 0)
        XCTAssertTrue(kit.store.needsTermsAgain)
        XCTAssertFalse(DuoTestKit().store.needsTermsAgain, "no identity, nothing to resume")
        _ = await kit.store.acceptTerms()
        XCTAssertFalse(kit.store.needsTermsAgain)
    }

    func testRefusedDeleteWithoutCredentialDoesNotClaimSuccess() async {
        let kit = DuoTestKit()
        kit.dependencies.exiting = DuoExitService(dependencies: kit.dependencies)
        kit.store.recordBirthYear(Calendar.current.component(.year, from: Date()), month: 1)
        let deleted = await kit.store.deleteMyData()
        XCTAssertFalse(deleted)
        XCTAssertEqual(kit.identity.prepared, 0)
        XCTAssertTrue(kit.transport.calls.isEmpty)
        XCTAssertEqual(kit.store.ageStatus, .refused)
    }

    func testNetworkChecksReloadWidgetAndCannotMirrorAnAllowedAnswerOverRefusal() throws {
        let kit = DuoTestKit()
        let secrets = ToggleAgeSecretStore()
        let cache = kit.dependencies.cache
        cache.recordConfirmedAgeStatus(.allowed)
        var reloads = 0
        let store = DuoStore(cache: cache, usesServer: true, reloadWidget: { reloads += 1 })
        let d = DuoDependencies(host: store, cache: cache, secrets: DuoSecrets(store: secrets),
                                clock: kit.clock, random: kit.random, client: kit.dependencies.client,
                                attester: kit.attester, deviceCheck: FakeDuoDeviceCheck())
        d.identity = kit.identity
        store.install(d)
        let initial = reloads
        secrets.setUnreadable(true)
        d.refreshAgeNetworkState()
        XCTAssertEqual(reloads, initial + 1)
        XCTAssertTrue(cache.ageCheckUnavailable)
        secrets.setUnreadable(false)
        d.refreshAgeNetworkState()
        XCTAssertEqual(reloads, initial + 2)
        XCTAssertFalse(cache.ageCheckUnavailable)
        store.pendingInvite = DuoPendingInvite(code: "H7K39QWX", k: nil, receivedAt: kit.clock.now)
        try d.secrets.markAgeRefused()
        d.refreshAgeNetworkState()
        XCTAssertEqual(reloads, initial + 3)
        XCTAssertNil(store.pendingInvite)
        XCTAssertEqual(store.ageStatus, .refused)
        cache.recordConfirmedAgeStatus(.allowed)
        try secrets.deleteAll(service: DuoSecrets.ageService)
        d.refreshAgeNetworkState()
        XCTAssertEqual(cache.ageStatus, .refused, "the gate's effective refusal is what widgets read")
        XCTAssertEqual(d.ageNetworkGate.state, .refused)
    }
}
#endif
