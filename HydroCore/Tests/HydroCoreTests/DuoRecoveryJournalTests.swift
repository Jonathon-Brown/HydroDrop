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

    /// A tester's Keychain holds staging and production side by side in Duo's one service.
    /// Giving one up used to erase the whole service, and the other identity with it.
    func testAbandoningOneEnvironmentKeepsTheOtherEnvironmentsIdentity() throws {
        let store = DuoMemorySecretStore(); let secrets = DuoSecrets(store: store)
        let staging = DuoRecoveryJournal(store: store, environment: .staging)
        let production = DuoRecoveryJournal(store: store, environment: .production)
        let productionDevice = "10000000-0000-4000-8000-000000000002"
        let s = active(); try staging.replace(s, expectedRevision: nil); try staging.writeMirror(s); try staging.writeMarker(s)
        var p = active(); p.environment = .production
        p.active = DuoJournalCredential(DuoCredential(memberID: member, deviceID: productionDevice, deviceSecret: secret))
        try production.replace(p, expectedRevision: nil); try production.writeMirror(p); try production.writeMarker(p)
        let link = DuoSecrets.linkSecretAccount(duoID: UUID(uuidString: "50000000-0000-4000-8000-000000000001")!)
        for account in [DuoSecrets.attestKeyAccount(deviceID: device), DuoSecrets.attestKeyAccount(deviceID: productionDevice),
                        DuoSecrets.pendingAttestKeyAccount, link] {
            try store.write(Data("x".utf8), service: DuoSecrets.service, account: account, accessibility: .afterFirstUnlock)
        }
        try secrets.save(DuoCredential(memberID: member, deviceID: device, deviceSecret: secret))
        try secrets.writeInstallMarker(random: DuoSystemRandom())

        try staging.abandon(random: DuoSystemRandom())

        XCTAssertEqual(try production.read(), p); XCTAssertEqual(try production.readMirror()?.credential, p.active)
        XCTAssertTrue(try production.markerMatches(p))
        // The link secret names no environment, so it waits for the last wipe (the shortcut in
        // `DuoSecrets.deleteEverything`).
        XCTAssertEqual(store.accounts(service: DuoSecrets.service),
                       [DuoSecrets.attestKeyAccount(deviceID: productionDevice), production.markerAccount,
                        production.mirrorAccount, production.recordAccount, link].sorted())
        try production.abandon(random: DuoSystemRandom())
        XCTAssertEqual(store.accounts(service: DuoSecrets.service), [])
    }

    /// A restored phone holds the other environment's mirror alone, and a record that cannot be
    /// read may still be an identity: both count as held, so neither is wiped.
    func testAMirrorOnlyOrUnreadableOtherEnvironmentIsKept() throws {
        for unreadable in [false, true] {
            let store = DuoMemorySecretStore()
            let staging = DuoRecoveryJournal(store: store, environment: .staging)
            let production = DuoRecoveryJournal(store: store, environment: .production)
            try staging.replace(active(), expectedRevision: nil)
            var p = active(); p.environment = .production
            try production.writeMirror(p)
            if unreadable {
                try store.write(Data("{".utf8), service: DuoSecrets.service, account: production.recordAccount,
                                accessibility: .afterFirstUnlockThisDeviceOnly)
            }
            try staging.abandon(random: DuoSystemRandom())
            XCTAssertEqual(try production.readMirror()?.credential, p.active, "unreadable: \(unreadable)")
            XCTAssertEqual(store.accounts(service: DuoSecrets.service).count, unreadable ? 2 : 1, "unreadable: \(unreadable)")
        }
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
