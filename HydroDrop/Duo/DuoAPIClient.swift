#if DUO_V2
import CryptoKit
import Foundation

// The one object that talks HTTP to the Duo server (plan P2 stage A; final design §6.0 to §6.7,
// §11.2, D48, D63). It implements `DuoTransport` for the contract's 19 client-called endpoints
// (`contract-v1`'s `openapi.json`; `GET /health` is for monitors and has no method here) and
// nothing else in the app builds a `URLRequest` for Duo.
//
// What it does, and what it leaves to others:
//
// - Every request leaves through the `DuoHTTPSession` it was handed, the attestation challenge
//   and every retry included. In the app that is `DuoComposition`'s `DuoObservedSession` over
//   `URLSessionHTTP`, which notes each response's status and request id in Diagnostics, so a
//   request that went round it would leave a clean run with nothing to quote.
// - Bodies are written by `DuoWireCoding.encode` and nothing else, so the same typed request is
//   always the same bytes: an idempotent replay under the same key has to send exactly what the
//   server hashed the first time (§6.0), and the attestation binds that very hash (§11.2).
// - A bearer route with no credential throws `unauthenticated` with status 0 without sending
//   anything, and without asking for a challenge or touching the attester. That is the consent
//   rule (§3.1): no request carries `Authorization`, and nothing is attested, until the person has
//   tapped Create, Join or Reconnect and the identity code has minted a credential. (The status
//   0 is what lets the retry rule tell it from the server's own 401: nothing was forgotten.)
// - Every non-2xx answer goes to `DuoErrorClassifier`, the one place a status and a body become
//   an error. An answer that came from somewhere the request did not go, and any redirect, is
//   `maintenance`: it is an edge misbehaving, not the server speaking. A 2xx that is not the
//   endpoint's own status, or whose body does not decode, is `unreadable`. A connection that
//   failed or gave no answer is `offline`; a call whose task was cancelled throws
//   `CancellationError`, which is the caller's to ignore, never an error to show.
// - The only retries are attestation's own (§11.2). Every other retry, of a rate limit, a 503, a
//   lost connection, belongs to the sync engine, the op queue and the flows, which all decide
//   through `DuoRetry.verdict`; a second retry loop here would multiply theirs.
// - Attested calls go one at a time, first come first served, from the challenge to the adoption
//   of the key (`DuoAttestationGate`). Two at once (a redeem beside a token's first upload, say)
//   would each make a pending key and the later adoption would overwrite the earlier, and two
//   assertions with one key would race the counter the server keeps for it. One gap is left, and
//   accepted: a call cancelled while App Attest was working leaves the gate at once, but the
//   attester's own work goes on outside it (`untilCancelled` cancels that task and does not wait
//   for it, since a stuck one may never answer). If the next call attests a key meanwhile, the
//   abandoned attestation can land after it and overwrite the one pending key the identity code
//   keeps, so the server accepts the next call's key but the phone never adopts it, and the call
//   after that attests once more. The ids are compared at adoption, so a wrong key is never
//   adopted; the cost is one extra App Attest key.
// - It logs nothing at all. A body can hold a name, an invite code or a DeviceCheck token, and a
//   header the bearer; the session already notes the status and request id, which is all
//   Diagnostics may keep (§10.8, §11.7).
// - It keeps no state about the person: no cache, no Keychain, no defaults, no files. The
//   credential is read from the identity once per call, so the bearer and the device named in
//   the bind stay the same through that call's retries.
//
// What a caller does with each outcome (the contract the op queue, the sync engine and the flows
// are written to). An outcome is known only after a 2xx that was read, or a refusal the server
// judged. After `CancellationError`, `offline`, or `unreadable` at a 2xx status (or at status 0)
// the request may well have landed, so an idempotent (I) caller keeps its in-flight record and
// later replays the same `Idempotency-Key` with the same bytes, which the server answers from its
// record if the first one did land (§6.0). It drops the record only after a 2xx it could read,
// or after a refusal other than a 429 or a 503 (both of which say "not now", not "no"). A write
// that is not (I) is never re-sent blindly after an unknown outcome: `rotate` above all, since
// the server may already have replaced the secret and a second rotate made with the old one
// cannot get the new one back. The few that are sent again are so because their own content
// makes a repeat harmless: a status row (the `ver` CAS answers a repeat as unchanged or a
// conflict, §6.5) and a nudge (its id is its key, §6.6), or because the op queue replays the
// very bytes it recorded (`PATCH /me`).

