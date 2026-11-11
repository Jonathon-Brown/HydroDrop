import Foundation

/// A credential operation is one protected value. In particular the candidate and the fact
/// that its request could have left the phone never live in different Keychain items.
public struct DuoJournalCredential: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var memberID: String
    public var deviceID: String
    public var deviceSecret: String
    public var secretVersion: Int
    public var credentialProtocol: String
    public init(_ credential: DuoCredential, protocolVersion: String = "1.1") {
        memberID = credential.memberID; deviceID = credential.deviceID; deviceSecret = credential.deviceSecret
        secretVersion = credential.secretVersion; credentialProtocol = protocolVersion
    }
    public var credential: DuoCredential { DuoCredential(memberID: memberID, deviceID: deviceID, deviceSecret: deviceSecret, secretVersion: secretVersion) }
    public var bearer: DuoRecoveryCredential { DuoRecoveryCredential(deviceID: deviceID, deviceSecret: deviceSecret) }
    public var description: String { "DuoJournalCredential(<redacted>)" }
    public var debugDescription: String { description }
    enum CodingKeys: String, CodingKey { case memberID = "member_id", deviceID = "device_id", deviceSecret = "device_secret", secretVersion = "secret_version", credentialProtocol = "credential_protocol" }
    public func validate() throws {
        guard DuoRecoveryWire.isUUID(memberID), bearer.isValid, DuoRecoveryWire.isVersion(secretVersion), ["1.0", "1.1"].contains(credentialProtocol) else { throw DuoJournalError.invalid }
    }
}

public enum DuoCredentialRole: String, Codable, Sendable { case established, reconnectThrowaway = "reconnect_throwaway" }
public enum DuoRecoveryEnvironment: String, Codable, Sendable { case staging, production }
public struct DuoRecoveryPending: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Kind: String, Codable, Sendable { case mint, rotation }
    public enum Role: String, Codable, Sendable { case create, join, reconnectThrowaway = "reconnect_throwaway", restore }
    public var kind: Kind
    public var operationID: String
    public var candidateSecret: String
    public var role: Role
    public var acceptedTermsVersion: Int
    public var platform: String
    public var appVersion: String
    public var reservedDeviceID: String?
    public var reservationExpiresAt: String?
    public var expectedSecretVersion: Int?
    public var expectedMemberID: String?
    public var commitMayHaveRun: Bool
    public var confirmed: DuoJournalCredential?
    public init(kind: Kind, operationID: String, candidateSecret: String, role: Role, acceptedTermsVersion: Int, appVersion: String) {
        self.kind = kind; self.operationID = operationID; self.candidateSecret = candidateSecret; self.role = role
        self.acceptedTermsVersion = acceptedTermsVersion; platform = "ios"; self.appVersion = appVersion
        commitMayHaveRun = false
    }
    public var candidate: DuoRecoveryCredential? { reservedDeviceID.map { DuoRecoveryCredential(deviceID: $0, deviceSecret: candidateSecret) } }
    public var description: String { "DuoRecoveryPending(<redacted>)" }
    public var debugDescription: String { description }
    enum CodingKeys: String, CodingKey {
        case kind, operationID = "operation_id", candidateSecret = "candidate_secret", role, acceptedTermsVersion = "accepted_terms_version", platform, appVersion = "app_version"
        case reservedDeviceID = "reserved_device_id", reservationExpiresAt = "reservation_expires_at", expectedSecretVersion = "expected_secret_version", expectedMemberID = "expected_member_id", commitMayHaveRun = "commit_may_have_run", confirmed
    }
}

