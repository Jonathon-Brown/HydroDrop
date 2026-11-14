#if DUO_V2
import Foundation

/// The same gate surrounds the typed call and the physical session. The outer call invalidates
/// its result after refusal; the inner session stops every retry and attestation challenge.
struct DuoAgeGatedTransport: DuoTransport {
    let base: DuoTransport
    let gate: DuoNetworkGate
    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse {
        try await gate.run() { try await base.createDevice(request) }
    }
    func attestChallenge() async throws -> DuoWireAttestChallenge {
        try await gate.run() { try await base.attestChallenge() }
    }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse {
        try await gate.run(preservingDispatchedAnswer: true) { try await base.rotate(as: credential) }
    }
    func me() async throws -> DuoWireGetMeResponse {
        try await gate.run() { try await base.me() }
    }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember {
        try await gate.run() { try await base.updateMe(request) }
    }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws {
        try await gate.run(deletion: true) { try await base.deleteMe(request, key: key) }
    }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws {
        try await gate.run() { try await base.registerPush(request, firstUpload: firstUpload) }
    }
    func unregisterPush() async throws {
        try await gate.run() { try await base.unregisterPush() }
    }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse {
        try await gate.run() { try await base.createDuo(request, key: key) }
    }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite {
        try await gate.run() { try await base.createInvite(duoID: duoID, purpose: purpose, key: key) }
    }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse {
        try await gate.run() { try await base.peekInvite(code: code) }
    }
    func peekInvite(code: String, credential: DuoCredential?) async throws -> DuoWirePeekResponse {
        try await gate.run { try await base.peekInvite(code: code, credential: credential) }
    }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult {
        try await gate.run() { try await base.redeemInvite(request, key: key) }
    }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse {
        try await gate.run() { try await base.reconnect(request, key: key) }
    }
    func fetchDuo(id: String) async throws -> DuoWireHeader {
        try await gate.run() { try await base.fetchDuo(id: id) }
    }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges {
        try await gate.run() { try await base.fetchChanges(duoID: duoID, since: since) }
    }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult {
        try await gate.run() { try await base.pushDayStatuses(duoID: duoID, request) }
    }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult {
        try await gate.run() { try await base.sendNudge(duoID: duoID, request) }
    }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse {
        try await gate.run() { try await base.leave(duoID: duoID, key: key) }
    }
    func block(duoID: String, key: DuoIdempotencyKey) async throws {
        try await gate.run() { try await base.block(duoID: duoID, key: key) }
    }
}

struct DuoAgeGatedSession: DuoHTTPSession {
    let base: DuoHTTPSession
    let gate: DuoNetworkGate
    let deletionURL: URL
    private var rotationURL: URL { deletionURL.deletingLastPathComponent().appendingPathComponent("devices/me/rotate") }
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let deletion = request.httpMethod == "DELETE" && request.url == deletionURL
        let recoveryBase = deletionURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("v1.1")
        let recoveryRotation = recoveryBase.appendingPathComponent("devices/me/rotate")
        let recoveryCommit = recoveryBase.appendingPathComponent("devices")
        let rotation = request.httpMethod == "POST" && request.url.map { [rotationURL, recoveryRotation, recoveryCommit].contains($0) } == true
        // Only a canonical reservation cancellation at the configured origin is a privacy
        // exit. A suffix match would also authorize an attacker-controlled URL or a query.
        let cancellation: Bool
        if request.httpMethod == "POST", let url = request.url, url.query == nil, url.fragment == nil {
            let parts = url.pathComponents
            let id = parts.count >= 2 ? parts[parts.count - 2] : ""
            cancellation = DuoRecoveryWire.isUUID(id) && url == recoveryBase.appendingPathComponent("device-issuances/\(id)/cancel")
        } else { cancellation = false }
        return try await gate.run(deletion: deletion || cancellation, preservingDispatchedAnswer: rotation) {
            try Task.checkCancellation()
            return try await base.data(for: request)
        }
    }
}

/// The recovery seam shares the same physical gate. Committed proofs survive a changed age
/// answer; callers may save them for deletion but cannot use them to hydrate ordinary state.
struct DuoAgeGatedRecoveryTransport: DuoCredentialRecoveryTransport {
    let base: DuoCredentialRecoveryTransport
    let gate: DuoNetworkGate
    func recoveryCapabilities() async throws -> DuoRecoveryCapabilities {
        try await gate.run { try await base.recoveryCapabilities() }
    }
    func prepareDeviceIssuance(_ request: DuoRecoveryPrepareRequest) async throws -> DuoRecoveryIssuance {
        try await gate.run { try await base.prepareDeviceIssuance(request) }
    }
    func commitDevice(_ request: DuoRecoveryCommitRequest, as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCredentialState {
        try await gate.run(preservingDispatchedAnswer: true) { try await base.commitDevice(request, as: credential) }
    }
    func credentialState(as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCredentialState {
        try await gate.run { try await base.credentialState(as: credential) }
    }
    func rotateCredential(_ request: DuoRecoveryRotateRequest, as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCredentialState {
        try await gate.run(preservingDispatchedAnswer: true) { try await base.rotateCredential(request, as: credential) }
    }
    func cancelDeviceIssuance(deviceID: String, as credential: DuoRecoveryCredential) async throws -> DuoRecoveryCancelResponse {
        try await gate.run(deletion: true) { try await base.cancelDeviceIssuance(deviceID: deviceID, as: credential) }
    }
    func deleteMe(as credential: DuoRecoveryCredential, _ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws {
        try await gate.run(deletion: true) { try await base.deleteMe(as: credential, request, key: key) }
    }
}

struct DuoAgeGatedAttester: DuoAttesting {
    let base: DuoAttesting
    let gate: DuoNetworkGate
    var isSupported: Bool { base.isSupported }
    func hasKey(forDevice deviceID: String) -> Bool { base.hasKey(forDevice: deviceID) }
    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken {
        try await gate.run { try await base.attestNewKey(clientDataHash: clientDataHash) }
    }
    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken {
        try await gate.run { try await base.assert(clientDataHash: clientDataHash, deviceID: deviceID) }
    }
    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) {
        guard gate.state == .open else { return }
        base.adoptPendingKey(keyID, forDevice: deviceID)
    }
    func forgetKeys(forDevice deviceID: String) { base.forgetKeys(forDevice: deviceID) }
}

struct DuoAgeGatedDeviceCheck: DuoDeviceCheckProviding {
    let base: DuoDeviceCheckProviding
    let gate: DuoNetworkGate
    var isSupported: Bool { base.isSupported }
    func token() async -> String? {
        try? await gate.run { await base.token() }
    }
}
#endif