final class DuoAPIClient: DuoTransport, Sendable {
    private let baseURL: URL
    private let client: DuoClientInfo
    private let credentials: DuoCredentialProviding
    private let attester: DuoAttesting
    private let session: DuoHTTPSession
    private let gate = DuoAttestationGate()

    init(baseURL: URL, client: DuoClientInfo, credentials: DuoCredentialProviding, attester: DuoAttesting,
         session: DuoHTTPSession = URLSessionHTTP()) {
        self.baseURL = baseURL
        self.client = client
        self.credentials = credentials
        self.attester = attester
        self.session = session
    }

    // MARK: - Identity and device

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse {
        let body = try Self.encode(request)
        // The whole method is one attested call: the key attested with the mint belongs to the
        // device the mint just made, which only the answer names, so it is adopted here, still
        // inside the gate (a bearer action's key is adopted in `sendAttested`).
        return try await attestedCall {
            let answer = try await send(Route("POST", "/devices", auth: .anonymous, attest: .deviceCreate, body: body, success: [201]))
            let response: DuoWireCreateDeviceResponse = try Self.decode(answer)
            if let keyID = answer.acceptedNewKeyID { attester.adoptPendingKey(keyID, forDevice: response.deviceId) }
            return response
        }
    }

    func attestChallenge() async throws -> DuoWireAttestChallenge {
        try Self.decode(try await send(Route("POST", "/attest/challenge", auth: .anonymous, success: [201])))
    }

    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse {
        // Authenticated as the credential it is given, never as whatever the identity holds when
        // the request leaves: a Create or Join that stored a new credential in the gap used to
        // have its own secret rotated by a call meant for the restored one, and then held a
        // secret the server had just replaced. One send, never retried here (its answer carries
        // the only copy of the new secret), and not attested, so it never waits at the gate.
        try Self.decode(try await send(Route("POST", "/devices/me/rotate", auth: .given(credential), success: [200])))
    }

    func me() async throws -> DuoWireGetMeResponse {
        try Self.decode(try await send(Route("GET", "/me", auth: .bearer, success: [200])))
    }

    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember {
        try Self.decode(try await send(Route("PATCH", "/me", auth: .bearer, body: try Self.encode(request), success: [200])))
    }

    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws {
        // A body on a DELETE: the contract requires one, `{}` when there is no DeviceCheck token.
        _ = try await send(Route("DELETE", "/me", auth: .bearer, key: key, body: try Self.encode(request), success: [204]))
    }

    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws {
        let route = Route("PUT", "/devices/me/push", auth: .bearer, attest: firstUpload ? .pushRegister : nil,
                          body: try Self.encode(request), success: [204])
        // Attested only on a token's first upload by this device (§6.2); on a re-upload the
        // server reads no header, so none is made, no challenge is spent and the gate is not held.
        if firstUpload {
            _ = try await attestedCall { try await send(route) }
        } else {
            _ = try await send(route)
        }
    }

    func unregisterPush() async throws {
        _ = try await send(Route("DELETE", "/devices/me/push", auth: .bearer, success: [204]))
    }

    // MARK: - Duos and invites

    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse {
        let route = Route("POST", "/duos", auth: .bearer, key: key, attest: .duoCreate, body: try Self.encode(request), success: [201])
        return try Self.decode(try await attestedCall { try await send(route) })
    }

    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite {
        let id = try Self.segment(duoID)
        return try Self.decode(try await send(Route("POST", "/duos/\(id)/invites", auth: .bearer, key: key,
                                                    body: try Self.encode(DuoWireCreateInviteRequest(purpose: purpose)), success: [201])))
    }