public struct DuoRecoveryRecord: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public enum Phase: String, Codable, Sendable {
        case activeLegacy = "active_legacy", active, prepareReady = "prepare_ready", reservationSaved = "reservation_saved", commitUncertain = "commit_uncertain"
        case rotateReady = "rotate_ready", rotateUncertain = "rotate_uncertain", promotionPending = "promotion_pending", cleanupPending = "cleanup_pending", abandoned
    }
    public enum Access: String, Codable, Sendable { case eligible, restoreConfirmationRequired = "restore_confirmation_required", suspended, cleanupOnly = "cleanup_only", abandoned }
    public enum Intent: String, Codable, Sendable { case use, cancelSetup = "cancel_setup", deleteIdentity = "delete_identity", abandonLocal = "abandon_local" }
    public var storageVersion = 1
    public var wireVersion = "1.1"
    public var environment: DuoRecoveryEnvironment
    // The journal schema uses JSON-safe 53-bit counters, including when HydroCore
    // is compiled for the Watch app, whose native Int is only 32 bits.
    public var recordRevision: Int64 = 1
    public var installationID: String
    public var identityGeneration: Int64 = 0
    public var phase: Phase
    public var access: Access = .eligible
    public var restoreConfirmationRequired = false
    public var restoreRotationRequired = false
    public var intent: Intent = .use
    public var activeRole: DuoCredentialRole?
    public var active: DuoJournalCredential?
    public var pending: DuoRecoveryPending?
    public var abandonedOperationID: String?
    public var mirrorWrittenRevision: Int64?
    public init(environment: DuoRecoveryEnvironment, installationID: String, phase: Phase) {
        self.environment = environment; self.installationID = installationID; self.phase = phase
    }
    public var description: String { "DuoRecoveryRecord(\(phase.rawValue), revision: \(recordRevision), <redacted>)" }
    public var ordinaryCredential: DuoCredential? {
        guard intent == .use, access == .eligible, !restoreConfirmationRequired, !restoreRotationRequired,
              pending == nil, phase == .active || phase == .activeLegacy else { return nil }
        return active?.credential
    }
    public var debugDescription: String { description }
    enum CodingKeys: String, CodingKey {
        case storageVersion = "storage_version", wireVersion = "wire_version", environment, recordRevision = "record_revision", installationID = "installation_id", identityGeneration = "identity_generation", phase, access
        case restoreConfirmationRequired = "restore_confirmation_required", restoreRotationRequired = "restore_rotation_required", intent, activeRole = "active_role", active, pending, abandonedOperationID = "abandoned_operation_id", mirrorWrittenRevision = "mirror_written_revision"
    }
    public func validate() throws {
        guard storageVersion == 1, wireVersion == "1.1", recordRevision > 0, recordRevision <= 9_007_199_254_740_991,
              identityGeneration >= 0, identityGeneration <= 9_007_199_254_740_991, DuoRecoveryWire.isUUID(installationID),
              (active == nil) == (activeRole == nil), mirrorWrittenRevision.map({ $0 > 0 && $0 <= recordRevision }) ?? true,
              abandonedOperationID.map(DuoRecoveryWire.isUUID) ?? true else { throw DuoJournalError.invalid }
        try active?.validate()
        if phase == .abandoned {
            guard intent == .abandonLocal, access == .abandoned, active == nil, pending == nil else { throw DuoJournalError.invalid }; return
        }
        if phase == .cleanupPending {
            guard [.cancelSetup, .deleteIdentity].contains(intent), access == .cleanupOnly, active != nil || pending != nil else { throw DuoJournalError.invalid }
        } else {
            guard intent == .use, ![.abandoned, .cleanupOnly].contains(access) else { throw DuoJournalError.invalid }
        }
        if phase == .active || phase == .activeLegacy {
            guard pending == nil, active?.credentialProtocol == (phase == .active ? "1.1" : "1.0") else { throw DuoJournalError.invalid }; return
        }
        guard let p = pending else {
            guard phase == .cleanupPending, active != nil else { throw DuoJournalError.invalid }; return
        }
        guard DuoRecoveryWire.isUUID(p.operationID), DuoRecoveryWire.isSecret(p.candidateSecret), DuoRecoveryWire.isVersion(p.acceptedTermsVersion),
              ["ios", "android"].contains(p.platform), (1...64).contains(p.appVersion.unicodeScalars.count),
              p.reservedDeviceID.map(DuoRecoveryWire.isUUID) ?? true,
              p.reservationExpiresAt.map({ DuoRecoveryWire.timestamp($0) != nil }) ?? true,
              p.expectedMemberID.map(DuoRecoveryWire.isUUID) ?? true,
              p.expectedSecretVersion.map(DuoRecoveryWire.isVersion) ?? true else { throw DuoJournalError.invalid }
        try p.confirmed?.validate()
        if p.kind == .mint {
            guard p.role != .restore, p.expectedMemberID == nil, p.expectedSecretVersion == nil,
                  active == nil || p.role == .reconnectThrowaway || phase == .promotionPending,
                  (p.reservedDeviceID == nil) == (p.reservationExpiresAt == nil) else { throw DuoJournalError.invalid }
            if phase == .prepareReady { guard p.reservedDeviceID == nil, !p.commitMayHaveRun else { throw DuoJournalError.invalid } }
            else if phase != .cleanupPending { guard p.reservedDeviceID != nil else { throw DuoJournalError.invalid } }
            guard ![.rotateReady, .rotateUncertain].contains(phase) else { throw DuoJournalError.invalid }
        } else {
            guard p.role == .restore, let active, p.reservedDeviceID == active.deviceID, p.reservationExpiresAt == nil,
                  p.expectedMemberID == active.memberID, let version = p.expectedSecretVersion,
                  version < Int(Int32.max), p.candidateSecret != (phase == .promotionPending ? "" : active.deviceSecret),
                  active.secretVersion == (phase == .promotionPending ? version + 1 : version),
                  ![.prepareReady, .reservationSaved, .commitUncertain].contains(phase) else { throw DuoJournalError.invalid }
        }
        if [.reservationSaved, .rotateReady].contains(phase), p.commitMayHaveRun { throw DuoJournalError.invalid }
        if [.commitUncertain, .rotateUncertain, .promotionPending].contains(phase), !p.commitMayHaveRun { throw DuoJournalError.invalid }
        if phase == .promotionPending {
            guard let c = p.confirmed, c == active, c.deviceID == p.reservedDeviceID, c.deviceSecret == p.candidateSecret,
                  c.credentialProtocol == "1.1", c.secretVersion == (p.kind == .mint ? 1 : (p.expectedSecretVersion! + 1)),
                  p.expectedMemberID.map({ c.memberID == $0 }) ?? true else { throw DuoJournalError.invalid }
        } else if p.confirmed != nil { throw DuoJournalError.invalid }
    }
}

