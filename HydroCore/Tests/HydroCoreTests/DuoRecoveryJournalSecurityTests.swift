import Foundation
import XCTest
@testable import HydroCore

/// These tests attack stored records and persistence boundaries independently of the live
/// coordinator's happy path. A corrupted or uncertain write must never become absence.
final class DuoRecoveryJournalSecurityTests: XCTestCase {
    private let device = "11111111-1111-4111-8111-111111111111"
    private let member = "22222222-2222-4222-8222-222222222222"
    private let installation = "33333333-3333-4333-8333-333333333333"
    private let operation = "44444444-4444-4444-8444-444444444444"
    private let oldSecret = "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8"
    private let nextSecret = Data(repeating: 7, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")

    private func active() -> DuoRecoveryRecord {
        var r = DuoRecoveryRecord(environment: .staging, installationID: installation, phase: .active)
        r.active = DuoJournalCredential(DuoCredential(memberID: member, deviceID: device, deviceSecret: oldSecret))
        r.activeRole = .reconnectThrowaway
        return r
    }
    private func rotation() -> DuoRecoveryRecord {
        var r = active(); r.phase = .rotateReady
        var p = DuoRecoveryPending(kind: .rotation, operationID: operation, candidateSecret: nextSecret, role: .restore, acceptedTermsVersion: 1, appVersion: "2.0")
        p.expectedMemberID = member; p.expectedSecretVersion = 1; p.reservedDeviceID = device
        r.pending = p
        return r
    }

    func testPendingMetadataUsesPinnedScalarAndIntegerBounds() throws {
        var r = rotation(); r.pending?.appVersion = String(repeating: "😀", count: 64)
        XCTAssertNoThrow(try r.validate())
        r.pending?.appVersion = "a" + String(repeating: "\u{301}", count: 64)
        XCTAssertThrowsError(try r.validate())
        r = rotation(); r.pending?.acceptedTermsVersion = Int(Int32.max) + 1
        XCTAssertThrowsError(try r.validate())
        r = rotation(); r.pending?.role = .create
        XCTAssertThrowsError(try r.validate())
    }

    func testContradictoryPhaseAndOwnershipProofsFailClosed() {
        var records: [DuoRecoveryRecord] = []
        var r = rotation(); r.pending?.expectedMemberID = "55555555-5555-4555-8555-555555555555"; records.append(r)
        r = rotation(); r.pending?.candidateSecret = oldSecret; records.append(r)
        r = rotation(); r.pending?.expectedSecretVersion = 2; records.append(r)
        r = rotation(); r.pending?.commitMayHaveRun = true; records.append(r)
        r = rotation(); r.phase = .rotateUncertain; records.append(r)
        r = rotation(); r.phase = .cleanupPending; records.append(r)
        r = active(); r.activeRole = nil; records.append(r)
        r = active(); r.phase = .abandoned; records.append(r)
        for (index, record) in records.enumerated() { XCTAssertThrowsError(try record.validate(), "mutation \(index)") }
    }

    func testNeitherUnresolvedCandidateNorCopiedRestoreFlagsGrantOrdinaryUse() throws {
        var r = rotation(); XCTAssertNil(r.ordinaryCredential)
        r = active(); r.restoreRotationRequired = true; XCTAssertNil(r.ordinaryCredential)
        r = active(); r.restoreConfirmationRequired = true; XCTAssertNil(r.ordinaryCredential)
        r = active(); r.access = .suspended; XCTAssertNil(r.ordinaryCredential)
        r = active(); r.access = .cleanupOnly; r.intent = .deleteIdentity; r.phase = .cleanupPending
        try r.validate(); XCTAssertNil(r.ordinaryCredential)
    }

    func testMirrorRejectsPendingAndRawEscapedDuplicateKeys() throws {
        let store = DuoMemorySecretStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging)
        XCTAssertThrowsError(try journal.writeMirror(rotation()))
        let r = active(); try journal.replace(r, expectedRevision: nil); try journal.writeMirror(r)
        let original = try XCTUnwrap(try store.read(service: DuoSecrets.service, account: journal.mirrorAccount))
        let text = try XCTUnwrap(String(data: original, encoding: .utf8))
        let duplicate = text.replacingOccurrences(of: "\"storage_version\":1", with: "\"storage_version\":1,\"storage\\u005fversion\":1")
        XCTAssertNotEqual(duplicate, text)
        try store.write(Data(duplicate.utf8), service: DuoSecrets.service, account: journal.mirrorAccount, accessibility: .afterFirstUnlock)
        XCTAssertThrowsError(try journal.readMirror())
        XCTAssertEqual(try journal.read(), r, "A corrupt mirror cannot replace the authoritative journal")
    }

    func testReadbackFailureDoesNotPretendWriteWasAbsent() throws {
        let store = ReadbackFailureStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging)
        store.failNextReadAfterWrite = true
        XCTAssertThrowsError(try journal.replace(rotation(), expectedRevision: nil))
        let recovered = try XCTUnwrap(try DuoRecoveryJournal(store: store, environment: .staging).read())
        XCTAssertEqual(recovered.phase, .rotateReady); XCTAssertNil(recovered.ordinaryCredential)
        XCTAssertThrowsError(try journal.replace(active(), expectedRevision: nil), "The uncertain write is not permission to overwrite as a fresh install")
    }

    func testAbandonmentFencesOldRevisionAcrossNewExplicitSetup() throws {
        let store = DuoMemorySecretStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging)
        let old = active(); try journal.replace(old, expectedRevision: nil)
        try journal.abandon(random: DuoSystemRandom())
        let abandoned = try XCTUnwrap(try journal.read())
        var fresh = rotation(); fresh.recordRevision = abandoned.recordRevision + 1; fresh.identityGeneration = abandoned.identityGeneration + 1
        try journal.replace(fresh, expectedRevision: abandoned.recordRevision)
        var callback = old; callback.recordRevision += 1
        XCTAssertThrowsError(try journal.replace(callback, expectedRevision: old.recordRevision))
        XCTAssertEqual(try journal.read(), fresh); XCTAssertNil(try journal.read()?.ordinaryCredential)
    }

    func testMissingMalformedAndMismatchedMarkersAreNeverSameInstallProof() throws {
        let store = DuoMemorySecretStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging); let r = active()
        XCTAssertFalse(try journal.markerMatches(r))
        try store.write(Data("legacy-sixteen!!".utf8), service: DuoSecrets.service, account: journal.markerAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertThrowsError(try journal.markerMatches(r))
        try store.write(Data(operation.utf8), service: DuoSecrets.service, account: journal.markerAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertFalse(try journal.markerMatches(r))
        try journal.writeMarker(r); XCTAssertTrue(try journal.markerMatches(r))
    }
}

private final class ReadbackFailureStore: DuoSecretStore, @unchecked Sendable {
    let memory = DuoMemorySecretStore()
    var failNextReadAfterWrite = false
    private var failRead = false
    func read(service: String, account: String) throws -> Data? {
        if failRead { failRead = false; throw DuoJournalError.unavailable }
        return try memory.read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try memory.write(data, service: service, account: account, accessibility: accessibility)
        if failNextReadAfterWrite { failNextReadAfterWrite = false; failRead = true }
    }
    func delete(service: String, account: String) throws { try memory.delete(service: service, account: account) }
    func deleteAll(service: String) throws { try memory.deleteAll(service: service) }
}