    func peekInvite(code: String) async throws -> DuoWirePeekResponse {
        // Anonymous for a phone with no identity, and with its bearer when it has one, so the
        // server applies the pair row and a person someone blocked sees nothing (D34). The
        // code rides in the body, never the path, so no log line anywhere holds it (SEC F3).
        try Self.decode(try await send(Route("POST", "/invites/peek", auth: .bearerIfAny,
                                             body: try Self.encode(DuoWirePeekRequest(code: code)), success: [200])))
    }

    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult {
        let route = Route("POST", "/invites/redeem", auth: .bearer, key: key, attest: .inviteRedeem, body: try Self.encode(request),
                          success: [201])
        return try Self.decode(try await attestedCall { try await send(route) })
    }

    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse {
        // The reconnect has no attestation action of its own: the contract binds it as a redeem.
        let route = Route("POST", "/invites/reconnect", auth: .bearer, key: key, attest: .inviteRedeem, body: try Self.encode(request),
                          success: [200])
        return try Self.decode(try await attestedCall { try await send(route) })
    }

    func fetchDuo(id: String) async throws -> DuoWireHeader {
        // Reserved: no stage calls it in P2, since the change feed's header answers everything
        // the sync engine asks (§6.3 keeps it for a lighter refresh). It is here so the transport
        // matches the contract and the Android port finds nothing missing.
        let segment = try Self.segment(id)
        return try Self.decode(try await send(Route("GET", "/duos/\(segment)", auth: .bearer, success: [200])))
    }

    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges {
        // `since` is always sent, 0 included, so the request says what it means rather than
        // leaning on the server's reading of an absent one. A cursor below 0 cannot come from
        // the server (it is a non-negative int64 there) and would be `400 schema` for ever; it
        // is sent as 0, which asks for everything, the right answer to a cursor that is wrong.
        let id = try Self.segment(duoID)
        return try Self.decode(try await send(Route("GET", "/duos/\(id)/changes", since: max(0, since), auth: .bearer,
                                                    success: [200])))
    }

    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult {
        let id = try Self.segment(duoID)
        return try Self.decode(try await send(Route("PUT", "/duos/\(id)/statuses", auth: .bearer,
                                                    body: try Self.encode(request), success: [200])))
    }

    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult {
        // 201 for a new nudge, 200 with the stored row for an id this device already sent here,
        // which is how a retry after a lost answer learns it landed the first time (§6.6).
        let id = try Self.segment(duoID)
        let answer = try await send(Route("POST", "/duos/\(id)/nudges", auth: .bearer,
                                          body: try Self.encode(request), success: [200, 201]))
        return DuoWireSendNudgeResult(response: try Self.decode(answer), wasAlreadySent: answer.status == 200)
    }

    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse {
        // `{}`: the contract requires the empty object, not an empty body.
        let id = try Self.segment(duoID)
        return try Self.decode(try await send(Route("POST", "/duos/\(id)/leave", auth: .bearer, key: key,
                                                    body: try Self.encode(DuoWireEmptyRequest()), success: [200])))
    }

    func block(duoID: String, key: DuoIdempotencyKey) async throws {
        let id = try Self.segment(duoID)
        _ = try await send(Route("POST", "/duos/\(id)/block", auth: .bearer, key: key,
                                 body: try Self.encode(DuoWireEmptyRequest()), success: [204]))
    }

    // MARK: - Routes

    private enum Auth {
        /// `POST /devices` and `POST /attest/challenge`: never a bearer, even when there is one.
        case anonymous
        /// Every other route: the bearer, or nothing sent at all.
        case bearer
        /// `POST /invites/peek`: the bearer when this phone has one, else anonymous.
        case bearerIfAny
        /// `POST /devices/me/rotate`: the bearer of this credential, whatever the identity holds now.
        case given(DuoCredential)
    }

