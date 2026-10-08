#if DUO_V2
import CryptoKit
import XCTest
@testable import HydroDrop

// MARK: - The file's own doubles

/// A `DuoHTTPSession` that records every request it is given and answers as the test says: by
/// `answer` when set, else a fresh attestation challenge for `POST /attest/challenge` and the
/// next of `replies` for anything else (a lost connection once they run out). Every request the
/// client makes, the challenge and each retry included, has to come through here, so a request
/// that went round the session the client was handed would show up as one missing.
private final class ScriptedSession: DuoHTTPSession, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = ["Content-Type": "application/json", "X-Request-Id": "9b1c2d3e4f5a6b7c-LHR"]
        var body = Data()
        /// The URL the response says it came from, when it is not the request's (a redirect).
        var url: URL?
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private var challengesIssued = 0
    var answer: ((URLRequest) throws -> Reply)?
    var replies: [Reply] = []
    var challengeReply: Reply?

    var requests: [URLRequest] { lock.withLock { recorded } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let reply: Reply = try lock.withLock {
            recorded.append(request)
            if let answer { return try answer(request) }
            if request.url?.path.hasSuffix("/attest/challenge") == true {
                if let challengeReply { return challengeReply }
                challengesIssued += 1
                return Reply(status: 201, body: Wire.json(Wire.challenge(challengesIssued)))
            }
            guard !replies.isEmpty else { throw URLError(.notConnectedToInternet) }
            return replies.removeFirst()
        }
        let response = HTTPURLResponse(url: reply.url ?? request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1",
                                       headerFields: reply.headers)!
        return (reply.body, response)
    }
}

/// A session in front of a `ScriptedSession` that holds the first request to one path until the
/// test lets it go, and records the order in which requests start (before any is held), so a
/// test can show what a second call did, or did not do, while the first was out.
private final class HeldSession: DuoHTTPSession, @unchecked Sendable {
    private let inner: ScriptedSession
    private let holdPath: String
    private let lock = NSLock()
    private var startedPaths: [String] = []
    private var held = false
    private var released = false
    private var holding: CheckedContinuation<Void, Never>?
    private var watching: CheckedContinuation<Void, Never>?

    init(_ inner: ScriptedSession, holding path: String) {
        self.inner = inner
        self.holdPath = path
    }

    var started: [String] { lock.withLock { startedPaths } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        let shouldHold: Bool = lock.withLock {
            startedPaths.append(path)
            guard path == holdPath, !held else { return false }
            held = true
            return true
        }
        if shouldHold {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let (resumeNow, watcher): (Bool, CheckedContinuation<Void, Never>?) = lock.withLock {
                    let watcher = watching
                    watching = nil
                    if released { return (true, watcher) }
                    holding = continuation
                    return (false, watcher)
                }
                watcher?.resume()
                if resumeNow { continuation.resume() }
            }
        }
        return try await inner.data(for: request)
    }

    /// Returns once the held request has arrived.
    func waitUntilHeld() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let arrived: Bool = lock.withLock {
                if holding != nil || released { return true }
                watching = continuation
                return false
            }
            if arrived { continuation.resume() }
        }
    }

    func release() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock {
            released = true
            let waiting = holding
            holding = nil
            return waiting
        }
        waiting?.resume()
    }
}

/// An attester whose first `attestNewKey` never answers until the test unsticks it, and which
/// ignores cancellation the way App Attest is not known to honour it. Every later call answers
/// at once.
private final class HangingAttester: DuoAttesting, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var stuck: CheckedContinuation<Void, Never>?
    private var watching: CheckedContinuation<Void, Never>?
    private var isStuck = false

    var isSupported: Bool { true }
    func hasKey(forDevice deviceID: String) -> Bool { false }

    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken {
        let call: Int = lock.withLock { calls += 1; return calls }
        if call == 1 {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                let watcher: CheckedContinuation<Void, Never>? = lock.withLock {
                    stuck = continuation
                    isStuck = true
                    let watcher = watching
                    watching = nil
                    return watcher
                }
                watcher?.resume()
            }
        }
        return DuoAttestationToken(token: "QVRURVNU-\(call)", keyID: "key-\(call)", kind: .attestation)
    }

    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken {
        DuoAttestationToken(token: "QVNTRVJU", keyID: "key-of-\(deviceID)", kind: .assertion)
    }

    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) {}
    func forgetKeys(forDevice deviceID: String) {}

    func waitUntilStuck() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let already: Bool = lock.withLock {
                if isStuck { return true }
                watching = continuation
                return false
            }
            if already { continuation.resume() }
        }
    }

    func unstick() {
        let waiting: CheckedContinuation<Void, Never>? = lock.withLock { let waiting = stuck; stuck = nil; return waiting }
        waiting?.resume()
    }
}

/// An attester that records what it is asked, with the client data hash each time, and can be
/// told to fail. `FakeDuoAttester` keeps neither the hashes (the bind is compared byte for byte
/// here) nor a way to throw; a reading of `isSupported` is recorded too, so a test can show the
/// attester was not so much as looked at.
private final class ScriptedAttester: DuoAttesting, @unchecked Sendable {
    private let lock = NSLock()
    private var supported: Bool
    private var keys: Set<String>
    private var failure: Error?
    private var assertFailure: Error?
    private var made = 0
    private var asserted = 0
    private var entries: [String] = []
    private var clientDataHashes: [Data] = []

    /// `failure` is thrown by both calls; `assertFailure` by `assert` alone.
    init(supported: Bool = true, keys: Set<String> = [], failure: Error? = nil, assertFailure: Error? = nil) {
        self.supported = supported
        self.keys = keys
        self.failure = failure
        self.assertFailure = assertFailure
    }

    var log: [String] { lock.withLock { entries } }
    var hashes: [Data] { lock.withLock { clientDataHashes } }

    var isSupported: Bool { lock.withLock { entries.append("isSupported"); return supported } }

    func hasKey(forDevice deviceID: String) -> Bool { lock.withLock { entries.append("hasKey:\(deviceID)"); return keys.contains(deviceID) } }

    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken {
        try lock.withLock {
            entries.append("attestNewKey")
            clientDataHashes.append(clientDataHash)
            if let failure { throw failure }
            made += 1
            return DuoAttestationToken(token: "QVRURVNU-\(made)", keyID: "key-\(made)", kind: .attestation)
        }
    }

    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken {
        try lock.withLock {
            entries.append("assert:\(deviceID)")
            clientDataHashes.append(clientDataHash)
            if let failure = failure ?? assertFailure { throw failure }
            asserted += 1
            return DuoAttestationToken(token: "QVNTRVJU-\(asserted)", keyID: "key-of-\(deviceID)", kind: .assertion)
        }
    }

    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) {
        lock.withLock { entries.append("adopt:\(keyID):\(deviceID)"); keys.insert(deviceID) }
    }

    func forgetKeys(forDevice deviceID: String) { lock.withLock { entries.append("forget:\(deviceID)"); keys.remove(deviceID) } }
}

/// The wire's fixtures: what a request sends and what the server answers, as typed values and
/// as the server's bytes.
private enum Wire {
    static let base = URL(string: "https://api-staging.hydrodrop.us/v1")!
    static let client = DuoClientInfo(marketingVersion: "2.0", build: "57")
    static let credential = DuoFixtures.credential()
    static let duo = "6d2a0000-0000-4000-8000-000000000001"
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    static func key(_ n: Int) -> DuoIdempotencyKey { DuoIdempotencyKey(String(format: "2b1c0000-0000-4000-8000-%012d", n)) }

    /// The n-th challenge a session hands out: `...0b0010`, `...0b0020`, and so on.
    static func challengeID(_ n: Int) -> String { String(format: "6d2a0000-0000-4000-8000-0000000b%04d", n * 10) }
    static func challenge(_ n: Int) -> DuoWireAttestChallenge {
        DuoWireAttestChallenge(challengeId: challengeID(n), challenge: "q83vEjRWeJBzh-nHvNkFFSIsr3Kdo6pZuL1lDGmzRpI", expiresAt: at.addingTimeInterval(300))
    }

