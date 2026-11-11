#if DUO_V2
import XCTest
@testable import HydroDrop

/// The transport keeps the synthetic server while each relaunch constructs a new identity.
/// These tests exercise the durable boundaries, rather than relying on a task's captured RAM.
private final class RecoveryServer: DuoCredentialRecoveryTransport, @unchecked Sendable {
    static let device = "10000000-0000-4000-8000-000000000001"
    static let member = "20000000-0000-4000-8000-000000000001"
    var calls: [String] = []
    var candidate: String?
    var current: String?
    var version = 1
    var loseCommit = false
    var loseRotate = false
    var rejectCandidateWithUnknown401 = false
    var cancelled = false
    var deleted = false
    var failCapabilities = false
    var failPrepare = false
    var overrideState: DuoRecoveryCredentialState?
    var onCommit: (() -> Void)?
    var stateFailures: [DuoRecoveryError] = []
    var cancelFailure: DuoRecoveryError?
    var loseRotateBeforeCommit = false
    var rotateSecrets: [String] = []
    var deleteFailures: [DuoRecoveryError] = []
    var deleteHandler: ((DuoRecoveryCredential) throws -> Void)?
    var deletionDevices: [String] = []
    func state() -> DuoRecoveryCredentialState {
        overrideState ?? DuoRecoveryCredentialState(deviceID: Self.device, memberID: Self.member, secretVersion: version, deviceTier: "low", supportID: "0123456789AB")
    }
    func recoveryCapabilities() async throws -> DuoRecoveryCapabilities {
        calls.append("capabilities"); if failCapabilities { throw DuoRecoveryError.offline }; return DuoRecoveryCapabilities()
    }
    func prepareDeviceIssuance(_ request: DuoRecoveryPrepareRequest) async throws -> DuoRecoveryIssuance {
        calls.append("prepare"); candidate = request.deviceSecret
        if failPrepare { throw DuoRecoveryError.offline }
        return DuoRecoveryIssuance(deviceID: Self.device, expiresAt: "2026-11-05T00:00:00.000Z")
    }
    func commitDevice(_ request: DuoRecoveryCommitRequest, as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCredentialState {
        calls.append("commit"); current = credential.deviceSecret; onCommit?()
        if loseCommit { loseCommit = false; throw DuoRecoveryError.offline }; return state()
    }
    func credentialState(as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCredentialState {
        calls.append("state")
        if !stateFailures.isEmpty { throw stateFailures.removeFirst() }
        guard credential.deviceSecret == current, !deleted else {
            if rejectCandidateWithUnknown401 { throw DuoRecoveryError.unavailable(DuoErrorContext(httpStatus: 401)) }
            throw DuoRecoveryError.refused(.credentialRejected, DuoErrorContext(httpStatus: 401))
        }
        return state()
    }
    func rotateCredential(_ request: DuoRecoveryRotateRequest, as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCredentialState {
        calls.append("rotate"); rotateSecrets.append(request.nextDeviceSecret)
        if loseRotateBeforeCommit { loseRotateBeforeCommit = false; throw DuoRecoveryError.offline }
        guard current == credential.deviceSecret, version == request.expectedSecretVersion else { throw DuoRecoveryError.refused(.credentialConflict, DuoErrorContext(httpStatus: 409)) }
        current = request.nextDeviceSecret; version += 1
        if loseRotate { loseRotate = false; throw DuoRecoveryError.offline }; return state()
    }
    func cancelDeviceIssuance(deviceID: String, as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCancelResponse {
        calls.append("cancel"); cancelled = true
        if let cancelFailure { throw cancelFailure }
        return DuoRecoveryCancelResponse(deviceID: deviceID, outcome: current == nil ? .cancelled : .committed)
    }
    func deleteMe(as credential: DuoRecoveryCredential, _ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws {
        calls.append("delete"); deletionDevices.append(credential.deviceID)
        XCTAssertNil(request.deviceCheckToken)
        if let deleteHandler { try deleteHandler(credential); return }
        if !deleteFailures.isEmpty { throw deleteFailures.removeFirst() }
        guard current == credential.deviceSecret else { throw DuoRecoveryError.refused(.credentialRejected, DuoErrorContext(httpStatus: 401)) }
        deleted = true
    }
}

private final class RecoveryFailingStore: DuoSecretStore, @unchecked Sendable {
    let memory = DuoMemorySecretStore()
    var failMirror = false
    var readError = false
    var writeCount = 0
    var failWriteAt: Int?
    var failAfterWrite = false
    var failReadback = false
    private var unreadableOnce: String?
    func read(service: String, account: String) throws -> Data? {
        if readError { throw DuoJournalError.unavailable }
        if unreadableOnce == account { unreadableOnce = nil; throw DuoJournalError.unavailable }
        return try memory.read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        writeCount += 1
        let fail = writeCount == failWriteAt
        if failMirror && account.hasPrefix("portable-") { throw DuoJournalError.unavailable }
        if fail && !failAfterWrite && !failReadback { throw DuoJournalError.unavailable }
        try memory.write(data, service: service, account: account, accessibility: accessibility)
        if fail && failReadback { unreadableOnce = account }
        else if fail && failAfterWrite { throw DuoJournalError.unavailable }
    }
    func delete(service: String, account: String) throws { try memory.delete(service: service, account: account) }
    func deleteAll(service: String) throws { try memory.deleteAll(service: service) }
}

@MainActor final class DuoRecoveryIdentityTests: XCTestCase {
    private func identity(_ kit: DuoTestKit, server: RecoveryServer, store: DuoSecretStore? = nil, directory: URL = DuoIdentity.defaultDirectory) -> DuoRecoveryIdentity {
        kit.dependencies.cache.ageStatus = .allowed
        kit.dependencies.cache.acceptedTermsVersion = DuoProtocolConstants.termsVersion
        let d: DuoDependencies
        if let store {
            d = DuoDependencies(host: kit.store, cache: kit.dependencies.cache, secrets: DuoSecrets(store: store), clock: kit.clock,
                                random: kit.random, client: kit.dependencies.client, attester: kit.attester, deviceCheck: FakeDuoDeviceCheck())
            d.transport = kit.transport
        } else { d = kit.dependencies }
        d.recoveryTransport = server
        let identity = DuoRecoveryIdentity(dependencies: d, environment: .staging, directory: directory)
        d.identity = identity
        return identity
    }
    func testLostCommitRecoversAfterNewCoordinatorWithoutMintingAgain() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); server.loseCommit = true
        let first = identity(kit, server: server)
        let result = await first.mint(role: .create, replacing: nil)
        XCTAssertNil(result); XCTAssertEqual(try first.journal.read()?.phase, .commitUncertain); XCTAssertNil(first.credential)
        let relaunched = identity(kit, server: server)
        let launch = await relaunched.prepare()
        XCTAssertEqual(launch, .ready); XCTAssertEqual(relaunched.credential?.deviceSecret, server.current)
        XCTAssertEqual(server.calls, ["capabilities", "prepare", "commit", "state"])
        XCTAssertEqual(try relaunched.journal.readMirror()?.credential.deviceSecret, server.current)
        XCTAssertTrue(kit.transport.calls.isEmpty)
    }
    func testMirrorFailureRetainsConfirmedJournalAndRelaunchOnlyFinishesLocalWrites() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); let store = RecoveryFailingStore(); store.failMirror = true
        let first = identity(kit, server: server, store: store)
        _ = await first.mint(role: .join, replacing: nil)
        XCTAssertEqual(try first.journal.read()?.phase, .promotionPending); XCTAssertNil(first.credential)
        let calls = server.calls; store.failMirror = false
        let relaunched = identity(kit, server: server, store: store)
        let launch = await relaunched.prepare()
        XCTAssertEqual(launch, .ready); XCTAssertEqual(server.calls, calls); XCTAssertNotNil(relaunched.credential)
    }
    func testPortableRestoreRotatesOnceButKeepsContinueIndependent() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        let first = identity(kit, server: server); _ = await first.mint(role: .create, replacing: nil)
        let mirror = try XCTUnwrap(try kit.secretStore.read(service: DuoSecrets.service, account: first.journal.mirrorAccount))
        let restoredStore = DuoMemorySecretStore()
        try restoredStore.write(mirror, service: DuoSecrets.service, account: first.journal.mirrorAccount, accessibility: .afterFirstUnlock)
        server.loseRotate = true
        let restored = identity(kit, server: server, store: restoredStore)
        let firstLaunch = await restored.prepare(); XCTAssertEqual(firstLaunch, .unavailable)
        XCTAssertEqual(try restored.journal.read()?.phase, .rotateUncertain)
        let relaunch = identity(kit, server: server, store: restoredStore)
        let secondLaunch = await relaunch.prepare()
        XCTAssertEqual(secondLaunch, .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil)))
        let record = try XCTUnwrap(try relaunch.journal.read())
        XCTAssertTrue(record.restoreConfirmationRequired); XCTAssertFalse(record.restoreRotationRequired)
        XCTAssertNil(relaunch.credential); XCTAssertEqual(server.calls.filter { $0 == "rotate" }.count, 1)
        XCTAssertTrue(kit.transport.calls.isEmpty, "Ordinary member hydration must wait for Continue")
    }
    func testRefusalDuringCommitRetainsProofButNeverPublishesCredential() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        server.onCommit = { kit.dependencies.cache.ageStatus = .refused }
        let sut = identity(kit, server: server)
        _ = await sut.mint(role: .create, replacing: nil)
        let record = try XCTUnwrap(try sut.journal.read())
        XCTAssertEqual(record.phase, .active); XCTAssertEqual(record.access, .suspended); XCTAssertNil(sut.credential)
        let deleted = await sut.deleteIdentity()
        XCTAssertTrue(deleted); XCTAssertTrue(server.deleted); XCTAssertEqual(server.calls.last, "delete")
    }
    func testPrivacyCleanupOfLostMintCancelsThenDeletesWithoutStateProbe() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); server.loseCommit = true
        let first = identity(kit, server: server); _ = await first.mint(role: .create, replacing: nil)
        let relaunched = identity(kit, server: server)
        kit.dependencies.cache.ageStatus = .refused
        let deleted = await relaunched.deleteIdentity()
        XCTAssertTrue(deleted); XCTAssertEqual(Array(server.calls.suffix(2)), ["cancel", "delete"])
        XCTAssertFalse(server.calls.contains("state")); XCTAssertEqual(try relaunched.journal.read()?.phase, .abandoned)
        XCTAssertTrue(kit.secretStore.accounts(service: DuoSecrets.service).isEmpty)
    }
    func testAbandonDuringCommitFencesLateSuccess() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); let sut = identity(kit, server: server)
        server.onCommit = { XCTAssertTrue(sut.abandonLocally()) }
        let result = await sut.mint(role: .create, replacing: nil)
        XCTAssertNil(result); XCTAssertNil(sut.credential); XCTAssertEqual(try sut.journal.read()?.phase, .abandoned)
        let relaunched = identity(kit, server: server)
        let launch = await relaunched.prepare(); XCTAssertEqual(launch, .none)
    }
    func testCapabilitiesFailureHasNoV1FallbackOrJournal() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); server.failCapabilities = true
        let sut = identity(kit, server: server)
        let result = await sut.mint(role: .create, replacing: nil)
        XCTAssertNil(result); XCTAssertNil(try sut.journal.read()); XCTAssertEqual(server.calls, ["capabilities"])
        XCTAssertTrue(kit.transport.calls.isEmpty)
    }
    func testUnknownProvenanceLegacyCredentialStopsBeforeAnyNetwork() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        try kit.dependencies.secrets.save(DuoFixtures.credential())
        let sut = identity(kit, server: server)
        let launch = await sut.prepare()
        XCTAssertEqual(launch, .unavailable); XCTAssertTrue(server.calls.isEmpty); XCTAssertTrue(kit.transport.calls.isEmpty)
        XCTAssertNotNil(try kit.secretStore.read(service: DuoSecrets.service, account: DuoSecrets.deviceAccount))
    }
    func testUnreadableJournalIsNotAbsenceAndCannotMint() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); let store = RecoveryFailingStore(); store.readError = true
        let sut = identity(kit, server: server, store: store)
        let launch = await sut.prepare(); let result = await sut.mint(role: .create, replacing: nil)
        XCTAssertEqual(launch, .unavailable); XCTAssertNil(result); XCTAssertTrue(server.calls.isEmpty)
    }
    private func pendingRotation(_ kit: DuoTestKit, server: RecoveryServer) async throws -> DuoRecoveryIdentity {
        let sut = identity(kit, server: server)
        _ = await sut.mint(role: .create, replacing: nil)
        let r = try XCTUnwrap(try sut.journal.read())
        try kit.secretStore.delete(service: DuoSecrets.service, account: sut.journal.markerAccount)
        server.loseRotateBeforeCommit = true
        let launch = await sut.prepare()
        XCTAssertEqual(launch, .unavailable)
        XCTAssertEqual(try sut.journal.read()?.phase, .rotateUncertain)
        XCTAssertEqual(server.version, r.active?.secretVersion)
        return sut
    }
    func testRotationExactCandidateRejectionChecksOldEpochAndRetriesSameCandidate() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        _ = try await pendingRotation(kit, server: server)
        let candidate = try XCTUnwrap(try DuoRecoveryJournal(store: kit.secretStore, environment: .staging).read()?.pending?.candidateSecret)
        let calls = server.calls.count
        let relaunched = identity(kit, server: server)
        let launch = await relaunched.prepare()
        XCTAssertEqual(launch, .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil)))
        XCTAssertEqual(Array(server.calls.dropFirst(calls)), ["state", "state", "rotate"])
        XCTAssertEqual(server.rotateSecrets, [candidate, candidate])
    }
    func testAmbiguousCandidate401NeverProbesOldCredential() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        _ = try await pendingRotation(kit, server: server)
        server.rejectCandidateWithUnknown401 = true
        let calls = server.calls.count
        let relaunched = identity(kit, server: server)
        let launch = await relaunched.prepare()
        XCTAssertEqual(launch, .unavailable); XCTAssertEqual(Array(server.calls.dropFirst(calls)), ["state"])
        XCTAssertEqual(try relaunched.journal.read()?.phase, .rotateUncertain)
    }
    func testOldCredentialBanRetainsPendingWithoutRotationOrMint() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        _ = try await pendingRotation(kit, server: server)
        server.stateFailures = [.refused(.credentialRejected, DuoErrorContext(httpStatus: 401)), .refused(.banned, DuoErrorContext(httpStatus: 403))]
        let calls = server.calls.count
        let relaunched = identity(kit, server: server)
        let launch = await relaunched.prepare()
        XCTAssertEqual(launch, .unavailable); XCTAssertEqual(Array(server.calls.dropFirst(calls)), ["state", "state"])
        XCTAssertEqual(try relaunched.journal.read()?.phase, .rotateUncertain); XCTAssertEqual(kit.store.availability, .banned)
    }
    func testUnknownRotationPrivacyCleanupTriesCandidateThenOldOnlyAfterExactRejection() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        _ = try await pendingRotation(kit, server: server)
        let calls = server.calls.count
        let relaunched = identity(kit, server: server)
        kit.dependencies.cache.ageStatus = .refused
        let deleted = await relaunched.deleteIdentity()
        XCTAssertTrue(deleted); XCTAssertEqual(Array(server.calls.dropFirst(calls)), ["delete", "delete"])
        XCTAssertEqual(try relaunched.journal.read()?.phase, .abandoned)
    }
    func testUnknownRotationCleanupAmbiguous401DoesNotTryOldAndKeepsIntent() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        _ = try await pendingRotation(kit, server: server)
        server.deleteFailures = [.unavailable(DuoErrorContext(httpStatus: 401))]
        let calls = server.calls.count
        let relaunched = identity(kit, server: server)
        let deleted = await relaunched.deleteIdentity()
        XCTAssertFalse(deleted); XCTAssertEqual(Array(server.calls.dropFirst(calls)), ["delete"])
        XCTAssertEqual(try relaunched.journal.read()?.phase, .cleanupPending)
        XCTAssertEqual(try relaunched.journal.read()?.intent, .deleteIdentity)
    }
    func testExpiredCancellationIsNotDeletionProof() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); server.loseCommit = true
        let first = identity(kit, server: server); _ = await first.mint(role: .create, replacing: nil)
        server.cancelFailure = .refused(.issuanceUnavailable, DuoErrorContext(httpStatus: 410))
        let relaunched = identity(kit, server: server)
        let deleted = await relaunched.deleteIdentity()
        XCTAssertFalse(deleted); XCTAssertEqual(try relaunched.journal.read()?.phase, .cleanupPending)
        XCTAssertNotNil(try relaunched.journal.read()?.pending?.candidateSecret)
        XCTAssertFalse(server.calls.contains("delete"))
    }
    func testSamePhoneReinstallMissingSandboxSentinelRequiresCASAndContinue() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("D65-reinstall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = identity(kit, server: server, directory: folder)
        _ = await first.mint(role: .create, replacing: nil)
        XCTAssertNotNil(first.credential)
        try FileManager.default.removeItem(at: folder)
        let relaunched = identity(kit, server: server, directory: folder)
        XCTAssertNil(relaunched.credential, "Surviving Keychain marker does not prove the sandbox installation")
        let launch = await relaunched.prepare()
        XCTAssertEqual(launch, .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil)))
        XCTAssertEqual(server.calls.filter { $0 == "rotate" }.count, 1)
        XCTAssertTrue(try XCTUnwrap(try relaunched.journal.read()).restoreConfirmationRequired)
        XCTAssertTrue(kit.transport.calls.isEmpty)
    }

    func testEveryMintKeychainBoundaryRestartsFromDurableState() async throws {
        // Marker, initial journal, reservation, dispatch uncertainty, confirmation, mirror,
        // marker verification and pending-clear are each failed before, after, and at readback.
        for failureMode in 0..<3 {
            for boundary in 1...8 {
                let kit = DuoTestKit(); let server = RecoveryServer(); let store = RecoveryFailingStore()
                store.failWriteAt = boundary; store.failAfterWrite = failureMode == 1; store.failReadback = failureMode == 2
                let folder = FileManager.default.temporaryDirectory.appendingPathComponent("D65-boundary-\(UUID().uuidString)")
                defer { try? FileManager.default.removeItem(at: folder) }
                let first = identity(kit, server: server, store: store, directory: folder)
                _ = await first.mint(role: .create, replacing: nil)
                store.failWriteAt = nil
                let restarted = identity(kit, server: server, store: store, directory: folder)
                var launch = await restarted.prepare()
                if launch == .none {
                    // A new explicit setup tap is safe only before any dispatchable operation
                    // existed. A known or uncertain commit must never enter this branch.
                    XCTAssertNil(server.current, "boundary \(boundary), mode \(failureMode)")
                    _ = await restarted.mint(role: .create, replacing: nil)
                    launch = await restarted.prepare()
                }
                XCTAssertEqual(launch, .ready, "boundary \(boundary), mode \(failureMode)")
                XCTAssertEqual(restarted.credential?.deviceSecret, server.current)
                XCTAssertEqual(server.calls.filter { $0 == "commit" }.count, 1)
                XCTAssertEqual(try restarted.journal.read()?.phase, .active)
            }
        }
    }

    func testReconnectCleanupCheckpointsCandidateBeforeDeletingRetainedOldIdentity() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); let first = identity(kit, server: server)
        let oldDevice = "10000000-0000-4000-8000-000000000002"
        let oldSecret = Data(repeating: 12, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let candidate = Data(repeating: 13, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
        var r = DuoRecoveryRecord(environment: .staging, installationID: "30000000-0000-4000-8000-000000000001", phase: .commitUncertain)
        r.active = DuoJournalCredential(DuoCredential(memberID: RecoveryServer.member, deviceID: oldDevice, deviceSecret: oldSecret))
        r.activeRole = .established
        var pending = DuoRecoveryPending(kind: .mint, operationID: "40000000-0000-4000-8000-000000000001", candidateSecret: candidate, role: .reconnectThrowaway, acceptedTermsVersion: 1, appVersion: "2.0")
        pending.reservedDeviceID = RecoveryServer.device; pending.reservationExpiresAt = "2026-11-05T00:00:00.000Z"; pending.commitMayHaveRun = true
        r.pending = pending; try first.journal.replace(r, expectedRevision: nil)
        server.current = candidate
        var oldAttempts = 0
        server.deleteHandler = { credential in
            if credential.deviceID == oldDevice {
                oldAttempts += 1
                if oldAttempts == 1 { throw DuoRecoveryError.offline }
            }
        }
        let firstResult = await first.deleteIdentity()
        XCTAssertFalse(firstResult)
        let checkpoint = try XCTUnwrap(try first.journal.read())
        XCTAssertEqual(checkpoint.phase, .cleanupPending); XCTAssertNil(checkpoint.pending)
        XCTAssertEqual(checkpoint.active?.deviceID, oldDevice); XCTAssertEqual(checkpoint.intent, .deleteIdentity)
        server.cancelFailure = .refused(.issuanceUnavailable, DuoErrorContext(httpStatus: 410))
        let relaunched = identity(kit, server: server)
        let secondResult = await relaunched.deleteIdentity()
        XCTAssertTrue(secondResult)
        XCTAssertEqual(server.deletionDevices, [RecoveryServer.device, oldDevice, oldDevice])
        XCTAssertEqual(server.calls.filter { $0 == "cancel" }.count, 1)
        XCTAssertEqual(try relaunched.journal.read()?.phase, .abandoned)
    }

    func testPendingCleanupCannotBeEscapedByNewReconnectTap() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        let first = try await pendingRotation(kit, server: server)
        server.deleteFailures = [.offline]
        let deleted = await first.deleteIdentity(); XCTAssertFalse(deleted)
        let old = try XCTUnwrap(try first.journal.read()?.active?.credential)
        let calls = server.calls.count
        let relaunched = identity(kit, server: server)
        let result = await relaunched.mint(role: .reconnectThrowaway, replacing: old)
        XCTAssertNil(result); XCTAssertEqual(server.calls.count, calls)
        XCTAssertEqual(try relaunched.journal.read()?.phase, .cleanupPending)
    }
    func testPendingRotationReinstallKeepsCandidateAndStillRequiresContinue() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("D65-pending-reinstall-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = identity(kit, server: server, directory: folder)
        _ = await first.mint(role: .create, replacing: nil)
        try kit.secretStore.delete(service: DuoSecrets.service, account: first.journal.markerAccount)
        server.loseRotate = true
        _ = await first.prepare()
        let pending = try XCTUnwrap(try first.journal.read()?.pending)
        try FileManager.default.removeItem(at: folder)
        let calls = server.calls.count
        let relaunched = identity(kit, server: server, directory: folder)
        let launch = await relaunched.prepare()
        XCTAssertEqual(launch, .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil)))
        XCTAssertEqual(Array(server.calls.dropFirst(calls)), ["state"])
        XCTAssertEqual(server.current, pending.candidateSecret)
        XCTAssertFalse(try XCTUnwrap(try relaunched.journal.read()).restoreRotationRequired)
        XCTAssertTrue(try XCTUnwrap(try relaunched.journal.read()).restoreConfirmationRequired)
        XCTAssertNil(relaunched.credential)
    }

    func testReconnectPreparationFailureKeepsPriorCredentialAndRoleRestricted() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); let sut = identity(kit, server: server)
        _ = await sut.mint(role: .create, replacing: nil)
        let old = try XCTUnwrap(sut.credential)
        server.failPrepare = true
        let result = await sut.mint(role: .reconnectThrowaway, replacing: old)
        XCTAssertNil(result)
        let r = try XCTUnwrap(try sut.journal.read())
        XCTAssertEqual(r.active?.credential, old); XCTAssertEqual(r.activeRole, .established)
        XCTAssertEqual(r.phase, .prepareReady); XCTAssertEqual(r.pending?.role, .reconnectThrowaway)
        XCTAssertNil(sut.credential)
        let restarted = identity(kit, server: server)
        _ = await restarted.prepare()
        XCTAssertEqual(try restarted.journal.read()?.active?.credential, old)
        XCTAssertNil(restarted.credential)
    }
    func testThrowawayRoleSurvivesPortableRestoreAndPendingRemoval() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); let first = identity(kit, server: server)
        _ = await first.mint(role: .reconnectThrowaway, replacing: nil)
        XCTAssertEqual(try first.journal.read()?.activeRole, .reconnectThrowaway)
        let mirror = try XCTUnwrap(try kit.secretStore.read(service: DuoSecrets.service, account: first.journal.mirrorAccount))
        let restoredStore = DuoMemorySecretStore()
        try restoredStore.write(mirror, service: DuoSecrets.service, account: first.journal.mirrorAccount, accessibility: .afterFirstUnlock)
        let restored = identity(kit, server: server, store: restoredStore)
        let launch = await restored.prepare()
        XCTAssertEqual(launch, .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil)))
        XCTAssertNil(try restored.journal.read()?.pending)
        XCTAssertEqual(try restored.journal.read()?.activeRole, .reconnectThrowaway)
        XCTAssertEqual(try restored.journal.readMirror()?.credentialRole, .reconnectThrowaway)
        let restarted = identity(kit, server: server, store: restoredStore)
        _ = await restarted.prepare()
        XCTAssertEqual(try restarted.journal.read()?.activeRole, .reconnectThrowaway)
    }
    func testAgeSuspensionNeverClearsDurableContinueChoice() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); let first = identity(kit, server: server)
        _ = await first.mint(role: .create, replacing: nil)
        try kit.secretStore.delete(service: DuoSecrets.service, account: first.journal.markerAccount)
        _ = await first.prepare()
        XCTAssertTrue(try XCTUnwrap(try first.journal.read()).restoreConfirmationRequired)
        kit.dependencies.cache.requireAgeRecheck()
        let suspended = await first.prepare()
        XCTAssertEqual(suspended, .unavailable)
        XCTAssertEqual(try first.journal.read()?.access, .suspended)
        XCTAssertTrue(try XCTUnwrap(try first.journal.read()).restoreConfirmationRequired)
        let calls = server.calls
        kit.dependencies.cache.recordConfirmedAgeStatus(.allowed)
        let restarted = identity(kit, server: server)
        let launch = await restarted.prepare()
        XCTAssertEqual(launch, .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil)))
        XCTAssertEqual(server.calls, calls)
    }
    func testMismatchingCandidateStateNeverPromotesOrProbesOld() async throws {
        for mutation in 0..<4 {
            let kit = DuoTestKit(); let server = RecoveryServer(); let first = identity(kit, server: server)
            _ = await first.mint(role: .create, replacing: nil)
            try kit.secretStore.delete(service: DuoSecrets.service, account: first.journal.markerAccount)
            server.loseRotate = true; _ = await first.prepare()
            var answer = server.state()
            switch mutation {
            case 0: answer.memberID = "20000000-0000-4000-8000-000000000099"
            case 1: answer.deviceID = "10000000-0000-4000-8000-000000000099"
            case 2: answer.secretVersion += 1
            default: answer.credentialProtocol = "1.0"
            }
            server.overrideState = answer
            let calls = server.calls.count
            let restarted = identity(kit, server: server)
            let launch = await restarted.prepare()
            XCTAssertEqual(launch, .unavailable)
            XCTAssertEqual(Array(server.calls.dropFirst(calls)), ["state"])
            XCTAssertEqual(try restarted.journal.read()?.phase, .rotateUncertain)
            XCTAssertNil(restarted.credential)
        }
    }

    func testRetryAfterSurvivesRestartAndRestrictsRecoveryAndPrivacyCleanup() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); server.loseCommit = true
        let first = identity(kit, server: server); _ = await first.mint(role: .create, replacing: nil)
        server.stateFailures = [.refused(.rateLimited, DuoErrorContext(httpStatus: 429, retryAfter: 60))]
        let refused = await first.prepare(); XCTAssertEqual(refused, .unavailable)
        let deadline = try XCTUnwrap(try first.journal.retryDeadline())
        XCTAssertEqual(deadline.timeIntervalSince(kit.clock.now), 60, accuracy: 0.001)
        let calls = server.calls.count
        let restarted = identity(kit, server: server)
        let launch = await restarted.prepare(); let deleted = await restarted.deleteIdentity()
        XCTAssertEqual(launch, .unavailable); XCTAssertFalse(deleted); XCTAssertEqual(server.calls.count, calls)
        let later = DuoTestKit(now: kit.clock.now.addingTimeInterval(61), secretStore: kit.secretStore)
        let elapsed = identity(later, server: server)
        let resumed = await elapsed.prepare()
        XCTAssertEqual(resumed, .ready); XCTAssertEqual(Array(server.calls.dropFirst(calls)), ["state"])
        XCTAssertNil(try elapsed.journal.retryDeadline())
    }

    func testContinueStaysAnsweredWhenOrdinaryHydrationIsOffline() async throws {
        let kit = DuoTestKit(); let server = RecoveryServer(); let sut = identity(kit, server: server)
        _ = await sut.mint(role: .create, replacing: nil)
        try kit.secretStore.delete(service: DuoSecrets.service, account: sut.journal.markerAccount)
        _ = await sut.prepare()
        XCTAssertEqual(kit.store.availability, .needsRestoreChoice(DuoRestorePrompt(partnerName: nil, myName: nil)))
        // FakeDuoTransport's ordinary GET/me is offline unless a response is provided.
        await sut.continueAsRestored()
        XCTAssertFalse(try XCTUnwrap(try sut.journal.read()).restoreConfirmationRequired)
        XCTAssertEqual(kit.store.availability, .available)
        XCTAssertNotNil(sut.credential)
        XCTAssertEqual(kit.transport.calls, [.me])
        let launch = await sut.prepare(); XCTAssertEqual(launch, .ready)
    }

}
#endif