    private struct Route {
        var method: String
        var path: String
        var since: Int64?
        var auth: Auth
        var key: DuoIdempotencyKey?
        var attest: DuoAttestAction?
        var body: Data?
        var success: Set<Int>

        init(_ method: String, _ path: String, since: Int64? = nil, auth: Auth, key: DuoIdempotencyKey? = nil,
             attest: DuoAttestAction? = nil, body: Data? = nil, success: Set<Int>) {
            self.method = method
            self.path = path
            self.since = since
            self.auth = auth
            self.key = key
            self.attest = attest
            self.body = body
            self.success = success
        }
    }

    /// A response with one of the endpoint's own success statuses.
    private struct Answer {
        var status: Int
        var data: Data
        var requestID: String?
        /// The key a new-key attestation on the accepted attempt came from, when the identity it
        /// belongs to is not known until the answer is read (`POST /devices`).
        var acceptedNewKeyID: String?
    }

    // MARK: - Sending

    /// Runs one attested call while holding the gate, so the next attested call does not ask for
    /// its challenge until this one has adopted its key or failed. A call cancelled while it
    /// waits leaves the queue at once and never holds the gate.
    private func attestedCall<T>(_ work: () async throws -> T) async throws -> T {
        try await gate.enter()
        do {
            let result = try await work()
            await gate.leave()
            return result
        } catch {
            await gate.leave()
            throw error
        }
    }

