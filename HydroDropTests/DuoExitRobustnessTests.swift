#if DUO_V2
import Combine
import CryptoKit
import XCTest
@testable import HydroDrop

// The stage E review's findings, each as a test that failed against the reviewed code and passes
// with its fix (E1 to E19 in the vault note "stage-e-fixes"), ported from the three lenses'
// probes: deletion completeness (`LDFindingTests`), queue durability and ordering (`LQProbes`,
// and a trimmed `LQStressTests` against a model of the Worker's idempotency table), and user
// safety (`LSProbes`, with mutants M03 and M05). Kept apart from `DuoExitServiceTests` and
// `DuoOpQueueServiceTests`, which state the services' rules one by one; these state what went
// wrong in a way someone would live it.

// MARK: - Helpers (stage E, robustness)

/// Holds a request, or a delay, until the test lets it go.
fileprivate final class ERGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var entries = 0

    var entered: Int { lock.lock(); defer { lock.unlock() }; return entries }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            entries += 1
            if released {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let resumed = waiting
        waiting = []
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}

/// `FakeDuoTransport` with a gate in front of any of four calls.
fileprivate final class ERGatedTransport: DuoTransport, @unchecked Sendable {
    let base: FakeDuoTransport
    var leaveGate: ERGate?
    var updateMeGate: ERGate?
    var deleteGate: ERGate?
    var blockGate: ERGate?

    init(_ base: FakeDuoTransport) { self.base = base }

    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse {
        if let leaveGate { await leaveGate.wait() }
        return try await base.leave(duoID: duoID, key: key)
    }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember {
        if let updateMeGate { await updateMeGate.wait() }
        return try await base.updateMe(request)
    }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws {
        if let deleteGate { await deleteGate.wait() }
        try await base.deleteMe(request, key: key)
    }
    func block(duoID: String, key: DuoIdempotencyKey) async throws {
        if let blockGate { await blockGate.wait() }
        try await base.block(duoID: duoID, key: key)
    }
    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { try await base.createDevice(request) }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try await base.attestChallenge() }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { try await base.rotate(as: credential) }
    func me() async throws -> DuoWireGetMeResponse { try await base.me() }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { try await base.registerPush(request, firstUpload: firstUpload) }
    func unregisterPush() async throws { try await base.unregisterPush() }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { try await base.createDuo(request, key: key) }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { try await base.createInvite(duoID: duoID, purpose: purpose, key: key) }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try await base.peekInvite(code: code) }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { try await base.redeemInvite(request, key: key) }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { try await base.reconnect(request, key: key) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try await base.fetchDuo(id: id) }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try await base.fetchChanges(duoID: duoID, since: since) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { try await base.pushDayStatuses(duoID: duoID, request) }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try await base.sendNudge(duoID: duoID, request) }
}

fileprivate struct ERKeychainRefusal: Error {}

/// A memory Keychain that can refuse deletes: every one, or the first few.
fileprivate final class ERRefusingSecretStore: DuoSecretStore, @unchecked Sendable {
    let memory = DuoMemorySecretStore()
    private let lock = NSLock()
    private var refusalsLeft = 0
    private var wholeServiceDeletes = 0

    /// How many deletes, of one item or of a whole service, to refuse from now on.
    func refuse(_ count: Int) { lock.lock(); refusalsLeft = count; lock.unlock() }
    var deleteAllCalls: Int { lock.lock(); defer { lock.unlock() }; return wholeServiceDeletes }

    private func refused() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard refusalsLeft > 0 else { return false }
        refusalsLeft -= 1
        return true
    }

    func read(service: String, account: String) throws -> Data? { try memory.read(service: service, account: account) }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try memory.write(data, service: service, account: account, accessibility: accessibility)
    }
    func delete(service: String, account: String) throws {
        if refused() { throw ERKeychainRefusal() }
        try memory.delete(service: service, account: account)
    }
    func deleteAll(service: String) throws {
        lock.lock(); wholeServiceDeletes += 1; lock.unlock()
        if refused() { throw ERKeychainRefusal() }
        try memory.deleteAll(service: service)
    }
}

/// A push service that queues a new upload as soon as one is dropped, as the seam allows.
@MainActor
fileprivate final class ERRequeuingPush: DuoPushRegistering {
    weak var ops: DuoOpQueueService?
    private(set) var requeued = 0
    func tokenArrived(_ token: Data, environment: DuoAPNsEnvironment) {}
    func reevaluate(_ reason: DuoPushUploadReason) {}
    func noLiveDuoRemains() {}
    func opFinished(_ op: DuoQueuedOp, succeeded: Bool) {
        guard !succeeded, requeued < 10_000 else { return }
        requeued += 1
        ops?.enqueue(try! DuoQueuedOp.registerPush(DuoWireRegisterPushRequest(token: "t", apnsEnv: nil, tz: nil, wakeStartMin: nil, wakeEndMin: nil,
                                                                                notificationsEnabled: true), firstUpload: false, key: "p\(requeued)", now: Date()))
    }
}

/// What stage C's refresh does to the queue (it drains it), recording the wipe epoch it ran in.
@MainActor
fileprivate final class ERDrainingSync: DuoSyncing {
    weak var host: DuoStore?
    var ops: DuoOpQueueing?
    private(set) var refreshEpochs: [Int] = []
    func activate(logReader: DuoLogReading) {}
    func logChanged(_ summary: DuoLogSummary) {}
    func refresh() async {
        refreshEpochs.append(host?.wipeEpoch ?? -1)
        await ops?.drain()
    }
    func flush() async {}
    func backgroundRefresh() async -> Bool { false }
    func pushArrived(_ payload: DuoPushPayload) async {}
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async {}
}

/// A refresh that is held open until the test lets it go.
@MainActor
fileprivate final class ERHeldSync: DuoSyncing {
    let gate: ERGate
    private(set) var asked = 0
    init(gate: ERGate) { self.gate = gate }
    func activate(logReader: DuoLogReading) {}
    func logChanged(_ summary: DuoLogSummary) {}
    func refresh() async { asked += 1; await gate.wait() }
    func flush() async {}
    func backgroundRefresh() async -> Bool { false }
    func pushArrived(_ payload: DuoPushPayload) async {}
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async {}
}

/// A memory Keychain that will not let go of the install marker, deleted one by one or with the service.
fileprivate final class ERMarkerStickyStore: DuoSecretStore, @unchecked Sendable {
    let base = DuoMemorySecretStore()
    func read(service: String, account: String) throws -> Data? { try base.read(service: service, account: account) }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try base.write(data, service: service, account: account, accessibility: accessibility)
    }
    func delete(service: String, account: String) throws {
        if account == DuoSecrets.installMarkerAccount { throw ERKeychainRefusal() }
        try base.delete(service: service, account: account)
    }
    func deleteAll(service: String) throws {
        let marker = try base.read(service: service, account: DuoSecrets.installMarkerAccount)
        try base.deleteAll(service: service)
        if let marker { try base.write(marker, service: service, account: DuoSecrets.installMarkerAccount, accessibility: .afterFirstUnlockThisDeviceOnly) }
    }
}

@MainActor
fileprivate final class ERCounter {
    var count = 0
    var peak = 0
    var started = 0
}

// MARK: - The tests

