#if DUO_V2
import Foundation

// STUB (foundation). Stage A replaces this whole file with the URLSession client; the
// initialiser below is the one `DuoComposition` calls and must keep its shape.

final class DuoAPIClient: DuoTransport, @unchecked Sendable {
    private let unwired = DuoUnwiredTransport()

    init(baseURL: URL, client: DuoClientInfo, credentials: DuoCredentialProviding, attester: DuoAttesting,
         session: DuoHTTPSession = URLSessionHTTP()) {}

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { try await unwired.createDevice(request) }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try await unwired.attestChallenge() }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { try await unwired.rotate(as: credential) }
    func me() async throws -> DuoWireGetMeResponse { try await unwired.me() }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { try await unwired.updateMe(request) }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { try await unwired.deleteMe(request, key: key) }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { try await unwired.registerPush(request, firstUpload: firstUpload) }
    func unregisterPush() async throws { try await unwired.unregisterPush() }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { try await unwired.createDuo(request, key: key) }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { try await unwired.createInvite(duoID: duoID, purpose: purpose, key: key) }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try await unwired.peekInvite(code: code) }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { try await unwired.redeemInvite(request, key: key) }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { try await unwired.reconnect(request, key: key) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try await unwired.fetchDuo(id: id) }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try await unwired.fetchChanges(duoID: duoID, since: since) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { try await unwired.pushDayStatuses(duoID: duoID, request) }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try await unwired.sendNudge(duoID: duoID, request) }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { try await unwired.leave(duoID: duoID, key: key) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try await unwired.block(duoID: duoID, key: key) }
}
#endif