    private func send(_ route: Route) async throws -> Answer {
        try Task.checkCancellation()
        // One reading of the credential for the whole call: the bearer, the device in the bind
        // and the device a new key is adopted for all come from it, retries included. A rotate
        // brings its own and does not read it.
        let credential: DuoCredential?
        if case .given = route.auth { credential = nil } else { credential = credentials.credential }
        let bearer: DuoCredential?
        switch route.auth {
        case .anonymous:
            bearer = nil
        case .bearer:
            // Nothing is sent, and no challenge asked for, without a credential (§3.1). The
            // status is 0 because no response came back; nothing reached a server.
            guard let credential else { throw DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0)) }
            bearer = credential
        case .bearerIfAny:
            bearer = credential
        case .given(let given):
            bearer = given
        }
        // A bearer the server cannot parse is answered 401 `unauthenticated` before anything is
        // looked up, which the retry rule would read as "this identity is gone" and end every live
        // duo for it. A credential handed over in another spelling (an upper-case
        // `UUID().uuidString` for the device, say) would do exactly that, so it is refused here,
        // with nothing sent, as the status-0 error that forgets nothing.
        if let bearer, !Self.isSendable(bearer) { throw DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0)) }
        let request = try makeRequest(route, bearer: bearer)
        guard let action = route.attest else { return try await perform(request, success: route.success) }
        return try await sendAttested(request, route: route, action: action, deviceID: bearer?.deviceID)
    }

    /// An attested call (§11.2, D48). The server is at `ATTEST_MODE` off for now and reads no
    /// header, and in every mode an attestation is a dimmer, not a door: a phone that cannot
    /// attest, or whose attestation fails, goes on without the header at the low tier. So every
    /// path here ends in the request being sent, and each refusal is answered a bounded number of
    /// times:
    ///
    /// - `attest_required` on an attempt with a header (a challenge that died, or a header the
    ///   server could not verify, which lowers the device): once more with a fresh challenge, and
    ///   if that is refused the same way, once more with no header.
    /// - `attest_required` on an attempt with no header (a device at the attested tier sent none,
    ///   and the refusal has just lowered it): once more with no header, which the lowered device
    ///   is let through with. A phone that cannot attest at all gets only this.
    /// - `attest_invalid` after an assertion (the server has no key for this device, or not this
    ///   one): once more with a new key's attestation and a fresh challenge. After an attestation,
    ///   or a second time, it is final, and the request goes once more with no header, at the low
    ///   tier the refusal has just put the device on (a decision of 2026-10-07: a headerless
    ///   request is open to anyone anyway, and §11.2 keeps failing devices working).
    ///
    /// So a call sends at most three attempts with a header (the first, a fresh challenge's, a new
    /// key's) and two without, five in all, with at most three challenges before them; a phone
    /// that cannot attest sends at most two. A retry keeps the request's `Idempotency-Key` and its
    /// bytes; only `X-HD-Attest` changes. A new key is adopted only after a 2xx that it was sent
    /// with: one made for an attempt the server refused, or that was never accepted, is not kept
    /// here. The server may keep it all the same: its gate stores a verified attestation before
    /// the request's own handler runs, so a 404, 409, 410 or 428 from the handler leaves the
    /// server holding the new key while the phone keeps its old one (or none). That corrects
    /// itself at the next 2xx that carries a new key (an assertion with the old key is refused as
    /// `attest_invalid`, and its one retry brings a new key), and costs one extra challenge and
    /// one extra App Attest key for each such refusal.
    private func sendAttested(_ request: URLRequest, route: Route, action: DuoAttestAction, deviceID: String?) async throws -> Answer {
        let body = route.body ?? Data()
        // The bearer actions bind the device; without one there is nothing to bind to, which a
        // bearer route never reaches (`send` threw first), so it goes without a header.
        var attesting = attester.isSupported && (!action.bindsDevice || deviceID != nil)
        var useNewKey = attesting && (!action.bindsDevice || !attester.hasKey(forDevice: deviceID ?? ""))
        var retriedChallenge = false
        var retriedNewKey = false
        var sentHeaderlessAfterInvalid = false
        var retriedHeaderless = false

        while true {
            try Task.checkCancellation()
            var attempt = request
            var token: DuoAttestationToken?
            if attesting {
                if let made = try await attestation(action: action, body: body, deviceID: deviceID, newKey: useNewKey) {
                    attempt.setValue(made.header, forHTTPHeaderField: "X-HD-Attest")
                    token = made.token
                    // A key is attested once only, so any later attempt brings another.
                    if made.token.kind == .attestation { useNewKey = true }
                } else {
                    // Neither a challenge nor a token could be had: this call goes on without a
                    // header and does not ask the attester again.
                    attesting = false
                }
            }
            do {
                var answer = try await perform(attempt, success: route.success)
                if let token, token.kind == .attestation {
                    if action.bindsDevice, let deviceID {
                        attester.adoptPendingKey(token.keyID, forDevice: deviceID)
                    } else {
                        answer.acceptedNewKeyID = token.keyID
                    }
                }
                return answer
            } catch DuoTransportError.attestRequired(let context) {
                if token != nil {
                    if !retriedChallenge {
                        retriedChallenge = true
                    } else {
                        attesting = false
                    }
                    continue
                }
                if !retriedHeaderless {
                    retriedHeaderless = true
                    continue
                }
                throw DuoTransportError.attestRequired(context)
            } catch DuoTransportError.attestInvalid(let context) {
                if token?.kind == .assertion, !retriedNewKey {
                    retriedNewKey = true
                    useNewKey = true
                    continue
                }
                if token != nil, !sentHeaderlessAfterInvalid {
                    sentHeaderlessAfterInvalid = true
                    attesting = false
                    continue
                }
                throw DuoTransportError.attestInvalid(context)
            }
        }
    }

    private struct Attestation {
        var header: String
        var token: DuoAttestationToken
    }

    /// A fresh challenge and the attester's token over its bind, as `X-HD-Attest`'s value, or
    /// nil when neither an assertion nor an attestation could be had over it: no challenge (the
    /// endpoint is paused by PAUSE_ANON, rate limited or unreachable), or an attester that threw.
    /// The request then goes without a header, as the design wants of a phone that cannot attest.
    /// An assertion that fails is not that: its challenge is still unused, so a new key is
    /// attested over the same bind instead, and the call keeps its header. Cancellation is not a
    /// failure to attest, and is thrown on.
    private func attestation(action: DuoAttestAction, body: Data, deviceID: String?, newKey: Bool) async throws -> Attestation? {
        let challenge: DuoWireAttestChallenge
        do {
            challenge = try await attestChallenge()
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return nil
        }
        let bind = Self.bind(challengeID: challenge.challengeId, action: action, deviceID: deviceID, body: body)
        let attester = self.attester
        if !newKey, action.bindsDevice, let deviceID {
            do {
                let token = try await Self.untilCancelled { try await attester.assert(clientDataHash: bind, deviceID: deviceID) }
                return Attestation(header: "v1.ios.\(challenge.challengeId).\(token.token)", token: token)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                // The stored key could not assert (lost, or refused by the Secure Enclave): a new
                // one is attested below over the same bind, with the same unspent challenge.
            }
        }
        do {
            let token = try await Self.untilCancelled { try await attester.attestNewKey(clientDataHash: bind) }
            return Attestation(header: "v1.ios.\(challenge.challengeId).\(token.token)", token: token)
        } catch {
            if error is CancellationError || Task.isCancelled { throw CancellationError() }
            return nil
        }
    }

    /// Runs one of the attester's calls in a task of its own and returns its answer, or throws
    /// `CancellationError` the moment the calling task is cancelled, whether or not the attester
    /// has answered. App Attest talks to Apple's servers and the Secure Enclave and is not known
    /// to honour cancellation; a call stuck there would otherwise hold the gate, and every
    /// attested call queued behind it, for as long as it stayed stuck.
    private static func untilCancelled<T: Sendable>(_ operation: @escaping @Sendable () async throws -> T) async throws -> T {
        let race = DuoCancellableCall<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                race.start(continuation, operation)
            }
        } onCancel: {
            race.cancel()
        }
    }

    /// The attestation's bind, which App Attest signs as the client data hash (§11.2, D48):
    ///
    ///     SHA-256(UTF-8(challenge_id) ‖ 0x0A ‖ UTF-8(action) ‖ 0x0A ‖ [UTF-8(device_id) ‖ 0x0A ‖] SHA-256(body))
    ///
    /// with the device only on the three actions that ride a bearer, spelled exactly as the
    /// bearer spells it, and the inner hash the 32 raw bytes of the exact body sent. Without the
    /// device, someone intercepting their own phone's traffic could hand one key's attestation
    /// to several scripted identities; `device_create` has no device yet and keeps the form
    /// without it. The server computes the same (`src/attest/header.ts`, `bindHash`).
    static func bind(challengeID: String, action: DuoAttestAction, deviceID: String?, body: Data) -> Data {
        var message = Data(challengeID.utf8)
        message.append(0x0A)
        message.append(contentsOf: action.rawValue.utf8)
        message.append(0x0A)
        if action.bindsDevice, let deviceID {
            message.append(contentsOf: deviceID.utf8)
            message.append(0x0A)
        }
        message.append(contentsOf: SHA256.hash(data: body))
        return Data(SHA256.hash(data: message))
    }

    /// Sends one request through the session and reads its status. Only the endpoint's own
    /// success statuses come back; every other answer is thrown as the error it means.
    private func perform(_ request: URLRequest, success: Set<Int>) async throws -> Answer {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw Self.transportError(for: error)
        }
        guard let http = response as? HTTPURLResponse else { throw DuoTransportError.unreadable(httpStatus: 0, requestID: nil) }
        let status = http.statusCode
        // An answer from somewhere the request did not go (a redirect followed by a session that
        // allowed one, or something in between that rewrote the response) is not the server's,
        // whatever it says: nothing in it is read, and the caller waits and tries again.
        guard Self.isSameEndpoint(http.url, as: request.url) else { throw DuoTransportError.maintenance(DuoErrorContext(httpStatus: status)) }
        let headerID = DuoErrorClassifier.headerRequestID(xRequestID: http.value(forHTTPHeaderField: "X-Request-Id"),
                                                          cfRay: http.value(forHTTPHeaderField: "CF-Ray"))
        // The server never redirects, so a 3xx is an edge set up wrong: the request waits (a
        // queued one is kept, not dropped) until it is put right.
        if (300...399).contains(status) { throw DuoTransportError.maintenance(DuoErrorContext(httpStatus: status, requestID: headerID)) }
        guard (200...299).contains(status) else {
            throw DuoErrorClassifier.classify(status: status, contentType: http.value(forHTTPHeaderField: "Content-Type"),
                                              retryAfter: http.value(forHTTPHeaderField: "Retry-After"), requestID: headerID, body: data)
        }
        // A 2xx that is not this endpoint's (a 200 where the contract says 204, say) is not an
        // answer this build knows how to read, and is not taken as a success either.
        guard success.contains(status) else { throw DuoTransportError.unreadable(httpStatus: status, requestID: headerID) }
        return Answer(status: status, data: data, requestID: headerID)
    }

    /// Whether a response came from where its request went: the same scheme, host, port and path.
    static func isSameEndpoint(_ answered: URL?, as asked: URL?) -> Bool {
        guard let answered, let asked else { return false }
        func parts(_ url: URL) -> (String, String, Int, String) {
            let scheme = url.scheme?.lowercased() ?? ""
            let port = url.port ?? (scheme == "https" ? 443 : scheme == "http" ? 80 : -1)
            return (scheme, url.host()?.lowercased() ?? "", port, url.path(percentEncoded: true))
        }
        return parts(answered) == parts(asked)
    }

    /// What a failure to get any answer means. A call whose task was cancelled throws
    /// `CancellationError`, so no caller ever shows it or counts it as a failure. Every `URLError`
    /// is otherwise `offline`: the ones the design names (no connection, a timeout, a connection
    /// lost, DNS, roaming and data off, a failed TLS handshake), the rest too (a certificate a
    /// hotel's portal substituted, a response cut off half way), and `URLError.cancelled` itself
    /// when this task was not cancelled, since then something other than the caller stopped the
    /// request (the system tearing the session down, say). Each leaves the request perhaps sent
    /// and perhaps not, for the caller to try again later rather than to read as anything the
    /// server said. A redirect is not among them: `URLSessionHTTP` refuses every one, and the
    /// 3xx comes back as an ordinary response, which `perform` reads as `maintenance`.
    static func transportError(for error: Error) -> Error {
        if error is CancellationError || Task.isCancelled { return CancellationError() }
        if error is URLError { return DuoTransportError.offline }
        if let transport = error as? DuoTransportError { return transport }
        return DuoTransportError.offline
    }

    // MARK: - Building

    private func makeRequest(_ route: Route, bearer: DuoCredential?) throws -> URLRequest {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw DuoTransportError.schema(DuoErrorContext(httpStatus: 0))
        }
        var basePath = components.percentEncodedPath
        while basePath.hasSuffix("/") { basePath.removeLast() }
        components.percentEncodedPath = basePath + route.path
        components.queryItems = route.since.map { [URLQueryItem(name: "since", value: String($0))] }
        guard let url = components.url else { throw DuoTransportError.schema(DuoErrorContext(httpStatus: 0)) }

        var request = URLRequest(url: url)
        request.httpMethod = route.method
        // `URLSessionHTTP`'s configuration already says both; a request says them too, so no
        // session it is ever handed can answer from a cache or send a cookie.
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        // CFNetwork would otherwise send the person's whole list of preferred languages, which
        // says something about them and which the server reads no more than it reads this.
        request.setValue("en", forHTTPHeaderField: "Accept-Language")
        request.setValue(client.clientHeader, forHTTPHeaderField: "X-HD-Client")
        if let body = route.body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if let bearer { request.setValue("Bearer \(bearer.bearer)", forHTTPHeaderField: "Authorization") }
        if let key = route.key { request.setValue(key.value, forHTTPHeaderField: "Idempotency-Key") }
        return request
    }

    /// A duo id as one path segment: the lowercase UUID the contract's `{id}` is, and nothing
    /// else. Anything else never leaves the phone and reads as `schema` with no status. Escaping
    /// odd ids was not enough: the server's URL parser decodes `%2E` back into a dot, so the ids
    /// `.` and `..` became dot segments and reached another route. The nil UUID a `link_device`
    /// invite is made with passes.
    private static func segment(_ id: String) throws -> String {
        let isLowercaseUUID = Self.isLowercaseUUID(id)
        guard isLowercaseUUID else { throw DuoTransportError.schema(DuoErrorContext(httpStatus: 0)) }
        return id
    }

    /// `^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$`, byte for byte: the
    /// contract's `{id}` and the device id the server's bearer parser accepts.
    static func isLowercaseUUID(_ text: String) -> Bool {
        let bytes = Array(text.utf8)
        return bytes.count == 36 && bytes.indices.allSatisfy { index in
            let byte = bytes[index]
            if [8, 13, 18, 23].contains(index) { return byte == UInt8(ascii: "-") }
            return (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
        }
    }

    /// Whether the server's bearer parser (`src/auth/bearer.ts`, split at the first `.`) could
    /// read this credential: a lowercase UUID for the device, and a secret that is not empty and
    /// holds no space, tab, line break or other control character.
    static func isSendable(_ credential: DuoCredential) -> Bool {
        guard isLowercaseUUID(credential.deviceID), !credential.deviceSecret.isEmpty else { return false }
        return credential.deviceSecret.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) && !CharacterSet.controlCharacters.contains(scalar)
        }
    }

    /// The one encoder. A body that cannot be encoded never leaves the phone; it reads as
    /// `schema`, which is what the server would have said of it, with no status since nothing
    /// was sent.
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        do { return try DuoWireCoding.encode(value) } catch { throw DuoTransportError.schema(DuoErrorContext(httpStatus: 0)) }
    }

    private static func decode<T: Decodable>(_ answer: Answer) throws -> T {
        do {
            return try DuoWireCoding.decode(T.self, from: answer.data)
        } catch {
            throw DuoTransportError.unreadable(httpStatus: answer.status, requestID: answer.requestID)
        }
    }
}