@MainActor
final class DuoExitRobustnessTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let id = DuoFixtures.duoID
    private let other = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000002")!
    private let orphan = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000ff")!
    private var folders: [URL] = []
    private var keptAlive: [AnyObject] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        keptAlive = []
        super.tearDown()
    }

    @MainActor
    private struct Rig {
        let kit: DuoTestKit
        let exits: DuoExitService
        let ops: DuoOpQueueService
        var store: DuoStore { kit.store }
        var transport: FakeDuoTransport { kit.transport }
        var cache: DuoCache { kit.dependencies.cache }
    }

    /// The real exit service and queue over a `DuoTestKit`. With `retries` false a wait ends at once
    /// with no retry, so a test sees the one attempt it makes.
    private func makeRig(credential: DuoCredential? = DuoFixtures.credential(), retries: Bool = false) -> Rig {
        let kit = DuoTestKit(credential: credential)
        kit.identity.launch = credential == nil ? .none : .ready
        if !retries { kit.dependencies.sleep = { _ in throw CancellationError() } }
        let ops = DuoOpQueueService(dependencies: kit.dependencies)
        kit.dependencies.ops = ops
        let exits = DuoExitService(dependencies: kit.dependencies)
        kit.dependencies.exiting = exits
        return Rig(kit: kit, exits: exits, ops: ops)
    }

    private func fail(_ code: DuoErrorCode, _ status: Int, retryAfter: Int? = nil) -> DuoTransportError {
        DuoTransportError(code: code, context: DuoErrorContext(httpStatus: status, requestID: "req-1", retryAfter: retryAfter))
    }

    private func live(_ duoID: UUID? = nil, role: DuoRole = .owner, partner: String = "Sam") -> DuoState {
        DuoFixtures.duo(id: duoID ?? id, role: role, partner: partner, now: now)
    }

    /// An ended duo whose end came from the server an hour before the test's moment, so no entry
    /// made now can be taken for the one that stamped it.
    private func ended(_ duoID: UUID? = nil) -> DuoState {
        var duo = DuoFixtures.duo(id: duoID ?? id, ended: true, now: now)
        duo.endedAt = now.addingTimeInterval(-3_600)
        return duo
    }

    private func leftOK(_ by: DuoEndedBy = .owner) -> DuoWireLeaveResponse {
        DuoWireLeaveResponse(state: "ended", endedBy: by, endedAt: Date(timeIntervalSince1970: 1_790_000_500))
    }

    private func member(_ name: String? = "Joanna") -> DuoWireMember {
        DuoWireMember(id: DuoFixtures.credential().memberID, displayName: name, skin: "classic", supportId: "ABCD1234EFGH", tier: .low, termsVersion: 1)
    }

    private func memberInfo(_ name: String? = "Jo") -> DuoMemberInfo {
        DuoMemberInfo(memberID: DuoFixtures.credential().memberID, displayName: name, skin: "classic", supportID: "ABCD1234EFGH", tier: .low,
                      termsVersion: 1, nudgesPerDay: 1, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: now)
    }

    private func renameOp(_ name: String, key: String) throws -> DuoQueuedOp {
        try DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: .value(name)), key: key, now: now)
    }

    private func pushOp(key: String) throws -> DuoQueuedOp {
        try DuoQueuedOp.registerPush(DuoWireRegisterPushRequest(token: "ab12", apnsEnv: "sandbox", tz: "UTC", wakeStartMin: nil, wakeEndMin: nil,
                                                                notificationsEnabled: false), firstUpload: false, key: key, now: now)
    }

    private func count(_ rig: Rig, _ match: (FakeDuoTransport.Call) -> Bool) -> Int { rig.transport.calls.filter(match).count }
    private func isLeave(_ call: FakeDuoTransport.Call) -> Bool { if case .leave = call { return true }; return false }
    private func isBlock(_ call: FakeDuoTransport.Call) -> Bool { if case .block = call { return true }; return false }
    private func isRename(_ call: FakeDuoTransport.Call) -> Bool { if case .updateMe = call { return true }; return false }
    private func isDelete(_ call: FakeDuoTransport.Call) -> Bool { if case .deleteMe = call { return true }; return false }
    private func isUpload(_ call: FakeDuoTransport.Call) -> Bool { if case .registerPush = call { return true }; return false }

    private func duoKeys(_ rig: Rig) -> Set<String> {
        Set(rig.kit.defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("duo") })
    }

    private func settle(_ rig: Rig) async {
        for _ in 0..<5_000 where !rig.ops.isIdle { await Task.yield() }
        for _ in 0..<300 { await Task.yield() }
    }

    private func yield(until condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func folder() -> URL {
        let made = FileManager.default.temporaryDirectory.appendingPathComponent("DuoExitRobustnessTests-\(UUID().uuidString)", isDirectory: true)
        folders.append(made)
        return made
    }

    /// A session worth deleting: a live duo, a typed name, the member record, the ledger, a queued
    /// rename, and Keychain items, orphans included.
    private func seed(_ rig: Rig) throws {
        let store = rig.store
        store.myDisplayName = "Joanna"
        store.memberInfo = memberInfo()
        store.upsert(live())
        var ledger = DuoLedger()
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: id, day: "2026-09-20"))
        rig.cache.saveLedger(ledger)
        rig.ops.enqueue(try renameOp("Joanna", key: "rename"))
        let secrets = rig.kit.dependencies.secrets
        try secrets.save(DuoFixtures.credential())
        try secrets.writeInstallMarker(random: rig.kit.random)
        try secrets.saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: id)
        try secrets.saveLinkSecret("ZYXWVTSRQPNMKJHGFEDCBA3210", forDuo: orphan)
        XCTAssertEqual(store.recordBirthYear(1990, now: now), .allowed)
    }

    private func assertWiped(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(duoKeys(rig).isSubset(of: Set(DuoCache.keptKeys)), "on disk, only what a wipe keeps: \(duoKeys(rig).subtracting(DuoCache.keptKeys).sorted())", file: file, line: line)
        XCTAssertTrue(rig.store.duos.isEmpty, file: file, line: line)
        XCTAssertEqual(rig.store.myDisplayName, "", file: file, line: line)
        XCTAssertNil(rig.store.memberInfo, file: file, line: line)
        XCTAssertEqual(rig.kit.secretStore.accounts(service: DuoSecrets.service), [], file: file, line: line)
        XCTAssertEqual(rig.store.ageStatus, .allowed, "the age answer stays", file: file, line: line)
    }

    // MARK: - E1: a delete whose answer was lost

    func testE1_aDeleteWhoseAnswerIsLostIsFinishedByTheNext401() async throws {
        // LDFindingTests.testF1_ and LDFindingTests2.testF1c_: the server deleted the member, the
        // answer never came, and the next request (here the queued rename, as the network monitor
        // drains it) meets 401. Without the marker that 401 forgot only part of the phone: the
        // ended cards with the partner's name, the typed name and the ledger stayed, with nothing
        // on screen able to take them, since Delete my Duo data needs an identity to be shown.
        let rig = makeRig()
        try seed(rig)
        rig.transport.onDeleteMe = { _, _ in throw DuoTransportError.offline }

        let first = await rig.exits.deleteMyData()
        XCTAssertFalse(first)
        XCTAssertNotNil(rig.cache.deleteRequestedAt, "the request may have landed, so it is remembered")
        XCTAssertFalse(rig.store.duos.isEmpty, "and nothing is wiped on an answer that proves nothing")

        rig.transport.onUpdateMe = { _ in throw self.fail(.unauthenticated, 401) }
        await rig.ops.drain()
        await settle(rig)

        assertWiped(rig)
    }

    func testE1_aTapAfterTheIdentityWentWithTheMarkerSetFinishesTheDelete() async throws {
        // A second tap with the identity gone and the marker set: the identity being gone is the
        // answer the first tap never got. It used to say "That did not work. Please try again."
        // for ever, sending nothing.
        let rig = makeRig()
        try seed(rig)
        rig.transport.onDeleteMe = { _, _ in throw DuoTransportError.offline }
        _ = await rig.exits.deleteMyData()
        rig.kit.identity.discard()
        rig.kit.identity.launch = .none
        rig.store.notice = nil

        let second = await rig.exits.deleteMyData()

        XCTAssertTrue(second)
        XCTAssertNil(rig.store.notice)
        XCTAssertEqual(count(rig, isDelete), 1, "no second request: there is no identity to send it with")
        assertWiped(rig)
    }

    func testE1_onlyARefusalTheServerJudgedClearsTheMarker() async throws {
        let cleared: [(String, Error)] = [
            ("401 device_revoked", fail(.deviceRevoked, 401)), ("403 banned", fail(.banned, 403)),
            ("426", fail(.upgradeRequired, 426)), ("428", fail(.termsRequired, 428)), ("400 schema", fail(.schema, 400)),
            ("413", fail(.payloadTooLarge, 413)), ("409 unknown code", DuoTransportError.unreadable(httpStatus: 409, requestID: nil)),
        ]
        let kept: [(String, Error)] = [
            ("offline", DuoTransportError.offline), ("cancelled", CancellationError()),
            ("200 unreadable", DuoTransportError.unreadable(httpStatus: 200, requestID: nil)),
            ("no response", DuoTransportError.unreadable(httpStatus: 0, requestID: nil)),
            ("503 maintenance", fail(.maintenance, 503)), ("429", fail(.rateLimited, 429, retryAfter: 60)),
            ("no credential", fail(.unauthenticated, 0)),
        ]
        for (name, error) in cleared + kept {
            let rig = makeRig()
            rig.store.upsert(live())
            rig.transport.onDeleteMe = { _, _ in throw error }
            let deleted = await rig.exits.deleteMyData()
            XCTAssertFalse(deleted, name)
            let isCleared = cleared.contains { $0.0 == name }
            XCTAssertEqual(rig.cache.deleteRequestedAt == nil, isCleared,
                           "\(name): \(isCleared ? "the server judged it, so nothing was deleted" : "it may have landed")")
            XCTAssertNotNil(rig.store.duo(id), "\(name): nothing is wiped")
        }
    }

    func testE1_theMarkerIsOnDiskBeforeTheRequestLeaves() async throws {
        // LDFindingTests.testF1b_: the app closed while DELETE /me was out. Whatever the server did,
        // the relaunch finds the marker, so a 401 then finishes the wipe.
        let rig = makeRig()
        rig.store.upsert(live())
        let gate = ERGate()
        let gated = ERGatedTransport(rig.transport)
        gated.deleteGate = gate
        rig.kit.dependencies.transport = gated
        rig.transport.onDeleteMe = { _, _ in }
        let delete = Task { await rig.exits.deleteMyData() }
        await yield(until: { gate.entered == 1 }, "the delete is out")

        XCTAssertNotNil(DuoCache(defaults: rig.kit.defaults).deleteRequestedAt, "a relaunch reading the defaults finds it")

        gate.release()
        let deleted = await delete.value
        XCTAssertTrue(deleted)
        XCTAssertNil(rig.cache.deleteRequestedAt, "and a delete that went through leaves nothing behind")
    }

    // MARK: - E6, E8: Delete my Duo data on a phone the server superseded, and its words

    func testE6_aPhoneWhoseLaunchSaysDisconnectedStillSendsItsDelete() async throws {
        // LDFindingTests.testF6_: a superseded phone keeps DELETE /me for 30 days (D33, §3.5) even
        // when its launch's GET /me answered device_revoked. The server decides.
        let rig = makeRig()
        try seed(rig)
        rig.kit.identity.launch = .disconnected
        rig.transport.onDeleteMe = { _, _ in }

        let deleted = await rig.exits.deleteMyData()

        XCTAssertTrue(deleted)
        XCTAssertEqual(count(rig, isDelete), 1)
        assertWiped(rig)
    }

    func testE6_noDeleteGoesWhileTheRestoreQuestionIsUp() async throws {
        let rig = makeRig()
        rig.store.upsert(live())
        rig.kit.identity.launch = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        rig.transport.onDeleteMe = { _, _ in }
        let deleted = await rig.exits.deleteMyData()
        XCTAssertFalse(deleted)
        XCTAssertTrue(rig.transport.calls.isEmpty, "the credential may be someone else's")
    }

    func testE8_aFailedDeleteNeverSaysTheDuoWillCatchUp() async throws {
        // LSProbes.testLSF4_: the maintenance line ends "Your duo will catch up when it is", which
        // is not true of a delete: nothing is queued.
        for error in [fail(.maintenance, 503), DuoTransportError.unreadable(httpStatus: 500, requestID: "req-1")] {
            let rig = makeRig()
            rig.store.upsert(live())
            rig.transport.onDeleteMe = { _, _ in throw error }
            _ = await rig.exits.deleteMyData()
            XCTAssertEqual(rig.store.notice, DuoUserMessage.text(for: error, context: .deletion), "\(error)")
            XCTAssertFalse(rig.store.notice?.contains("catch up") ?? true, "\(error)")
        }
    }

    // MARK: - E17: a Keychain that refuses the wipe

    /// An exit service over a Keychain that can refuse, with the kit's other doubles.
    private func refusingRig() throws -> (Rig, ERRefusingSecretStore, DuoExitService) {
        let rig = makeRig()
        let keychain = ERRefusingSecretStore()
        let dependencies = DuoDependencies(host: rig.store, cache: rig.cache, secrets: DuoSecrets(store: keychain), clock: rig.kit.clock,
                                           random: rig.kit.random, client: rig.kit.dependencies.client, attester: rig.kit.attester,
                                           deviceCheck: FakeDuoDeviceCheck())
        dependencies.identity = rig.kit.identity
        dependencies.transport = rig.transport
        dependencies.announcer = rig.kit.announcer
        dependencies.push = rig.kit.push
        dependencies.sync = rig.kit.sync
        dependencies.sleep = { _ in throw CancellationError() }
        let ops = DuoOpQueueService(dependencies: dependencies)
        dependencies.ops = ops
        let exits = DuoExitService(dependencies: dependencies)
        dependencies.exiting = exits
        keptAlive.append(contentsOf: [dependencies, ops, exits] as [AnyObject])
        try DuoSecrets(store: keychain).save(DuoFixtures.credential())
        try DuoSecrets(store: keychain).writeInstallMarker(random: rig.kit.random)
        try DuoSecrets(store: keychain).saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: id)
        rig.store.upsert(live())
        return (rig, keychain, exits)
    }

    func testE17_aKeychainThatRefusesTheWipeIsTriedAgainAndTheScreenSaysSo() throws {
        // LDFindingTests.testF2_: every delete refused, swallowed by `try?`. The screen looked clean
        // while the credential stayed, and the next launch read it back and asked "Continue as Jo?"
        // about the identity the person had just said was not theirs.
        let (rig, keychain, exits) = try refusingRig()
        keychain.refuse(Int.max)

        exits.startFresh()

        XCTAssertNotNil(DuoSecrets(store: keychain).credential(), "the Keychain kept it")
        XCTAssertEqual(keychain.deleteAllCalls, 2, "read back, and tried once more")
        XCTAssertEqual(rig.store.notice, DuoUserMessage.generic, "rather than looking clean")
    }

    func testE17_aSecondTryThatWorksSaysNothing() throws {
        let (rig, keychain, exits) = try refusingRig()
        keychain.refuse(1)

        exits.startFresh()

        XCTAssertNil(DuoSecrets(store: keychain).credential())
        XCTAssertEqual(keychain.memory.accounts(service: DuoSecrets.service), [])
        XCTAssertNil(rig.store.notice)
    }

    func testE17_aDeleteThatWentThroughWithTheKeychainRefusingStillSaysSo() async throws {
        // LDFindingTests.testF2b_: the server did delete, so it returns true, but the phone could not
        // forget the credential, and says so instead of looking clean.
        let (rig, keychain, exits) = try refusingRig()
        keychain.refuse(Int.max)
        rig.transport.onDeleteMe = { _, _ in }

        let deleted = await exits.deleteMyData()

        XCTAssertTrue(deleted)
        XCTAssertEqual(rig.store.notice, DuoUserMessage.generic)
    }

    // MARK: - E5: an unreadable 2xx

    func testE5_anUnreadable2xxAtTheEndpointsOwnStatusIsDoneAndHoldsNothingBehindIt() async throws {
        // LQProbes P1: a 2xx the client cannot read, at the endpoint's own status (a leave's 200 whose
        // body a later server shapes differently, say). The server did it. Kept, it was sent again at
        // every trigger, for ever (21 times in 20 triggers and a relaunch), and the entries behind it
        // in its group never went.
        let rig = makeRig()
        rig.store.upsert(live())
        rig.store.upsert(ended(other))
        rig.transport.onLeave = { _, _ in throw DuoTransportError.unreadable(httpStatus: 200, requestID: "r") }
        rig.transport.onBlock = { _, _ in }
        rig.transport.onUpdateMe = { _ in self.member() }
        await rig.exits.leave(live())
        await rig.exits.block(ended(other))
        rig.ops.enqueue(try renameOp("New", key: "rename"))
        for _ in 0..<10 { await rig.ops.drain(); await settle(rig) }

        XCTAssertEqual(count(rig, isLeave), 1)
        XCTAssertEqual(count(rig, isBlock), 1)
        XCTAssertEqual(count(rig, isRename), 1)
        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertNil(rig.store.duo(id)?.pendingOp)
        XCTAssertNil(rig.store.duo(other)?.pendingOp)
    }

    func testE5_aRenameWhose200CannotBeReadIsDoneAndWritesNothing() async throws {
        let rig = makeRig()
        rig.store.memberInfo = memberInfo("Jo")
        rig.transport.onUpdateMe = { _ in throw DuoTransportError.unreadable(httpStatus: 200, requestID: nil) }
        rig.ops.enqueue(try renameOp("Joanna", key: "rename"))
        await rig.ops.drain()
        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertEqual(rig.store.memberInfo?.displayName, "Jo", "nothing of a body it could not read")
    }

    func testE5_noResponseAtAllStillHolds() async throws {
        let rig = makeRig()
        rig.transport.onLeave = { _, _ in throw DuoTransportError.unreadable(httpStatus: 0, requestID: nil) }
        rig.store.upsert(live())
        await rig.exits.leave(live())
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.leave])
        XCTAssertEqual(rig.store.duo(id)?.pendingOp, .leave)
    }

    // MARK: - E4: the server's window, and the groups (D74)

    func testE4_aRateLimitedRenameDoesNotHoldABlockAndTriggersInsideItsWindowSendNothing() async throws {
        // LQProbes P2: the fourth name change of the day (429, Retry-After to midnight) at the head
        // of the queue, then a Block. Every trigger sent the PATCH again inside its window and the
        // block never went: the partner's duo stayed live while this card said it had ended.
        let rig = makeRig(retries: true)
        let delays = ERGate()
        rig.kit.dependencies.sleep = { _ in await delays.wait(); try Task.checkCancellation() }
        rig.store.upsert(live())
        rig.transport.onUpdateMe = { _ in throw self.fail(.rateLimited, 429, retryAfter: 20_000) }
        rig.transport.onBlock = { _, _ in }
        rig.ops.enqueue(try renameOp("Fourth", key: "rename"))
        await rig.ops.drain()

        await rig.exits.block(live())
        for _ in 0..<5 { await rig.ops.drain() } // five foregrounds inside the window

        XCTAssertEqual(count(rig, isRename), 1, "no trigger inside the server's window sends it again")
        XCTAssertEqual(count(rig, isBlock), 1, "and it holds back nothing of another group")
        XCTAssertTrue(try XCTUnwrap(rig.store.duo(id)).hasEnded)
        XCTAssertNil(rig.store.duo(id)?.pendingOp)
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.updateMe])
        XCTAssertFalse(rig.ops.isIdle, "a retry waits for the end of the window")
        rig.ops.discardAll()
        delays.release()
        await settle(rig)
    }

    func testE4_noConnectionIsTriedAtOnceByEveryTrigger() async throws {
        let rig = makeRig()
        rig.store.upsert(live())
        await rig.exits.leave(live()) // offline
        for _ in 0..<3 { await rig.ops.drain() }
        XCTAssertEqual(count(rig, isLeave), 4, "a connection coming back is the moment to try, not a minute later")
    }

    func testE4_retryTasksStayAtMostOneAndNoneOutlivesADiscard() async throws {
        // LQProbes2 P10, kept as a guard: 300 triggers, half of them not awaited.
        let rig = makeRig(retries: true)
        let counter = ERCounter()
        rig.kit.dependencies.sleep = { seconds in
            counter.count += 1; counter.started += 1; counter.peak = max(counter.peak, counter.count)
            defer { counter.count -= 1 }
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        }
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "k", now: now)) // offline for ever
        for index in 0..<300 {
            if index.isMultiple(of: 2) { await rig.ops.drain() } else { Task { await rig.ops.drain() } }
            for _ in 0..<5 { await Task.yield() }
        }
        for _ in 0..<500 { await Task.yield() }
        rig.ops.discardAll()
        for _ in 0..<2_000 where counter.count > 0 { await Task.yield() }
        XCTAssertLessThanOrEqual(counter.peak, 1)
        XCTAssertEqual(counter.count, 0)
        XCTAssertTrue(rig.ops.isIdle)
    }

    func testE4_theRetryAtTheEndOfTheWindowSendsIt() async throws {
        let rig = makeRig(retries: true)
        var answers: [Result<DuoWireMember, DuoTransportError>] = [.failure(fail(.rateLimited, 429, retryAfter: 100)), .success(member())]
        rig.transport.onUpdateMe = { _ in try answers.removeFirst().get() }
        rig.ops.enqueue(try renameOp("Joanna", key: "rename"))
        await rig.ops.drain()
        await settle(rig)
        XCTAssertEqual(count(rig, isRename), 2)
        XCTAssertEqual(rig.kit.sleeper.delays, [100])
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    // MARK: - E9: entries and the identity they were made with

    func testE9_aPhoneWithNoCredentialKeepsItsLeaveAndDropsWhatBelongedToTheIdentity() async throws {
        // LQProbes P3a: App Group defaults restored without the Keychain. The queue was emptied at
        // the first drain, the card stopped saying its leave was on its way, and "I had a duo" (a
        // reconnect into the same member) then had nothing left to send.
        let rig = makeRig(credential: nil)
        var card = live()
        card.endedAt = now
        card.endedBy = .owner
        card.pendingOp = .leave
        rig.store.upsert(card)
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "restored-leave", now: now))
        rig.ops.enqueue(try renameOp("PreviousName", key: "rename"))
        rig.ops.enqueue(try pushOp(key: "upload"))

        await rig.ops.drain()

        XCTAssertEqual(rig.ops.pending.map(\.key), ["restored-leave"])
        XCTAssertEqual(rig.store.duo(id)?.pendingOp, .leave)
        XCTAssertTrue(rig.transport.calls.isEmpty)

        try rig.kit.identity.store(DuoFixtures.credential()) // "I had a duo"
        rig.kit.identity.launch = .ready
        rig.transport.onLeave = { _, _ in self.leftOK() }
        await rig.ops.drain()
        XCTAssertEqual(count(rig, isLeave), 1, "the leave the person asked for reaches the server")
        XCTAssertNil(rig.store.duo(id)?.pendingOp)
    }

    func testE9_aNewIdentityTakesTheOldRenameAndUploadWithIt() async throws {
        // LQProbes P3b: with no drain in between, an old identity's rename went out under the new
        // member a Join had just made. Stage D calls `discardIdentityBound()` when it mints one.
        let rig = makeRig()
        rig.ops.enqueue(try renameOp("PreviousOwner", key: "old-rename"))
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "leave", now: now))
        rig.ops.enqueue(try pushOp(key: "old-upload"))
        let queue: DuoOpQueueing = rig.ops

        queue.discardIdentityBound()

        XCTAssertEqual(rig.ops.pending.map(\.key), ["leave"])
        XCTAssertEqual(DuoOpQueueService(dependencies: rig.kit.dependencies).pending.map(\.key), ["leave"], "on disk too")
    }

    // MARK: - E6: a launch that says disconnected

    func testE6_aDisconnectedLaunchStillSendsLeavesAndBlocksButNothingElse() async throws {
        // LQProbes P4: `.disconnected` is what an unsettled phone's launch answers when its GET /me
        // meets device_revoked, which a superseded phone gets everywhere but leave, block and
        // DELETE /me. Its leave sat in the queue for good.
        let rig = makeRig()
        rig.kit.identity.launch = .disconnected
        rig.store.upsert(live())
        rig.transport.onLeave = { _, _ in self.leftOK() }
        rig.transport.onUpdateMe = { _ in self.member() }
        rig.ops.enqueue(try renameOp("Jo", key: "rename"))

        await rig.exits.leave(live())

        XCTAssertEqual(count(rig, isLeave), 1, "the server decides: allowed for 30 days, or device_revoked and dropped")
        XCTAssertEqual(count(rig, isRename), 0, "a rename is refused to a superseded phone, so it is not sent")
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.updateMe])
    }

    func testE6_anUnsettledSupersededPhoneSendsItsLeaveAndItsDelete() async throws {
        // LSProbes.testLSF5b_, with the real identity: a same-phone reinstall whose launch GET /me
        // meets device_revoked.
        let rig = makeRig()
        let secrets = rig.kit.dependencies.secrets
        try secrets.save(DuoFixtures.credential())
        try secrets.writeInstallMarker(random: rig.kit.random)
        let identity = DuoIdentity(dependencies: rig.kit.dependencies, directory: folder(), holdInBackground: { _ in {} })
        rig.kit.dependencies.identity = identity
        rig.store.upsert(live())
        rig.transport.onMe = { throw self.fail(.deviceRevoked, 401) }
        rig.transport.onLeave = { _, _ in self.leftOK() }
        rig.transport.onDeleteMe = { _, _ in }
        let launch = await identity.prepare()
        XCTAssertEqual(launch, .disconnected)

        await rig.exits.leave(live())
        XCTAssertEqual(count(rig, isLeave), 1)
        let deleted = await rig.exits.deleteMyData()
        XCTAssertTrue(deleted)
        XCTAssertEqual(count(rig, isDelete), 1)
    }

    // MARK: - E13: a block's success

    func testE13_aBlocksSuccessEndsACardStillShownLive() async throws {
        // LQProbes P5: a block that went (queued before a kill between the enqueue and the card's
        // write, or with a fetch re-reading the duo as live while it waited) left the card live.
        let rig = makeRig()
        rig.store.upsert(live(role: .partner))
        rig.transport.onBlock = { _, _ in }
        rig.ops.enqueue(try DuoQueuedOp.block(duoID: id, key: "b", now: now))

        await rig.ops.drain()

        let card = try XCTUnwrap(rig.store.duo(id))
        XCTAssertTrue(card.hasEnded)
        XCTAssertEqual(card.endedBy, .partner, "ended by me, in my role")
        XCTAssertNil(card.pendingOp)
    }

    func testE13_theQueueHoldsTheEntryBeforeTheCardSaysItEnded() async throws {
        // Mutant S2 (the enqueue moved after the card's write) survived every stage test: a kill
        // between the two would leave an ended card with nothing queued to end it.
        for kind in [DuoPendingOp.leave, .block] {
            let rig = makeRig()
            rig.store.upsert(live())
            var queuedWhenTheCardEnded: Bool?
            let watch = rig.store.$duos.sink { duos in
                guard queuedWhenTheCardEnded == nil, duos.first(where: { $0.id == self.id })?.hasEnded == true else { return }
                queuedWhenTheCardEnded = rig.ops.pending.contains { $0.duoID == self.id.uuidString.lowercased() }
            }
            if kind == .leave { await rig.exits.leave(live()) } else { await rig.exits.block(live()) }
            watch.cancel()
            XCTAssertEqual(queuedWhenTheCardEnded, true, "\(kind): queued before the card said it ended")
        }
    }

    // MARK: - E14, E11: what one drain sends

    func testE14_aLeaveTappedWhileAStaleDrainIsOutIsSentByItsOwnTap() async throws {
        // LQProbes P7: the tap waited for a drain that returned without sending what was queued
        // after it began, so the leave waited for the next trigger.
        let rig = makeRig()
        let gate = ERGate()
        let gated = ERGatedTransport(rig.transport)
        gated.updateMeGate = gate
        rig.kit.dependencies.transport = gated
        rig.transport.onUpdateMe = { _ in self.member() }
        rig.transport.onLeave = { _, _ in self.leftOK() }
        rig.store.upsert(live())
        rig.ops.enqueue(try renameOp("Old", key: "old"))
        let first = Task { await rig.ops.drain() }
        await yield(until: { gate.entered == 1 }, "the rename is out")
        rig.ops.discardAll() // a 401 met elsewhere, say, while it was out
        let tap = Task { await rig.exits.leave(self.live()) }
        for _ in 0..<200 { await Task.yield() }
        gate.release()
        await first.value
        await tap.value

        XCTAssertEqual(count(rig, isLeave), 1, "sent by the tap that queued it")
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    func testE11_oneDrainSendsOnlyWhatWasQueuedWhenItBegan() async throws {
        // LQProbes P8: a push service that queues a new upload whenever one is dropped kept one
        // drain going for 500 sends.
        let rig = makeRig()
        let push = ERRequeuingPush()
        push.ops = rig.ops
        rig.kit.dependencies.push = push
        rig.transport.onRegisterPush = { _, _ in throw DuoTransportError.schema(DuoErrorContext(httpStatus: 400)) }
        rig.ops.enqueue(try pushOp(key: "p0"))

        await rig.ops.drain()

        XCTAssertEqual(count(rig, isUpload), 1)
        XCTAssertEqual(rig.ops.pending.map(\.key), ["p1"], "the new entry waits for the next drain")
        rig.ops.discardAll()
    }

    // MARK: - E10: a rejected rename

    func testE10_aRejectedRenameSaysSoAndPutsBackTheNameTheServerHolds() async throws {
        // LQProbes P9: dropped without a word, with the refused name left as the person's own.
        let rig = makeRig()
        rig.store.memberInfo = memberInfo("Jo")
        rig.store.myDisplayName = "Bad Name"
        rig.transport.onUpdateMe = { _ in throw self.fail(.nameRejected, 422) }
        rig.ops.enqueue(try renameOp("Bad Name", key: "r"))

        await rig.ops.drain()

        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertEqual(rig.store.notice, "Please choose a different name.")
        XCTAssertEqual(rig.store.myDisplayName, "Jo")
    }

    func testE10_aRejectedRenameWithALaterOneQueuedLeavesTheLaterName() async throws {
        let rig = makeRig()
        rig.store.memberInfo = memberInfo("Jo")
        rig.store.myDisplayName = "Good Name"
        var answers: [Result<DuoWireMember, DuoTransportError>] = [.failure(fail(.nameRejected, 422)), .failure(.offline)]
        rig.transport.onUpdateMe = { _ in try answers.removeFirst().get() }
        rig.ops.enqueue(try renameOp("Bad Name", key: "r1"))
        rig.ops.enqueue(try renameOp("Good Name", key: "r2"))

        await rig.ops.drain()

        XCTAssertEqual(rig.store.notice, "Please choose a different name.")
        XCTAssertEqual(rig.store.myDisplayName, "Good Name", "the later rename still says what the person wants")
        XCTAssertEqual(rig.ops.pending.map(\.key), ["r2"])
    }

    // MARK: - E7: a cleared duo in Diagnostics

    func testE7_aClearedDuosFailingLeaveLeavesNoTraceInDiagnostics() async throws {
        // LSProbes.testLSF3_: Clear took the duo's Diagnostics, then its queued leave met a 503 and
        // wrote the cleared duo's id straight back.
        let rig = makeRig()
        rig.store.upsert(live())
        await rig.exits.leave(live()) // offline
        rig.exits.clear(try XCTUnwrap(rig.store.duo(id)))
        rig.transport.onLeave = { _, _ in throw self.fail(.maintenance, 503) }

        await rig.ops.drain()

        XCTAssertNil(rig.store.diagnostics.duos[id.uuidString.lowercased()])
        XCTAssertEqual(rig.store.diagnostics.recentErrors.first?.code, "maintenance", "the failure itself is still noted")
    }

    // MARK: - E3: a ban learned when the entry goes

    func testE3_aBanLearnedWhenTheLeaveIsSentPutsTheCardBack() async throws {
        // LSProbes.testLSF1_: availability is not kept across a launch, so the first sign of a ban
        // can be the leave's own 403. The card said the duo had ended, nothing was waiting to end
        // it, and the duo was live on the server.
        let rig = makeRig()
        rig.store.upsert(live())
        rig.transport.onLeave = { _, _ in throw self.fail(.banned, 403) }

        await rig.exits.leave(live())

        let card = try XCTUnwrap(rig.store.duo(id))
        XCTAssertFalse(card.hasEnded, "the server never ended it")
        XCTAssertNil(card.endedBy)
        XCTAssertNil(card.pendingOp)
        XCTAssertEqual(rig.store.availability, .banned, "and the banned banner says why")
    }

    func testE3_anOfflineLeaveRefusedAsBannedLaterPutsTheCardBack() async throws {
        // LSProbes.testLSF1b_.
        let rig = makeRig()
        rig.store.upsert(live())
        await rig.exits.leave(live()) // offline
        rig.transport.onLeave = { _, _ in throw self.fail(.banned, 403) }
        await rig.ops.drain()
        XCTAssertFalse(try XCTUnwrap(rig.store.duo(id)).hasEnded)
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    func testE3_aBlockOfALiveDuoRefusedAsBannedPutsTheCardBack() async throws {
        // LSProbes.testLSF1c_.
        let rig = makeRig()
        rig.store.upsert(live())
        rig.transport.onBlock = { _, _ in throw self.fail(.banned, 403) }
        await rig.exits.block(live())
        XCTAssertFalse(try XCTUnwrap(rig.store.duo(id)).hasEnded)
    }

    func testE3_aBlockOfAnEndedDuoRefusedAsBannedKeepsItsOwnEnd() async throws {
        let rig = makeRig()
        rig.store.upsert(ended())
        rig.transport.onBlock = { _, _ in throw self.fail(.banned, 403) }
        await rig.exits.block(ended())
        let card = try XCTUnwrap(rig.store.duo(id))
        XCTAssertEqual(card.endedAt, now.addingTimeInterval(-3_600), "an end the entry did not stamp is not undone")
        XCTAssertEqual(card.endedBy, .partner)
    }

    // MARK: - E2: no credential

    func testE2_aLeaveWithNoCredentialChangesNothingAndSaysWhy() async throws {
        // LSProbes.testLSF2_: the card said the duo had ended, nothing could ever send the leave,
        // and the person was told nothing.
        for kind in [DuoPendingOp.leave, .block] {
            let rig = makeRig(credential: nil)
            rig.store.upsert(live())
            rig.store.availability = .disconnected // what the identity says of live duos and no credential
            if kind == .leave { await rig.exits.leave(live()) } else { await rig.exits.block(live()) }
            XCTAssertFalse(try XCTUnwrap(rig.store.duo(id)).hasEnded, "\(kind)")
            XCTAssertTrue(rig.ops.pending.isEmpty, "\(kind)")
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(kind)")
            XCTAssertEqual(rig.store.notice, DuoUserMessage.generic, "\(kind)")
            XCTAssertEqual(rig.kit.push.clearedLast, 0, "\(kind)")
        }
    }

    func testE2_withTheRealIdentityTheReconnectOfferOutlivesThatLeave() async throws {
        // LSProbes.testLSF2b_: after that leave the next launch had no live duo, so the phone was no
        // longer offered "I had a duo", with the duo live on the server.
        let rig = makeRig(credential: nil)
        let directory = folder()
        let identity = DuoIdentity(dependencies: rig.kit.dependencies, directory: directory, holdInBackground: { _ in {} })
        rig.kit.dependencies.identity = identity
        rig.store.upsert(live())
        let first = await identity.prepare()
        XCTAssertEqual(first, DuoIdentityLaunch.none)
        XCTAssertEqual(rig.store.availability, .disconnected)

        await rig.exits.leave(live())

        rig.store.availability = .unknown // a relaunch
        let relaunched = DuoIdentity(dependencies: rig.kit.dependencies, directory: directory, holdInBackground: { _ in {} })
        rig.kit.dependencies.identity = relaunched
        let again = await relaunched.prepare()
        XCTAssertEqual(again, DuoIdentityLaunch.none)
        XCTAssertEqual(rig.store.availability, .disconnected, "the reconnect offer is still there")
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    // MARK: - E18: Start fresh with a block still waiting

    func testE18_startFreshSendsAWaitingBlockBeforeTheWipe() async throws {
        // LSProbes.testLSF6_: a superseded phone's block waiting on a 503 when the person taps Start
        // fresh on the disconnected card. It was thrown away after one try.
        let rig = makeRig(retries: true)
        let bound = ERGate()
        rig.kit.dependencies.sleep = { _ in await bound.wait(); try Task.checkCancellation() }
        rig.store.upsert(live())
        rig.transport.onBlock = { _, _ in throw self.fail(.maintenance, 503) }
        await rig.exits.block(live())
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.block])
        rig.kit.dependencies.noteFailure(fail(.deviceRevoked, 401)) // the disconnected card
        rig.transport.onBlock = { _, _ in }

        rig.exits.startFresh()
        await yield(until: { rig.store.duos.isEmpty }, "the wipe follows the drain")

        XCTAssertEqual(count(rig, isBlock), 2, "the block the person asked for is tried once more before the wipe")
        XCTAssertTrue(duoKeys(rig).isSubset(of: Set(DuoCache.keptKeys)))
        XCTAssertNil(rig.kit.identity.credential)
        bound.release()
        await settle(rig)
    }

    func testE18_startFreshIsNotHeldLongerThanItsBound() async throws {
        let rig = makeRig(retries: true)
        let bound = ERGate()
        rig.kit.dependencies.sleep = { _ in await bound.wait(); try Task.checkCancellation() }
        let gate = ERGate()
        let gated = ERGatedTransport(rig.transport)
        gated.blockGate = gate
        rig.kit.dependencies.transport = gated
        rig.store.upsert(live())
        rig.ops.enqueue(try DuoQueuedOp.block(duoID: id, key: "b", now: now))
        rig.transport.onBlock = { _, _ in }

        rig.exits.startFresh()
        await yield(until: { gate.entered == 1 }, "the block is out")
        XCTAssertFalse(rig.store.duos.isEmpty, "the wipe waits for the block, within its bound")
        bound.release() // five seconds, and the block has still not answered
        await yield(until: { rig.store.duos.isEmpty }, "the bound ends the wait")
        gate.release()
        await settle(rig)
        XCTAssertTrue(duoKeys(rig).isSubset(of: Set(DuoCache.keptKeys)), "and the late answer writes nothing back")
    }

    func testE18_notMeStartFreshSendsNothing() throws {
        // "Not me, start fresh" on the restore question: the credential is someone else's.
        let rig = makeRig()
        rig.store.upsert(live())
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "restored", now: now))
        rig.store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        rig.exits.startFresh()
        XCTAssertTrue(rig.store.duos.isEmpty, "at once")
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    // MARK: - E15, E16: after a leave lands

    func testE15_notificationsThatArrivedWhileTheLeaveWaitedAreTakenBackWhenItLands() async throws {
        // LSProbes.testLSF7_.
        let rig = makeRig()
        rig.store.upsert(live())
        await rig.exits.leave(live()) // offline
        XCTAssertEqual(rig.kit.announcer.removedFor, [id])
        rig.transport.onLeave = { _, _ in self.leftOK() }
        await rig.ops.drain()
        XCTAssertEqual(rig.kit.announcer.removedFor, [id, id])
    }

    func testE16_aLeaveThatLandsAsksForARefreshSoASiblingTheServerEndedShowsSo() async throws {
        // LSProbes.testLSF8_: a leave ends every live duo of the pair (§7.5); the sibling showed live
        // until the next foreground.
        for kind in [DuoPendingOp.leave, .block] {
            let rig = makeRig()
            rig.store.upsert(live())
            rig.store.upsert(live(other, partner: "Sam"))
            rig.transport.onLeave = { _, _ in self.leftOK() }
            rig.transport.onBlock = { _, _ in }
            if kind == .leave { await rig.exits.leave(live()) } else { await rig.exits.block(live()) }
            await yield(until: { rig.kit.sync.calls.contains("refresh") }, "\(kind): a refresh is asked for")
        }
    }

    func testE16_aDroppedLeaveAsksForNoRefresh() async throws {
        let rig = makeRig()
        rig.store.upsert(live())
        rig.transport.onLeave = { _, _ in throw self.fail(.deviceRevoked, 401) }
        await rig.exits.leave(live())
        await settle(rig)
        XCTAssertFalse(rig.kit.sync.calls.contains("refresh"))
    }

    // MARK: - E19: the safety lens's surviving mutants

    func testM03_aBlockTappedTwiceWhileQueuedQueuesOne() async throws {
        let rig = makeRig()
        rig.store.upsert(ended())
        await rig.exits.block(ended()) // offline
        await rig.exits.block(try XCTUnwrap(rig.store.duo(id)))
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.block])
    }

    func testM05_blockingAnEndedDuoWithNoLiveDuoLeftAsksThePushServiceNothing() async throws {
        let rig = makeRig()
        rig.store.upsert(ended())
        rig.transport.onBlock = { _, _ in }
        await rig.exits.block(ended())
        XCTAssertEqual(rig.kit.push.clearedLast, 0, "no live duo ended: the token was let go, or never held, already")
    }

    // MARK: - Second review: E20 to E24

    private func throwaway() -> DuoCredential {
        DuoCredential(memberID: "6d2a0000-0000-4000-8000-0000000000d1", deviceID: "6d2a0000-0000-4000-8000-0000000000d2",
                      deviceSecret: String(repeating: "t", count: 43))
    }

    private func apiClient(_ rig: Rig, _ session: DuoHTTPSession) -> DuoAPIClient {
        DuoAPIClient(baseURL: URL(string: "https://api.duo-stage-e.test/v1")!, client: rig.kit.dependencies.client,
                     credentials: rig.kit.identity, attester: rig.kit.attester, session: session)
    }

    /// The 5-second bound of Start fresh held open; every other wait ends at once with no retry.
    private func heldBound(_ rig: Rig) -> ERGate {
        let bound = ERGate()
        rig.kit.dependencies.sleep = { seconds in
            if seconds == DuoExitService.startFreshBound { await bound.wait() } else { throw CancellationError() }
        }
        return bound
    }

    func testE20_aLeaveQueuedBeforeAFailedReconnectWaitsForTheMemberItWasFor() async throws {
        // RVAttacks.testRVF_A5_: a Reconnect refused or cut short leaves its throwaway as the stored
        // credential, behind another member's duos. The queued leave went out under it, met 404,
        // counted as done, and the duo it was for stayed live on the server.
        let rig = makeRig(credential: throwaway())
        rig.cache.throwawayDeviceID = throwaway().deviceID
        var card = live()
        card.endedAt = now
        card.endedBy = .owner
        card.pendingOp = .leave
        rig.store.upsert(card)
        rig.store.availability = .disconnected
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "old-leave", now: now))
        rig.transport.onLeave = { _, _ in throw self.fail(.duoUnknown, 404) }

        await rig.ops.drain()
        await settle(rig)

        XCTAssertTrue(rig.transport.calls.isEmpty, "nothing is sent under the throwaway")
        XCTAssertEqual(rig.ops.pending.map(\.key), ["old-leave"])
        XCTAssertEqual(rig.store.duo(id)?.pendingOp, .leave, "the card still says it is on its way")
        XCTAssertTrue(rig.ops.isIdle, "and nothing is scheduled: the Reconnect's own drain sends it")

        // The Reconnect works: stage D stores the member's credential, clears the mark and drains.
        try rig.kit.identity.store(DuoFixtures.credential())
        rig.cache.throwawayDeviceID = nil
        rig.transport.onLeave = { _, _ in self.leftOK() }
        await rig.ops.drain()
        XCTAssertEqual(count(rig, isLeave), 1, "then it goes, under the member it was for")
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    func testE20_aLeaveOrBlockTappedOnTheThrowawayChangesNothingAndSaysWhy() async throws {
        for kind in [DuoPendingOp.leave, .block] {
            let rig = makeRig(credential: throwaway())
            rig.cache.throwawayDeviceID = throwaway().deviceID
            rig.store.upsert(live())
            rig.store.availability = .disconnected
            rig.transport.onLeave = { _, _ in throw self.fail(.duoUnknown, 404) }
            rig.transport.onBlock = { _, _ in throw self.fail(.duoUnknown, 404) }
            if kind == .leave { await rig.exits.leave(live()) } else { await rig.exits.block(live()) }
            XCTAssertFalse(try XCTUnwrap(rig.store.duo(id)).hasEnded, "\(kind)")
            XCTAssertTrue(rig.ops.pending.isEmpty, "\(kind)")
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(kind)")
            XCTAssertEqual(rig.store.notice, DuoUserMessage.generic, "\(kind)")
            XCTAssertEqual(rig.kit.push.clearedLast, 0, "\(kind)")
        }
    }

    func testE20_startFreshOnTheThrowawayWipesAtOnceAndSendsNothing() throws {
        let rig = makeRig(credential: throwaway())
        rig.cache.throwawayDeviceID = throwaway().deviceID
        rig.store.upsert(live())
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "kept", now: now))
        rig.exits.startFresh()
        XCTAssertTrue(rig.store.duos.isEmpty, "at once: no exit could be sent with it")
        XCTAssertNil(rig.exits.pendingStartFresh)
        XCTAssertTrue(rig.transport.calls.isEmpty)
    }

    func testE21_aBlockAnswered200ByAFilterIsNotTakenAsLanded() async throws {
        // RVAttacks.testRVF_A1_: a school's filter answers the block's own URL with a 200 page. The
        // block's status is 204, so the client reads the page as `unreadable(200)`, which E5 then
        // counted as done: dropped from the queue, and the server never saw it.
        let rig = makeRig(retries: true)
        let session = RecordingSession()
        session.respond = { request in
            (Data("<html>This site is blocked by your school</html>".utf8),
             HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!)
        }
        rig.kit.dependencies.transport = apiClient(rig, session)
        rig.store.upsert(live())

        await rig.exits.block(live())
        await settle(rig)

        XCTAssertEqual(session.requests.filter { $0.url?.path.hasSuffix("/block") == true }.count, DuoRetry.maximumAttempts,
                       "tried again, as for maintenance")
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.block])
        XCTAssertEqual(rig.store.duo(id)?.pendingOp, .block, "and the card still says it is on its way")
    }

    func testE21_aPushUploadAnswered200ByAFilterIsNotToldAsSent() async throws {
        // RVAttacks.testRVF_A1b_.
        let rig = makeRig()
        let session = RecordingSession()
        session.respond = { request in
            (Data("<html>blocked</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "text/html"])!)
        }
        rig.kit.dependencies.transport = apiClient(rig, session)
        rig.ops.enqueue(try pushOp(key: "upload"))
        await rig.ops.drain()
        XCTAssertTrue(rig.kit.push.finished.isEmpty, "the server never got the token")
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.registerPush])
    }

    func testE21_aLeaveWhose200BodyCannotBeReadIsStillDone() async throws {
        let rig = makeRig()
        let session = RecordingSession()
        session.respond = { request in
            (Data(#"{"something":"else"}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
        }
        rig.kit.dependencies.transport = apiClient(rig, session)
        rig.store.upsert(live())
        await rig.exits.leave(live())
        XCTAssertTrue(rig.ops.pending.isEmpty, "the leave's own 200: it landed")
        XCTAssertNil(rig.store.duo(id)?.pendingOp)
    }

    func testE22_startFreshDropsTheIdentitysOwnEntriesAtOnce() async throws {
        // RVAttacks.testRVF_A2_ and RVAdaptedLD's refresh in the window: a refresh inside the 5 s
        // (a foreground, or the one a landed exit asks for) drained the rename and the push upload
        // queued for the identity being given up, before the wipe.
        let rig = makeRig()
        let bound = heldBound(rig)
        rig.store.upsert(live())
        rig.ops.enqueue(try renameOp("Jo B", key: "rename"))
        rig.ops.enqueue(try pushOp(key: "upload"))
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "leave", now: now))

        rig.exits.startFresh()

        XCTAssertEqual(rig.ops.pending.map(\.key), ["leave"], "only the exit is left to send, from the start")
        bound.release()
        await yield(until: { rig.exits.pendingStartFresh == nil }, "Start fresh ends")
        await settle(rig)
    }

    func testE22_startFreshsLastDrainAsksForNoRefreshAndSendsOnlyTheExit() async throws {
        let rig = makeRig()
        let sync = ERDrainingSync()
        sync.host = rig.store
        sync.ops = rig.ops
        rig.kit.dependencies.sync = sync
        let bound = heldBound(rig)
        rig.store.upsert(live())
        rig.ops.enqueue(try renameOp("Jo B", key: "rename"))
        rig.ops.enqueue(try pushOp(key: "upload"))
        await rig.exits.leave(live()) // offline: queued behind them
        rig.transport.reset()
        rig.transport.onLeave = { _, _ in self.leftOK() }
        rig.transport.onUpdateMe = { _ in self.member() }
        rig.transport.onRegisterPush = { _, _ in }
        let epoch = rig.store.wipeEpoch

        rig.exits.startFresh()
        for _ in 0..<2_000 where rig.exits.pendingStartFresh != nil { await Task.yield() }
        for _ in 0..<500 { await Task.yield() }
        bound.release()

        XCTAssertTrue(rig.store.duos.isEmpty)
        XCTAssertEqual(count(rig, isLeave), 1, "the leave goes")
        XCTAssertEqual(count(rig, isRename), 0)
        XCTAssertEqual(count(rig, isUpload), 0)
        XCTAssertFalse(sync.refreshEpochs.contains(epoch), "no refresh ran before the wipe")
    }

    func testE22_theExitsOnlyDrainAsksForNoRefreshEvenWithNothingElseQueued() async throws {
        let rig = makeRig()
        let bound = heldBound(rig)
        rig.store.upsert(live())
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "leave", now: now))
        rig.transport.onLeave = { _, _ in self.leftOK() }
        rig.exits.startFresh()
        for _ in 0..<2_000 where rig.exits.pendingStartFresh != nil { await Task.yield() }
        for _ in 0..<500 { await Task.yield() }
        bound.release()
        XCTAssertEqual(count(rig, isLeave), 1)
        XCTAssertFalse(rig.kit.sync.calls.contains("refresh"), "the wipe follows: nothing is left to read")
    }

    func testE23_aDeleteMarkOlderThanThisInstallProvesNothing() async throws {
        // RVAttacks.testRVF_A4_: a mark restored from a backup without the Keychain made Delete my
        // Duo data say done with nothing sent. The install day is in a file no backup carries, so a
        // mark from before it is someone else's moment, or this phone's before a restore.
        let rig = makeRig(credential: nil)
        rig.store.upsert(live())
        rig.cache.deleteRequestedAt = now.addingTimeInterval(-21 * 86_400) // before the kit's install day, 2026-09-01

        let deleted = await rig.exits.deleteMyData()

        XCTAssertFalse(deleted)
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertNotNil(rig.store.duo(id), "nothing wiped")
        XCTAssertNil(rig.cache.deleteRequestedAt, "and the mark that proved nothing is gone")
        XCTAssertEqual(rig.store.notice, DuoUserMessage.generic)
    }

    func testE23_aMarkFromTheInstallDayItselfStillFinishesTheDelete() async throws {
        let rig = makeRig(credential: nil)
        rig.store.upsert(live())
        rig.cache.deleteRequestedAt = DayKey.date(from: rig.kit.identity.installDay, calendar: rig.kit.clock.calendar)
        let deleted = await rig.exits.deleteMyData()
        XCTAssertTrue(deleted)
        XCTAssertTrue(rig.store.duos.isEmpty)
    }

    // MARK: - E24: the re-verifier's killers for the 13 surviving mutants

    func testK_M07_aCoded429KeepsTheDeleteMarker() async throws {
        let rig = makeRig()
        rig.store.upsert(live())
        rig.transport.onDeleteMe = { _, _ in throw DuoTransportError(code: .nudgeLimit, context: DuoErrorContext(httpStatus: 429, requestID: "r")) }
        _ = await rig.exits.deleteMyData()
        XCTAssertNotNil(rig.cache.deleteRequestedAt, "a 429 is \"not now\" whatever its code")
    }

    func testK_M07b_anUnreadable401KeepsTheDeleteMarker() async throws {
        let rig = makeRig()
        rig.store.upsert(live())
        rig.transport.onDeleteMe = { _, _ in throw DuoTransportError.unreadable(httpStatus: 401, requestID: "r") }
        let deleted = await rig.exits.deleteMyData()
        XCTAssertFalse(deleted)
        XCTAssertNotNil(rig.cache.deleteRequestedAt)
    }

    func testK_M12_aBannedBlockKeepsThePartnersEndAtTheSameInstant() async throws {
        let rig = makeRig()
        var duo = live()
        duo.endedAt = now // the entry's createdAt
        duo.endedBy = .partner
        rig.store.upsert(duo)
        rig.transport.onBlock = { _, _ in throw self.fail(.banned, 403) }
        await rig.exits.block(duo)
        let card = try XCTUnwrap(rig.store.duo(id))
        XCTAssertEqual(card.endedAt, now)
        XCTAssertEqual(card.endedBy, .partner)
    }

    func testK_M12b_aBannedBlockKeepsAnEndOfMineTheEntryDidNotStamp() async throws {
        let rig = makeRig()
        var duo = live()
        duo.endedAt = now.addingTimeInterval(-3_600)
        duo.endedBy = .owner // my own earlier leave, with the server's time
        rig.store.upsert(duo)
        rig.transport.onBlock = { _, _ in throw self.fail(.banned, 403) }
        await rig.exits.block(duo)
        let card = try XCTUnwrap(rig.store.duo(id))
        XCTAssertEqual(card.endedAt, now.addingTimeInterval(-3_600))
        XCTAssertEqual(card.endedBy, .owner)
    }

    func testK_M35_aRenameOutWhenANewIdentityIsMintedDoesNotLand() async throws {
        let rig = makeRig()
        let gate = ERGate()
        let gated = ERGatedTransport(rig.transport)
        gated.updateMeGate = gate
        rig.kit.dependencies.transport = gated
        rig.transport.onUpdateMe = { _ in DuoWireMember(id: "old", displayName: "Old name", supportId: "S", tier: .low, termsVersion: 1) }
        rig.ops.enqueue(try renameOp("Old name", key: "r"))
        let drain = Task { await rig.ops.drain() }
        await yield(until: { gate.entered == 1 }, "the rename is out")
        rig.ops.discardIdentityBound()
        rig.store.memberInfo = DuoMemberInfo(memberID: "new", displayName: "New", skin: "classic", supportID: "S2", tier: .low, termsVersion: 1,
                                             nudgesPerDay: 1, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: now)
        gate.release()
        await drain.value
        XCTAssertEqual(rig.store.memberInfo?.displayName, "New", "the old identity's answer is not written over the new member")
    }

    func testK_M47_aLeaveTapDoesNotWaitForTheRefreshItAsksFor() async throws {
        let rig = makeRig()
        let gate = ERGate()
        let sync = ERHeldSync(gate: gate)
        rig.kit.dependencies.sync = sync
        rig.store.upsert(live())
        rig.transport.onLeave = { _, _ in self.leftOK() }
        let done = ERCounter()
        let tap = Task { await rig.exits.leave(self.live()); done.count += 1 }
        await yield(until: { done.count == 1 }, "the tap returns while the refresh is still out")
        XCTAssertEqual(sync.asked, 1, "the refresh was asked for")
        gate.release()
        await tap.value
    }

    func testK_M51_anInstallMarkerTheKeychainKeepsIsTold() throws {
        let rig = makeRig()
        let keychain = ERMarkerStickyStore()
        let secrets = DuoSecrets(store: keychain)
        try secrets.save(DuoFixtures.credential())
        try secrets.writeInstallMarker(random: TestRandom())
        let dependencies = DuoDependencies(host: rig.store, cache: rig.cache, secrets: secrets, clock: rig.kit.clock, random: rig.kit.random,
                                           client: rig.kit.dependencies.client, attester: rig.kit.attester, deviceCheck: FakeDuoDeviceCheck())
        dependencies.identity = rig.kit.identity
        dependencies.transport = rig.transport
        let exits = DuoExitService(dependencies: dependencies)
        dependencies.exiting = exits
        keptAlive.append(contentsOf: [dependencies, exits] as [AnyObject])

        exits.startFresh()

        XCTAssertNil(secrets.credential())
        XCTAssertTrue(secrets.hasInstallMarker(), "the Keychain kept the marker")
        XCTAssertEqual(rig.store.notice, DuoUserMessage.generic, "and the person is told")
    }

    func testK_M54_theSpinnerIsUpWhileStartFreshWaitsAndDownAfter() async throws {
        let rig = makeRig()
        let bound = heldBound(rig)
        rig.store.upsert(live())
        let leaveGate = ERGate()
        let gated = ERGatedTransport(rig.transport)
        gated.leaveGate = leaveGate
        rig.kit.dependencies.transport = gated
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "l", now: now))
        rig.exits.startFresh()
        await yield(until: { leaveGate.entered == 1 }, "the leave is out")
        XCTAssertTrue(rig.store.isWorking, "up while the leave is out")
        bound.release()
        await yield(until: { rig.exits.pendingStartFresh == nil }, "the bound ends the wait")
        XCTAssertFalse(rig.store.isWorking)
        XCTAssertTrue(rig.store.duos.isEmpty)
        leaveGate.release()
        await settle(rig)
    }

    func testK_M57_startFreshsDrainSendsTheLeaveAndNotTheRename() async throws {
        let rig = makeRig()
        let bound = heldBound(rig)
        rig.store.upsert(live())
        rig.ops.enqueue(try renameOp("Jo B", key: "r"))
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "l", now: now))
        rig.transport.onLeave = { _, _ in self.leftOK() }
        rig.transport.onUpdateMe = { _ in self.member() }
        rig.exits.startFresh()
        await yield(until: { rig.exits.pendingStartFresh == nil }, "the wipe follows the drain")
        bound.release()
        XCTAssertEqual(count(rig, isLeave), 1)
        XCTAssertEqual(count(rig, isRename), 0)
        XCTAssertTrue(rig.store.duos.isEmpty)
    }

    func testK_M57b_startFreshsDrainSendsOnlyTheExitsEvenIfARenameArrivesInTheWindow() async throws {
        // The exits-only drain stands on its own: a rename queued after Start fresh began, before
        // its drain (a stage that queues one in the window), is in the drain's snapshot and is
        // still not sent by it.
        let rig = makeRig()
        let bound = heldBound(rig)
        rig.store.upsert(live())
        rig.transport.onLeave = { _, _ in self.leftOK() }
        rig.transport.onUpdateMe = { _ in self.member() }
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "l", now: now))
        rig.exits.startFresh()
        rig.ops.enqueue(try renameOp("Late", key: "late"))
        await yield(until: { rig.exits.pendingStartFresh == nil }, "the wipe follows the drain")
        bound.release()
        XCTAssertEqual(count(rig, isLeave), 1)
        XCTAssertEqual(count(rig, isRename), 0)
    }

    func testK_M58_aSecondStartFreshTapKeepsTheFirstOneInCharge() async throws {
        let rig = makeRig()
        let bound = heldBound(rig)
        rig.store.upsert(live())
        let leaveGate = ERGate()
        let gated = ERGatedTransport(rig.transport)
        gated.leaveGate = leaveGate
        rig.kit.dependencies.transport = gated
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "l", now: now))
        rig.exits.startFresh()
        let first = rig.exits.pendingStartFresh
        rig.exits.startFresh()
        XCTAssertNotNil(first)
        XCTAssertTrue(rig.exits.pendingStartFresh == first, "the second tap starts nothing")
        await yield(until: { leaveGate.entered == 1 }, "the leave is out")
        for _ in 0..<500 { await Task.yield() }
        XCTAssertEqual(leaveGate.entered, 1, "one leave, not two")
        bound.release()
        leaveGate.release()
        await yield(until: { rig.exits.pendingStartFresh == nil }, "done")
        await settle(rig)
    }

    func testK_M59_aDisconnectedLaunchStillSendsTheWaitingBlockBeforeTheWipe() async throws {
        let rig = makeRig()
        rig.kit.identity.launch = .disconnected
        let bound = heldBound(rig)
        rig.store.upsert(live())
        rig.ops.enqueue(try DuoQueuedOp.block(duoID: id, key: "b", now: now))
        rig.transport.onBlock = { _, _ in }
        rig.exits.startFresh()
        await yield(until: { rig.exits.pendingStartFresh == nil }, "the wipe follows the drain")
        bound.release()
        XCTAssertEqual(count(rig, isBlock), 1, "D33: a superseded phone's block is the server's to judge")
        XCTAssertTrue(rig.store.duos.isEmpty)
    }

    func testK_M60_aDeleteDuringStartFreshsWaitIsTheOnlyWipe() async throws {
        let rig = makeRig()
        let bound = heldBound(rig)
        rig.store.upsert(live())
        let leaveGate = ERGate()
        let gated = ERGatedTransport(rig.transport)
        gated.leaveGate = leaveGate
        rig.kit.dependencies.transport = gated
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "l", now: now))
        rig.transport.onDeleteMe = { _, _ in }
        let epoch = rig.store.wipeEpoch
        rig.exits.startFresh()
        await yield(until: { leaveGate.entered == 1 }, "the leave is out")
        let deleted = await rig.exits.deleteMyData()
        bound.release()
        await yield(until: { rig.exits.pendingStartFresh == nil }, "Start fresh ends")
        leaveGate.release()
        await settle(rig)
        XCTAssertTrue(deleted)
        XCTAssertEqual(rig.store.wipeEpoch - epoch, 1, "one wipe, not two")
    }

    func testK_M61_withNoCredentialStartFreshWipesAtOnce() throws {
        let rig = makeRig(credential: nil)
        rig.store.upsert(live())
        rig.ops.enqueue(try DuoQueuedOp.leave(duoID: id, key: "kept", now: now))
        rig.exits.startFresh()
        XCTAssertTrue(rig.store.duos.isEmpty)
        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertNil(rig.exits.pendingStartFresh)
    }

    // MARK: - D75: only Clear takes the pushed "ended" notice

    func testD75_aLeaveOrBlockKeepsTheEndedNoticeAndOnlyTheClearTakesIt() async throws {
        for kind in [DuoPendingOp.leave, .block] {
            let rig = makeRig()
            rig.store.upsert(live())
            rig.transport.onLeave = { _, _ in self.leftOK() }
            rig.transport.onBlock = { _, _ in }
            if kind == .leave { await rig.exits.leave(live()) } else { await rig.exits.block(live()) }
            await settle(rig)
            XCTAssertTrue(rig.ops.pending.isEmpty, "\(kind) landed")
            XCTAssertEqual(rig.kit.announcer.removedFor, [id, id], "\(kind): at the tap and at the landing, both keeping the ended notice")
            XCTAssertTrue(rig.kit.announcer.removedIncludingEnded.isEmpty, "\(kind): the app ended it, so the person is still told")

            rig.exits.clear(ended())

            XCTAssertEqual(rig.kit.announcer.removedIncludingEnded, [id], "\(kind): the Clear takes the notice with the card")
            XCTAssertEqual(rig.kit.announcer.removedFor.count, 2, "\(kind): and nothing else")
        }
    }

    func testD75_aLeaveStillQueuedAtTheClearTakesNothingMoreWhenItLands() async throws {
        // D67 keeps the leave; its landing finds no card, so it neither shows nor takes anything.
        let rig = makeRig()
        rig.store.upsert(live())
        await rig.exits.leave(live()) // offline: the ended card, the leave queued
        rig.exits.clear(ended())
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.leave])
        rig.transport.onLeave = { _, _ in self.leftOK() }
        await rig.ops.drain()
        await settle(rig)
        XCTAssertTrue(rig.ops.pending.isEmpty, "the leave went")
        XCTAssertNil(rig.store.duo(id))
        XCTAssertEqual(rig.kit.announcer.removedFor, [id], "only at the tap")
        XCTAssertEqual(rig.kit.announcer.removedIncludingEnded, [id], "only at the Clear")
    }

    // MARK: - E19: the queue against a model of the Worker, with kills

    func testStressAgainstAModelOfTheWorkerWithKillsAndLostAnswers() async throws {
        let seeds = Int(ProcessInfo.processInfo.environment["ER_SEEDS"] ?? "60") ?? 60
        var totals = ERStressTotals()
        for seed in 0..<seeds {
            await ERStress.runOne(seed: UInt64(seed), steps: 40, totals: &totals)
        }
        print("ER-STRESS runs=\(totals.runs) steps=\(totals.steps) ops=\(totals.ops) relaunches=\(totals.relaunches) requests=\(totals.requests) effects=\(totals.effects)")
        for failure in totals.failures.prefix(20) { print("ER-FAIL \(failure)") }
        XCTAssertGreaterThan(totals.effects, 0)
        XCTAssertTrue(totals.failures.isEmpty, "\(totals.failures.count) invariant failures: \(totals.failures.prefix(5))")
    }
}

