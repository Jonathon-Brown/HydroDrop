#if DUO_V2
import XCTest
@testable import HydroDrop

// MARK: - Test helpers (stage E)

/// Holds a `DELETE /me` until the test lets it go.
fileprivate final class EExitGate: @unchecked Sendable {
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

/// `FakeDuoTransport` with a gate in front of `DELETE /me`.
fileprivate final class EExitGatedTransport: DuoTransport, @unchecked Sendable {
    let base: FakeDuoTransport
    var deleteGate: EExitGate?

    init(_ base: FakeDuoTransport) { self.base = base }

    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws {
        if let deleteGate { await deleteGate.wait() }
        try await base.deleteMe(request, key: key)
    }

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { try await base.createDevice(request) }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try await base.attestChallenge() }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { try await base.rotate(as: credential) }
    func me() async throws -> DuoWireGetMeResponse { try await base.me() }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { try await base.updateMe(request) }
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
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { try await base.leave(duoID: duoID, key: key) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try await base.block(duoID: duoID, key: key) }
}

/// Counts callers that came back, from tasks on the main actor.
@MainActor
fileprivate final class EExitCounter {
    var count = 0
}

// MARK: - The tests

/// Every way out (final design §7.5, §10.1, §12.2, §12.3, §3.4), through the real exit service and
/// the real op queue over a `DuoTestKit`.
@MainActor
final class DuoExitServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let otherDuo = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000002")!
    private let orphanDuo = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000ff")!
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    private struct Rig {
        let kit: DuoTestKit
        let exits: DuoExitService
        let ops: DuoOpQueueService
        var store: DuoStore { kit.store }
        var transport: FakeDuoTransport { kit.transport }
    }

    private func makeRig(credential: DuoCredential? = DuoFixtures.credential()) -> Rig {
        let kit = DuoTestKit(credential: credential)
        kit.identity.launch = credential == nil ? .none : .ready
        // These tests are about the exits, not the queue's retries (`DuoOpQueueServiceTests` has
        // those): a wait ends at once with no retry, so each test sees the one attempt it makes and
        // nothing of the queue runs on after it.
        kit.dependencies.sleep = { _ in throw CancellationError() }
        let ops = DuoOpQueueService(dependencies: kit.dependencies)
        kit.dependencies.ops = ops
        let exits = DuoExitService(dependencies: kit.dependencies)
        kit.dependencies.exiting = exits
        return Rig(kit: kit, exits: exits, ops: ops)
    }

    private func leaveResponse(_ endedBy: DuoEndedBy = .owner) -> DuoWireLeaveResponse {
        DuoWireLeaveResponse(state: "ended", endedBy: endedBy, endedAt: Date(timeIntervalSince1970: 1_790_000_500))
    }

    private func failure(_ code: DuoErrorCode, status: Int) -> DuoTransportError {
        DuoTransportError(code: code, context: DuoErrorContext(httpStatus: status, requestID: "req-1"))
    }

    private func memberInfo() -> DuoMemberInfo {
        DuoMemberInfo(memberID: "m", displayName: "Jo", skin: "forest", supportID: "ABCD1234EFGH", tier: .low, termsVersion: 1,
                      nudgesPerDay: 1, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: now)
    }

    private func liveDuo(_ id: UUID = DuoFixtures.duoID, role: DuoRole = .owner, partner: String = "Sam") -> DuoState {
        var duo = DuoFixtures.duo(id: id, role: role, partner: partner, now: now)
        duo.invite = DuoInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: now.addingTimeInterval(3_600))
        duo.openInviteExpiresAt = now.addingTimeInterval(3_600)
        return duo
    }

    private func endedDuo(_ id: UUID = DuoFixtures.duoID) -> DuoState {
        DuoFixtures.duo(id: id, ended: true, now: now)
    }

    private func duoKeys(_ defaults: UserDefaults) -> Set<String> {
        Set(defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix("duo") })
    }

    private func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DuoExitServiceTests-\(UUID().uuidString)", isDirectory: true)
        folders.append(folder)
        return folder
    }

    /// Writes something under every key `DuoCache` knows, every Keychain item Duo makes, and the
    /// queue, so a wipe can be checked against the whole list rather than the parts a test thought of.
    private func seedEverything(_ rig: Rig) async throws {
        let store = rig.store
        let cache = rig.kit.dependencies.cache
        let secrets = rig.kit.dependencies.secrets
        let duoID = DuoFixtures.duoID
        store.myDisplayName = "Jo"
        _ = await store.acceptTerms()
        store.diagnostics.recordRequest(status: 200, requestID: "old-request", at: now)
        store.diagnostics.record(failure(.maintenance, status: 503), duoID: duoID, now: now)
        store.memberInfo = memberInfo()
        store.pendingInvite = DuoPendingInvite(code: "H7K39QWX", k: "ABCDEFGHJKMNPQRSTVWXYZ0123", receivedAt: now)
        store.upsert(liveDuo())
        store.upsert(endedDuo(otherDuo))
        var ledger = DuoLedger()
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: duoID, day: "2026-10-06"))
        cache.saveLedger(ledger)
        rig.ops.enqueue(try DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: .value("Jo")), key: "rename", now: now))
        cache.saveRejectedDays([duoID.uuidString.lowercased(): DuoRejectedDays(rows: ["2026-10-06": DuoFixtures.status(.owner, "2026-10-06", bucket: 100)])])
        cache.savePushUpload(DuoPushUploadState(tokenHash: "h", environment: .sandbox, zone: "UTC", windowStart: nil, windowEnd: nil,
                                                enabled: true, uploadedAt: now))
        cache.saveSeenDeviceIDs(["old-device"])
        var journal = DuoInflightJournal()
        _ = journal.key(for: "POST /invites/redeem", body: Data(#"{"code":"H7K39QWX","device_check_token":"abc"}"#.utf8), now: now,
                        random: rig.kit.random)
        cache.saveInflight(journal)
        cache.markCleared(UUID(), now: now)
        // What a wipe keeps.
        store.notificationsEnabled = false
        cache.inviteMomentDismissed = true
        cache.goalRaiseNoticeShown = true
        XCTAssertEqual(store.recordBirthYear(1990, now: now), .allowed)
        // The Keychain: the credential and marker, this duo's link secret, a link secret for a duo
        // that left the cache by another route, this device's attestation key, another device's,
        // and a pending one.
        let credential = DuoFixtures.credential()
        try secrets.save(credential)
        try secrets.writeInstallMarker(random: rig.kit.random)
        try secrets.saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: duoID)
        try secrets.saveLinkSecret("ZYXWVTSRQPNMKJHGFEDCBA3210", forDuo: orphanDuo)
        let keychain = rig.kit.secretStore
        try keychain.write(Data("key-1".utf8), service: DuoSecrets.service, account: DuoSecrets.attestKeyAccount(deviceID: credential.deviceID),
                         accessibility: .afterFirstUnlockThisDeviceOnly)
        try keychain.write(Data("key-0".utf8), service: DuoSecrets.service, account: DuoSecrets.attestKeyAccount(deviceID: "6d2a0000-0000-4000-8000-0000000000cc"),
                         accessibility: .afterFirstUnlockThisDeviceOnly)
        try keychain.write(Data("key-2".utf8), service: DuoSecrets.service, account: DuoSecrets.pendingAttestKeyAccount,
                         accessibility: .afterFirstUnlockThisDeviceOnly)
        rig.kit.attester.keys = [credential.deviceID]
    }

    /// What every wipe must leave and take, checked the same way for Delete my Duo data and Start fresh.
    private func assertWiped(_ rig: Rig, file: StaticString = #filePath, line: UInt = #line) {
        let store = rig.store
        let kit = rig.kit
        XCTAssertEqual(duoKeys(kit.defaults), Set(DuoCache.keptKeys), "on disk, exactly the keys a wipe keeps", file: file, line: line)
        XCTAssertEqual(kit.secretStore.accounts(service: DuoSecrets.service), [],
                       "every Keychain item of Duo's service, orphans included", file: file, line: line)
        XCTAssertTrue(store.duos.isEmpty, file: file, line: line)
        XCTAssertNil(store.memberInfo, file: file, line: line)
        XCTAssertNil(store.pendingInvite, file: file, line: line)
        XCTAssertEqual(store.diagnostics, DuoDiagnostics(), file: file, line: line)
        XCTAssertEqual(store.myDisplayName, "", file: file, line: line)
        XCTAssertFalse(store.needsTerms, file: file, line: line)
        XCTAssertFalse(store.newDeviceNotice, file: file, line: line)
        XCTAssertTrue(rig.ops.pending.isEmpty, file: file, line: line)
        XCTAssertTrue(kit.dependencies.cache.loadInflight(now: now).entries.isEmpty, file: file, line: line)
        XCTAssertTrue(kit.dependencies.cache.loadLedger().seen.isEmpty, file: file, line: line)
        XCTAssertNil(kit.dependencies.cache.loadPushUpload(), "the push record goes with the identity", file: file, line: line)
        XCTAssertNil(kit.identity.credential, file: file, line: line)
        XCTAssertEqual(kit.identity.discardCount, 1, file: file, line: line)
        XCTAssertFalse(kit.attester.hasKey(forDevice: DuoFixtures.credential().deviceID), file: file, line: line)
        XCTAssertEqual(kit.announcer.removedAll, 1, "every Duo notification is taken back", file: file, line: line)
        XCTAssertFalse(store.hasIdentity, file: file, line: line)
        XCTAssertFalse(store.isWorking, file: file, line: line)
        // What stays.
        XCTAssertEqual(store.ageStatus, .allowed, "the age answer is never deleted", file: file, line: line)
        XCTAssertEqual(kit.dependencies.cache.ageStatus, .allowed, file: file, line: line)
        XCTAssertFalse(store.notificationsEnabled, "nor the notifications switch", file: file, line: line)
        XCTAssertTrue(kit.dependencies.cache.inviteMomentDismissed, file: file, line: line)
        XCTAssertTrue(kit.dependencies.cache.goalRaiseNoticeShown, file: file, line: line)
    }

    // MARK: - Leave

    func testAnOfflineLeaveShowsTheEndedCardAtOnceAndClearsItsWaitWhenSent() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo())

        await rig.exits.leave(liveDuo()) // no connection

        let shown = try XCTUnwrap(rig.store.duo(DuoFixtures.duoID))
        XCTAssertEqual(shown.endedAt, now, "§10.1: the ended card at once")
        XCTAssertEqual(shown.endedBy, .owner, "ended by me, in my role")
        XCTAssertEqual(shown.pendingOp, .leave)
        XCTAssertNil(shown.invite, "the server voids the open code with the end")
        XCTAssertNil(shown.openInviteExpiresAt)
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.leave])
        XCTAssertEqual(rig.ops.pending.first?.path, "/duos/\(DuoFixtures.duoID.uuidString.lowercased())/leave")

        rig.transport.onLeave = { _, _ in self.leaveResponse() }
        await rig.ops.drain() // the connection is back

        let sent = try XCTUnwrap(rig.store.duo(DuoFixtures.duoID))
        XCTAssertNil(sent.pendingOp)
        XCTAssertEqual(sent.endedAt, Date(timeIntervalSince1970: 1_790_000_500), "the server's end replaces the local one")
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    func testAnOnlineLeaveIsSentAtOnceAndAPartnersLeaveSaysPartner() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo(role: .partner))
        rig.transport.onLeave = { _, _ in self.leaveResponse(.partner) }

        await rig.exits.leave(liveDuo(role: .partner))

        let duo = try XCTUnwrap(rig.store.duo(DuoFixtures.duoID))
        XCTAssertEqual(duo.endedBy, .partner)
        XCTAssertNil(duo.pendingOp)
        XCTAssertEqual(rig.transport.calls.count, 1, "online, it is sent at once")
        guard case .leave(let duoID, let key) = try XCTUnwrap(rig.transport.calls.first) else { return XCTFail("\(rig.transport.calls)") }
        XCTAssertEqual(duoID, DuoFixtures.duoID.uuidString.lowercased())
        XCTAssertEqual(key.value, key.value.lowercased(), "an Idempotency-Key is a lowercase UUID (§6.0)")
        XCTAssertNotNil(UUID(uuidString: key.value))
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    func testALeaveEndsTheCardAndTakesItsNotificationsButKeepsItsLinkSecret() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo())
        try rig.kit.dependencies.secrets.saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: DuoFixtures.duoID)
        rig.transport.onLeave = { _, _ in self.leaveResponse() }

        await rig.exits.leave(liveDuo())

        XCTAssertTrue(try XCTUnwrap(rig.store.duo(DuoFixtures.duoID)).hasEnded)
        XCTAssertEqual(rig.kit.announcer.removedFor, [DuoFixtures.duoID, DuoFixtures.duoID], "at the tap, and again when it lands")
        XCTAssertNotNil(rig.kit.dependencies.secrets.linkSecret(forDuo: DuoFixtures.duoID), "the link secret stays until Clear")
    }

    func testLeavingTheLastLiveDuoForgetsThePushTokenAndNotBefore() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo())
        rig.store.upsert(liveDuo(otherDuo, partner: "Alex"))
        rig.transport.onLeave = { _, _ in self.leaveResponse() }

        await rig.exits.leave(liveDuo())
        XCTAssertEqual(rig.kit.push.clearedLast, 0, "another duo is still live")

        await rig.exits.leave(liveDuo(otherDuo, partner: "Alex"))
        XCTAssertEqual(rig.kit.push.clearedLast, 1, "no live duo remains: the token is forgotten (§3.1)")
    }

    func testALeaveTappedTwiceQueuesOneRequest() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo())
        await rig.exits.leave(liveDuo())
        await rig.exits.leave(liveDuo())
        XCTAssertEqual(rig.ops.pending.count, 1)
        XCTAssertEqual(rig.kit.push.clearedLast, 1)
    }

    func testALeaveOfADuoAlreadyOverSendsNothing() async throws {
        let rig = makeRig()
        rig.store.upsert(endedDuo())
        await rig.exits.leave(endedDuo())
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertEqual(rig.store.duo(DuoFixtures.duoID)?.endedBy, .partner, "the end it had stays")
    }

    // MARK: - Block

    func testABlockOfAnEndedDuoKeepsItsEndAndIsSent() async throws {
        let rig = makeRig()
        rig.store.upsert(endedDuo())
        rig.store.upsert(liveDuo(otherDuo, partner: "Alex"))

        await rig.exits.block(endedDuo()) // offline first

        var duo = try XCTUnwrap(rig.store.duo(DuoFixtures.duoID))
        XCTAssertEqual(duo.endedBy, .partner, "the end it had stays")
        XCTAssertEqual(duo.endedAt, now)
        XCTAssertEqual(duo.pendingOp, .block)
        XCTAssertEqual(rig.ops.pending.map(\.path), ["/duos/\(DuoFixtures.duoID.uuidString.lowercased())/block"])
        XCTAssertEqual(rig.kit.push.clearedLast, 0, "blocking an ended duo ends no live duo here")

        rig.transport.onBlock = { _, _ in }
        await rig.ops.drain()
        duo = try XCTUnwrap(rig.store.duo(DuoFixtures.duoID))
        XCTAssertNil(duo.pendingOp)
        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertFalse(try XCTUnwrap(rig.store.duo(otherDuo)).hasEnded, "a sibling ends at its next fetch, as the server says (§7.5)")
    }

    func testABlockOfALiveDuoEndsItAtOnce() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo(role: .partner))
        rig.transport.onBlock = { _, _ in }

        await rig.exits.block(liveDuo(role: .partner))

        let duo = try XCTUnwrap(rig.store.duo(DuoFixtures.duoID))
        XCTAssertEqual(duo.endedAt, now)
        XCTAssertEqual(duo.endedBy, .partner, "my role")
        XCTAssertNil(duo.pendingOp)
        XCTAssertEqual(rig.kit.push.clearedLast, 1)
    }

    func testABlockAfterAQueuedLeaveIsQueuedBehindIt() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo())
        await rig.exits.leave(liveDuo())
        await rig.exits.block(liveDuo())
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.leave, .block])
        XCTAssertEqual(rig.store.duo(DuoFixtures.duoID)?.pendingOp, .block)
    }

    func testLeaveAndBlockWhileBannedDoNothingButSayWhereToTurn() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo())
        rig.store.upsert(endedDuo(otherDuo))
        rig.store.availability = .banned

        await rig.exits.leave(liveDuo())
        XCTAssertEqual(rig.store.notice, DuoAvailability.banned.bannerMessage)
        rig.store.notice = nil
        await rig.exits.block(endedDuo(otherDuo))
        XCTAssertEqual(rig.store.notice, DuoAvailability.banned.bannerMessage)

        XCTAssertTrue(rig.ops.pending.isEmpty, "a banned member's leave or block would be refused 403 and dropped (D33)")
        XCTAssertTrue(rig.transport.calls.isEmpty)
        XCTAssertFalse(try XCTUnwrap(rig.store.duo(DuoFixtures.duoID)).hasEnded, "and the card must not claim the duo ended")
        XCTAssertNil(rig.store.duo(otherDuo)?.pendingOp)
        XCTAssertEqual(rig.kit.push.clearedLast, 0)
    }

    func testNothingIsSentForALeaveWithoutACredential() async throws {
        let rig = makeRig(credential: nil)
        rig.store.upsert(liveDuo())
        rig.transport.onLeave = { _, _ in self.leaveResponse() }

        await rig.exits.leave(liveDuo())

        XCTAssertTrue(rig.transport.calls.isEmpty, "§3.1: no request without a credential")
        XCTAssertTrue(rig.ops.pending.isEmpty)
    }

    // MARK: - Clear

    func testClearTakesTheDuoAndEverythingItLeftOnThePhone() throws {
        let rig = makeRig()
        let cache = rig.kit.dependencies.cache
        let id = DuoFixtures.duoID
        rig.store.upsert(endedDuo())
        rig.store.upsert(endedDuo(otherDuo))
        try rig.kit.dependencies.secrets.saveLinkSecret("ABCDEFGHJKMNPQRSTVWXYZ0123", forDuo: id)
        try rig.kit.dependencies.secrets.saveLinkSecret("ZYXWVTSRQPNMKJHGFEDCBA3210", forDuo: otherDuo)
        var ledger = DuoLedger()
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: id, day: "2026-10-06"))
        _ = ledger.markSeen(DuoLedger.goalKey(duoID: otherDuo, day: "2026-10-06"))
        cache.saveLedger(ledger)
        let row = DuoFixtures.status(.owner, "2026-10-06", bucket: 100)
        cache.saveRejectedDays([id.uuidString.lowercased(): DuoRejectedDays(rows: ["2026-10-06": row]),
                                otherDuo.uuidString.lowercased(): DuoRejectedDays(rows: ["2026-10-06": row])])
        rig.store.diagnostics.record(failure(.maintenance, status: 503), duoID: id, now: now)
        XCTAssertFalse(cache.isCleared(id, now: now))

        rig.exits.clear(endedDuo())

        XCTAssertNil(rig.store.duo(id))
        XCTAssertNotNil(rig.store.duo(otherDuo))
        XCTAssertTrue(cache.isCleared(id, now: now), "remembered, so GET /me's 30 days of ended duos cannot bring it back")
        XCTAssertFalse(cache.isCleared(otherDuo, now: now))
        XCTAssertNil(rig.kit.dependencies.secrets.linkSecret(forDuo: id))
        XCTAssertNotNil(rig.kit.dependencies.secrets.linkSecret(forDuo: otherDuo))
        XCTAssertEqual(cache.loadLedger().seen, [DuoLedger.goalKey(duoID: otherDuo, day: "2026-10-06")])
        XCTAssertEqual(Set(cache.loadRejectedDays().keys), [otherDuo.uuidString.lowercased()])
        XCTAssertNil(rig.store.diagnostics.duos[id.uuidString.lowercased()])
        XCTAssertEqual(rig.kit.announcer.removedIncludingEnded, [id], "the pushed ended notice goes with the card (§12.2)")
        XCTAssertTrue(rig.kit.announcer.removedFor.isEmpty, "the removal that keeps it is for an end, not a Clear (D75)")
        XCTAssertEqual(rig.kit.push.clearedLast, 1, "no live duo is left, so the push service is asked to let the token go")
        XCTAssertTrue(rig.transport.calls.isEmpty, "a Clear is local (§12.2)")
        XCTAssertFalse(cache.loadDuos().contains { $0.id == id }, "gone from disk too")
    }

    func testClearingWithALiveDuoLeftKeepsThePushToken() {
        let rig = makeRig()
        rig.store.upsert(endedDuo())
        rig.store.upsert(liveDuo(otherDuo, partner: "Alex"))
        rig.exits.clear(endedDuo())
        XCTAssertEqual(rig.kit.push.clearedLast, 0)
    }

    func testClearNeverTakesALiveDuo() {
        let rig = makeRig()
        rig.store.upsert(liveDuo())
        rig.exits.clear(liveDuo())
        XCTAssertNotNil(rig.store.duo(DuoFixtures.duoID), "hidden and remembered as cleared, a live duo could never be shown again")
        XCTAssertFalse(rig.kit.dependencies.cache.isCleared(DuoFixtures.duoID, now: now))
    }

    func testClearKeepsALeaveOrBlockStillWaitingAndItIsStillSent() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo())
        rig.store.upsert(endedDuo(otherDuo))
        await rig.exits.leave(liveDuo())    // no connection
        await rig.exits.block(endedDuo(otherDuo))
        XCTAssertEqual(rig.ops.pending.count, 2)

        rig.exits.clear(try XCTUnwrap(rig.store.duo(DuoFixtures.duoID)))
        rig.exits.clear(try XCTUnwrap(rig.store.duo(otherDuo)))
        XCTAssertTrue(rig.store.duos.isEmpty)
        XCTAssertEqual(rig.ops.pending.map(\.kind), [.leave, .block], "the person's leave and block still have to reach the server")

        rig.transport.onLeave = { _, _ in self.leaveResponse() }
        rig.transport.onBlock = { _, _ in }
        await rig.ops.drain()
        XCTAssertTrue(rig.ops.pending.isEmpty)
        XCTAssertTrue(rig.store.duos.isEmpty, "the answers find no card and bring none back")
        XCTAssertTrue(rig.kit.dependencies.cache.loadDuos().isEmpty)
    }

    // MARK: - Delete my Duo data

    func testDeleteMyDataOnlineSendsTheTokenThenWipesAndReturnsTrue() async throws {
        let rig = makeRig()
        try await seedEverything(rig)
        rig.transport.onDeleteMe = { _, _ in }

        let deleted = await rig.exits.deleteMyData()

        XCTAssertTrue(deleted)
        guard case .deleteMe(let request, let key) = try XCTUnwrap(rig.transport.calls.first) else { return XCTFail("\(rig.transport.calls)") }
        XCTAssertEqual(rig.transport.calls.count, 1, "nothing else is sent: not the queue, not a push removal")
        XCTAssertEqual(request.deviceCheckToken, "RGV2aWNlQ2hlY2s=", "D54: the token rides with the delete")
        XCTAssertFalse(key.value.isEmpty)
        assertWiped(rig)
        XCTAssertEqual(rig.kit.push.clearedLast, 0, "the server's delete took the token row; nothing is queued after a wipe")
    }

    func testDeleteMyDataIsNotKeptInTheJournalAndEachTapHasItsOwnKey() async throws {
        let rig = makeRig()
        rig.transport.onDeleteMe = { _, _ in throw DuoTransportError.offline }
        _ = await rig.exits.deleteMyData()
        _ = await rig.exits.deleteMyData()
        let keys = rig.transport.calls.compactMap { if case .deleteMe(_, let key) = $0 { return key }; return nil }
        XCTAssertEqual(keys.count, 2)
        XCTAssertNotEqual(keys[0], keys[1], "D62: DELETE /me keeps no record on the server, so nothing here is replayed")
        XCTAssertNil(rig.kit.defaults.object(forKey: DuoCache.inflightKey), "and no DeviceCheck token is left in the journal")
    }

    func testAReplayedDeleteThatMeetsUnauthenticatedCountsAsDone() async throws {
        let rig = makeRig()
        try await seedEverything(rig)
        rig.transport.onDeleteMe = { _, _ in throw self.failure(.unauthenticated, status: 401) }

        let deleted = await rig.exits.deleteMyData()

        XCTAssertTrue(deleted, "§6.0: a replay of a delete that landed answers 401")
        assertWiped(rig)
    }

    func testTheClientsOwnNoCredentialIsNotADelete() async throws {
        let rig = makeRig()
        try await seedEverything(rig)
        rig.transport.onDeleteMe = { _, _ in throw DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0)) }

        let deleted = await rig.exits.deleteMyData()

        XCTAssertFalse(deleted, "status 0: nothing reached the server, so nothing was deleted")
        XCTAssertEqual(rig.store.duos.count, 2)
        XCTAssertNotNil(rig.kit.identity.credential)
        XCTAssertEqual(rig.store.notice, DuoUserMessage.generic)
    }

    func testAFailedDeleteWipesNothingAndSaysWhy() async throws {
        // None of these proves the server did not delete, so each keeps the mark (`deleteRequestedAt`)
        // a later 401 finishes the wipe from, and none says the duo "will catch up" (nothing is queued).
        let cases: [(DuoTransportError, String)] = [
            (.offline, "No connection right now. Try again in a bit."),
            (failure(.maintenance, status: 503), "That did not work. Please try again. (ref req-1)"),
            (failure(.rateLimited, status: 429), "Too many tries. Wait a bit and try again."),
            (.unreadable(httpStatus: 200, requestID: nil), "That did not work. Please try again."),
        ]
        for (error, words) in cases {
            let rig = makeRig()
            try await seedEverything(rig)
            let keysBefore = duoKeys(rig.kit.defaults)
            let keychainBefore = rig.kit.secretStore.accounts(service: DuoSecrets.service)
            rig.transport.onDeleteMe = { _, _ in throw error }

            let deleted = await rig.exits.deleteMyData()

            XCTAssertFalse(deleted, "\(error)")
            XCTAssertEqual(rig.store.notice, words, "\(error)")
            XCTAssertEqual(duoKeys(rig.kit.defaults), keysBefore.union([DuoCache.deleteRequestedKey]), "nothing on disk was wiped: \(error)")
            XCTAssertNotNil(rig.kit.dependencies.cache.deleteRequestedAt, "\(error)")
            XCTAssertEqual(rig.kit.secretStore.accounts(service: DuoSecrets.service), keychainBefore, "nor in the Keychain: \(error)")
            XCTAssertEqual(rig.store.duos.count, 2)
            XCTAssertNotNil(rig.store.memberInfo)
            XCTAssertNotNil(rig.kit.identity.credential)
            XCTAssertEqual(rig.kit.identity.discardCount, 0)
            XCTAssertEqual(rig.ops.pending.count, 1)
            XCTAssertFalse(rig.store.isWorking, "the spinner is put away")
            XCTAssertEqual(rig.kit.announcer.removedAll, 0)
        }
    }

    func testACancelledDeleteChangesNothingAndSaysNothing() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo())
        rig.transport.onDeleteMe = { _, _ in throw CancellationError() }
        let deleted = await rig.exits.deleteMyData()
        XCTAssertFalse(deleted)
        XCTAssertNil(rig.store.notice)
        XCTAssertTrue(rig.store.diagnostics.recentErrors.isEmpty)
        XCTAssertNotNil(rig.store.duo(DuoFixtures.duoID))
    }

    func testABannedMembersDeleteGoesThroughAndWipes() async throws {
        // D33: the banned check exempts `DELETE /me`, so in-app deletion always works.
        let rig = makeRig()
        try await seedEverything(rig)
        rig.store.availability = .banned
        rig.transport.onDeleteMe = { _, _ in }

        let deleted = await rig.exits.deleteMyData()

        XCTAssertTrue(deleted)
        assertWiped(rig)
        XCTAssertEqual(rig.store.availability, .unknown, "nothing is left to be banned from")
    }

    func testASupersededPhonesDeleteGoesThroughAndWipes() async throws {
        // A phone a reconnect superseded keeps leave, block and delete for 30 days (§3.5), even with
        // the disconnected card up, which its `GET /me` answered `device_revoked` for.
        let rig = makeRig()
        try await seedEverything(rig)
        rig.store.availability = .disconnected
        rig.transport.onDeleteMe = { _, _ in }

        let deleted = await rig.exits.deleteMyData()

        XCTAssertTrue(deleted)
        assertWiped(rig)
    }

    func testARevokedPhonesDeleteIsAFailureAndWipesNothing() async throws {
        // `device_revoked` on `DELETE /me` means another holder rotated this phone's secret away:
        // nothing was deleted, and the member still exists on the other phone.
        let rig = makeRig()
        try await seedEverything(rig)
        let keysBefore = duoKeys(rig.kit.defaults)
        let keychainBefore = rig.kit.secretStore.accounts(service: DuoSecrets.service)
        rig.transport.onDeleteMe = { _, _ in throw self.failure(.deviceRevoked, status: 401) }

        let deleted = await rig.exits.deleteMyData()

        XCTAssertFalse(deleted)
        XCTAssertEqual(rig.store.availability, .disconnected, "the disconnected card, with Start fresh as the honest way out")
        XCTAssertEqual(rig.store.notice, "This phone was disconnected from the duo")
        XCTAssertEqual(duoKeys(rig.kit.defaults), keysBefore)
        XCTAssertEqual(rig.kit.secretStore.accounts(service: DuoSecrets.service), keychainBefore)
        XCTAssertNotNil(rig.kit.identity.credential)
        XCTAssertEqual(rig.store.duos.count, 2)
        XCTAssertEqual(rig.kit.announcer.removedAll, 0)
    }

    func testNoDeleteIsSentWithoutAReadyIdentity() async throws {
        // `.disconnected` is not here: a superseded phone keeps DELETE /me (E6, `DuoExitRobustnessTests`).
        for launch in [DuoIdentityLaunch.none, .unavailable, .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))] {
            let rig = makeRig()
            rig.store.upsert(liveDuo())
            rig.kit.identity.launch = launch
            rig.transport.onDeleteMe = { _, _ in }
            let deleted = await rig.exits.deleteMyData()
            XCTAssertFalse(deleted, "\(launch)")
            XCTAssertTrue(rig.transport.calls.isEmpty, "\(launch)")
            XCTAssertNotNil(rig.store.duo(DuoFixtures.duoID), "\(launch)")
            XCTAssertFalse(rig.store.isWorking)
        }
    }

    func testTwoDeletesAtOnceSendOne() async throws {
        let rig = makeRig()
        let gate = EExitGate()
        let gated = EExitGatedTransport(rig.transport)
        gated.deleteGate = gate
        rig.kit.dependencies.transport = gated
        rig.transport.onDeleteMe = { _, _ in }

        let first = Task { await rig.exits.deleteMyData() }
        for _ in 0..<10_000 where gate.entered == 0 { await Task.yield() }
        XCTAssertTrue(rig.store.isWorking, "the spinner is up while it is out")
        // The second tap runs in a task of its own and is watched for a bounded while: one that
        // went on to send would wait at the gate, and must fail the test rather than hang it.
        let finished = EExitCounter()
        let second = Task { let result = await rig.exits.deleteMyData(); finished.count += 1; return result }
        for _ in 0..<10_000 where finished.count == 0 && gate.entered < 2 { await Task.yield() }
        XCTAssertEqual(finished.count, 1, "the second tap comes straight back")
        XCTAssertEqual(gate.entered, 1, "and no second DELETE /me goes out")
        gate.release()
        let secondResult = await second.value
        let firstResult = await first.value

        XCTAssertFalse(secondResult)
        XCTAssertTrue(firstResult)
        XCTAssertEqual(rig.transport.calls.count, 1)
    }

    func testAStartFreshWhileADeleteIsOutLeavesTheNewIdentityAlone() async throws {
        let rig = makeRig()
        rig.store.upsert(liveDuo())
        let gate = EExitGate()
        let gated = EExitGatedTransport(rig.transport)
        gated.deleteGate = gate
        rig.kit.dependencies.transport = gated
        rig.transport.onDeleteMe = { _, _ in }

        let delete = Task { await rig.exits.deleteMyData() }
        for _ in 0..<10_000 where gate.entered == 0 { await Task.yield() }
        rig.exits.startFresh()
        // The person starts again at once: a new identity and a new duo.
        let fresh = DuoCredential(memberID: "6d2a0000-0000-4000-8000-0000000000dd", deviceID: "6d2a0000-0000-4000-8000-0000000000ee",
                                  deviceSecret: String(repeating: "f", count: 43))
        try rig.kit.identity.store(fresh)
        rig.store.upsert(liveDuo(otherDuo, partner: "Alex"))
        rig.store.myDisplayName = "Jo"
        gate.release()
        let deleted = await delete.value

        XCTAssertTrue(deleted, "the old member was deleted, which is what the person asked")
        XCTAssertEqual(rig.kit.identity.credential, fresh, "the late answer does not wipe the identity made since")
        XCTAssertEqual(rig.kit.identity.discardCount, 1, "only Start fresh's own discard")
        XCTAssertNotNil(rig.store.duo(otherDuo))
        XCTAssertEqual(rig.store.myDisplayName, "Jo")
    }

    // MARK: - Start fresh

    func testStartFreshSendsNothingAndLeavesNothingOfThePersonBehind() async throws {
        let rig = makeRig()
        try await seedEverything(rig)

        rig.exits.startFresh()

        XCTAssertTrue(rig.transport.calls.isEmpty, "Start fresh has no server call; the seat ends by the 30-day rule")
        assertWiped(rig)
        XCTAssertEqual(rig.kit.push.clearedLast, 0, "and queues nothing either")
        await rig.ops.drain()
        XCTAssertTrue(rig.transport.calls.isEmpty, "nothing is sent until a new Create, Join or Reconnect tap")
    }

    func testStartFreshAnswersTheRestoreQuestionAndKeepsTheAgeRefusalInItsOwnService() throws {
        let rig = makeRig()
        try rig.kit.dependencies.secrets.markAgeRefused()
        try rig.kit.dependencies.secrets.save(DuoFixtures.credential())
        rig.store.availability = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))

        rig.exits.startFresh()

        XCTAssertEqual(rig.store.availability, .unknown, "\"Not me, start fresh\" does not keep asking")
        XCTAssertTrue(rig.kit.dependencies.secrets.isAgeRefused(), "D60: the refusal is in a service of its own and stays")
        XCTAssertEqual(rig.kit.secretStore.accounts(service: DuoSecrets.ageService), [DuoSecrets.ageRefusedAccount])
        XCTAssertEqual(rig.kit.secretStore.accounts(service: DuoSecrets.service), [])
    }

    func testAfterAWipeTheRealIdentityIsGoneAndItsLaunchSaysSo() async throws {
        // With the real identity, not the fake: without `discard()` the credential it read stays in
        // memory after the Keychain item is deleted, and its launch answer stays `.ready`.
        for viaDelete in [false, true] {
            let rig = makeRig()
            let folder = temporaryFolder()
            let identity = DuoIdentity(dependencies: rig.kit.dependencies, directory: folder, holdInBackground: { _ in {} })
            rig.kit.dependencies.identity = identity
            try identity.store(DuoFixtures.credential())
            let ready = await identity.prepare()
            XCTAssertEqual(ready, .ready)
            XCTAssertTrue(rig.store.hasIdentity)
            rig.transport.onDeleteMe = { _, _ in }

            if viaDelete {
                let deleted = await rig.exits.deleteMyData()
                XCTAssertTrue(deleted)
            } else {
                rig.exits.startFresh()
            }

            XCTAssertNil(identity.credential, viaDelete ? "after a delete" : "after Start fresh")
            let launch = await identity.prepare()
            XCTAssertEqual(launch, DuoIdentityLaunch.none, "nothing is sent until a new tap")
            XCTAssertFalse(rig.store.hasIdentity)
            XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("duo.settled").path))
            let relaunched = DuoIdentity(dependencies: rig.kit.dependencies, directory: folder, holdInBackground: { _ in {} })
            XCTAssertNil(relaunched.credential, "and a relaunch reads none from the Keychain")
            let relaunchedLaunch = await relaunched.prepare()
            XCTAssertEqual(relaunchedLaunch, DuoIdentityLaunch.none)
            XCTAssertEqual(rig.transport.calls.count, viaDelete ? 1 : 0)
            XCTAssertTrue(rig.transport.calls.allSatisfy { if case .deleteMe = $0 { return true }; return false }, "no other request")
        }
    }

    func testAWipeLetsGoOfARetryStillWaitingOutItsDelay() async throws {
        let rig = makeRig()
        let delays = EExitGate()
        rig.kit.dependencies.sleep = { _ in await delays.wait(); try Task.checkCancellation() }
        rig.store.upsert(liveDuo())
        await rig.exits.leave(liveDuo()) // no connection: one try, and a retry waits out its minute
        XCTAssertFalse(rig.ops.isIdle)

        rig.exits.startFresh() // one last try of the queued leave (E18), then the wipe
        for _ in 0..<10_000 where !rig.store.duos.isEmpty { await Task.yield() }

        XCTAssertTrue(rig.store.duos.isEmpty)
        XCTAssertTrue(rig.ops.isIdle, "the old identity's retry goes with it, so nothing waits behind it for the next one")
        XCTAssertEqual(rig.transport.calls.count, 2, "the tap's try and Start fresh's last one")
        delays.release()
        for _ in 0..<500 { await Task.yield() }
        XCTAssertEqual(rig.transport.calls.count, 2, "and nothing is sent when its minute is up")
    }

    func testTheWipeTakesOrphanKeychainItemsUnderDuosService() throws {
        let rig = makeRig()
        let secrets = rig.kit.dependencies.secrets
        try secrets.saveLinkSecret("ZYXWVTSRQPNMKJHGFEDCBA3210", forDuo: orphanDuo)
        try rig.kit.secretStore.write(Data("key".utf8), service: DuoSecrets.service,
                                      account: DuoSecrets.attestKeyAccount(deviceID: "6d2a0000-0000-4000-8000-0000000000cc"),
                                      accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertEqual(rig.kit.secretStore.accounts(service: DuoSecrets.service).count, 2)

        rig.exits.startFresh()

        XCTAssertNil(secrets.linkSecret(forDuo: orphanDuo), "a link secret for a duo the cache no longer had")
        XCTAssertEqual(rig.kit.secretStore.accounts(service: DuoSecrets.service), [], "and another device's attestation key")
    }
}
#endif