/// A first-in, first-out lock for attested calls. An actor method alone would not do: an actor
/// is re-entrant across `await`, so a second call would run its challenge while the first waited
/// on the network. A call that finds the gate taken waits in line; `leave()` hands the gate to the
/// first in line, or opens it. A call cancelled while it waits is taken out of the line and
/// thrown `CancellationError`, and never holds the gate.
private actor DuoAttestationGate {
    private var busy = false
    private var waiters: [(id: Int, continuation: CheckedContinuation<Void, Error>)] = []
    private var lastID = 0

    func enter() async throws {
        guard busy else {
            busy = true
            return
        }
        lastID += 1
        let id = lastID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else {
                    waiters.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
    }

    func leave() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().continuation.resume()
        }
    }

    /// Takes a cancelled call out of the line. One already handed the gate is not in the line any
    /// more and holds it like any other; it leaves through `leave()` when its cancelled work throws.
    private func withdraw(_ id: Int) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }
}

/// One call raced against its caller's cancellation: whichever comes first resumes the caller,
/// once, and the other is ignored. The call itself is cancelled too, in case it does listen.
private final class DuoCancellableCall<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var cancelled = false
    private var task: Task<Void, Never>?

    func start(_ continuation: CheckedContinuation<T, Error>, _ operation: @escaping @Sendable () async throws -> T) {
        lock.lock()
        if cancelled {
            lock.unlock()
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        task = Task { [self] in
            do { finish(.success(try await operation())) } catch { finish(.failure(error)) }
        }
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let waiting = continuation
        continuation = nil
        let running = task
        lock.unlock()
        running?.cancel()
        waiting?.resume(throwing: CancellationError())
    }

    private func finish(_ result: Result<T, Error>) {
        lock.lock()
        let waiting = continuation
        continuation = nil
        lock.unlock()
        waiting?.resume(with: result)
    }
}
#endif
