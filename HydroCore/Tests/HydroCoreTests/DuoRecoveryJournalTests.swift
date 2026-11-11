import XCTest
@testable import HydroCore

final class DuoRecoveryJournalTests: XCTestCase {
    private let installation = "30000000-0000-4000-8000-000000000001"
    private let device = "10000000-0000-4000-8000-000000000001"
    private let member = "20000000-0000-4000-8000-000000000001"
    private let secret = Data(repeating: 1, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: "")
    private func active() -> DuoRecoveryRecord {
        var r = DuoRecoveryRecord(environment: .staging, installationID: installation, phase: .active)
        r.active = DuoJournalCredential(DuoCredential(memberID: member, deviceID: device, deviceSecret: secret))
        r.activeRole = .established
        return r
    }
    func testClosedNullableShapeAndIndependentRestoreFlagsRoundTrip() throws {
        var r = active(); r.restoreConfirmationRequired = true; r.restoreRotationRequired = false; r.access = .suspended
        let bytes = try DuoRecoveryJournal.encodeRecord(r)
        XCTAssertEqual(try DuoRecoveryJournal.decodeRecord(bytes), r)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        XCTAssertTrue(object["pending"] is NSNull)
        object.removeValue(forKey: "pending")
        XCTAssertThrowsError(try DuoRecoveryJournal.decodeRecord(JSONSerialization.data(withJSONObject: object)))
        object["pending"] = NSNull(); object["future_feature"] = true
        XCTAssertThrowsError(try DuoRecoveryJournal.decodeRecord(JSONSerialization.data(withJSONObject: object)))
    }
    func testCASRejectsStaleCallbackAfterReconstructingJournal() throws {
        let store = DuoMemorySecretStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging)
        let r = active(); try journal.replace(r, expectedRevision: nil)
        var next = r; next.recordRevision = 2; next.access = .suspended
        try DuoRecoveryJournal(store: store, environment: .staging).replace(next, expectedRevision: 1)
        var stale = r; stale.recordRevision = 2; stale.restoreConfirmationRequired = true
        XCTAssertThrowsError(try journal.replace(stale, expectedRevision: 1))
        XCTAssertEqual(try journal.read(), next)
    }
    func testTombstoneSurvivesServiceEraseAndWinsOverReintroducedMirror() throws {
        let store = DuoMemorySecretStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging)
        let r = active(); try journal.replace(r, expectedRevision: nil); try journal.writeMirror(r)
        let mirror = try XCTUnwrap(try store.read(service: DuoSecrets.service, account: journal.mirrorAccount))
        try journal.abandon(random: DuoSystemRandom())
        try store.write(mirror, service: DuoSecrets.service, account: journal.mirrorAccount, accessibility: .afterFirstUnlock)
        let restarted = DuoRecoveryJournal(store: store, environment: .staging)
        XCTAssertEqual(try restarted.read()?.phase, .abandoned)
        XCTAssertNil(try restarted.read()?.ordinaryCredential)
        let bytes = try XCTUnwrap(try store.read(service: DuoRecoveryJournal.tombstoneService, account: journal.recordAccount))
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(secret))
    }
    func testPortableMirrorBindsEnvironmentAndConfirmedRole() throws {
        let store = DuoMemorySecretStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging)
        var r = active(); r.activeRole = .reconnectThrowaway
        try journal.replace(r, expectedRevision: nil); try journal.writeMirror(r)
        XCTAssertEqual(try journal.readMirror()?.credentialRole, .reconnectThrowaway)
        let bytes = try XCTUnwrap(try store.read(service: DuoSecrets.service, account: journal.mirrorAccount))
        let production = DuoRecoveryJournal(store: store, environment: .production)
        try store.write(bytes, service: DuoSecrets.service, account: production.mirrorAccount, accessibility: .afterFirstUnlock)
        XCTAssertThrowsError(try production.readMirror())
    }
    func testMalformedAndDuplicateKeyRecordNeverReadsAsMissing() throws {
        let store = DuoMemorySecretStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging)
        try store.write(Data("{\"storage_version\":1,\"storage_version\":1}".utf8), service: DuoSecrets.service, account: journal.recordAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertThrowsError(try journal.read())
        try store.write(Data("null".utf8), service: DuoSecrets.service, account: journal.recordAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertThrowsError(try journal.read())
    }
    func testRotationPendingCannotEraseExpectedEpochOrChangeRole() throws {
        var r = active(); r.activeRole = .reconnectThrowaway; r.phase = .rotateReady
        var p = DuoRecoveryPending(kind: .rotation, operationID: "40000000-0000-4000-8000-000000000001", candidateSecret: Data(repeating: 2, count: 32).base64EncodedString().replacingOccurrences(of: "=", with: ""), role: .restore, acceptedTermsVersion: 1, appVersion: "2.0")
        p.expectedMemberID = member; p.expectedSecretVersion = 1; p.reservedDeviceID = device; r.pending = p
        XCTAssertNoThrow(try r.validate()); XCTAssertNil(r.ordinaryCredential)
        r.pending?.expectedSecretVersion = 2
        XCTAssertThrowsError(try r.validate())
    }
    func testRetryAfterIsStrictEnvironmentBoundAndReadAfterRestart() throws {
        let store = DuoMemorySecretStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging)
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        try journal.saveRetryDeadline(now.addingTimeInterval(60), now: now)
        XCTAssertEqual(try DuoRecoveryJournal(store: store, environment: .staging).retryDeadline(), now.addingTimeInterval(60))
        XCTAssertNil(try DuoRecoveryJournal(store: store, environment: .production).retryDeadline())
        XCTAssertThrowsError(try journal.saveRetryDeadline(now.addingTimeInterval(Double(Int32.max) + 1), now: now))
        try store.write(Data("{}".utf8), service: DuoRecoveryJournal.tombstoneService,
                        account: "retry-after-v1.1.staging", accessibility: .afterFirstUnlockThisDeviceOnly)
        XCTAssertThrowsError(try journal.retryDeadline())
        try journal.clearRetryDeadline(); XCTAssertNil(try journal.retryDeadline())
    }

    func testLegacyMigrationRejectsUnknownAndDuplicateFields() throws {
        let original = try JSONEncoder().encode(XCTUnwrap(active().active).credential)
        XCTAssertEqual(try DuoRecoveryJournal.decodeLegacyCredential(original).credentialProtocol, "1.0")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["environment"] = "staging"
        XCTAssertThrowsError(try DuoRecoveryJournal.decodeLegacyCredential(JSONSerialization.data(withJSONObject: object)))
        let duplicated = String(decoding: original, as: UTF8.self).dropLast() + ",\"secretVersion\":1}"
        XCTAssertThrowsError(try DuoRecoveryJournal.decodeLegacyCredential(Data(duplicated.utf8)))
    }

    func testCounterRangeIsJSONSafeAndIndependentOfNativeWordSize() throws {
        let maximum: Int64 = 9_007_199_254_740_991
        var r = active(); r.recordRevision = maximum; r.identityGeneration = maximum
        r.mirrorWrittenRevision = maximum
        XCTAssertEqual(try DuoRecoveryJournal.decodeRecord(DuoRecoveryJournal.encodeRecord(r)), r)
        var invalid = r; invalid.recordRevision = maximum + 1
        XCTAssertThrowsError(try DuoRecoveryJournal.encodeRecord(invalid))
        invalid = r; invalid.identityGeneration = maximum + 1
        XCTAssertThrowsError(try DuoRecoveryJournal.encodeRecord(invalid))
        let store = DuoMemorySecretStore(); let journal = DuoRecoveryJournal(store: store, environment: .staging)
        try store.write(DuoRecoveryJournal.encodeRecord(r), service: DuoSecrets.service,
                        account: journal.recordAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        var next = r; next.recordRevision += 1
        XCTAssertThrowsError(try journal.replace(next, expectedRevision: maximum))
        XCTAssertThrowsError(try journal.abandon(random: DuoSystemRandom()))
        XCTAssertEqual(try journal.read(), r)
    }

}