// MARK: - The model of the Worker (trimmed from the queue lens's LQSupport)

fileprivate struct ERRandom: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
    mutating func int(_ range: ClosedRange<Int>) -> Int { range.lowerBound + Int(next() % UInt64(range.count)) }
}

/// The awaits of a killed process: never resumed.
fileprivate final class ERLimbo: @unchecked Sendable {
    static let shared = ERLimbo()
    private let lock = NSLock()
    private var held: [Any] = []
    func hang<T>() async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            lock.lock(); held.append(continuation); lock.unlock()
        }
    }
}

fileprivate final class ERDisk: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Any] = [:]
    func get(_ key: String) -> Any? { lock.lock(); defer { lock.unlock() }; return items[key] }
    func set(_ key: String, _ value: Any?) { lock.lock(); items[key] = value; lock.unlock() }
    var all: [String: Any] { lock.lock(); defer { lock.unlock() }; return items }
}

fileprivate final class ERLife: @unchecked Sendable {
    private let lock = NSLock()
    private var isDead = false
    var dead: Bool { lock.lock(); defer { lock.unlock() }; return isDead }
    func kill() { lock.lock(); isDead = true; lock.unlock() }
}

/// The defaults a process sees: the shared disk while it lives; after its kill every write is lost.
fileprivate final class ERDefaults: UserDefaults, @unchecked Sendable {
    let disk: ERDisk
    let life: ERLife
    init(disk: ERDisk, life: ERLife) {
        self.disk = disk
        self.life = life
        super.init(suiteName: "er.memory.unused")!
    }
    override func object(forKey defaultName: String) -> Any? { disk.get(defaultName) }
    override func set(_ value: Any?, forKey defaultName: String) {
        if life.dead { return }
        disk.set(defaultName, value)
    }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) {
        if life.dead { return }
        disk.set(defaultName, nil)
    }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? Bool) ?? false }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? Int) ?? 0 }
    override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? Double) ?? 0 }
    override func dictionaryRepresentation() -> [String: Any] { disk.all }
}

