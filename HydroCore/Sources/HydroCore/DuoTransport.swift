import Foundation

// The seam between Duo's logic and the network (final design §14, plan P2 item 3). The
// store, the sync engine, the membership flows and the identity code all talk to the server
// through `DuoTransport` and nothing else, so each can be tested against a scripted fake
// and the real API client can be tested against a stubbed URL session.
//
// One method for each of the contract's 19 client-called endpoints (`GET /health` is for
// monitors, not for the app). A method takes the typed request and returns the typed
// answer, or throws a `DuoTransportError`. Every call that the contract marks as idempotent
// (I) takes the `Idempotency-Key` its caller persisted before sending: the caller owns the
// key, because only the caller knows whether a request is a first attempt or a replay.

/// An `Idempotency-Key`, a UUID the caller keeps and replays unchanged (§6.0).
public struct DuoIdempotencyKey: Equatable, Hashable, Codable, Sendable {
    public var value: String

    public init(_ value: String) {
        self.value = value
    }

    public static func make(random: DuoRandom) -> DuoIdempotencyKey {
        DuoIdempotencyKey(random.uuid().uuidString.lowercased())
    }
}

public protocol DuoTransport: Sendable {
    // MARK: Identity and device

    /// `POST /devices`. Attested as `device_create` when attestation is available.
    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse
    /// `POST /attest/challenge`.
    func attestChallenge() async throws -> DuoWireAttestChallenge
    /// `POST /devices/me/rotate`. Any other holder of the old secret then answers `device_revoked`.
    /// It authenticates as `credential`, the one the launch decided on, and not as whatever the
    /// identity holds when the request leaves: a Create or Join that stores a new credential in
    /// the gap used to have its own secret rotated by a call meant for the restored one, and
    /// the phone kept the old secret of the identity it was now using. Never retried within a
    /// launch (its answer carries the only copy of the new secret, and the old one is gone). A
    /// launch that cannot tell what happened to one tries again at the next launch; if the first
    /// had landed, that one is answered `device_revoked`, which contract-v1 cannot avoid (D65).
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse
    /// `GET /me`.
    func me() async throws -> DuoWireGetMeResponse
    /// `PATCH /me`.
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember
    /// `DELETE /me`, idempotent (I).
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws
    /// `PUT /devices/me/push`. `firstUpload` is true for the first upload of a token by this
    /// device, which is attested as `push_register` (§6.2).
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws
    /// `DELETE /devices/me/push`.
    func unregisterPush() async throws

    // MARK: Duos and invites

    /// `POST /duos`, idempotent (I). Attested as `duo_create`.
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse
    /// `POST /duos/{id}/invites`, idempotent (I). For `link_device` the id is ignored by the
    /// server; pass any duo id or the nil UUID.
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite
    /// `POST /invites/peek`. Anonymous when this phone has no identity, with its bearer when
    /// it has one (so the pair row is applied and a person someone blocked sees nothing, D34).
    func peekInvite(code: String) async throws -> DuoWirePeekResponse
    /// `POST /invites/redeem`, idempotent (I). Attested as `invite_redeem`.
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult
    /// `POST /invites/reconnect`, idempotent (I). Attested as `invite_redeem`.
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse
    /// `GET /duos/{id}`, the header alone.
    func fetchDuo(id: String) async throws -> DuoWireHeader
    /// `GET /duos/{id}/changes?since=`.
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges
    /// `PUT /duos/{id}/statuses`. The answer is the change feed after the write.
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult
    /// `POST /duos/{id}/nudges`.
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult
    /// `POST /duos/{id}/leave`, idempotent (I). A superseded device may call it.
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse
    /// `POST /duos/{id}/block`, idempotent (I). A superseded device may call it.
    func block(duoID: String, key: DuoIdempotencyKey) async throws
}

// MARK: - Attestation and DeviceCheck (the seams the API client uses; the identity stage implements them)

/// The four calls the server attests, and the names the bind is made with (§11.2, D48).
public enum DuoAttestAction: String, Sendable {
    case deviceCreate = "device_create"
    case duoCreate = "duo_create"
    case inviteRedeem = "invite_redeem"
    case pushRegister = "push_register"

    /// `device_create` has no device yet, so its bind leaves the device out; the other three
    /// carry a bearer and name it.
    public var bindsDevice: Bool { self != .deviceCreate }
}

public struct DuoAttestationToken: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        /// A key's first use: App Attest's attestation object.
        case attestation
        /// Every later use: an assertion.
        case assertion
    }

    /// Unpadded base64url, as `X-HD-Attest` carries it.
    public var token: String
    public var keyID: String
    public var kind: Kind

    public init(token: String, keyID: String, kind: Kind) {
        self.token = token
        self.keyID = keyID
        self.kind = kind
    }
}

public protocol DuoAttesting: Sendable {
    /// False in the simulator and on a device that cannot attest: the app then goes on
    /// without a header, at the low tier (§11.2).
    var isSupported: Bool { get }
    func hasKey(forDevice deviceID: String) -> Bool
    /// Makes a new key and attests it over `clientDataHash` (the bind). The key is held as
    /// pending until `adoptPendingKey`. A key can be attested only once, so each identity
    /// brings its own, and a retry after an invalid assertion brings another.
    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken
    /// Asserts over `clientDataHash` with the key stored for `deviceID`.
    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken
    /// Stores the pending key for `deviceID` once the server has accepted it.
    func adoptPendingKey(_ keyID: String, forDevice deviceID: String)
    func forgetKeys(forDevice deviceID: String)
}

public protocol DuoDeviceCheckProviding: Sendable {
    var isSupported: Bool { get }
    /// A fresh base64 `DCDevice` token, or nil where DeviceCheck is unsupported or fails. It
    /// is per request: the server never stores it, and the phone keeps one only inside the
    /// in-flight record of a request still waiting for its answer, at most 23 hours (§11.2, D62).
    func token() async -> String?
}

/// Where the API client finds this phone's credential. The identity code implements it.
public protocol DuoCredentialProviding: Sendable {
    /// Nil before the first Create, Join or Reconnect tap (§3.1: no request carries
    /// `Authorization` until then).
    var credential: DuoCredential? { get }
}