    /// What the server writes: snake_case keys and `YYYY-MM-DDTHH:MM:SSZ` times.
    static func json<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(DuoWireTime.format(date))
        }
        return try! encoder.encode(value)
    }

    static func error(_ code: String, status: Int, details: String? = nil, retryAfter: String? = nil) -> ScriptedSession.Reply {
        let detailsField = details.map { #","details":\#($0)"# } ?? ""
        var reply = ScriptedSession.Reply(status: status, body: Data(#"{"error":{"code":"\#(code)","message":"m"\#(detailsField),"request_id":"body-id"}}"#.utf8))
        if let retryAfter { reply.headers["Retry-After"] = retryAfter }
        return reply
    }

    static func html(_ status: Int, retryAfter: String? = nil) -> ScriptedSession.Reply {
        var reply = ScriptedSession.Reply(status: status, headers: ["Content-Type": "text/html; charset=UTF-8", "X-Request-Id": "9b1c-WAF"],
                                          body: Data("<!DOCTYPE html><html><body>Sorry, you have been blocked</body></html>".utf8))
        if let retryAfter { reply.headers["Retry-After"] = retryAfter }
        return reply
    }

    // Requests
    static let createDevice = DuoWireCreateDeviceRequest(appVersion: "2.0 (57)", termsVersion: 1, deviceCheckToken: "RGV2aWNlQ2hlY2s=")
    static let updateMe = DuoWireUpdateMeRequest(displayName: .value("Sam"), skin: .value("forest"))
    static let deleteMe = DuoWireDeleteMeRequest(deviceCheckToken: nil)
    static let registerPush = DuoWireRegisterPushRequest(token: "7c3d", apnsEnv: "sandbox", tz: "America/Toronto", wakeStartMin: 480,
                                                         wakeEndMin: 1320, notificationsEnabled: true)
    static let rowIn = DuoWireStatusIn(day: "2026-09-24", goalMet: false, progressBucket: 25, baseVer: 0)
    static let createDuo = DuoWireCreateDuoRequest(displayName: nil, skin: "classic", myToday: "2026-09-24", e2eeCapable: true, statuses: [rowIn])
    static let redeem = DuoWireRedeemRequest(code: "H7K39QWX", displayName: "Sam", skin: "forest", myToday: "2026-09-24", e2eeCapable: true,
                                             statuses: [rowIn], deviceCheckToken: "RGV2aWNlQ2hlY2s=")
    static let reconnect = DuoWireReconnectRequest(code: "H7K3-9QWX")
    static let putStatuses = DuoWirePutStatusesRequest(myToday: "2026-09-24", since: 410,
                                                       statuses: [DuoWireStatusIn(day: "2026-09-24", goalMet: false, progressBucket: 50, baseVer: 3)])
    static let nudge = DuoWireSendNudgeRequest(id: "nudge-3B9E1C2A-0000-4000-8000-000000000001", presetId: "waterBreak", senderDay: "2026-09-24")

    // Answers
    static let device = DuoWireCreateDeviceResponse(memberId: credential.memberID, deviceId: "6d2a0000-0000-4000-8000-0000000000cc",
                                                    deviceSecret: String(repeating: "t", count: 43), tier: .attested, supportId: "HD-7K3Q-9WXA")
    static let rotated = DuoWireRotateResponse(deviceSecret: String(repeating: "u", count: 43), secretVersion: 2)
    static let member = DuoWireMember(id: credential.memberID, displayName: "Jo", skin: "classic", supportId: "HD-7K3Q-9WXA", tier: .attested, termsVersion: 1)
    static let me = DuoWireGetMeResponse(member: member, limits: DuoWireLimits(nudgesPerDay: 3, maxActiveDuos: 5),
                                         devices: [DuoWireDevice(id: credential.deviceID, platform: "ios", createdAt: at, thisDevice: true, superseded: false)],
                                         duos: [DuoFixtures.wireHeader()], minClient: DuoWireMinClient(ios: "2.0", android: "1.1"))
    static let invite = DuoWireInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: at.addingTimeInterval(172_800))
    static let created = DuoWireCreateDuoResponse(duo: DuoFixtures.wireHeader(state: .pending, seq: 1), invite: invite, accepted: ["2026-09-24"],
                                                  unchanged: [], rejected: [])
    static let peek = DuoWirePeekResponse(purpose: "invite", state: "open", expiresAt: at.addingTimeInterval(172_800), inviterDisplayName: "Jo",
                                          inviterSkin: "classic")
    static let changes = DuoFixtures.wireChanges(cursor: 418, statuses: [DuoFixtures.wireRow(.owner, "2026-09-24", bucket: 100, ver: 4)],
                                                 nudges: [DuoWireNudge(id: "nudge-8F2A0000-0000-4000-8000-000000000001", fromRole: .owner,
                                                                       presetId: "sipWithMe", createdAt: at)],
                                                 handled: [DuoWireHandled(kind: "goal_met", day: "2026-09-24")])
    static let withResult = DuoWireChangesWithResult(changes: changes, accepted: ["2026-09-24"], unchanged: [],
                                                     rejected: [DuoWireRejected(day: "2026-09-23", reason: .verConflict,
                                                                                current: DuoFixtures.wireRow(.owner, "2026-09-23", bucket: 50, ver: 3))])
    static let reconnected = DuoWireReconnectResponse(memberId: credential.memberID, supportId: "HD-7K3Q-9WXA", duos: [DuoFixtures.wireHeader()],
                                                      supersededDevices: 1)
    static let left = DuoWireLeaveResponse(state: "ended", endedBy: .partner, endedAt: at)
    static let nudged = DuoWireSendNudgeResponse(nudge: DuoWireNudge(id: nudge.id, fromRole: .owner, presetId: "waterBreak", createdAt: at),
                                                 remainingToday: 2)
}

/// One row of the endpoint table: what the client must send for one call, and what it must
/// make of the answer.
private struct Endpoint {
    enum Auth { case anonymous, bearer, bearerIfAny }

    var name: String
    var method: String
    var path: String
    var query: String?
    var auth: Auth
    var key: DuoIdempotencyKey?
    var body: Data?
    var status: Int
    var reply: Data
    var call: (DuoAPIClient) async throws -> Void

    init(_ name: String, _ method: String, _ path: String, query: String? = nil, auth: Auth, key: DuoIdempotencyKey? = nil, body: Data? = nil,
         status: Int, reply: Data = Data(), call: @escaping (DuoAPIClient) async throws -> Void) {
        self.name = name
        self.method = method
        self.path = path
        self.query = query
        self.auth = auth
        self.key = key
        self.body = body
        self.status = status
        self.reply = reply
        self.call = call
    }
}

// MARK: - The tests

/// `DuoAPIClient`, stage A of plan P2: the 19 endpoints of contract-v1 as the server expects
/// them, the consent rule, the error mapping through the whole client, and attestation with
/// D48's bind and its two retries (final design §6.0 to §6.7, §11.2).
final class DuoAPIClientTests: XCTestCase {
    private func makeClient(_ session: DuoHTTPSession, credential: DuoCredential? = Wire.credential, attester: DuoAttesting? = nil,
                            base: URL = Wire.base) -> DuoAPIClient {
        DuoAPIClient(baseURL: base, client: Wire.client, credentials: FakeDuoIdentity(credential: credential),
                     attester: attester ?? ScriptedAttester(supported: false), session: session)
    }

    private func failure(_ body: () async throws -> Void) async -> Error? {
        do { try await body(); return nil } catch { return error }
    }

    private static func encoded<T: Encodable>(_ value: T) -> Data { try! DuoWireCoding.encode(value) }

    private static func hex(_ data: Data) -> String { data.map { String(format: "%02x", $0) }.joined() }

    /// The bind as the design writes it, built here by hand: SHA-256 of the challenge id, the
    /// action, the device on a bearer action, and the raw SHA-256 of the body, each part after
    /// the first following a line feed.
    private static func handBuiltBind(_ challengeID: String, _ action: String, device: String?, body: Data) -> Data {
        var parts = [Data(challengeID.utf8), Data(action.utf8)]
        if let device { parts.append(Data(device.utf8)) }
        parts.append(Data(SHA256.hash(data: body)))
        return Data(SHA256.hash(data: Data(parts.joined(separator: [0x0A]))))
    }

    /// The table. Every endpoint of `DuoTransport`, in contract-v1's order, with the method and
    /// path the contract gives it, whether it carries the bearer and an `Idempotency-Key`, the
    /// exact body, and the success status the contract declares.
    private static func endpoints() -> [Endpoint] {
        let duo = Wire.duo
        return [
            Endpoint("createDevice", "POST", "/devices", auth: .anonymous, body: encoded(Wire.createDevice), status: 201, reply: Wire.json(Wire.device)) {
                let answer = try await $0.createDevice(Wire.createDevice); XCTAssertEqual(answer, Wire.device)
            },
            Endpoint("attestChallenge", "POST", "/attest/challenge", auth: .anonymous, status: 201, reply: Wire.json(Wire.challenge(1))) {
                let answer = try await $0.attestChallenge(); XCTAssertEqual(answer, Wire.challenge(1))
            },
            Endpoint("rotate", "POST", "/devices/me/rotate", auth: .bearer, status: 200, reply: Wire.json(Wire.rotated)) {
                let answer = try await $0.rotate(as: Wire.credential); XCTAssertEqual(answer, Wire.rotated)
            },
            Endpoint("me", "GET", "/me", auth: .bearer, status: 200, reply: Wire.json(Wire.me)) {
                let answer = try await $0.me(); XCTAssertEqual(answer, Wire.me)
            },
            Endpoint("updateMe", "PATCH", "/me", auth: .bearer, body: encoded(Wire.updateMe), status: 200, reply: Wire.json(Wire.member)) {
                let answer = try await $0.updateMe(Wire.updateMe); XCTAssertEqual(answer, Wire.member)
            },
            Endpoint("deleteMe", "DELETE", "/me", auth: .bearer, key: Wire.key(6), body: Data("{}".utf8), status: 204) {
                try await $0.deleteMe(Wire.deleteMe, key: Wire.key(6))
            },
            Endpoint("registerPush", "PUT", "/devices/me/push", auth: .bearer, body: encoded(Wire.registerPush), status: 204) {
                try await $0.registerPush(Wire.registerPush, firstUpload: true)
            },
            Endpoint("unregisterPush", "DELETE", "/devices/me/push", auth: .bearer, status: 204) {
                try await $0.unregisterPush()
            },
            Endpoint("createDuo", "POST", "/duos", auth: .bearer, key: Wire.key(9), body: encoded(Wire.createDuo), status: 201, reply: Wire.json(Wire.created)) {
                let answer = try await $0.createDuo(Wire.createDuo, key: Wire.key(9)); XCTAssertEqual(answer, Wire.created)
            },
            Endpoint("createInvite", "POST", "/duos/\(duo)/invites", auth: .bearer, key: Wire.key(10), body: Data(#"{"purpose":"reconnect"}"#.utf8),
                     status: 201, reply: Wire.json(Wire.invite)) {
                let answer = try await $0.createInvite(duoID: duo, purpose: .reconnect, key: Wire.key(10)); XCTAssertEqual(answer, Wire.invite)
            },
            Endpoint("peekInvite", "POST", "/invites/peek", auth: .bearerIfAny, body: Data(#"{"code":"H7K3-9QWX"}"#.utf8), status: 200, reply: Wire.json(Wire.peek)) {
                let answer = try await $0.peekInvite(code: "H7K3-9QWX"); XCTAssertEqual(answer, Wire.peek)
            },
            Endpoint("redeemInvite", "POST", "/invites/redeem", auth: .bearer, key: Wire.key(12), body: encoded(Wire.redeem), status: 201, reply: Wire.json(Wire.withResult)) {
                let answer = try await $0.redeemInvite(Wire.redeem, key: Wire.key(12)); XCTAssertEqual(answer, Wire.withResult)
            },
            Endpoint("reconnect", "POST", "/invites/reconnect", auth: .bearer, key: Wire.key(13), body: Data(#"{"code":"H7K3-9QWX"}"#.utf8), status: 200,
                     reply: Wire.json(Wire.reconnected)) {
                let answer = try await $0.reconnect(Wire.reconnect, key: Wire.key(13)); XCTAssertEqual(answer, Wire.reconnected)
            },
            Endpoint("fetchDuo", "GET", "/duos/\(duo)", auth: .bearer, status: 200, reply: Wire.json(DuoFixtures.wireHeader())) {
                let answer = try await $0.fetchDuo(id: duo); XCTAssertEqual(answer, DuoFixtures.wireHeader())
            },
            Endpoint("fetchChanges", "GET", "/duos/\(duo)/changes", query: "since=418", auth: .bearer, status: 200, reply: Wire.json(Wire.changes)) {
                let answer = try await $0.fetchChanges(duoID: duo, since: 418); XCTAssertEqual(answer, Wire.changes)
            },
            Endpoint("pushDayStatuses", "PUT", "/duos/\(duo)/statuses", auth: .bearer, body: encoded(Wire.putStatuses), status: 200, reply: Wire.json(Wire.withResult)) {
                let answer = try await $0.pushDayStatuses(duoID: duo, Wire.putStatuses); XCTAssertEqual(answer, Wire.withResult)
            },
            Endpoint("sendNudge", "POST", "/duos/\(duo)/nudges", auth: .bearer, body: encoded(Wire.nudge), status: 201, reply: Wire.json(Wire.nudged)) {
                let answer = try await $0.sendNudge(duoID: duo, Wire.nudge)
                XCTAssertEqual(answer, DuoWireSendNudgeResult(response: Wire.nudged, wasAlreadySent: false))
            },
            Endpoint("leave", "POST", "/duos/\(duo)/leave", auth: .bearer, key: Wire.key(18), body: Data("{}".utf8), status: 200, reply: Wire.json(Wire.left)) {
                let answer = try await $0.leave(duoID: duo, key: Wire.key(18)); XCTAssertEqual(answer, Wire.left)
            },
            Endpoint("block", "POST", "/duos/\(duo)/block", auth: .bearer, key: Wire.key(19), body: Data("{}".utf8), status: 204) {
                try await $0.block(duoID: duo, key: Wire.key(19))
            },
        ]
    }

    /// Checks one request against its row: method, the whole URL, every header and the body.
    private func assertShape(_ request: URLRequest, _ endpoint: Endpoint, bearer: DuoCredential? = Wire.credential,
                             file: StaticString = #filePath, line: UInt = #line) {
        let name = endpoint.name
        XCTAssertEqual(request.httpMethod, endpoint.method, name, file: file, line: line)
        let query = endpoint.query.map { "?\($0)" } ?? ""
        XCTAssertEqual(request.url?.absoluteString, "https://api-staging.hydrodrop.us/v1\(endpoint.path)\(query)", name, file: file, line: line)
        XCTAssertEqual(request.httpBody, endpoint.body, "\(name): the body is exactly the encoder's bytes", file: file, line: line)
        let headers = request.allHTTPHeaderFields ?? [:]
        XCTAssertEqual(headers["Accept"], "application/json", name, file: file, line: line)
        XCTAssertEqual(headers["Accept-Language"], "en", "\(name): never the person's own language list", file: file, line: line)
        XCTAssertEqual(headers["X-HD-Client"], "ios/2.0 (57)", name, file: file, line: line)
        XCTAssertEqual(headers["Content-Type"], endpoint.body == nil ? nil : "application/json", "\(name): Content-Type only with a body",
                       file: file, line: line)
        let carriesBearer = endpoint.auth == .bearer || (endpoint.auth == .bearerIfAny && bearer != nil)
        XCTAssertEqual(headers["Authorization"], carriesBearer ? "Bearer \(bearer?.bearer ?? "")" : nil, "\(name): Authorization", file: file, line: line)
        XCTAssertEqual(headers["Idempotency-Key"], endpoint.key?.value, "\(name): Idempotency-Key", file: file, line: line)
        XCTAssertNil(headers["X-HD-Attest"], "\(name): no attestation from an attester that is not supported", file: file, line: line)
        var expected: Set<String> = ["Accept", "Accept-Language", "X-HD-Client"]
        if endpoint.body != nil { expected.insert("Content-Type") }
        if carriesBearer { expected.insert("Authorization") }
        if endpoint.key != nil { expected.insert("Idempotency-Key") }
        XCTAssertEqual(Set(headers.keys), expected, "\(name): no other header", file: file, line: line)
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData, name, file: file, line: line)
        XCTAssertFalse(request.httpShouldHandleCookies, name, file: file, line: line)
    }

    // MARK: Requests

    func testEveryEndpointSendsTheContractsRequestAndReadsItsAnswer() async throws {
        let endpoints = Self.endpoints()
        XCTAssertEqual(endpoints.count, 19, "every client-called endpoint of contract-v1, and no /health")
        XCTAssertEqual(Set(endpoints.map(\.name)).count, 19)
        XCTAssertEqual(Set(endpoints.filter { $0.key != nil }.map(\.name)),
                       ["deleteMe", "createDuo", "createInvite", "redeemInvite", "reconnect", "leave", "block"],
                       "Idempotency-Key on exactly the seven (I) calls")
        XCTAssertEqual(Set(endpoints.filter { $0.auth == .anonymous }.map(\.name)), ["createDevice", "attestChallenge"])
        for endpoint in endpoints {
            let session = ScriptedSession()
            session.replies = [ScriptedSession.Reply(status: endpoint.status, body: endpoint.reply)]
            let attester = ScriptedAttester(supported: false)
            try await endpoint.call(makeClient(session, attester: attester))
            XCTAssertEqual(session.requests.count, 1, "\(endpoint.name): one request, through the session it was given")
            guard let request = session.requests.first else { continue }
            assertShape(request, endpoint)
            XCTAssertFalse(attester.log.contains { $0.hasPrefix("attestNewKey") || $0.hasPrefix("assert") || $0.hasPrefix("hasKey") },
                           "\(endpoint.name): an attester that cannot attest is asked nothing more")
        }
    }

    func testTheBodiesAreTheEncodersBytesAndSayWhatTheContractNeeds() throws {
        XCTAssertEqual(String(decoding: Self.encoded(Wire.deleteMe), as: UTF8.self), "{}", "DELETE /me with no token is the empty object")
        XCTAssertEqual(String(decoding: Self.encoded(DuoWireDeleteMeRequest(deviceCheckToken: "RGV2")), as: UTF8.self),
                       #"{"device_check_token":"RGV2"}"#)
        XCTAssertEqual(String(decoding: Self.encoded(DuoWireEmptyRequest()), as: UTF8.self), "{}", "leave and block send the empty object")
        XCTAssertEqual(String(decoding: Self.encoded(Wire.createDuo), as: UTF8.self),
                       #"{"display_name":null,"e2ee_capable":true,"my_today":"2026-09-24","skin":"classic","statuses":[{"base_ver":0,"day":"2026-09-24","goal_met":false,"progress_bucket":25}]}"#)
    }

    func testABearerRouteWithNoCredentialSendsNothingAndAsksTheAttesterNothing() async {
        let duo = Wire.duo
        let calls: [(String, (DuoAPIClient) async throws -> Void)] = [
            ("me", { _ = try await $0.me() }),
            ("updateMe", { _ = try await $0.updateMe(Wire.updateMe) }),
            ("deleteMe", { try await $0.deleteMe(Wire.deleteMe, key: Wire.key(1)) }),
            ("registerPush first", { try await $0.registerPush(Wire.registerPush, firstUpload: true) }),
            ("registerPush", { try await $0.registerPush(Wire.registerPush, firstUpload: false) }),
            ("unregisterPush", { try await $0.unregisterPush() }),
            ("createDuo", { _ = try await $0.createDuo(Wire.createDuo, key: Wire.key(1)) }),
            ("createInvite", { _ = try await $0.createInvite(duoID: duo, purpose: .invite, key: Wire.key(1)) }),
            ("redeemInvite", { _ = try await $0.redeemInvite(Wire.redeem, key: Wire.key(1)) }),
            ("reconnect", { _ = try await $0.reconnect(Wire.reconnect, key: Wire.key(1)) }),
            ("fetchDuo", { _ = try await $0.fetchDuo(id: duo) }),
            ("fetchChanges", { _ = try await $0.fetchChanges(duoID: duo, since: 0) }),
            ("pushDayStatuses", { _ = try await $0.pushDayStatuses(duoID: duo, Wire.putStatuses) }),
            ("sendNudge", { _ = try await $0.sendNudge(duoID: duo, Wire.nudge) }),
            ("leave", { _ = try await $0.leave(duoID: duo, key: Wire.key(1)) }),
            ("block", { try await $0.block(duoID: duo, key: Wire.key(1)) }),
        ]
        for (name, call) in calls {
            let session = ScriptedSession()
            session.answer = { _ in XCTFail("\(name) sent a request with no credential"); return ScriptedSession.Reply(status: 500) }
            let attester = ScriptedAttester(supported: true)
            let error = await failure { try await call(self.makeClient(session, credential: nil, attester: attester)) }
            XCTAssertEqual(error as? DuoTransportError, .unauthenticated(DuoErrorContext(httpStatus: 0)), name)
            XCTAssertTrue(session.requests.isEmpty, "\(name): nothing leaves the phone before a tap (§3.1)")
            XCTAssertEqual(attester.log, [], "\(name): no challenge, no attestation, no key looked up")
        }
    }

    func testACredentialTheServerCouldNotParseIsNeverSentAndForgetsNothing() async {
        // The server's bearer parser answers 401 `unauthenticated` to any of these before it looks
        // anything up, and that 401 would end every live duo; so none of them leaves the phone.
        let good = Wire.credential
        let malformed = [
            DuoCredential(memberID: good.memberID, deviceID: good.deviceID.uppercased(), deviceSecret: good.deviceSecret),
            DuoCredential(memberID: good.memberID, deviceID: UUID().uuidString, deviceSecret: good.deviceSecret),
            DuoCredential(memberID: good.memberID, deviceID: "{\(good.deviceID)}", deviceSecret: good.deviceSecret),
            DuoCredential(memberID: good.memberID, deviceID: good.deviceID + " ", deviceSecret: good.deviceSecret),
            DuoCredential(memberID: good.memberID, deviceID: "", deviceSecret: good.deviceSecret),
            DuoCredential(memberID: good.memberID, deviceID: good.deviceID, deviceSecret: ""),
            DuoCredential(memberID: good.memberID, deviceID: good.deviceID, deviceSecret: "two words"),
            DuoCredential(memberID: good.memberID, deviceID: good.deviceID, deviceSecret: good.deviceSecret + "\n"),
            DuoCredential(memberID: good.memberID, deviceID: good.deviceID, deviceSecret: "tab\there"),
            DuoCredential(memberID: good.memberID, deviceID: good.deviceID, deviceSecret: "nul\u{0}byte"),
            DuoCredential(memberID: good.memberID, deviceID: good.deviceID, deviceSecret: "no\u{00A0}break"),
        ]
        let calls: [(String, (DuoAPIClient, DuoCredential) async throws -> Void)] = [
            ("me", { client, _ in _ = try await client.me() }),
            ("peek", { client, _ in _ = try await client.peekInvite(code: "H7K3-9QWX") }),
            ("rotate", { client, credential in _ = try await client.rotate(as: credential) }),
            ("redeem", { client, _ in _ = try await client.redeemInvite(Wire.redeem, key: Wire.key(1)) }),
            ("push", { client, _ in try await client.registerPush(Wire.registerPush, firstUpload: true) }),
        ]
        for credential in malformed {
            for (name, call) in calls {
                let session = ScriptedSession()
                let attester = ScriptedAttester()
                let error = await failure { try await call(self.makeClient(session, credential: credential, attester: attester), credential) }
                let label = "\(name) device \(credential.deviceID.debugDescription) secret \(credential.deviceSecret.count) chars"
                XCTAssertEqual(error as? DuoTransportError, .unauthenticated(DuoErrorContext(httpStatus: 0)), label)
                XCTAssertEqual(DuoRetry.verdict(for: error ?? CancellationError()), .fail, "\(label): a failure that forgets nothing")
                XCTAssertTrue(session.requests.isEmpty, "\(label): nothing sent")
                XCTAssertFalse(attester.log.contains { $0.hasPrefix("attestNewKey") || $0.hasPrefix("assert") }, "\(label): nothing attested")
            }
        }
        // The anonymous routes carry no bearer, so a malformed credential does not stop them.
        let session = ScriptedSession()
        session.replies = [.init(status: 201, body: Wire.json(Wire.device))]
        let answer = await failure { _ = try await self.makeClient(session, credential: malformed[0]).createDevice(Wire.createDevice) }
        XCTAssertNil(answer)
        XCTAssertNil(session.requests.first?.value(forHTTPHeaderField: "Authorization"))
    }

    func testPeekIsAnonymousWithoutACredentialAndCarriesTheBearerWithOne() async throws {
        let peek = Self.endpoints().first { $0.name == "peekInvite" }!
        for credential in [nil, Wire.credential] {
            let session = ScriptedSession()
            session.replies = [ScriptedSession.Reply(status: 200, body: Wire.json(Wire.peek))]
            let answer = try await makeClient(session, credential: credential).peekInvite(code: "H7K3-9QWX")
            XCTAssertEqual(answer, Wire.peek)
            XCTAssertEqual(session.requests.count, 1)
            assertShape(session.requests[0], peek, bearer: credential)
        }
    }

    func testTheMintAndTheChallengeNeverCarryTheBearerEvenWhenThereIsOne() async throws {
        let session = ScriptedSession()
        session.replies = [ScriptedSession.Reply(status: 201, body: Wire.json(Wire.device))]
        _ = try await makeClient(session, credential: Wire.credential).createDevice(Wire.createDevice)
        _ = try await makeClient(session, credential: Wire.credential).attestChallenge()
        XCTAssertEqual(session.requests.count, 2)
        for request in session.requests {
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"), request.url?.path ?? "")
        }
        let challenge = session.requests[1]
        XCTAssertNil(challenge.httpBody, "the challenge has no body")
        XCTAssertNil(challenge.value(forHTTPHeaderField: "Content-Type"), "and so no Content-Type")
        XCTAssertEqual(challenge.value(forHTTPHeaderField: "X-HD-Client"), "ios/2.0 (57)")
    }

    func testARotateIsSentAsTheCredentialItIsGivenWhateverTheIdentityHoldsNow() async throws {
        let restored = DuoCredential(memberID: Wire.credential.memberID, deviceID: "6d2a0000-0000-4000-8000-0000000000dd",
                                     deviceSecret: String(repeating: "r", count: 43), secretVersion: 1)
        for ambient in [nil, Wire.credential] {
            let session = ScriptedSession()
            session.replies = [.init(status: 200, body: Wire.json(Wire.rotated))]
            let attester = ScriptedAttester()
            let answer = try await makeClient(session, credential: ambient, attester: attester).rotate(as: restored)
            XCTAssertEqual(answer, Wire.rotated)
            XCTAssertEqual(session.requests.count, 1)
            XCTAssertEqual(session.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(restored.bearer)",
                           "the identity holds \(ambient == nil ? "nothing" : "another credential"): the rotate still goes as the one it was given")
            XCTAssertEqual(session.requests.first?.httpMethod, "POST")
            XCTAssertEqual(session.requests.first?.url?.path, "/v1/devices/me/rotate")
            XCTAssertNil(session.requests.first?.httpBody)
            XCTAssertNil(session.requests.first?.value(forHTTPHeaderField: "X-HD-Attest"))
            XCTAssertEqual(attester.log, [], "not attested")
        }
    }

    func testARotateThatFailsIsSentOnceAndNeverRetried() async {
        let failures: [(String, ScriptedSession.Reply?)] = [
            ("401 unauthenticated", Wire.error("unauthenticated", status: 401)),
            ("401 device_revoked", Wire.error("device_revoked", status: 401)),
            ("503", Wire.error("maintenance", status: 503, retryAfter: "1")),
            ("429", Wire.error("rate_limited", status: 429, retryAfter: "30")),
            ("attest_required", Wire.error("attest_required", status: 403, details: #"{"retryable":true}"#)),
            ("a 200 that does not decode", .init(status: 200, body: Data("{}".utf8))),
            ("no connection", nil),
        ]
        for (name, reply) in failures {
            let session = ScriptedSession()
            session.replies = reply.map { [$0, $0, $0] } ?? []
            let error = await failure { _ = try await self.makeClient(session, credential: nil, attester: ScriptedAttester()).rotate(as: Wire.credential) }
            XCTAssertNotNil(error, name)
            XCTAssertNotEqual(error as? DuoTransportError, .unauthenticated(DuoErrorContext(httpStatus: 0)),
                              "\(name): a rotate has its credential, so it never fails for want of one")
            XCTAssertEqual(session.requests.count, 1, "\(name): one send, never retried")
        }
    }

    func testARotateDoesNotWaitAtTheAttestationGate() async throws {
        let inner = ScriptedSession()
        inner.replies = [.init(status: 200, body: Wire.json(Wire.rotated)), .init(status: 201, body: Wire.json(Wire.withResult))]
        let held = HeldSession(inner, holding: "/v1/invites/redeem")
        let client = makeClient(held, attester: ScriptedAttester())
        let redeem = Task { try await client.redeemInvite(Wire.redeem, key: Wire.key(1)) }
        await held.waitUntilHeld()
        let answer = try await client.rotate(as: Wire.credential)
        XCTAssertEqual(answer, Wire.rotated, "the rotate went while the redeem still held the gate")
        held.release()
        _ = try await redeem.value
    }

    func testARecordedRequestDecodesToTheSameBytesAndThoseAreTheBytesSent() async throws {
        // The in-flight journal keeps a request's bytes and a replay goes through the typed
        // transport again (§6.0), so decoding the record and encoding it once more must give the
        // very bytes the server hashed, and those must be what leaves the phone.
        let redeems = [
            DuoWireRedeemRequest(code: "H7K39QWX", displayName: nil, skin: "forest", myToday: "2026-09-24", e2eeCapable: true,
                                 statuses: [Wire.rowIn]),
            Wire.redeem,
        ]
        for (index, request) in redeems.enumerated() {
            let recorded = Self.encoded(request)
            let decoded = try DuoWireCoding.decode(DuoWireRedeemRequest.self, from: recorded)
            XCTAssertEqual(decoded, request, "redeem \(index)")
            XCTAssertEqual(Self.encoded(decoded), recorded, "redeem \(index): the same bytes")
            let session = ScriptedSession()
            session.replies = [.init(status: 201, body: Wire.json(Wire.withResult))]
            _ = try await makeClient(session).redeemInvite(decoded, key: Wire.key(1))
            XCTAssertEqual(session.requests.first?.httpBody, recorded, "redeem \(index): what was sent is the record")
        }
        let nameless = String(decoding: Self.encoded(redeems[0]), as: UTF8.self)
        XCTAssertTrue(nameless.contains(#""display_name":null"#), "a null name is written, and read back, as null")
        XCTAssertFalse(nameless.contains("device_check_token"), "no token, no key")
        XCTAssertTrue(String(decoding: Self.encoded(Wire.redeem), as: UTF8.self).contains(#""device_check_token":"RGV2aWNlQ2hlY2s=""#))

        for request in [Wire.createDuo,
                        DuoWireCreateDuoRequest(displayName: "Sam", skin: "forest", myToday: "2026-09-24", e2eeCapable: false, statuses: [])] {
            let recorded = Self.encoded(request)
            let decoded = try DuoWireCoding.decode(DuoWireCreateDuoRequest.self, from: recorded)
            XCTAssertEqual(decoded, request)
            XCTAssertEqual(Self.encoded(decoded), recorded, "createDuo: the same bytes")
            let session = ScriptedSession()
            session.replies = [.init(status: 201, body: Wire.json(Wire.created))]
            _ = try await makeClient(session).createDuo(decoded, key: Wire.key(2))
            XCTAssertEqual(session.requests.first?.httpBody, recorded, "createDuo: what was sent is the record")
        }
    }

    func testAReplayOfTheSameTypedRequestUnderTheSameKeySendsIdenticalBytes() async throws {
        let duo = Wire.duo
        let calls: [(String, ScriptedSession.Reply, (DuoAPIClient) async throws -> Void)] = [
            ("deleteMe", .init(status: 204), { try await $0.deleteMe(DuoWireDeleteMeRequest(deviceCheckToken: "RGV2"), key: Wire.key(1)) }),
            ("createDuo", .init(status: 201, body: Wire.json(Wire.created)), { _ = try await $0.createDuo(Wire.createDuo, key: Wire.key(1)) }),
            ("createInvite", .init(status: 201, body: Wire.json(Wire.invite)), { _ = try await $0.createInvite(duoID: duo, purpose: .linkDevice, key: Wire.key(1)) }),
            ("redeemInvite", .init(status: 201, body: Wire.json(Wire.withResult)), { _ = try await $0.redeemInvite(Wire.redeem, key: Wire.key(1)) }),
            ("reconnect", .init(status: 200, body: Wire.json(Wire.reconnected)), { _ = try await $0.reconnect(Wire.reconnect, key: Wire.key(1)) }),
            ("leave", .init(status: 200, body: Wire.json(Wire.left)), { _ = try await $0.leave(duoID: duo, key: Wire.key(1)) }),
            ("block", .init(status: 204), { try await $0.block(duoID: duo, key: Wire.key(1)) }),
        ]
        for (name, reply, call) in calls {
            let session = ScriptedSession()
            session.replies = [reply, reply]
            // Two clients, as after a relaunch: nothing the first one kept can make the bytes agree.
            try await call(makeClient(session))
            try await call(makeClient(session))
            XCTAssertEqual(session.requests.count, 2, name)
            let (first, second) = (session.requests[0], session.requests[1])
            XCTAssertNotNil(first.httpBody, name)
            XCTAssertEqual(first.httpBody, second.httpBody, "\(name): the same bytes")
            XCTAssertEqual(first.url, second.url, name)
            XCTAssertEqual(first.httpMethod, second.httpMethod, name)
            XCTAssertEqual(first.value(forHTTPHeaderField: "Idempotency-Key"), Wire.key(1).value, name)
            XCTAssertEqual(second.value(forHTTPHeaderField: "Idempotency-Key"), Wire.key(1).value, name)
        }
    }

    func testFetchChangesAlwaysSendsSinceAndNeverANegativeOne() async throws {
        for (since, query) in [(Int64(0), "since=0"), (418, "since=418"), (Int64.max, "since=\(Int64.max)"), (-5, "since=0")] {
            let session = ScriptedSession()
            session.replies = [ScriptedSession.Reply(status: 200, body: Wire.json(Wire.changes))]
            _ = try await makeClient(session).fetchChanges(duoID: Wire.duo, since: since)
            XCTAssertEqual(session.requests.first?.url?.query, query)
        }
    }

    func testOnlyALowercaseUUIDIsADuoIDAndAnythingElseNeverLeavesThePhone() async throws {
        let session = ScriptedSession()
        session.replies = [ScriptedSession.Reply(status: 200, body: Wire.json(Wire.changes)),
                           ScriptedSession.Reply(status: 201, body: Wire.json(Wire.invite))]
        _ = try await makeClient(session).fetchChanges(duoID: Wire.duo, since: 1)
        _ = try await makeClient(session).createInvite(duoID: "00000000-0000-0000-0000-000000000000", purpose: .linkDevice, key: Wire.key(1))
        XCTAssertEqual(session.requests.map { $0.url?.absoluteString ?? "" },
                       ["https://api-staging.hydrodrop.us/v1/duos/\(Wire.duo)/changes?since=1",
                        "https://api-staging.hydrodrop.us/v1/duos/00000000-0000-0000-0000-000000000000/invites"],
                       "the lowercase UUID callers pass, and the nil UUID a link_device invite is made with, go as they are")
        // `.` and `..` became dot segments after the server's URL parsing even percent-encoded, so
        // no odd id is escaped and sent: it is refused before anything leaves.
        let refused = [".", "..", "../me?x=1#y", "", Wire.duo.uppercased(), Wire.duo + "\n", " " + Wire.duo, "6d2a0000-0000-4000-8000-00000000000g",
                       "6d2a0000000040008000000000000001", "6d2a0000-0000-4000-8000-0000000000012", "{\(Wire.duo)}"]
        let calls: [(String, (DuoAPIClient, String) async throws -> Void)] = [
            ("fetchChanges", { _ = try await $0.fetchChanges(duoID: $1, since: 1) }),
            ("fetchDuo", { _ = try await $0.fetchDuo(id: $1) }),
            ("createInvite", { _ = try await $0.createInvite(duoID: $1, purpose: .invite, key: Wire.key(1)) }),
            ("pushDayStatuses", { _ = try await $0.pushDayStatuses(duoID: $1, Wire.putStatuses) }),
            ("sendNudge", { _ = try await $0.sendNudge(duoID: $1, Wire.nudge) }),
            ("leave", { _ = try await $0.leave(duoID: $1, key: Wire.key(1)) }),
            ("block", { try await $0.block(duoID: $1, key: Wire.key(1)) }),
        ]
        for id in refused {
            for (name, call) in calls {
                let quiet = ScriptedSession()
                let error = await failure { try await call(self.makeClient(quiet), id) }
                XCTAssertEqual(error as? DuoTransportError, .schema(DuoErrorContext(httpStatus: 0)), "\(name) \(id.debugDescription)")
                XCTAssertTrue(quiet.requests.isEmpty, "\(name) \(id.debugDescription): nothing sent")
            }
        }
    }

    func testABaseURLWithATrailingSlashMakesTheSameURLs() async throws {
        let session = ScriptedSession()
        session.replies = [ScriptedSession.Reply(status: 200, body: Wire.json(Wire.me))]
        _ = try await makeClient(session, base: URL(string: "https://api-staging.hydrodrop.us/v1/")!).me()
        XCTAssertEqual(session.requests.first?.url?.absoluteString, "https://api-staging.hydrodrop.us/v1/me")
    }

    // MARK: Answers

    func testANudgeReads201AsNewAnd200AsOneThisDeviceAlreadySent() async throws {
        for (status, already) in [(201, false), (200, true)] {
            let session = ScriptedSession()
            session.replies = [ScriptedSession.Reply(status: status, body: Wire.json(Wire.nudged))]
            let answer = try await makeClient(session).sendNudge(duoID: Wire.duo, Wire.nudge)
            XCTAssertEqual(answer, DuoWireSendNudgeResult(response: Wire.nudged, wasAlreadySent: already), "\(status)")
        }
    }

    func testThe204EndpointsReturnOnA204AndAnyOther2xxIsUnreadable() async {
        let duo = Wire.duo
        let calls: [(String, (DuoAPIClient) async throws -> Void)] = [
            ("block", { try await $0.block(duoID: duo, key: Wire.key(1)) }),
            ("deleteMe", { try await $0.deleteMe(Wire.deleteMe, key: Wire.key(1)) }),
            ("unregisterPush", { try await $0.unregisterPush() }),
            ("registerPush", { try await $0.registerPush(Wire.registerPush, firstUpload: false) }),
        ]
        for (name, call) in calls {
            let session = ScriptedSession()
            session.replies = [ScriptedSession.Reply(status: 204), ScriptedSession.Reply(status: 200, body: Data("{}".utf8))]
            let ok = await failure { try await call(self.makeClient(session)) }
            XCTAssertNil(ok, "\(name): a 204 is the answer")
            let other = await failure { try await call(self.makeClient(session)) }
            XCTAssertEqual(other as? DuoTransportError, .unreadable(httpStatus: 200, requestID: "9b1c2d3e4f5a6b7c-LHR"), "\(name): a 200 is not its answer")
        }
    }

    func testA2xxThatDoesNotDecodeOrIsNotTheEndpointsStatusIsUnreadable() async {
        let session = ScriptedSession()
        session.replies = [
            ScriptedSession.Reply(status: 200, body: Data(#"{"member":{}}"#.utf8)),
            ScriptedSession.Reply(status: 200, body: Data("<html>ok</html>".utf8)),
            ScriptedSession.Reply(status: 200, headers: ["Content-Type": "application/json"], body: Data()),
            ScriptedSession.Reply(status: 200, body: Wire.json(Wire.created)),
            ScriptedSession.Reply(status: 202, body: Wire.json(Wire.withResult)),
            ScriptedSession.Reply(status: 201, headers: ["X-Request-Id": "bad id <with> spaces"], body: Data("{".utf8)),
        ]
        let client = makeClient(session)
        let malformed = await failure { _ = try await client.me() }
        XCTAssertEqual(malformed as? DuoTransportError, .unreadable(httpStatus: 200, requestID: "9b1c2d3e4f5a6b7c-LHR"))
        let html = await failure { _ = try await client.me() }
        XCTAssertEqual(html as? DuoTransportError, .unreadable(httpStatus: 200, requestID: "9b1c2d3e4f5a6b7c-LHR"))
        let empty = await failure { _ = try await client.rotate(as: Wire.credential) }
        XCTAssertEqual(empty as? DuoTransportError, .unreadable(httpStatus: 200, requestID: nil))
        let wrongStatus = await failure { _ = try await client.createDuo(Wire.createDuo, key: Wire.key(1)) }
        XCTAssertEqual(wrongStatus as? DuoTransportError, .unreadable(httpStatus: 200, requestID: "9b1c2d3e4f5a6b7c-LHR"),
                       "createDuo answers 201; a 200 is not its answer")
        let accepted = await failure { _ = try await client.pushDayStatuses(duoID: Wire.duo, Wire.putStatuses) }
        XCTAssertEqual(accepted as? DuoTransportError, .unreadable(httpStatus: 202, requestID: "9b1c2d3e4f5a6b7c-LHR"))
        let badID = await failure { _ = try await client.createInvite(duoID: Wire.duo, purpose: .invite, key: Wire.key(1)) }
        XCTAssertEqual(badID as? DuoTransportError, .unreadable(httpStatus: 201, requestID: nil), "an id that is not safe to print is dropped")
    }

    func testEachErrorClassComesThroughTheWholeClient() async {
        func error(_ reply: ScriptedSession.Reply, _ call: (DuoAPIClient) async throws -> Void) async -> Error? {
            let session = ScriptedSession()
            session.replies = [reply]
            return await failure { try await call(self.makeClient(session)) }
        }
        let pending = await error(Wire.error("pending_exists", status: 409, details: #"{"duo_id":"6d2a0000-0000-4000-8000-000000000001"}"#)) {
            _ = try await $0.createDuo(Wire.createDuo, key: Wire.key(1))
        }
        XCTAssertEqual(pending as? DuoTransportError,
                       .pendingExists(DuoErrorContext(httpStatus: 409, requestID: "9b1c2d3e4f5a6b7c-LHR",
                                                      details: DuoWireErrorDetails(duoId: "6d2a0000-0000-4000-8000-000000000001"))),
                       "a JSON error keeps its details, read through the envelope's own decoder")
        let banned = await error(Wire.error("banned", status: 403)) { _ = try await $0.me() }
        XCTAssertEqual((banned as? DuoTransportError)?.code, .banned)
        let waf = await error(Wire.html(403)) { _ = try await $0.me() }
        XCTAssertEqual(waf as? DuoTransportError, .maintenance(DuoErrorContext(httpStatus: 403, requestID: "9b1c-WAF")), "a WAF page is never banned")
        let portal = await error(Wire.html(401)) { _ = try await $0.me() }
        XCTAssertEqual(portal as? DuoTransportError, .maintenance(DuoErrorContext(httpStatus: 401, requestID: "9b1c-WAF")),
                       "D63: a 401 that is not the envelope is a portal or a proxy")
        XCTAssertEqual(DuoRetry.verdict(for: portal!), .retry(after: DuoRetry.fallbackDelay), "so nothing is forgotten")
        let gone = await error(Wire.error("unauthenticated", status: 401)) { _ = try await $0.me() }
        XCTAssertEqual((gone as? DuoTransportError)?.code, .unauthenticated)
        XCTAssertEqual(DuoRetry.verdict(for: gone!), .reidentify, "the server's own 401 still means the identity is gone")
        let limited = await error(Wire.html(429, retryAfter: "30")) { _ = try await $0.sendNudge(duoID: Wire.duo, Wire.nudge) }
        XCTAssertEqual(limited as? DuoTransportError, .rateLimited(DuoErrorContext(httpStatus: 429, requestID: "9b1c-WAF", retryAfter: 30)))
        let terms = await error(Wire.error("terms_required", status: 428, details: #"{"terms_version":1}"#)) {
            _ = try await $0.redeemInvite(Wire.redeem, key: Wire.key(1))
        }
        XCTAssertEqual((terms as? DuoTransportError)?.context?.details?.termsVersion, 1)
        let newer = await error(Wire.error("duo_frozen", status: 409)) { _ = try await $0.leave(duoID: Wire.duo, key: Wire.key(1)) }
        XCTAssertEqual(newer as? DuoTransportError, .unreadable(httpStatus: 409, requestID: "9b1c2d3e4f5a6b7c-LHR"))
        let bodyID = await error(ScriptedSession.Reply(status: 404, headers: ["Content-Type": "application/json"],
                                                       body: Wire.error("duo_unknown", status: 404).body)) {
            _ = try await $0.fetchChanges(duoID: Wire.duo, since: 3)
        }
        XCTAssertEqual(bodyID as? DuoTransportError, .duoUnknown(DuoErrorContext(httpStatus: 404, requestID: "body-id")),
                       "with no X-Request-Id, the body's request_id")
        XCTAssertEqual(DuoRetry.verdict(for: bodyID!), .ended)
    }

    func testAConnectionThatFailsIsOfflineAndOnlyACancelledTaskIsCancellation() async {
        let named: [URLError.Code] = [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost,
                                      .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed, .secureConnectionFailed, .cannotLoadFromNetwork]
        let others: [URLError.Code] = [.serverCertificateUntrusted, .serverCertificateHasBadDate, .badServerResponse, .cannotParseResponse,
                                       .httpTooManyRedirects, .userAuthenticationRequired, .resourceUnavailable]
        // `.cancelled` with the task still running: something other than the caller stopped the
        // request (the system tearing the session down, say), so it is a connection that failed.
        for code in named + others + [.cancelled] {
            let session = ScriptedSession()
            session.answer = { _ in throw URLError(code) }
            let error = await failure { _ = try await self.makeClient(session).me() }
            XCTAssertEqual(error as? DuoTransportError, .offline, "\(code.rawValue)")
        }
        // The caller's own task cancelled while the request was out: cancellation, never an app error.
        for thrown in [URLError(.cancelled) as Error, CancellationError(), URLError(.timedOut)] {
            let session = ScriptedSession()
            session.answer = { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw thrown
            }
            let client = makeClient(session)
            let error = await Task { () -> Error? in
                do { _ = try await client.me(); return nil } catch { return error }
            }.value
            XCTAssertTrue(error is CancellationError, "\(thrown)")
            XCTAssertNil(error as? DuoTransportError)
        }
        let session = ScriptedSession()
        session.answer = { _ in throw CancellationError() }
        let error = await failure { _ = try await self.makeClient(session).me() }
        XCTAssertTrue(error is CancellationError, "a session's own CancellationError is passed on as it is")
    }

    func testAnAnswerFromSomewhereElseOrARedirectIsMaintenanceAndNothingInItIsRead() async {
        let moved: [(String, URL)] = [
            ("another host", URL(string: "https://portal.example.net/v1/me")!),
            ("another path", URL(string: "https://api-staging.hydrodrop.us/v1/login")!),
            ("another port", URL(string: "https://api-staging.hydrodrop.us:8443/v1/me")!),
            ("another scheme", URL(string: "http://api-staging.hydrodrop.us/v1/me")!),
        ]
        for (name, url) in moved {
            for status in [200, 401, 403] {
                let session = ScriptedSession()
                let body = status == 200 ? Wire.json(Wire.me) : Wire.error("banned", status: status).body
                session.replies = [ScriptedSession.Reply(status: status, body: body, url: url)]
                let error = await failure { _ = try await self.makeClient(session).me() }
                XCTAssertEqual(error as? DuoTransportError, .maintenance(DuoErrorContext(httpStatus: status)), "\(name), \(status)")
            }
        }
        let same = ScriptedSession()
        same.replies = [ScriptedSession.Reply(status: 200, body: Wire.json(Wire.me), url: URL(string: "HTTPS://API-STAGING.hydrodrop.us:443/v1/me")!)]
        let answer = await failure { _ = try await self.makeClient(same).me() }
        XCTAssertNil(answer, "the same scheme, host, port and path in another spelling is the same place")

        for status in [301, 302, 303, 304, 307, 308] {
            let session = ScriptedSession()
            var reply = ScriptedSession.Reply(status: status, headers: ["Location": "https://portal.example.net/", "CF-Ray": "8a0b1c2d3e4f5a6b-YYZ"])
            reply.body = Data("<html>moved</html>".utf8)
            session.replies = [reply]
            let error = await failure { try await self.makeClient(session).block(duoID: Wire.duo, key: Wire.key(1)) }
            XCTAssertEqual(error as? DuoTransportError, .maintenance(DuoErrorContext(httpStatus: status, requestID: "8a0b1c2d3e4f5a6b-YYZ")),
                           "\(status): a redirect waits, it is not dropped")
            XCTAssertEqual(session.requests.count, 1, "and is not followed")
        }
    }

    func testTheRequestIDIsXRequestIdElseCFRayElseTheBodys() async {
        func error(_ headers: [String: String], status: Int, body: Data) async -> Error? {
            let session = ScriptedSession()
            session.replies = [ScriptedSession.Reply(status: status, headers: headers, body: body)]
            return await failure { _ = try await self.makeClient(session).me() }
        }
        let envelope = Wire.error("conflict", status: 409).body
        let json = "application/json"
        let fromRay = await error(["Content-Type": json, "CF-Ray": "8a0b1c2d3e4f5a6b-YYZ"], status: 409, body: envelope)
        XCTAssertEqual((fromRay as? DuoTransportError)?.requestID, "8a0b1c2d3e4f5a6b-YYZ", "no X-Request-Id: the CF-Ray")
        let both = await error(["Content-Type": json, "X-Request-Id": "9b1c2d3e4f5a6b7c-LHR", "CF-Ray": "8a0b1c2d3e4f5a6b-YYZ"], status: 409, body: envelope)
        XCTAssertEqual((both as? DuoTransportError)?.requestID, "9b1c2d3e4f5a6b7c-LHR")
        let neither = await error(["Content-Type": json], status: 409, body: envelope)
        XCTAssertEqual((neither as? DuoTransportError)?.requestID, "body-id")
        let wafRay = await error(["Content-Type": "text/html", "CF-Ray": "8a0b1c2d3e4f5a6b-YYZ"], status: 403, body: Data("<html/>".utf8))
        XCTAssertEqual(wafRay as? DuoTransportError, .maintenance(DuoErrorContext(httpStatus: 403, requestID: "8a0b1c2d3e4f5a6b-YYZ")))
        let unreadable = await error(["CF-Ray": "8a0b1c2d3e4f5a6b-YYZ"], status: 200, body: Data("{".utf8))
        XCTAssertEqual(unreadable as? DuoTransportError, .unreadable(httpStatus: 200, requestID: "8a0b1c2d3e4f5a6b-YYZ"))
    }

    func testATaskCancelledBeforeTheCallSendsNothing() async {
        let session = ScriptedSession()
        session.replies = [ScriptedSession.Reply(status: 200, body: Wire.json(Wire.me))]
        let client = makeClient(session)
        let error = await Task { () -> Error? in
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await client.me(); return nil } catch { return error }
        }.value
        XCTAssertTrue(error is CancellationError)
        XCTAssertTrue(session.requests.isEmpty)
    }

    // MARK: Attestation

    /// The server's own vectors for the bind (HydroDrop-Server `test/d48-device-bind.test.ts` at
    /// `contract-v1`, computed there with Node's crypto apart from the Worker's code).
    func testTheBindMatchesTheServersD48Vectors() {
        let challenge = "6d2a0000-0000-4000-8000-0000000b0010"
        let device = "6d2a0000-0000-4000-8000-0000000b0011"
        let body = Data(#"{"code":"H7K3-9QWX"}"#.utf8)
        XCTAssertEqual(Self.hex(DuoAPIClient.bind(challengeID: challenge, action: .deviceCreate, deviceID: nil, body: body)),
                       "a7a02de6d215ec92e6aa2d3c3eb46bace1626ecad84299326140d22bd73c33bd")
        XCTAssertEqual(Self.hex(DuoAPIClient.bind(challengeID: challenge, action: .deviceCreate, deviceID: device, body: body)),
                       "a7a02de6d215ec92e6aa2d3c3eb46bace1626ecad84299326140d22bd73c33bd", "device_create never binds a device")
        XCTAssertEqual(Self.hex(DuoAPIClient.bind(challengeID: challenge, action: .inviteRedeem, deviceID: device, body: body)),
                       "a5f3c2847ec6c109eb233421d500cb9a94e78201e831a3b56a534d31895ce1ed")
        XCTAssertEqual(Self.hex(DuoAPIClient.bind(challengeID: challenge, action: .duoCreate, deviceID: device, body: body)),
                       "13874a8ccc5084ad2ae68e80489aa5fdf49195456e8da86e982f11fed8be5c40")
        XCTAssertEqual(Self.hex(DuoAPIClient.bind(challengeID: challenge, action: .pushRegister, deviceID: device, body: body)),
                       "86ca2f6e5ee544aadb834164587a156dacda2d3cf7cdddbec888adf3e78cb20a")
    }

    func testTheMintIsAttestedWithANewKeyBoundWithoutADeviceAndTheKeyGoesToTheNewDevice() async throws {
        let session = ScriptedSession()
        session.replies = [ScriptedSession.Reply(status: 201, body: Wire.json(Wire.device))]
        let attester = ScriptedAttester(keys: [Wire.credential.deviceID])
        let answer = try await makeClient(session, credential: nil, attester: attester).createDevice(Wire.createDevice)
        XCTAssertEqual(answer, Wire.device)
        XCTAssertEqual(session.requests.map { $0.url?.path }, ["/v1/attest/challenge", "/v1/devices"], "the challenge goes through the same session")
        let mint = session.requests[1]
        XCTAssertEqual(mint.value(forHTTPHeaderField: "X-HD-Attest"), "v1.ios.\(Wire.challengeID(1)).QVRURVNU-1")
        XCTAssertNil(mint.value(forHTTPHeaderField: "Authorization"))
        XCTAssertEqual(attester.hashes, [Self.handBuiltBind(Wire.challengeID(1), "device_create", device: nil, body: Self.encoded(Wire.createDevice))])
        XCTAssertEqual(attester.log, ["isSupported", "attestNewKey", "adopt:key-1:\(Wire.device.deviceId)"],
                       "a fresh key for every identity, adopted for the device the answer names")
    }

    func testTheBearerActionsBindTheDeviceTheBearerNamesAndAssertWithItsKey() async throws {
        let credential = DuoCredential(memberID: Wire.credential.memberID, deviceID: "6d2a0000-0000-4000-8000-0000000b0011",
                                       deviceSecret: String(repeating: "s", count: 43))
        let calls: [(String, Data, ScriptedSession.Reply, (DuoAPIClient) async throws -> Void)] = [
            ("duo_create", Self.encoded(Wire.createDuo), .init(status: 201, body: Wire.json(Wire.created)),
             { _ = try await $0.createDuo(Wire.createDuo, key: Wire.key(1)) }),
            ("invite_redeem", Self.encoded(Wire.redeem), .init(status: 201, body: Wire.json(Wire.withResult)),
             { _ = try await $0.redeemInvite(Wire.redeem, key: Wire.key(1)) }),
            ("invite_redeem", Self.encoded(Wire.reconnect), .init(status: 200, body: Wire.json(Wire.reconnected)),
             { _ = try await $0.reconnect(Wire.reconnect, key: Wire.key(1)) }),
            ("push_register", Self.encoded(Wire.registerPush), .init(status: 204),
             { try await $0.registerPush(Wire.registerPush, firstUpload: true) }),
        ]
        for (action, body, reply, call) in calls {
            let session = ScriptedSession()
            session.replies = [reply]
            let attester = ScriptedAttester(keys: [credential.deviceID])
            try await call(makeClient(session, credential: credential, attester: attester))
            XCTAssertEqual(session.requests.count, 2, action)
            let sent = session.requests[1]
            XCTAssertEqual(sent.httpBody, body, action)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "X-HD-Attest"), "v1.ios.\(Wire.challengeID(1)).QVNTRVJU-1", action)
            XCTAssertEqual(sent.value(forHTTPHeaderField: "Authorization"), "Bearer \(credential.bearer)", action)
            XCTAssertEqual(attester.hashes, [Self.handBuiltBind(Wire.challengeID(1), action, device: credential.deviceID, body: body)], action)
            XCTAssertEqual(attester.log, ["isSupported", "hasKey:\(credential.deviceID)", "assert:\(credential.deviceID)"],
                           "\(action): an assertion with the key the device has, and nothing adopted")
        }
        // The reconnect's body is the server's own vector body, so its bind is the server's vector.
        let session = ScriptedSession()
        session.replies = [.init(status: 200, body: Wire.json(Wire.reconnected))]
        let attester = ScriptedAttester(keys: [credential.deviceID])
        _ = try await makeClient(session, credential: credential, attester: attester).reconnect(Wire.reconnect, key: Wire.key(1))
        XCTAssertEqual(attester.hashes.map(Self.hex), ["a5f3c2847ec6c109eb233421d500cb9a94e78201e831a3b56a534d31895ce1ed"])
    }

    func testABearerActionWithNoKeyAttestsANewOneAndAdoptsItOnlyAfterA2xx() async throws {
        let session = ScriptedSession()
        session.replies = [.init(status: 201, body: Wire.json(Wire.created))]
        let attester = ScriptedAttester()
        _ = try await makeClient(session, attester: attester).createDuo(Wire.createDuo, key: Wire.key(1))
        XCTAssertEqual(session.requests[1].value(forHTTPHeaderField: "X-HD-Attest"), "v1.ios.\(Wire.challengeID(1)).QVRURVNU-1")
        XCTAssertEqual(attester.log, ["isSupported", "hasKey:\(Wire.credential.deviceID)", "attestNewKey", "adopt:key-1:\(Wire.credential.deviceID)"])

        let refused = ScriptedSession()
        refused.replies = [Wire.error("duo_limit", status: 409)]
        let other = ScriptedAttester()
        let error = await failure { _ = try await self.makeClient(refused, attester: other).createDuo(Wire.createDuo, key: Wire.key(1)) }
        XCTAssertEqual((error as? DuoTransportError)?.code, .duoLimit)
        XCTAssertFalse(other.log.contains { $0.hasPrefix("adopt") }, "a key the server refused the request with is never stored")
    }

    func testNoChallengeIsAskedForWhenTheAttesterCannotAttest() async throws {
        let duo = Wire.duo
        let calls: [(String, ScriptedSession.Reply, (DuoAPIClient) async throws -> Void)] = [
            ("createDevice", .init(status: 201, body: Wire.json(Wire.device)), { _ = try await $0.createDevice(Wire.createDevice) }),
            ("createDuo", .init(status: 201, body: Wire.json(Wire.created)), { _ = try await $0.createDuo(Wire.createDuo, key: Wire.key(1)) }),
            ("redeemInvite", .init(status: 201, body: Wire.json(Wire.withResult)), { _ = try await $0.redeemInvite(Wire.redeem, key: Wire.key(1)) }),
            ("reconnect", .init(status: 200, body: Wire.json(Wire.reconnected)), { _ = try await $0.reconnect(Wire.reconnect, key: Wire.key(1)) }),
            ("registerPush", .init(status: 204), { try await $0.registerPush(Wire.registerPush, firstUpload: true) }),
            ("createInvite", .init(status: 201, body: Wire.json(Wire.invite)), { _ = try await $0.createInvite(duoID: duo, purpose: .invite, key: Wire.key(1)) }),
        ]
        for (name, reply, call) in calls {
            let session = ScriptedSession()
            session.replies = [reply]
            let attester = ScriptedAttester(supported: false)
            try await call(makeClient(session, attester: attester))
            XCTAssertEqual(session.requests.count, 1, "\(name): no challenge")
            XCTAssertNil(session.requests.first?.value(forHTTPHeaderField: "X-HD-Attest"), name)
            XCTAssertTrue(attester.log.allSatisfy { $0 == "isSupported" }, name)
        }
    }

    func testARepeatPushUploadIsNeverAttested() async throws {
        let session = ScriptedSession()
        session.replies = [.init(status: 204)]
        let attester = ScriptedAttester(keys: [Wire.credential.deviceID])
        try await makeClient(session, attester: attester).registerPush(Wire.registerPush, firstUpload: false)
        XCTAssertEqual(session.requests.map { $0.url?.path }, ["/v1/devices/me/push"], "no challenge")
        XCTAssertNil(session.requests[0].value(forHTTPHeaderField: "X-HD-Attest"))
        XCTAssertEqual(attester.log, [], "the attester is not even asked whether it can")
    }

    /// The main request's attempts, as `<attest header's challenge id, or "none">`.
    private func attempts(_ session: ScriptedSession, path: String) -> [String] {
        session.requests.filter { $0.url?.path == path }.map { request in
            guard let header = request.value(forHTTPHeaderField: "X-HD-Attest") else { return "none" }
            return header.split(separator: ".", maxSplits: 3).dropFirst(2).first.map(String.init) ?? header
        }
    }

    /// Every attempt of the main request carries the same bytes and the same key.
    private func assertOneRequest(_ session: ScriptedSession, path: String, key: DuoIdempotencyKey, file: StaticString = #filePath, line: UInt = #line) {
        let sent = session.requests.filter { $0.url?.path == path }
        XCTAssertEqual(Set(sent.map { $0.httpBody ?? Data() }).count, 1, "every attempt sends the same bytes", file: file, line: line)
        XCTAssertEqual(Set(sent.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), [key.value], "and keeps its key", file: file, line: line)
        XCTAssertEqual(sent.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }.count, sent.count, file: file, line: line)
    }

    func testAttestRequiredIsRetriedWithAFreshChallengeThenTwiceWithNoHeaderAndThenShown() async {
        let session = ScriptedSession()
        let required = Wire.error("attest_required", status: 403, details: #"{"retryable":true}"#)
        session.replies = [required, required, required, required, required]
        let attester = ScriptedAttester(keys: [Wire.credential.deviceID])
        let error = await failure { _ = try await self.makeClient(session, attester: attester).redeemInvite(Wire.redeem, key: Wire.key(7)) }
        XCTAssertEqual((error as? DuoTransportError)?.code, .attestRequired)
        XCTAssertEqual(session.requests.map { $0.url?.path ?? "" },
                       ["/v1/attest/challenge", "/v1/invites/redeem", "/v1/attest/challenge", "/v1/invites/redeem", "/v1/invites/redeem",
                        "/v1/invites/redeem"])
        XCTAssertEqual(attempts(session, path: "/v1/invites/redeem"), [Wire.challengeID(1), Wire.challengeID(2), "none", "none"],
                       "a fresh challenge, then no header, then no header once more (the refusal lowered the device), and no more")
        assertOneRequest(session, path: "/v1/invites/redeem", key: Wire.key(7))
        XCTAssertEqual(session.replies.count, 1, "the fifth refusal was never asked for")
    }

    func testTheWorstCaseIsFiveSendsAndThreeChallenges() async {
        let session = ScriptedSession()
        let required = Wire.error("attest_required", status: 403, details: #"{"retryable":true}"#)
        let invalid = Wire.error("attest_invalid", status: 403)
        session.replies = [required, invalid, required, required, required, .init(status: 201, body: Wire.json(Wire.withResult))]
        let attester = ScriptedAttester(keys: [Wire.credential.deviceID])
        let error = await failure { _ = try await self.makeClient(session, attester: attester).redeemInvite(Wire.redeem, key: Wire.key(9)) }
        XCTAssertEqual((error as? DuoTransportError)?.code, .attestRequired)
        XCTAssertEqual(attempts(session, path: "/v1/invites/redeem"), [Wire.challengeID(1), Wire.challengeID(2), Wire.challengeID(3), "none", "none"],
                       "an assertion, a fresh challenge's assertion, a new key's attestation, then no header twice")
        XCTAssertEqual(session.requests.filter { $0.url?.path == "/v1/attest/challenge" }.count, 3)
        XCTAssertEqual(session.requests.count, 8)
        XCTAssertEqual(session.replies.count, 1, "a sixth send never happens")
        assertOneRequest(session, path: "/v1/invites/redeem", key: Wire.key(9))
        XCTAssertFalse(attester.log.contains { $0.hasPrefix("adopt") })
    }

    func testAttestRequiredThenAcceptedWithNoHeaderGoesThroughAtTheLowTier() async throws {
        let session = ScriptedSession()
        let required = Wire.error("attest_required", status: 403, details: #"{"retryable":true}"#)
        session.replies = [required, required, .init(status: 201, body: Wire.json(Wire.created))]
        let attester = ScriptedAttester()
        let answer = try await makeClient(session, attester: attester).createDuo(Wire.createDuo, key: Wire.key(2))
        XCTAssertEqual(answer, Wire.created)
        XCTAssertEqual(attempts(session, path: "/v1/duos"), [Wire.challengeID(1), Wire.challengeID(2), "none"])
        assertOneRequest(session, path: "/v1/duos", key: Wire.key(2))
        XCTAssertFalse(attester.log.contains { $0.hasPrefix("adopt") }, "the request that went through carried no key, so none is adopted")
        XCTAssertEqual(attester.log.filter { $0 == "attestNewKey" }.count, 2, "a key is attested once, so the retry brings another")
    }

    func testAttestRequiredThenAcceptedOnTheFreshChallengeAdoptsThatAttemptsKey() async throws {
        let session = ScriptedSession()
        session.replies = [Wire.error("attest_required", status: 403, details: #"{"retryable":true}"#), .init(status: 204)]
        let attester = ScriptedAttester()
        try await makeClient(session, attester: attester).registerPush(Wire.registerPush, firstUpload: true)
        XCTAssertEqual(attempts(session, path: "/v1/devices/me/push"), [Wire.challengeID(1), Wire.challengeID(2)])
        XCTAssertEqual(attester.log.filter { $0.hasPrefix("adopt") }, ["adopt:key-2:\(Wire.credential.deviceID)"], "only the key that went through")
    }

    func testAttestInvalidAfterAnAssertionIsRetriedOnceWithANewKeyWhichIsAdoptedOnSuccess() async throws {
        let session = ScriptedSession()
        session.replies = [Wire.error("attest_invalid", status: 403), .init(status: 200, body: Wire.json(Wire.reconnected))]
        let attester = ScriptedAttester(keys: [Wire.credential.deviceID])
        let answer = try await makeClient(session, attester: attester).reconnect(Wire.reconnect, key: Wire.key(3))
        XCTAssertEqual(answer, Wire.reconnected)
        XCTAssertEqual(attempts(session, path: "/v1/invites/reconnect"), [Wire.challengeID(1), Wire.challengeID(2)], "a fresh challenge")
        let headers = session.requests.filter { $0.url?.path == "/v1/invites/reconnect" }.map { $0.value(forHTTPHeaderField: "X-HD-Attest") ?? "" }
        XCTAssertEqual(headers, ["v1.ios.\(Wire.challengeID(1)).QVNTRVJU-1", "v1.ios.\(Wire.challengeID(2)).QVRURVNU-1"],
                       "an assertion, then a new key's attestation")
        assertOneRequest(session, path: "/v1/invites/reconnect", key: Wire.key(3))
        let device = Wire.credential.deviceID
        XCTAssertEqual(attester.log, ["isSupported", "hasKey:\(device)", "assert:\(device)", "attestNewKey", "adopt:key-1:\(device)"])
        XCTAssertEqual(attester.hashes, [Self.handBuiltBind(Wire.challengeID(1), "invite_redeem", device: device, body: Self.encoded(Wire.reconnect)),
                                         Self.handBuiltBind(Wire.challengeID(2), "invite_redeem", device: device, body: Self.encoded(Wire.reconnect))])
    }

    func testAFinalAttestInvalidSendsOnceMoreWithNoHeaderAndNothingIsAdopted() async {
        let invalid = Wire.error("attest_invalid", status: 403)
        let twice = ScriptedSession()
        twice.replies = [invalid, invalid, invalid, invalid]
        let asserting = ScriptedAttester(keys: [Wire.credential.deviceID])
        let error = await failure { _ = try await self.makeClient(twice, attester: asserting).redeemInvite(Wire.redeem, key: Wire.key(4)) }
        XCTAssertEqual((error as? DuoTransportError)?.code, .attestInvalid)
        XCTAssertEqual(attempts(twice, path: "/v1/invites/redeem"), [Wire.challengeID(1), Wire.challengeID(2), "none"],
                       "one retry with a new key, then once with no header, and no more")
        XCTAssertEqual(twice.replies.count, 1)
        assertOneRequest(twice, path: "/v1/invites/redeem", key: Wire.key(4))
        XCTAssertFalse(asserting.log.contains { $0.hasPrefix("adopt") })

        let once = ScriptedSession()
        once.replies = [invalid, invalid, invalid]
        let keyless = ScriptedAttester()
        let first = await failure { _ = try await self.makeClient(once, credential: nil, attester: keyless).createDevice(Wire.createDevice) }
        XCTAssertEqual((first as? DuoTransportError)?.code, .attestInvalid)
        XCTAssertEqual(attempts(once, path: "/v1/devices"), [Wire.challengeID(1), "none"],
                       "a new key's attestation refused is final at once, then the mint goes once with no header")
        XCTAssertFalse(keyless.log.contains { $0.hasPrefix("adopt") })
    }

    func testAFinalAttestInvalidThenAHeaderlessAttestRequiredGoesThroughAtTheLowTier() async throws {
        let session = ScriptedSession()
        session.replies = [Wire.error("attest_invalid", status: 403), Wire.error("attest_invalid", status: 403),
                           Wire.error("attest_required", status: 403, details: #"{"retryable":true}"#),
                           .init(status: 201, body: Wire.json(Wire.created))]
        let attester = ScriptedAttester(keys: [Wire.credential.deviceID])
        let answer = try await makeClient(session, attester: attester).createDuo(Wire.createDuo, key: Wire.key(3))
        XCTAssertEqual(answer, Wire.created)
        XCTAssertEqual(attempts(session, path: "/v1/duos"), [Wire.challengeID(1), Wire.challengeID(2), "none", "none"])
        assertOneRequest(session, path: "/v1/duos", key: Wire.key(3))
        XCTAssertFalse(attester.log.contains { $0.hasPrefix("adopt") }, "the request that went through carried no key")
    }

    func testAnAttesterThatThrowsMeansNoHeaderAndIsNotAskedAgain() async throws {
        let session = ScriptedSession()
        session.replies = [Wire.error("attest_required", status: 403, details: #"{"retryable":true}"#), .init(status: 201, body: Wire.json(Wire.withResult))]
        let attester = ScriptedAttester(keys: [Wire.credential.deviceID], failure: NSError(domain: "DCErrorDomain", code: 1))
        _ = try await makeClient(session, attester: attester).redeemInvite(Wire.redeem, key: Wire.key(5))
        XCTAssertEqual(attempts(session, path: "/v1/invites/redeem"), ["none", "none"],
                       "no header, and its one retry after attest_required goes without one too")
        XCTAssertEqual(session.requests.filter { $0.url?.path == "/v1/attest/challenge" }.count, 1, "no second challenge for an attester that failed")
        let device = Wire.credential.deviceID
        XCTAssertEqual(attester.log, ["isSupported", "hasKey:\(device)", "assert:\(device)", "attestNewKey"],
                       "the failed assertion falls back to a new key over the same challenge, which fails too, and then nothing more")
        XCTAssertEqual(Set(attester.hashes).count, 1, "one bind, one challenge")
        assertOneRequest(session, path: "/v1/invites/redeem", key: Wire.key(5))
    }

    func testAFailedAssertionFallsBackToANewKeyOverTheSameChallengeAndKeepsItsHeader() async throws {
        let device = Wire.credential.deviceID
        let session = ScriptedSession()
        session.replies = [.init(status: 201, body: Wire.json(Wire.withResult))]
        let attester = ScriptedAttester(keys: [device], assertFailure: NSError(domain: "DCErrorDomain", code: 2))
        _ = try await makeClient(session, attester: attester).redeemInvite(Wire.redeem, key: Wire.key(6))
        XCTAssertEqual(session.requests.map { $0.url?.path ?? "" }, ["/v1/attest/challenge", "/v1/invites/redeem"], "one challenge, still unspent")
        XCTAssertEqual(session.requests[1].value(forHTTPHeaderField: "X-HD-Attest"), "v1.ios.\(Wire.challengeID(1)).QVRURVNU-1",
                       "the call keeps a header: a new key's attestation")
        XCTAssertEqual(attester.log, ["isSupported", "hasKey:\(device)", "assert:\(device)", "attestNewKey", "adopt:key-1:\(device)"])
        let bind = Self.handBuiltBind(Wire.challengeID(1), "invite_redeem", device: device, body: Self.encoded(Wire.redeem))
        XCTAssertEqual(attester.hashes, [bind, bind], "the same bind for both")

        // That token is an attestation, so an attest_invalid on it is final: once more with no header.
        let refused = ScriptedSession()
        refused.replies = [Wire.error("attest_invalid", status: 403), .init(status: 201, body: Wire.json(Wire.withResult))]
        let other = ScriptedAttester(keys: [device], assertFailure: NSError(domain: "DCErrorDomain", code: 2))
        _ = try await makeClient(refused, attester: other).redeemInvite(Wire.redeem, key: Wire.key(6))
        XCTAssertEqual(attempts(refused, path: "/v1/invites/redeem"), [Wire.challengeID(1), "none"])
        XCTAssertFalse(other.log.contains { $0.hasPrefix("adopt") })
    }

    func testAPhoneThatCannotAttestRetriesAnAttestRequiredOnceWithNoHeader() async {
        let session = ScriptedSession()
        let required = Wire.error("attest_required", status: 403, details: #"{"retryable":true}"#)
        session.replies = [required, required, required]
        let error = await failure { _ = try await self.makeClient(session, attester: ScriptedAttester(supported: false)).createDuo(Wire.createDuo, key: Wire.key(6)) }
        XCTAssertEqual((error as? DuoTransportError)?.code, .attestRequired)
        XCTAssertEqual(attempts(session, path: "/v1/duos"), ["none", "none"], "one retry, which the server lets a lowered device through on")
        XCTAssertTrue(session.requests.allSatisfy { $0.url?.path == "/v1/duos" }, "and never a challenge")
    }

    func testAChallengeThatCannotBeHadMeansNoHeader() async throws {
        for challengeReply in [Wire.error("maintenance", status: 503), Wire.error("rate_limited", status: 429, retryAfter: "10"), Wire.html(403),
                               ScriptedSession.Reply(status: 201, body: Data("{}".utf8))] {
            let session = ScriptedSession()
            session.challengeReply = challengeReply
            session.replies = [.init(status: 201, body: Wire.json(Wire.device))]
            let attester = ScriptedAttester()
            _ = try await makeClient(session, credential: nil, attester: attester).createDevice(Wire.createDevice)
            XCTAssertEqual(attempts(session, path: "/v1/devices"), ["none"], "\(challengeReply.status)")
            XCTAssertEqual(attester.log, ["isSupported"], "no token without a challenge")
        }
    }

    func testCancellationWhileAttestingIsThrownAndTheRequestIsNotSent() async {
        let session = ScriptedSession()
        session.replies = [.init(status: 201, body: Wire.json(Wire.created))]
        let attester = ScriptedAttester(failure: CancellationError())
        let error = await failure { _ = try await self.makeClient(session, attester: attester).createDuo(Wire.createDuo, key: Wire.key(1)) }
        XCTAssertTrue(error is CancellationError)
        XCTAssertEqual(session.requests.map { $0.url?.path }, ["/v1/attest/challenge"], "the create itself never went")
    }

    // MARK: One attested call at a time

    func testAttestedCallsGoOneAtATimeFromTheChallengeToTheAdoption() async throws {
        let device = Wire.credential.deviceID
        let inner = ScriptedSession()
        inner.replies = [.init(status: 201, body: Wire.json(Wire.withResult)), .init(status: 204)]
        let held = HeldSession(inner, holding: "/v1/invites/redeem")
        let attester = ScriptedAttester()
        let client = makeClient(held, attester: attester)
        let first = Task { try await client.redeemInvite(Wire.redeem, key: Wire.key(1)) }
        await held.waitUntilHeld()
        let second = Task { try await client.registerPush(Wire.registerPush, firstUpload: true) }
        for _ in 0..<50 { await Task.yield() }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(held.started, ["/v1/attest/challenge", "/v1/invites/redeem"], "the second call has not asked for its challenge")
        held.release()
        _ = try await first.value
        try await second.value
        XCTAssertEqual(held.started, ["/v1/attest/challenge", "/v1/invites/redeem", "/v1/attest/challenge", "/v1/devices/me/push"])
        XCTAssertEqual(attester.log, ["isSupported", "hasKey:\(device)", "attestNewKey", "adopt:key-1:\(device)",
                                      "isSupported", "hasKey:\(device)", "assert:\(device)"],
                       "the second call starts after the first adopted its key, and so asserts with it instead of making another")
    }

    func testACallCancelledWhileItWaitsLeavesTheLineAndTheGateStillOpens() async throws {
        let inner = ScriptedSession()
        inner.replies = [.init(status: 201, body: Wire.json(Wire.created)), .init(status: 200, body: Wire.json(Wire.reconnected))]
        let held = HeldSession(inner, holding: "/v1/duos")
        let client = makeClient(held, attester: ScriptedAttester())
        let first = Task { try await client.createDuo(Wire.createDuo, key: Wire.key(1)) }
        await held.waitUntilHeld()
        let waiting = Task { try await client.redeemInvite(Wire.redeem, key: Wire.key(2)) }
        for _ in 0..<20 { await Task.yield() }
        try await Task.sleep(nanoseconds: 100_000_000)
        waiting.cancel()
        let cancelled = await Task { () -> Error? in
            do { _ = try await waiting.value; return nil } catch { return error }
        }.value
        XCTAssertTrue(cancelled is CancellationError, "a cancelled waiter is let go at once, while the first still holds the gate")
        XCTAssertEqual(held.started, ["/v1/attest/challenge", "/v1/duos"], "and it sent nothing")
        held.release()
        _ = try await first.value
        let answer = try await client.reconnect(Wire.reconnect, key: Wire.key(3))
        XCTAssertEqual(answer, Wire.reconnected, "the gate opens for the next call: the cancelled one never held it")
    }

    func testAHungAttesterDoesNotHoldTheGatePastItsTasksCancellation() async throws {
        let session = ScriptedSession()
        session.replies = [.init(status: 201, body: Wire.json(Wire.created))]
        let attester = HangingAttester()
        let client = makeClient(session, attester: attester)
        let stuck = Task { try await client.createDuo(Wire.createDuo, key: Wire.key(1)) }
        await attester.waitUntilStuck()
        stuck.cancel()
        let error = await Task { () -> Error? in
            do { _ = try await stuck.value; return nil } catch { return error }
        }.value
        XCTAssertTrue(error is CancellationError, "the call gives up when its task is cancelled, though the attester never answered")
        let answer = try await client.createDuo(Wire.createDuo, key: Wire.key(2))
        XCTAssertEqual(answer, Wire.created, "and the next attested call goes through")
        XCTAssertEqual(session.requests.filter { $0.url?.path == "/v1/duos" }.count, 1, "the stuck call itself never sent its create")
        attester.unstick()
    }

    func testTheObservedSessionSeesEveryRequestTheChallengesAndRetriesIncluded() async throws {
        let scripted = ScriptedSession()
        let required = Wire.error("attest_required", status: 403, details: #"{"retryable":true}"#)
        scripted.replies = [required, required, .init(status: 201, body: Wire.json(Wire.withResult))]
        let seen = SeenResponses()
        let observed = DuoObservedSession(base: scripted) { status, id in seen.add(status, id) }
        _ = try await makeClient(observed, attester: ScriptedAttester()).redeemInvite(Wire.redeem, key: Wire.key(8))
        XCTAssertEqual(scripted.requests.count, 5)
        XCTAssertEqual(seen.all, ["201:9b1c2d3e4f5a6b7c-LHR", "403:9b1c2d3e4f5a6b7c-LHR", "201:9b1c2d3e4f5a6b7c-LHR",
                                  "403:9b1c2d3e4f5a6b7c-LHR", "201:9b1c2d3e4f5a6b7c-LHR"],
                       "every response, each challenge and each attempt, left its request id for Diagnostics")
    }
}
#endif