public struct DuoPortableCredential: Codable, Equatable, Sendable {
    public var storageVersion = 1
    public var environment: DuoRecoveryEnvironment
    public var credentialRole: DuoCredentialRole
    public var credential: DuoJournalCredential
    public init(environment: DuoRecoveryEnvironment, credentialRole: DuoCredentialRole, credential: DuoJournalCredential) {
        self.environment = environment; self.credentialRole = credentialRole; self.credential = credential
    }
    enum CodingKeys: String, CodingKey { case storageVersion = "storage_version", environment, credentialRole = "credential_role", credential }
}

public enum DuoJournalError: Error { case invalid, changed, unavailable, legacyProvenanceRequired }

/// Readback is part of a successful transition. A failed write never authorizes a network
/// request; even if the write reached Keychain, the next process discovers its actual phase.
public final class DuoRecoveryJournal: @unchecked Sendable {
    public let environment: DuoRecoveryEnvironment
    public let store: DuoSecretStore
    public static let tombstoneService = "us.hydrodrop.duo.lifecycle"
    public var recordAccount: String { "identity-v1.1.\(environment.rawValue)" }
    public var mirrorAccount: String { "portable-v1.1.\(environment.rawValue)" }
    public var markerAccount: String { "install-v1.1.\(environment.rawValue)" }
    private let lock = NSRecursiveLock()
    public init(store: DuoSecretStore, environment: DuoRecoveryEnvironment) { self.store = store; self.environment = environment }
    public func read() throws -> DuoRecoveryRecord? {
        lock.lock(); defer { lock.unlock() }
        if let data = try store.read(service: Self.tombstoneService, account: recordAccount) {
            let r = try Self.decodeRecord(data); guard r.environment == environment, r.phase == .abandoned else { throw DuoJournalError.invalid }; return r
        }
        guard let data = try store.read(service: DuoSecrets.service, account: recordAccount) else { return nil }
        let r = try Self.decodeRecord(data); guard r.environment == environment else { throw DuoJournalError.invalid }; return r
    }
    public func replace(_ value: DuoRecoveryRecord, expectedRevision: Int64?) throws {
        lock.lock(); defer { lock.unlock() }
        let current = try read()
        guard current?.recordRevision == expectedRevision else { throw DuoJournalError.changed }
        try value.validate(); guard value.environment == environment, value.recordRevision == (expectedRevision ?? 0) + 1 else { throw DuoJournalError.invalid }
        try verifiedWrite(try Self.encodeRecord(value), service: DuoSecrets.service, account: recordAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        if current?.phase == .abandoned {
            try store.delete(service: Self.tombstoneService, account: recordAccount)
            guard try store.read(service: Self.tombstoneService, account: recordAccount) == nil else { throw DuoJournalError.unavailable }
        }
    }
    public func writeMarker(_ record: DuoRecoveryRecord) throws {
        try verifiedWrite(Data(record.installationID.utf8), service: DuoSecrets.service, account: markerAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
    }
    public func markerMatches(_ record: DuoRecoveryRecord) throws -> Bool {
        guard let data = try store.read(service: DuoSecrets.service, account: markerAccount) else { return false }
        guard let marker = String(data: data, encoding: .utf8), DuoRecoveryWire.isUUID(marker) else { throw DuoJournalError.invalid }
        return marker == record.installationID
    }
    public func readMirror() throws -> DuoPortableCredential? {
        guard let data = try store.read(service: DuoSecrets.service, account: mirrorAccount) else { return nil }
        try DuoRecoveryWire.validateJSON(data)
        let object = try Self.object(data); try Self.keys(object, ["storage_version", "environment", "credential_role", "credential"])
        try Self.credentialObject(object["credential"])
        let mirror = try JSONDecoder().decode(DuoPortableCredential.self, from: data)
        guard mirror.storageVersion == 1, mirror.environment == environment else { throw DuoJournalError.invalid }
        try mirror.credential.validate(); return mirror
    }
    public func writeMirror(_ record: DuoRecoveryRecord) throws {
        guard let active = record.active, let role = record.activeRole,
              record.phase == .promotionPending || record.phase == .active || record.phase == .activeLegacy else { throw DuoJournalError.invalid }
        let mirror = DuoPortableCredential(environment: environment, credentialRole: role, credential: active)
        try verifiedWrite(try JSONEncoder().encode(mirror), service: DuoSecrets.service, account: mirrorAccount, accessibility: .afterFirstUnlock)
    }
    /// The tombstone is outside the wiped service, contains no credential, and takes precedence
    /// over both the journal and a stale mirror. A full-service erase therefore cannot make a
    /// late callback adopt an abandoned candidate or make an old backup appear newly consented.
    public func abandon(random: DuoRandom) throws {
        lock.lock(); defer { lock.unlock() }
        let current = try read()
        var tombstone = DuoRecoveryRecord(environment: environment, installationID: current?.installationID ?? random.uuid().uuidString.lowercased(), phase: .abandoned)
        tombstone.recordRevision = (current?.recordRevision ?? 0) + 1; tombstone.identityGeneration = (current?.identityGeneration ?? 0) + 1
        tombstone.intent = .abandonLocal; tombstone.access = .abandoned; tombstone.abandonedOperationID = current?.pending?.operationID ?? current?.abandonedOperationID
        try verifiedWrite(try Self.encodeRecord(tombstone), service: Self.tombstoneService, account: recordAccount, accessibility: .afterFirstUnlockThisDeviceOnly)
        try purgeAbandonedSecrets()
    }
    public func purgeAbandonedSecrets() throws {
        lock.lock(); defer { lock.unlock() }
        guard try read()?.phase == .abandoned else { throw DuoJournalError.changed }
        try store.deleteAll(service: DuoSecrets.service)
        for account in [recordAccount, mirrorAccount, markerAccount, DuoSecrets.deviceAccount, DuoSecrets.installMarkerAccount] {
            guard try store.read(service: DuoSecrets.service, account: account) == nil else { throw DuoJournalError.unavailable }
        }
    }
    private var retryAccount: String { "retry-after-v1.1.\(environment.rawValue)" }
    /// Retry-After contains no identity or secret, but must survive a restart of an uncertain
    /// operation. It is separate from the contract envelope and bound to this environment.
    public func retryDeadline() throws -> Date? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try store.read(service: Self.tombstoneService, account: retryAccount) else { return nil }
        try DuoRecoveryWire.validateJSON(data)
        let object = try Self.object(data); try Self.keys(object, ["storage_version", "environment", "not_before_ms"])
        let value = try JSONDecoder().decode(RetryDeadline.self, from: data)
        guard value.storage_version == 1, value.environment == environment.rawValue,
              value.not_before_ms >= 0, value.not_before_ms <= 253_402_300_799_999 else { throw DuoJournalError.invalid }
        return Date(timeIntervalSince1970: Double(value.not_before_ms) / 1_000)
    }
    public func saveRetryDeadline(_ deadline: Date, now: Date) throws {
        lock.lock(); defer { lock.unlock() }
        let delta = deadline.timeIntervalSince(now)
        let milliseconds = ceil(deadline.timeIntervalSince1970 * 1_000)
        guard delta.isFinite, delta >= 0, delta <= Double(Int32.max), milliseconds.isFinite,
              milliseconds >= 0, milliseconds <= 253_402_300_799_999 else { throw DuoJournalError.invalid }
        let value = RetryDeadline(storage_version: 1, environment: environment.rawValue, not_before_ms: Int64(milliseconds))
        try verifiedWrite(try JSONEncoder().encode(value), service: Self.tombstoneService, account: retryAccount,
                          accessibility: .afterFirstUnlockThisDeviceOnly)
    }
    public func clearRetryDeadline() throws {
        lock.lock(); defer { lock.unlock() }
        try store.delete(service: Self.tombstoneService, account: retryAccount)
        guard try store.read(service: Self.tombstoneService, account: retryAccount) == nil else { throw DuoJournalError.unavailable }
    }
    private struct RetryDeadline: Codable {
        let storage_version: Int
        let environment: String
        let not_before_ms: Int64
    }
    private func verifiedWrite(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        try store.write(data, service: service, account: account, accessibility: accessibility)
        guard try store.read(service: service, account: account) == data else { throw DuoJournalError.unavailable }
    }
    public static func decodeLegacyCredential(_ data: Data) throws -> DuoJournalCredential {
        try DuoRecoveryWire.validateJSON(data)
        let object = try self.object(data)
        try keys(object, ["memberID", "deviceID", "deviceSecret", "secretVersion"])
        let credential = try JSONDecoder().decode(DuoCredential.self, from: data)
        let result = DuoJournalCredential(credential, protocolVersion: "1.0")
        try result.validate(); return result
    }
    public static func encodeRecord(_ record: DuoRecoveryRecord) throws -> Data {
        try record.validate()
        var object = try self.object(JSONEncoder().encode(record))
        for key in ["active", "active_role", "pending", "abandoned_operation_id", "mirror_written_revision"] where object[key] == nil { object[key] = NSNull() }
        if var pending = object["pending"] as? [String: Any] {
            for key in ["reserved_device_id", "reservation_expires_at", "expected_secret_version", "expected_member_id", "confirmed"] where pending[key] == nil { pending[key] = NSNull() }
            object["pending"] = pending
        }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
    public static func decodeRecord(_ data: Data) throws -> DuoRecoveryRecord {
        try DuoRecoveryWire.validateJSON(data)
        let object = try self.object(data)
        try keys(object, ["storage_version", "wire_version", "environment", "record_revision", "installation_id", "identity_generation", "phase", "access", "restore_confirmation_required", "restore_rotation_required", "intent", "active_role", "active", "pending", "abandoned_operation_id", "mirror_written_revision"])
        if !(object["active"] is NSNull) { try credentialObject(object["active"]) }
        if !(object["pending"] is NSNull) {
            guard let p = object["pending"] as? [String: Any] else { throw DuoJournalError.invalid }
            try keys(p, ["kind", "operation_id", "candidate_secret", "role", "accepted_terms_version", "platform", "app_version", "reserved_device_id", "reservation_expires_at", "expected_secret_version", "expected_member_id", "commit_may_have_run", "confirmed"])
            if !(p["confirmed"] is NSNull) { try credentialObject(p["confirmed"]) }
        }
        let result = try JSONDecoder().decode(DuoRecoveryRecord.self, from: data); try result.validate(); return result
    }
    private static func object(_ data: Data) throws -> [String: Any] {
        guard let o = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw DuoJournalError.invalid }; return o
    }
    private static func keys(_ o: [String: Any], _ expected: Set<String>) throws {
        guard Set(o.keys) == expected else { throw DuoJournalError.invalid }
    }
    private static func credentialObject(_ object: Any?) throws {
        guard let object = object as? [String: Any] else { throw DuoJournalError.invalid }
        try keys(object, ["member_id", "device_id", "device_secret", "secret_version", "credential_protocol"])
    }
}