/// The Worker as far as the queue can see it: the idempotency table keyed by `Idempotency-Key`,
/// storing method, path and SHA-256 of the body, and the effect of each route.
fileprivate final class ERServer: @unchecked Sendable {
    struct Duo { var active = true; var endedBy: String?; var endedAt: String?; var blockBit = false }
    struct Record { var method: String; var path: String; var hash: String }

    enum Fault { case none, offlineBefore, transient(Int, String, [String: String]), killBefore, loseAnswerAfter, killAfter, gatewayAfter }

    private let lock = NSLock()
    private var rng: ERRandom
    let bearer: String
    var duos: [String: Duo] = [:]
    var displayName: String? = "Jo"
    var skin: String? = "classic"
    var pushToken: String?
    var records: [String: Record] = [:]
    var shapesByKey: [String: Set<String>] = [:]
    var mismatches = 0
    var effects: [String] = []
    var requests = 0
    var networkUp = true
    var faultsOn = true
    var clock = 1_790_000_000

    init(seed: UInt64, bearer: String) {
        rng = ERRandom(seed: seed)
        self.bearer = bearer
    }

    func withLock<T>(_ body: (ERServer) -> T) -> T { lock.lock(); defer { lock.unlock() }; return body(self) }

    func fault() -> Fault {
        withLock { s in
            guard s.networkUp else { return .offlineBefore }
            guard s.faultsOn else { return .none }
            if s.rng.chance(0.15) { return .offlineBefore }
            if s.rng.chance(0.03) { return .killBefore }
            if s.rng.chance(0.15) {
                switch s.rng.int(0...5) {
                case 0: return .transient(503, #"{"error":{"code":"maintenance","message":"m","request_id":"r","retry_after_s":31}}"#, ["Content-Type": "application/json", "Retry-After": "31"])
                case 1: return .transient(429, #"{"error":{"code":"rate_limited","message":"m","request_id":"r","retry_after_s":45}}"#, ["Content-Type": "application/json", "Retry-After": "45"])
                case 2: return .transient(500, "<html>oops</html>", ["Content-Type": "text/html"])
                case 3: return .transient(403, "<html>waf</html>", ["Content-Type": "text/html"])
                case 4: return .transient(401, "<html>portal</html>", ["Content-Type": "text/html"])
                default: return .transient(302, "", ["Location": "https://portal.example/"])
                }
            }
            if s.rng.chance(0.03) { return .killAfter }
            if s.rng.chance(0.15) { return .loseAnswerAfter }
            if s.rng.chance(0.05) { return .gatewayAfter }
            return .none
        }
    }

    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    private func json(_ status: Int, _ body: String) -> (Int, Data, [String: String]) {
        (status, Data(body.utf8), ["Content-Type": "application/json", "X-Request-Id": "rid-\(requests)"])
    }

    private func errorBody(_ code: String, _ status: Int) -> (Int, Data, [String: String]) {
        json(status, #"{"error":{"code":"\#(code)","message":"m","request_id":"rid"}}"#)
    }

    func apply(_ request: URLRequest) -> (Int, Data, [String: String]) { withLock { $0.applyLocked(request) } }

    private func applyLocked(_ request: URLRequest) -> (Int, Data, [String: String]) {
        requests += 1
        clock += 1
        guard request.value(forHTTPHeaderField: "Authorization") == "Bearer \(bearer)" else { return errorBody("unauthenticated", 401) }
        let method = request.httpMethod ?? "GET"
        let path = request.url?.path ?? ""
        let body = request.httpBody ?? Data()
        let parts = path.split(separator: "/").map(String.init)   // ["v1", "duos", id, "leave"]
        let key = request.value(forHTTPHeaderField: "Idempotency-Key")
        let hash = Self.hash(body)
        if let key { shapesByKey[key, default: []].insert("\(method) \(path) \(hash)") }
        switch (method, parts.count >= 4 ? parts[3] : parts.last ?? "") {
        case ("POST", "leave"), ("POST", "block"):
            guard let key, String(decoding: body, as: UTF8.self) == "{}" else { return errorBody("schema", 400) }
            let id = parts[2]
            let isLeave = parts[3] == "leave"
            if let record = records[key] {
                guard record.method == method, record.path == path, record.hash == hash else {
                    mismatches += 1
                    return errorBody("idempotency_mismatch", 422)
                }
                guard let duo = duos[id] else { return errorBody("maintenance", 503) }
                return isLeave ? leaveAnswer(duo) : (204, Data(), ["X-Request-Id": "rid"])
            }
            guard var duo = duos[id] else { return errorBody("duo_unknown", 404) }
            if isLeave {
                if !duo.active { return leaveAnswer(duo) }
                duo.active = false
                duo.endedBy = "owner"
                duo.endedAt = DuoWireTime.format(Date(timeIntervalSince1970: TimeInterval(clock)))
                duos[id] = duo
                effects.append("leave:\(id)")
                records[key] = Record(method: method, path: path, hash: hash)
                return leaveAnswer(duo)
            }
            var changed = false
            if duo.active {
                duo.active = false
                duo.endedBy = "owner"
                duo.endedAt = DuoWireTime.format(Date(timeIntervalSince1970: TimeInterval(clock)))
                changed = true
            }
            if !duo.blockBit { duo.blockBit = true; changed = true }
            duos[id] = duo
            if changed { effects.append("block:\(id)") }
            records[key] = Record(method: method, path: path, hash: hash)
            return (204, Data(), ["X-Request-Id": "rid"])
        case ("PATCH", "me"):
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return errorBody("schema", 400) }
            if object.keys.contains("display_name") {
                let new = object["display_name"] as? String
                if new != displayName { displayName = new; effects.append("name:\(new ?? "null")") }
            }
            if let new = object["skin"] as? String, new != skin { skin = new; effects.append("skin:\(new)") }
            let name = displayName.map { "\"\($0)\"" } ?? "null"
            return json(200, #"{"display_name":\#(name),"id":"6d2a0000-0000-4000-8000-0000000000aa","skin":"\#(skin ?? "classic")","support_id":"ABCD1234EFGH","terms_version":1,"tier":"low"}"#)
        case ("PUT", "push"):
            guard let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any], let token = object["token"] as? String else {
                return errorBody("schema", 400)
            }
            if token != pushToken { pushToken = token; effects.append("push:\(token)") }
            return (204, Data(), ["X-Request-Id": "rid"])
        case ("DELETE", "push"):
            if pushToken != nil { pushToken = nil; effects.append("unpush") }
            return (204, Data(), ["X-Request-Id": "rid"])
        default:
            return errorBody("schema", 400)
        }
    }

    private func leaveAnswer(_ duo: Duo) -> (Int, Data, [String: String]) {
        json(200, #"{"ended_at":"\#(duo.endedAt ?? "2026-10-08T09:00:00Z")","ended_by":"\#(duo.endedBy ?? "owner")","state":"ended"}"#)
    }
}

fileprivate final class ERSession: DuoHTTPSession, @unchecked Sendable {
    let server: ERServer
    let life: ERLife
    let yields: Int
    init(server: ERServer, life: ERLife, yields: Int) { self.server = server; self.life = life; self.yields = yields }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        if life.dead { return await ERLimbo.shared.hang() }
        for _ in 0..<yields { await Task.yield() }
        if life.dead { return await ERLimbo.shared.hang() }
        let url = request.url!
        func respond(_ r: (Int, Data, [String: String])) -> (Data, URLResponse) {
            (r.1, HTTPURLResponse(url: url, statusCode: r.0, httpVersion: nil, headerFields: r.2)!)
        }
        switch server.fault() {
        case .offlineBefore:
            throw URLError(.notConnectedToInternet)
        case .killBefore:
            life.kill()
            return await ERLimbo.shared.hang()
        case .transient(let status, let body, let headers):
            return respond((status, Data(body.utf8), headers))
        case .none:
            let answer = server.apply(request)
            for _ in 0..<yields { await Task.yield() }
            if life.dead { return await ERLimbo.shared.hang() }
            return respond(answer)
        case .loseAnswerAfter:
            _ = server.apply(request)
            throw URLError(.networkConnectionLost)
        case .killAfter:
            _ = server.apply(request)
            life.kill()
            return await ERLimbo.shared.hang()
        case .gatewayAfter:
            _ = server.apply(request)
            return respond((502, Data("<html>bad gateway</html>".utf8), ["Content-Type": "text/html"]))
        }
    }
}

fileprivate final class ERIdentity: DuoIdentityProviding, @unchecked Sendable {
    let life: ERLife
    var credential: DuoCredential?
    var installDay = "2026-09-01"
    var launch: DuoIdentityLaunch = .ready
    var killNow: () -> Bool = { false }
    init(credential: DuoCredential?, life: ERLife) { self.credential = credential; self.life = life }
    func store(_ credential: DuoCredential) throws { self.credential = credential; launch = .ready }
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() { credential = nil; launch = .none }
    func prepare() async -> DuoIdentityLaunch {
        if life.dead { return await ERLimbo.shared.hang() }
        await Task.yield()
        if killNow() { life.kill() }
        if life.dead { return await ERLimbo.shared.hang() }
        return launch
    }
    func continueAsRestored() async {}
}

@MainActor
fileprivate final class ERMonitor: DuoOpQueueService.PathMonitoring {
    private var onChange: (@MainActor (Bool) -> Void)?
    func start(_ onPathChange: @escaping @MainActor (Bool) -> Void) { onChange = onPathChange }
    func reading(_ satisfied: Bool) { onChange?(satisfied) }
}

/// The queue as the exit service sees it, recording each entry that reached the disk.
@MainActor
fileprivate final class EROps: DuoOpQueueing {
    let base: DuoOpQueueService
    let onEnqueue: (DuoQueuedOp) -> Void
    init(base: DuoOpQueueService, onEnqueue: @escaping (DuoQueuedOp) -> Void) { self.base = base; self.onEnqueue = onEnqueue }
    var pending: [DuoQueuedOp] { base.pending }
    func enqueue(_ op: DuoQueuedOp) {
        base.enqueue(op)
        if base.pending.contains(where: { $0.key == op.key }) { onEnqueue(op) }
    }
    func drain() async { await base.drain() }
    func startMonitoring() { base.startMonitoring() }
    func discardAll() { base.discardAll() }
    func discardIdentityBound() { base.discardIdentityBound() }
}

@MainActor
fileprivate final class ERProcess {
    let life = ERLife()
    let store: DuoStore
    let deps: DuoDependencies
    let service: DuoOpQueueService
    let ops: EROps
    let exit: DuoExitService
    let monitor = ERMonitor()

    init(disk: ERDisk, server: ERServer, credential: DuoCredential, yields: Int, onEnqueue: @escaping (DuoQueuedOp) -> Void,
         killAtAwait: @escaping () -> Bool) {
        let cache = DuoCache(defaults: ERDefaults(disk: disk, life: life))
        store = DuoStore(cache: cache, usesServer: true, reloadWidget: {})
        let identity = ERIdentity(credential: credential, life: life)
        identity.killNow = killAtAwait
        deps = DuoDependencies(host: store, cache: cache, secrets: DuoSecrets(store: DuoMemorySecretStore()), clock: TestClock(),
                               random: DuoSystemRandom(), client: DuoClientInfo(marketingVersion: "2.0", build: "57"),
                               attester: FakeDuoAttester(), deviceCheck: FakeDuoDeviceCheck())
        deps.identity = identity
        deps.transport = DuoAPIClient(baseURL: URL(string: "https://api.er.test/v1")!, client: deps.client, credentials: identity,
                                      attester: deps.attester, session: ERSession(server: server, life: life, yields: yields))
        let monitor = self.monitor
        service = DuoOpQueueService(dependencies: deps, makeMonitor: { monitor })
        ops = EROps(base: service, onEnqueue: onEnqueue)
        deps.ops = ops
        deps.push = FakePush()
        exit = DuoExitService(dependencies: deps)
        deps.exiting = exit
        let life = self.life
        deps.sleep = { _ in
            if life.dead { await ERLimbo.shared.hang() as Void }
            for _ in 0..<3 { await Task.yield() }
            if killAtAwait() { life.kill() }
            if life.dead { await ERLimbo.shared.hang() as Void }
            try Task.checkCancellation()
        }
        store.install(deps)
    }
}

/// Every process ever made: a killed one's tasks may still run up to their next await, and its
/// store is the dependencies' unowned host, which in the app lives as long as the app.
@MainActor fileprivate var erGraveyard: [ERProcess] = []

fileprivate final class ERKillBox: @unchecked Sendable {
    var rng: ERRandom
    var p: Double
    init(seed: UInt64, p: Double) { rng = ERRandom(seed: seed); self.p = p }
    func killNow() -> Bool { rng.chance(p) }
}

fileprivate struct ERStressTotals {
    var runs = 0, steps = 0, ops = 0, relaunches = 0, requests = 0, effects = 0
    var failures: [String] = []
}

/// The model-based run: the real exit service, queue service and API client over the model of the
/// Worker, with lost answers, transient failures, and kills at every external await and at random
/// moments, each followed by a relaunch over the same disk. Within each group the server's effects
/// must be exactly what the entries asked for, in their order (D74); nothing is applied twice or
/// under different bytes; every card ends up matching the server.
@MainActor
fileprivate enum ERStress {
    static let duoIDs = (1...4).map { UUID(uuidString: String(format: "6d2a0000-0000-4000-8000-%012d", $0))! }

    static func group(of effect: String) -> String {
        if effect.hasPrefix("leave:") || effect.hasPrefix("block:") { return "exits" }
        if effect.hasPrefix("name:") || effect.hasPrefix("skin:") { return "profile" }
        return "push"
    }

    static func expectedEffects(_ ops: [DuoQueuedOp]) -> [String] {
        var active = Set(duoIDs.map { $0.uuidString.lowercased() })
        var blocked = Set<String>()
        var name: String? = "Jo", skin: String? = "classic", token: String?
        var effects: [String] = []
        for op in ops {
            switch op.kind {
            case .leave:
                if active.remove(op.duoID!) != nil { effects.append("leave:\(op.duoID!)") }
            case .block:
                var changed = active.remove(op.duoID!) != nil
                if blocked.insert(op.duoID!).inserted { changed = true }
                if changed { effects.append("block:\(op.duoID!)") }
            case .updateMe:
                let request = try! DuoWireCoding.decode(DuoWireUpdateMeRequest.self, from: op.body)
                switch request.displayName {
                case .absent: break
                case .null: if name != nil { name = nil; effects.append("name:null") }
                case .value(let n): if n != name { name = n; effects.append("name:\(n)") }
                }
                if case .value(let s) = request.skin, s != skin { skin = s; effects.append("skin:\(s)") }
            case .registerPush:
                let request = try! DuoWireCoding.decode(DuoWireRegisterPushRequest.self, from: op.body)
                if request.token != token { token = request.token; effects.append("push:\(request.token)") }
            case .unregisterPush:
                if token != nil { token = nil; effects.append("unpush") }
            }
        }
        return effects
    }

    static func diskKeys(_ disk: ERDisk) -> [String] {
        guard let data = disk.get(DuoCache.opsKey) as? Data else { return [] }
        return ((try? JSONDecoder().decode([DuoQueuedOp].self, from: data)) ?? []).map(\.key)
    }

    static func runOne(seed: UInt64, steps: Int, totals: inout ERStressTotals) async {
        var rng = ERRandom(seed: seed &* 7919 &+ 1)
        let credential = DuoFixtures.credential()
        let server = ERServer(seed: seed &+ 17, bearer: "\(credential.deviceID).\(credential.deviceSecret)")
        server.withLock { s in for id in duoIDs { s.duos[id.uuidString.lowercased()] = .init() } }
        let disk = ERDisk()
        let box = ERKillBox(seed: seed &+ 5, p: 0.02)
        var enqueued: [DuoQueuedOp] = []
        var failures: [String] = []
        let yields = rng.int(0...6)
        func make() -> ERProcess {
            let made = ERProcess(disk: disk, server: server, credential: credential, yields: yields,
                                 onEnqueue: { enqueued.append($0) }, killAtAwait: { box.killNow() })
            erGraveyard.append(made)
            return made
        }
        final class Flag { var done = false }
        var live: [Flag] = []
        func spawn(_ body: @escaping @MainActor () async -> Void) {
            let flag = Flag()
            live.append(flag)
            Task { @MainActor in await body(); flag.done = true }
        }
        func waitLive(_ limit: Int) async {
            for _ in 0..<limit where live.contains(where: { !$0.done }) { await Task.yield() }
            live.removeAll { $0.done }
        }
        var process = make()
        for id in duoIDs { process.store.upsert(DuoFixtures.duo(id: id)) }
        process.service.startMonitoring()
        process.monitor.reading(true)
        func relaunch() {
            process = make()
            totals.relaunches += 1
            live = []
            process.service.startMonitoring()
            process.monitor.reading(true)
            let p = process
            spawn { await p.ops.drain() }
        }
        var seenOnDisk = Set<String>(), removed = Set<String>()
        func checkDisk(_ when: String) {
            let keys = diskKeys(disk)
            let order = enqueued.map(\.key)
            var index = order.startIndex
            for key in keys {
                guard let found = order[index...].firstIndex(of: key) else {
                    failures.append("seed \(seed) \(when): disk order \(keys) is not a subsequence of \(order)")
                    break
                }
                index = order.index(after: found)
            }
            for key in keys where removed.contains(key) { failures.append("seed \(seed) \(when): \(key) came back after removal") }
            let now = Set(keys)
            for key in seenOnDisk where !now.contains(key) { removed.insert(key) }
            seenOnDisk.formUnion(now)
        }
        var renameN = 0, pushN = 0
        for step in 0..<steps {
            totals.steps += 1
            if process.life.dead { relaunch() }
            let p = process
            switch rng.int(0...99) {
            case 0..<22:
                if let duo = p.store.duos.filter({ !$0.hasEnded }).randomElement(using: &rng) { spawn { await p.exit.leave(duo) } }
            case 22..<34:
                if let duo = p.store.duos.randomElement(using: &rng) { spawn { await p.exit.block(duo) } }
            case 34..<50:
                renameN += 1
                let name: DuoWireField<String> = rng.chance(0.15) ? .null : .value("n\(seed)-\(renameN)")
                let skin: DuoWireField<String> = rng.chance(0.3) ? .value(["forest", "grape", "classic"][rng.int(0...2)]) : .absent
                p.ops.enqueue(try! DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: name, skin: skin), key: UUID().uuidString.lowercased(), now: Date()))
                spawn { await p.ops.drain() }
            case 50..<60:
                pushN += 1
                let op: DuoQueuedOp
                if rng.chance(0.3) {
                    op = DuoQueuedOp.unregisterPush(key: UUID().uuidString.lowercased(), now: Date())
                } else {
                    op = try! DuoQueuedOp.registerPush(DuoWireRegisterPushRequest(token: "tok\(pushN)", apnsEnv: "sandbox", tz: "Europe/London",
                                                                                  wakeStartMin: 480, wakeEndMin: 1320, notificationsEnabled: true),
                                                       firstUpload: rng.chance(0.2), key: UUID().uuidString.lowercased(), now: Date())
                }
                p.ops.enqueue(op)
                spawn { await p.ops.drain() }
            case 60..<72:
                spawn { await p.ops.drain() }
            case 72..<80:
                p.monitor.reading(false)
                p.monitor.reading(true)
            case 80..<86:
                server.withLock { $0.networkUp.toggle() }
                if server.withLock({ $0.networkUp }) { p.monitor.reading(false); p.monitor.reading(true) }
            case 86..<92:
                p.life.kill()
            default:
                break
            }
            for _ in 0..<rng.int(0...40) { await Task.yield() }
            if rng.chance(0.2) { await waitLive(3_000) }
            checkDisk("step \(step)")
        }

        // Settle: the network back, no faults or kills, triggers until the queue is empty.
        server.withLock { $0.faultsOn = false; $0.networkUp = true }
        box.p = 0
        if process.life.dead { relaunch() }
        await waitLive(5_000)
        for _ in 0..<40 {
            if process.life.dead { relaunch() }
            let p = process
            spawn { await p.ops.drain() }
            await waitLive(5_000)
            for _ in 0..<300 where !process.service.isIdle { await Task.yield() }
            if diskKeys(disk).isEmpty { break }
        }
        for _ in 0..<500 { await Task.yield() }
        checkDisk("end")

        let expected = expectedEffects(enqueued)
        let actual = server.withLock { $0.effects }
        if !diskKeys(disk).isEmpty { failures.append("seed \(seed): queue not empty at the end: \(diskKeys(disk))") }
        for group in ["exits", "profile", "push"] {
            let want = expected.filter { Self.group(of: $0) == group }, got = actual.filter { Self.group(of: $0) == group }
            if want != got { failures.append("seed \(seed) \(group): effects \(got) != expected \(want)") }
        }
        let (mismatches, shapes) = server.withLock { ($0.mismatches, $0.shapesByKey) }
        if mismatches > 0 { failures.append("seed \(seed): \(mismatches) idempotency mismatches") }
        for (key, set) in shapes where set.count > 1 { failures.append("seed \(seed): key \(key) sent as \(set.count) different requests") }
        // The cards: nothing waiting, ended exactly when the server ended them.
        let store = DuoStore(cache: DuoCache(defaults: ERDefaults(disk: disk, life: ERLife())), usesServer: true, reloadWidget: {})
        for duo in store.duos {
            if duo.pendingOp != nil { failures.append("seed \(seed): card \(duo.id) still pending \(String(describing: duo.pendingOp))") }
            let serverDuo = server.withLock { $0.duos[duo.id.uuidString.lowercased()]! }
            if duo.hasEnded != !serverDuo.active {
                failures.append("seed \(seed): card \(duo.id) ended=\(duo.hasEnded), server active=\(serverDuo.active)")
            }
        }
        totals.runs += 1
        totals.ops += enqueued.count
        totals.requests += server.withLock { $0.requests }
        totals.effects += actual.count
        totals.failures += failures
    }
}
#endif
