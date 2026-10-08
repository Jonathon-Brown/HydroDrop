#if DUO_V2
import CryptoKit
import XCTest
@testable import HydroDrop

// The tests two adversarial verifiers wrote against `DuoAPIClient` (stage A review, 2026-10-08),
// each one the test that caught a mutant the stage's own tests let through, ported here so they
// outlive the verifiers' scratch folders. They drive the real client through doubles of their
// own: a session that holds a path at a latch and records a total order of events, an attester
// modelled on stage B's single pending slot, a credential provider that changes on every read,
// and a model of the attestation retry machine run across every dimension the design names.
// Every helper is private to this file.

// MARK: - Fixtures and the logical calls

private enum RProbe {
    /// Which logical call an event belongs to. Task-locals are copied into `Task {}`, so the
    /// attester's work inside the client's own race task still carries it.
    @TaskLocal static var call: String = "-"
}

private enum RWire {
    static let base = URL(string: "https://api-staging.hydrodrop.us/v1")!
    static let client = DuoClientInfo(marketingVersion: "2.0", build: "57")
    static let credential = DuoFixtures.credential()
    static let duo = "6d2a0000-0000-4000-8000-000000000001"
    static let at = Date(timeIntervalSince1970: 1_790_000_000)

    static let credA = DuoCredential(memberID: "6d2a0000-0000-4000-8000-0000000000aa", deviceID: "6d2a0000-0000-4000-8000-0000000000bb",
                                     deviceSecret: "SECRET_A_" + String(repeating: "a", count: 34), secretVersion: 1)
    static let credB = DuoCredential(memberID: "6d2a0000-0000-4000-8000-0000000000ab", deviceID: "6d2a0000-0000-4000-8000-0000000000cc",
                                     deviceSecret: "SECRET_B_" + String(repeating: "b", count: 34), secretVersion: 1)
    static let credR = DuoCredential(memberID: "6d2a0000-0000-4000-8000-0000000000ac", deviceID: "6d2a0000-0000-4000-8000-0000000000dd",
                                     deviceSecret: "SECRET_R_" + String(repeating: "r", count: 34), secretVersion: 1)

    static func key(_ n: Int) -> DuoIdempotencyKey { DuoIdempotencyKey(String(format: "2b1c0000-0000-4000-8000-%012d", n)) }
    static func challengeID(_ n: Int) -> String { String(format: "6d2a0000-0000-4000-8000-%012x", 0xc0000 + n) }
    static func challenge(_ n: Int) -> DuoWireAttestChallenge {
        DuoWireAttestChallenge(challengeId: challengeID(n), challenge: "q83vEjRWeJBzh-nHvNkFFSIsr3Kdo6pZuL1lDGmzRpI", expiresAt: at.addingTimeInterval(300))
    }

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

    static func errorBody(_ code: String, details: String? = nil) -> Data {
        let detailsField = details.map { #","details":\#($0)"# } ?? ""
        return Data(#"{"error":{"code":"\#(code)","message":"m"\#(detailsField),"request_id":"body-id"}}"#.utf8)
    }

    static let createDevice = DuoWireCreateDeviceRequest(appVersion: "2.0 (57)", termsVersion: 1, deviceCheckToken: "RGV2aWNlQ2hlY2s=")
    static let registerPush = DuoWireRegisterPushRequest(token: "7c3d", apnsEnv: "sandbox", tz: "America/Toronto", wakeStartMin: 480,
                                                         wakeEndMin: 1320, notificationsEnabled: true)
    static let rowIn = DuoWireStatusIn(day: "2026-09-24", goalMet: false, progressBucket: 25, baseVer: 0)
    static let createDuo = DuoWireCreateDuoRequest(displayName: "Zoë 💧", skin: "classic", myToday: "2026-09-24", e2eeCapable: true, statuses: [rowIn])
    static let redeem = DuoWireRedeemRequest(code: "H7K39QWX", displayName: "Sam", skin: "forest", myToday: "2026-09-24", e2eeCapable: true,
                                             statuses: [rowIn], deviceCheckToken: "RGV2aWNlQ2hlY2s=")
    static let reconnect = DuoWireReconnectRequest(code: "H7K3-9QWX")
    static let nudge = DuoWireSendNudgeRequest(id: "nudge-3B9E1C2A-0000-4000-8000-000000000001", presetId: "waterBreak", senderDay: "2026-09-24")

    static let device = DuoWireCreateDeviceResponse(memberId: credential.memberID, deviceId: "6d2a0000-0000-4000-8000-0000000000ee",
                                                    deviceSecret: String(repeating: "t", count: 43), tier: .attested, supportId: "HD-7K3Q-9WXA")
    static let rotated = DuoWireRotateResponse(deviceSecret: String(repeating: "u", count: 43), secretVersion: 2)
    static let member = DuoWireMember(id: credential.memberID, displayName: "Jo", skin: "classic", supportId: "HD-7K3Q-9WXA", tier: .attested, termsVersion: 1)
    static let me = DuoWireGetMeResponse(member: member, limits: DuoWireLimits(nudgesPerDay: 3, maxActiveDuos: 5),
                                         devices: [DuoWireDevice(id: credential.deviceID, platform: "ios", createdAt: at, thisDevice: true, superseded: false)],
                                         duos: [DuoFixtures.wireHeader()], minClient: DuoWireMinClient(ios: "2.0", android: "1.1"))
    static let invite = DuoWireInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: at.addingTimeInterval(172_800))
    static let created = DuoWireCreateDuoResponse(duo: DuoFixtures.wireHeader(state: .pending, seq: 1), invite: invite, accepted: ["2026-09-24"],
                                                  unchanged: [], rejected: [])
    static let changes = DuoFixtures.wireChanges(cursor: 418)
    static let withResult = DuoWireChangesWithResult(changes: changes, accepted: ["2026-09-24"], unchanged: [], rejected: [])
    static let reconnected = DuoWireReconnectResponse(memberId: credential.memberID, supportId: "HD-7K3Q-9WXA", duos: [DuoFixtures.wireHeader()],
                                                      supersededDevices: 1)
    static let nudged = DuoWireSendNudgeResponse(nudge: DuoWireNudge(id: nudge.id, fromRole: .owner, presetId: "waterBreak", createdAt: at),
                                                 remainingToday: 2)

    /// The bind computed here from the design's sentence, apart from the client's `bind`.
    static func bind(_ challengeID: String, _ action: String, device: String?, body: Data) -> Data {
        var message = Data()
        message.append(contentsOf: Array(challengeID.utf8)); message.append(10)
        message.append(contentsOf: Array(action.utf8)); message.append(10)
        if let device { message.append(contentsOf: Array(device.utf8)); message.append(10) }
        message.append(contentsOf: Array(SHA256.hash(data: body)))
        return Data(SHA256.hash(data: message))
    }
}

/// The logical calls a test can make, with what each sends and how it succeeds.
private enum RCall: String, CaseIterable {
    case createDevice, createDuo, redeem, reconnect, pushFirst, pushRepeat, fetchChanges, sendNudge, rotate, me

    var action: String? {
        switch self {
        case .createDevice: return "device_create"
        case .createDuo: return "duo_create"
        case .redeem, .reconnect: return "invite_redeem"
        case .pushFirst: return "push_register"
        default: return nil
        }
    }
    var path: String {
        switch self {
        case .createDevice: return "/v1/devices"
        case .createDuo: return "/v1/duos"
        case .redeem: return "/v1/invites/redeem"
        case .reconnect: return "/v1/invites/reconnect"
        case .pushFirst, .pushRepeat: return "/v1/devices/me/push"
        case .fetchChanges: return "/v1/duos/\(RWire.duo)/changes"
        case .sendNudge: return "/v1/duos/\(RWire.duo)/nudges"
        case .rotate: return "/v1/devices/me/rotate"
        case .me: return "/v1/me"
        }
    }
    var okStatus: Int {
        switch self {
        case .createDevice, .createDuo, .redeem, .sendNudge: return 201
        case .pushFirst, .pushRepeat: return 204
        default: return 200
        }
    }
    var okBody: Data {
        switch self {
        case .createDevice: return RWire.json(RWire.device)
        case .createDuo: return RWire.json(RWire.created)
        case .redeem: return RWire.json(RWire.withResult)
        case .reconnect: return RWire.json(RWire.reconnected)
        case .pushFirst, .pushRepeat: return Data()
        case .fetchChanges: return RWire.json(RWire.changes)
        case .sendNudge: return RWire.json(RWire.nudged)
        case .rotate: return RWire.json(RWire.rotated)
        case .me: return RWire.json(RWire.me)
        }
    }
    func run(_ client: DuoAPIClient, key: Int) async throws {
        switch self {
        case .createDevice: _ = try await client.createDevice(RWire.createDevice)
        case .createDuo: _ = try await client.createDuo(RWire.createDuo, key: RWire.key(key))
        case .redeem: _ = try await client.redeemInvite(RWire.redeem, key: RWire.key(key))
        case .reconnect: _ = try await client.reconnect(RWire.reconnect, key: RWire.key(key))
        case .pushFirst: try await client.registerPush(RWire.registerPush, firstUpload: true)
        case .pushRepeat: try await client.registerPush(RWire.registerPush, firstUpload: false)
        case .fetchChanges: _ = try await client.fetchChanges(duoID: RWire.duo, since: 1)
        case .sendNudge: _ = try await client.sendNudge(duoID: RWire.duo, RWire.nudge)
        case .rotate: _ = try await client.rotate(as: RWire.credential)
        case .me: _ = try await client.me()
        }
    }
}

// MARK: - Doubles

/// A total order of events (sequence numbers taken under one lock).
private final class REventLog: @unchecked Sendable {
    struct Event { var seq: Int; var call: String; var what: String }
    private let lock = NSLock()
    private var events: [Event] = []
    func add(_ what: String, call: String = RProbe.call) {
        lock.withLock { events.append(Event(seq: events.count, call: call, what: what)) }
    }
    var all: [Event] { lock.withLock { events } }
}

/// A gate a test opens later; waits on it ignore cancellation, as App Attest is not known to honour it.
private final class RLatch: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let now: Bool = lock.withLock {
                if open { return true }
                waiting.append(continuation)
                return false
            }
            if now { continuation.resume() }
        }
    }
    func release() {
        let all: [CheckedContinuation<Void, Never>] = lock.withLock { open = true; let all = waiting; waiting = []; return all }
        all.forEach { $0.resume() }
    }
}

/// A credential provider that hands out the next of `sequence` on every read (cycling), and
/// counts the reads. Locked, unlike `FakeDuoIdentity`, since several calls read it at once.
private final class RShiftingCredentials: DuoCredentialProviding, @unchecked Sendable {
    private let lock = NSLock()
    private let sequence: [DuoCredential?]
    private var index = 0
    private var count = 0
    init(_ sequence: [DuoCredential?]) { self.sequence = sequence }
    var reads: Int { lock.withLock { count } }
    var credential: DuoCredential? {
        lock.withLock {
            count += 1
            defer { index += 1 }
            return sequence[index % sequence.count]
        }
    }
}

/// An attester modelled on stage B's `DuoAppAttest`: one pending slot, written when an
/// attestation is made, and `adoptPendingKey` adopts only the key that is pending.
private final class RSlotAttester: DuoAttesting, @unchecked Sendable {
    private let lock = NSLock()
    let log: REventLog
    private var keys: [String: String] = [:]
    private var pending: String?
    private var made = 0
    private(set) var adoptMissed: [(String, String)] = []
    /// What each operation does before answering: nil answers at once.
    var behaviour: (@Sendable (_ op: String) async throws -> Void)?

    init(log: REventLog) { self.log = log }

    var isSupported: Bool { true }
    func hasKey(forDevice deviceID: String) -> Bool { lock.withLock { keys[deviceID] != nil } }
    func setKey(_ keyID: String, for device: String) { lock.withLock { keys[device] = keyID } }
    func storedKey(for device: String) -> String? { lock.withLock { keys[device] } }

    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken {
        log.add("attester.attestNewKey.start")
        try await behaviour?("attestNewKey")
        let keyID: String = lock.withLock { made += 1; let k = "K\(made)"; pending = k; return k }
        log.add("attester.attestNewKey.end")
        return DuoAttestationToken(token: "QVRU-\(keyID)", keyID: keyID, kind: .attestation)
    }

    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken {
        log.add("attester.assert.start")
        try await behaviour?("assert")
        guard let keyID = lock.withLock({ keys[deviceID] }) else { throw NSError(domain: "noKey", code: 1) }
        log.add("attester.assert.end")
        return DuoAttestationToken(token: "QVNT-\(keyID)", keyID: keyID, kind: .assertion)
    }

    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) {
        lock.withLock {
            if pending == keyID { keys[deviceID] = keyID; pending = nil } else { adoptMissed.append((keyID, "pending=\(pending ?? "nil")")) }
        }
        log.add("adopt \(keyID)")
    }
    func forgetKeys(forDevice deviceID: String) { lock.withLock { keys[deviceID] = nil; pending = nil } }
}

/// Records every attestation call with its client data hash and the device it was for, and every adoption.
private final class RRecordingAttester: DuoAttesting, @unchecked Sendable {
    private let lock = NSLock()
    private let supported: Bool
    private var keys: Set<String>
    private var entries: [String] = []
    private var made = 0
    private var stored: [(hash: Data, device: String?)] = []
    init(supported: Bool = true, keys: Set<String> = []) { self.supported = supported; self.keys = keys }
    var log: [String] { lock.withLock { entries } }
    var hashes: [(hash: Data, device: String?)] { lock.withLock { stored } }
    var isSupported: Bool { supported }
    func hasKey(forDevice deviceID: String) -> Bool { lock.withLock { keys.contains(deviceID) } }
    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken {
        lock.withLock {
            made += 1
            entries.append("attestNewKey")
            stored.append((clientDataHash, nil))
            return DuoAttestationToken(token: "ATT\(made)", keyID: "key-\(made)", kind: .attestation)
        }
    }
    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken {
        lock.withLock {
            entries.append("assert:\(deviceID)")
            stored.append((clientDataHash, deviceID))
            return DuoAttestationToken(token: "ASR", keyID: "key-of-\(deviceID)", kind: .assertion)
        }
    }
    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) { lock.withLock { entries.append("adopt:\(keyID):\(deviceID)"); keys.insert(deviceID) } }
    func forgetKeys(forDevice deviceID: String) { lock.withLock { entries.append("forget:\(deviceID)"); _ = keys.remove(deviceID) } }
}

/// Answers by closure, recording every request; challenges are answered automatically when
/// built from a list of replies.
private final class RStubSession: DuoHTTPSession, @unchecked Sendable {
    struct Reply {
        var status: Int
        var headers: [String: String] = ["Content-Type": "application/json", "X-Request-Id": "9b1c2d3e4f5a6b7c-LHR"]
        var body = Data()
    }
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let answer: (URLRequest) throws -> Reply
    var requests: [URLRequest] { lock.withLock { recorded } }
    init(answer: @escaping (URLRequest) throws -> Reply) { self.answer = answer }

    convenience init(replies: [Reply]) {
        var queue = replies
        let lock = NSLock()
        var issued = 0
        self.init { request in
            try lock.withLock {
                if request.url?.path.hasSuffix("/attest/challenge") == true {
                    issued += 1
                    return Reply(status: 201, body: RWire.json(RWire.challenge(issued)))
                }
                guard !queue.isEmpty else { throw URLError(.notConnectedToInternet) }
                return queue.removeFirst()
            }
        }
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lock.withLock { recorded.append(request) }
        let reply = try answer(request)
        return (reply.body, HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!)
    }
}

/// A session whose main requests can be scripted per path, and held at a latch; it logs when
/// each request starts and ends.
private final class RPathSession: DuoHTTPSession, @unchecked Sendable {
    let log: REventLog
    private let lock = NSLock()
    private var challenges = 0
    private var scripted: [String: [(Int, Data)]] = [:]
    private var holds: [String: RLatch] = [:]
    private var arrivals: [String: RLatch] = [:]

    init(log: REventLog) { self.log = log }

    func script(_ path: String, _ replies: [(Int, Data)]) { lock.withLock { scripted[path] = replies } }
    /// The next request to `path` waits at the returned latch, deaf to cancellation.
    func hold(_ path: String) -> (release: RLatch, arrived: RLatch) {
        let latch = RLatch(), arrival = RLatch()
        lock.withLock { holds[path] = latch; arrivals[path] = arrival }
        return (latch, arrival)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let path = request.url?.path ?? ""
        log.add("req.start \(path)")
        defer { log.add("req.end \(path)") }
        if path.hasSuffix("/attest/challenge") {
            let n: Int = lock.withLock { challenges += 1; return challenges }
            return (RWire.json(RWire.challenge(n)), HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil,
                                                                    headerFields: ["Content-Type": "application/json"])!)
        }
        let (hold, arrival): (RLatch?, RLatch?) = lock.withLock { (holds.removeValue(forKey: path), arrivals.removeValue(forKey: path)) }
        arrival?.release()
        if let hold { await hold.wait() }
        let next: (Int, Data)? = lock.withLock {
            guard var list = scripted[path], !list.isEmpty else { return nil }
            let first = list.removeFirst(); scripted[path] = list; return first
        }
        let call = RCall.allCases.first { $0.path == path }!
        let (status, body) = next ?? (call.okStatus, call.okBody)
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
    }
}

/// A response that names no URL at all.
private final class RNilURLResponse: HTTPURLResponse, @unchecked Sendable {
    override var url: URL? { nil }
}

private final class RTaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Task<Bool, Never>?
    var task: Task<Bool, Never>? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private final class ROnceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    func set(_ c: CheckedContinuation<T?, Never>) { lock.withLock { continuation = c } }
    func resume(_ value: T?) {
        let c: CheckedContinuation<T?, Never>? = lock.withLock { let c = continuation; continuation = nil; return c }
        c?.resume(returning: value)
    }
}

/// The answer of `body`, or nil once `seconds` have passed; never waits for a body that ignores cancellation.
private func rWithin<T: Sendable>(_ seconds: Double, _ body: @escaping @Sendable () async throws -> T) async -> Result<T, Error>? {
    let box = ROnceBox<Result<T, Error>>()
    let result: Result<T, Error>?? = await withCheckedContinuation { (c: CheckedContinuation<Result<T, Error>?, Never>) in
        box.set(c)
        Task { do { box.resume(.success(try await body())) } catch { box.resume(.failure(error)) } }
        Task { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)); box.resume(nil) }
    }
    return result ?? nil
}

// MARK: - The retry machine's model

/// One answer of the server to the main request.
private enum RReply: Character, CaseIterable {
    case required = "R", invalid = "I", ok = "O", refused = "X", wrong2xx = "U", undecodable = "D", redirect = "M"
}

private enum RChallenge: String { case ok, fail503, fail429, offline, garbage }

/// Shared by the doubles of one run: the event counter and where to cancel.
private final class RMachineProbe: @unchecked Sendable {
    let lock = NSLock()
    var events = 0
    var cancelAt: Int?
    var honour = true
    var cancelledAtEvent: Int?
    var task: Task<Result<String, Error>, Never>?
    var log: [String] = []

    /// Returns true when this event is where the task is cancelled.
    func event(_ what: String) -> Bool {
        let (hit, task): (Bool, Task<Result<String, Error>, Never>?) = lock.withLock {
            events += 1
            log.append("\(events):\(what)")
            if events == cancelAt { cancelledAtEvent = events; return (true, self.task) }
            return (false, nil)
        }
        if hit { task?.cancel() }
        return hit
    }
    var afterCancel: [String] {
        lock.withLock {
            guard let c = cancelledAtEvent else { return [] }
            return log.filter { Int($0.split(separator: ":")[0])! > c }
        }
    }
}

private final class RMachineSession: DuoHTTPSession, @unchecked Sendable {
    let probe: RMachineProbe
    let call: RCall
    private let lock = NSLock()
    var replies: [RReply]
    var challengePlan: [RChallenge]
    private(set) var mainRequests: [URLRequest] = []
    private(set) var issued: [String] = []
    private(set) var challengeRequests = 0

    init(probe: RMachineProbe, call: RCall, replies: [RReply], challenges: [RChallenge]) {
        self.probe = probe; self.call = call; self.replies = replies; self.challengePlan = challenges
    }

    private func http(_ r: URLRequest, _ status: Int, _ body: Data, headers: [String: String] = ["Content-Type": "application/json"]) -> (Data, URLResponse) {
        (body, HTTPURLResponse(url: r.url!, statusCode: status, httpVersion: nil, headerFields: headers)!)
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let isChallenge = request.url?.path.hasSuffix("/attest/challenge") == true
        let hit = probe.event(isChallenge ? "challenge" : "send")
        if hit && probe.honour { throw URLError(.cancelled) }
        if isChallenge {
            let (n, plan): (Int, RChallenge) = lock.withLock {
                challengeRequests += 1
                let plan = challengeRequests <= challengePlan.count ? challengePlan[challengeRequests - 1] : .ok
                return (challengeRequests, plan)
            }
            switch plan {
            case .ok:
                lock.withLock { issued.append(RWire.challengeID(n)) }
                return http(request, 201, RWire.json(RWire.challenge(n)))
            case .fail503: return http(request, 503, RWire.errorBody("maintenance"))
            case .fail429: return http(request, 429, RWire.errorBody("rate_limited"), headers: ["Content-Type": "application/json", "Retry-After": "30"])
            case .offline: throw URLError(.notConnectedToInternet)
            case .garbage: return http(request, 201, Data("{}".utf8))
            }
        }
        let next: RReply? = lock.withLock {
            mainRequests.append(request)
            return replies.isEmpty ? nil : replies.removeFirst()
        }
        guard let next else { throw URLError(.notConnectedToInternet) }
        switch next {
        case .required: return http(request, 403, RWire.errorBody("attest_required", details: #"{"retryable":true}"#))
        case .invalid: return http(request, 403, RWire.errorBody("attest_invalid"))
        case .ok: return http(request, call.okStatus, call.okBody)
        case .refused: return http(request, 409, RWire.errorBody("pending_exists"))
        case .wrong2xx: return http(request, call.okStatus == 204 ? 200 : 202, Data("{}".utf8))
        case .undecodable: return http(request, call.okStatus, Data("{".utf8))
        case .redirect: return http(request, 302, Data(), headers: ["Location": "https://portal.example.net/"])
        }
    }
}

private final class RMachineAttester: DuoAttesting, @unchecked Sendable {
    struct Op { var name: String; var hash: Data; var token: DuoAttestationToken? }
    let probe: RMachineProbe
    private let lock = NSLock()
    let supported: Bool
    var keys: Set<String>
    let assertFails: Bool
    let attestFails: Bool
    private var made = 0
    private var asserted = 0
    private(set) var ops: [Op] = []
    private(set) var adopted: [(String, String)] = []

    init(probe: RMachineProbe, supported: Bool, hasKey: Bool, assertFails: Bool, attestFails: Bool) {
        self.probe = probe; self.supported = supported; self.keys = hasKey ? [RWire.credential.deviceID] : []
        self.assertFails = assertFails; self.attestFails = attestFails
    }

    var isSupported: Bool { supported }
    func hasKey(forDevice deviceID: String) -> Bool { lock.withLock { keys.contains(deviceID) } }

    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken {
        let hit = probe.event("attestNewKey")
        if hit && probe.honour { try Task.checkCancellation(); throw CancellationError() }
        return try lock.withLock {
            if attestFails { ops.append(Op(name: "attestNewKey", hash: clientDataHash, token: nil)); throw NSError(domain: "DCErrorDomain", code: 1) }
            made += 1
            let t = DuoAttestationToken(token: "QVRU\(made)", keyID: "key-\(made)", kind: .attestation)
            ops.append(Op(name: "attestNewKey", hash: clientDataHash, token: t))
            return t
        }
    }

    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken {
        let hit = probe.event("assert")
        if hit && probe.honour { try Task.checkCancellation(); throw CancellationError() }
        return try lock.withLock {
            if assertFails || !keys.contains(deviceID) { ops.append(Op(name: "assert", hash: clientDataHash, token: nil)); throw NSError(domain: "DCErrorDomain", code: 2) }
            asserted += 1
            let t = DuoAttestationToken(token: "QVNT\(asserted)", keyID: "key-of-\(deviceID)", kind: .assertion)
            ops.append(Op(name: "assert", hash: clientDataHash, token: t))
            return t
        }
    }

    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) { lock.withLock { adopted.append((keyID, deviceID)); keys.insert(deviceID) } }
    func forgetKeys(forDevice deviceID: String) { lock.withLock { _ = keys.remove(deviceID) } }
}

private struct RRun {
    var call: RCall
    var replies: [RReply]
    var supported: Bool
    var outcome: Result<String, Error>
    var session: RMachineSession
    var attester: RMachineAttester
    var probe: RMachineProbe

    var sends: [URLRequest] { session.mainRequests }
    var headerOf: [String?] { sends.map { $0.value(forHTTPHeaderField: "X-HD-Attest") } }
}

// MARK: - The tests

final class DuoAPIClientRobustnessTests: XCTestCase {
    private func makeClient(_ session: DuoHTTPSession, attester: DuoAttesting, credentials: DuoCredentialProviding? = nil) -> DuoAPIClient {
        DuoAPIClient(baseURL: RWire.base, client: RWire.client, credentials: credentials ?? RShiftingCredentials([RWire.credential]),
                     attester: attester, session: session)
    }

    private func catching(_ body: () async throws -> Void) async -> Error? {
        do { try await body(); return nil } catch { return error }
    }

    // MARK: Credentials (verify-auth M03, M11, M29, M56)

    /// M03: a rotate never so much as reads the identity, is sent once, and is not attested.
    func testRotateNeverReadsTheAmbientCredentialAndIsNeverRetriedOrAttested() async throws {
        let creds = RShiftingCredentials([RWire.credA])
        let attester = RRecordingAttester(supported: true, keys: [RWire.credR.deviceID])
        for reply in [RStubSession.Reply(status: 200, body: RWire.json(RWire.rotated)),
                      RStubSession.Reply(status: 403, body: RWire.errorBody("attest_required")),
                      RStubSession.Reply(status: 403, body: RWire.errorBody("attest_invalid")),
                      RStubSession.Reply(status: 503, body: RWire.errorBody("maintenance"))] {
            let session = RStubSession(replies: [reply, reply, reply])
            _ = await catching { _ = try await self.makeClient(session, attester: attester, credentials: creds).rotate(as: RWire.credR) }
            XCTAssertEqual(session.requests.count, 1)
            XCTAssertEqual(session.requests.first?.value(forHTTPHeaderField: "Authorization"), "Bearer \(RWire.credR.bearer)")
            XCTAssertNil(session.requests.first?.value(forHTTPHeaderField: "X-HD-Attest"))
            XCTAssertNil(session.requests.first?.value(forHTTPHeaderField: "Idempotency-Key"))
        }
        XCTAssertEqual(creds.reads, 0, "the ambient identity is never so much as read by a rotate")
        XCTAssertTrue(attester.log.isEmpty)
    }

    /// M11: an identity that answers A, B, A, B... on every read never mixes within one call: one
    /// bearer, and every bind and adoption names that bearer's device.
    func testACredentialThatChangesOnEveryReadNeverMixesWithinOneCall() async throws {
        let required = RStubSession.Reply(status: 403, body: RWire.errorBody("attest_required", details: #"{"retryable":true}"#))
        let invalid = RStubSession.Reply(status: 403, body: RWire.errorBody("attest_invalid"))
        let ok = RStubSession.Reply(status: 201, body: RWire.json(RWire.withResult))
        for script in [[required, invalid, required, required, ok], [invalid, invalid, required, ok], [ok]] {
            let session = RStubSession(replies: script)
            let creds = RShiftingCredentials([RWire.credA, RWire.credB])
            let attester = RRecordingAttester(supported: true, keys: [RWire.credA.deviceID, RWire.credB.deviceID])
            _ = try await makeClient(session, attester: attester, credentials: creds).redeemInvite(RWire.redeem, key: RWire.key(1))
            let mains = session.requests.filter { $0.url?.path == "/v1/invites/redeem" }
            let auths = Set(mains.map { $0.value(forHTTPHeaderField: "Authorization") ?? "none" })
            XCTAssertEqual(auths.count, 1, "one bearer for every attempt: \(auths)")
            let device = String(auths.first!.dropFirst(7).split(separator: ".")[0])
            XCTAssertTrue(attester.hashes.allSatisfy { $0.device == nil || $0.device == device }, "assertions only with the call's own device")
            for r in mains {
                guard let header = r.value(forHTTPHeaderField: "X-HD-Attest") else { continue }
                let challenge = String(header.split(separator: ".")[2])
                let expected = RWire.bind(challenge, "invite_redeem", device: device, body: r.httpBody!)
                XCTAssertTrue(attester.hashes.contains { $0.hash == expected }, "the header's bind was made over this attempt's bytes and device")
            }
            XCTAssertTrue(attester.log.filter { $0.hasPrefix("adopt") }.allSatisfy { $0.hasSuffix(":\(device)") }, "adopted for the device the bearer named: \(attester.log)")
            XCTAssertEqual(Set(mains.map { $0.httpBody! }).count, 1)
            XCTAssertEqual(Set(mains.compactMap { $0.value(forHTTPHeaderField: "Idempotency-Key") }), [RWire.key(1).value])
            for r in session.requests where r.url?.path == "/v1/attest/challenge" {
                XCTAssertNil(r.value(forHTTPHeaderField: "Authorization"), "a challenge never carries the bearer")
                XCTAssertNil(r.value(forHTTPHeaderField: "Idempotency-Key"))
                XCTAssertNil(r.httpBody)
            }
        }
    }

    /// M11: sixty calls at once, with the identity changing under them, each stay consistent.
    func testManyConcurrentCallsWithDifferentCredentialsEachStayConsistent() async throws {
        let issued = NSLock()
        var count = 0
        let session = RStubSession { request in
            if request.url?.path == "/v1/attest/challenge" {
                let n: Int = issued.withLock { count += 1; return count }
                return .init(status: 201, body: RWire.json(RWire.challenge(n)))
            }
            switch request.url?.path {
            case "/v1/invites/redeem": return .init(status: 201, body: RWire.json(RWire.withResult))
            case "/v1/duos": return .init(status: 201, body: RWire.json(RWire.created))
            case "/v1/devices/me/push": return .init(status: 204)
            default: return .init(status: 200, body: RWire.json(RWire.me))
            }
        }
        let creds = RShiftingCredentials([RWire.credA, RWire.credB, nil, RWire.credB, RWire.credA, RWire.credA])
        let attester = RRecordingAttester(supported: true)
        let client = makeClient(session, attester: attester, credentials: creds)
        await withTaskGroup(of: Void.self) { group in
            for i in 0..<60 {
                group.addTask {
                    switch i % 4 {
                    case 0: _ = try? await client.redeemInvite(RWire.redeem, key: RWire.key(i))
                    case 1: _ = try? await client.createDuo(RWire.createDuo, key: RWire.key(i))
                    case 2: try? await client.registerPush(RWire.registerPush, firstUpload: true)
                    default: _ = try? await client.me()
                    }
                }
            }
        }
        let hashes = attester.hashes.map(\.hash)
        for r in session.requests {
            let path = r.url!.path
            if path == "/v1/attest/challenge" { XCTAssertNil(r.value(forHTTPHeaderField: "Authorization")); continue }
            let auth = try XCTUnwrap(r.value(forHTTPHeaderField: "Authorization"), "no bearer request without one: \(path)")
            let device = String(auth.dropFirst(7).split(separator: ".")[0])
            XCTAssertTrue([RWire.credA.bearer, RWire.credB.bearer].contains(String(auth.dropFirst(7))))
            guard let header = r.value(forHTTPHeaderField: "X-HD-Attest") else { continue }
            let action = path == "/v1/invites/redeem" ? "invite_redeem" : path == "/v1/duos" ? "duo_create" : "push_register"
            let challenge = String(header.split(separator: ".")[2])
            XCTAssertTrue(hashes.contains(RWire.bind(challenge, action, device: device, body: r.httpBody!)), "\(path): bind names the bearer's own device")
        }
        for entry in attester.log where entry.hasPrefix("adopt:") {
            XCTAssertTrue(entry.hasSuffix(RWire.credA.deviceID) || entry.hasSuffix(RWire.credB.deviceID), entry)
        }
    }

    /// M29: a response that names no URL is not believed.
    func testAResponseWithNoURLIsMaintenance() async {
        struct Session: DuoHTTPSession {
            func data(for request: URLRequest) async throws -> (Data, URLResponse) {
                (RWire.json(RWire.me), RNilURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
        }
        let client = makeClient(Session(), attester: RRecordingAttester(supported: false))
        let error = await catching { _ = try await client.me() }
        XCTAssertEqual(error as? DuoTransportError, .maintenance(DuoErrorContext(httpStatus: 200)), "a response with no URL is not read")
    }

    /// M56: the mint's key belongs to the device the answer names, whatever the identity holds.
    func testTheMintsKeyIsAdoptedForTheNewDeviceEvenWithAnOldCredentialAround() async throws {
        let session = RStubSession(replies: [.init(status: 201, body: RWire.json(RWire.device))])
        let attester = RRecordingAttester(supported: true, keys: [RWire.credA.deviceID])
        _ = try await makeClient(session, attester: attester, credentials: RShiftingCredentials([RWire.credA])).createDevice(RWire.createDevice)
        XCTAssertEqual(attester.log.filter { $0.hasPrefix("adopt") }, ["adopt:key-1:\(RWire.device.deviceId)"])
        XCTAssertNil(session.requests.last?.value(forHTTPHeaderField: "Authorization"))
    }

    // MARK: The gate (verify-gate K1, K2, K4, K6 to K9, FIFO, the calls it never holds)

    /// K1: a hung assertion (the device has a key) stops holding the gate once its task is cancelled.
    func testAHungAssertionDoesNotHoldTheGatePastCancellation() async throws {
        let log = REventLog()
        let session = RPathSession(log: log)
        let attester = RSlotAttester(log: log)
        attester.setKey("K0", for: RWire.credential.deviceID)
        let hang = RLatch()
        attester.behaviour = { _ in if RProbe.call == "stuck" { await hang.wait() } }
        let client = makeClient(session, attester: attester)
        let stuck = Task { try await RProbe.$call.withValue("stuck") { try await client.redeemInvite(RWire.redeem, key: RWire.key(1)) } }
        while !log.all.contains(where: { $0.what == "attester.assert.start" }) { await Task.yield() }
        stuck.cancel()
        let r = await rWithin(1) { try await stuck.value }
        if case .failure(let e)? = r { XCTAssertTrue(e is CancellationError) } else { XCTFail("the hung assertion kept the call: \(String(describing: r))") }
        let next = await rWithin(1) { try await client.createDuo(RWire.createDuo, key: RWire.key(2)) }
        if case .success? = next {} else { XCTFail("the gate stayed held behind a hung assertion") }
        hang.release()
    }

    /// K2: a gated call waits for as long as the holder holds, not for some fixed time.
    func testAGatedCallWaitsForAsLongAsTheHolderHolds() async throws {
        let log = REventLog()
        let session = RPathSession(log: log)
        let held = session.hold(RCall.redeem.path)
        let client = makeClient(session, attester: RSlotAttester(log: log))
        let first = Task { try await RProbe.$call.withValue("first") { try await client.redeemInvite(RWire.redeem, key: RWire.key(1)) } }
        await held.arrived.wait()
        let second = Task { try await RProbe.$call.withValue("second") { try await client.createDuo(RWire.createDuo, key: RWire.key(2)) } }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertFalse(log.all.contains { $0.call == "second" }, "the second call started while the first still held the gate")
        held.release.release()
        _ = try await first.value
        _ = try await second.value
    }

    /// K4: a cancellation that lands just after the attester answered never resumes the caller
    /// twice (a crash) and never loses the answer.
    func testCancellationRightAfterTheAttesterAnswers() async throws {
        for i in 0..<1500 {
            let log = REventLog()
            let session = RPathSession(log: log)
            let attester = RSlotAttester(log: log)
            let box = RTaskBox()
            attester.behaviour = { _ in
                let task = box.task
                DispatchQueue.global().async { task?.cancel() }
            }
            let client = makeClient(session, attester: attester)
            let task = Task { () -> Bool in
                do { _ = try await client.createDuo(RWire.createDuo, key: RWire.key(i)); return true } catch { return false }
            }
            box.task = task
            _ = await task.value
        }
    }

    /// K6: while the second holder holds, a newly arriving gated call waits too.
    func testAfterAHandOffTheGateIsStillClosed() async throws {
        let log = REventLog()
        let session = RPathSession(log: log)
        let heldA = session.hold(RCall.redeem.path)
        let heldB = session.hold(RCall.createDuo.path)
        let client = makeClient(session, attester: RSlotAttester(log: log))
        let a = Task { try await RProbe.$call.withValue("A") { try await client.redeemInvite(RWire.redeem, key: RWire.key(1)) } }
        await heldA.arrived.wait()
        let b = Task { try await RProbe.$call.withValue("B") { try await client.createDuo(RWire.createDuo, key: RWire.key(2)) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        heldA.release.release()
        _ = try await a.value
        await heldB.arrived.wait()
        let d = Task { try await RProbe.$call.withValue("D") { try await client.reconnect(RWire.reconnect, key: RWire.key(3)) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(log.all.contains { $0.call == "D" }, "a new call went in while B held the gate")
        heldB.release.release()
        _ = try await b.value
        _ = try await d.value
    }

    /// K7: the mint is gated: it does not ask for its challenge while another attested call holds.
    func testTheMintWaitsAtTheGate() async throws {
        let log = REventLog()
        let session = RPathSession(log: log)
        let held = session.hold(RCall.redeem.path)
        let client = makeClient(session, attester: RSlotAttester(log: log))
        let first = Task { try await RProbe.$call.withValue("first") { try await client.redeemInvite(RWire.redeem, key: RWire.key(1)) } }
        await held.arrived.wait()
        let mint = Task { try await RProbe.$call.withValue("mint") { try await client.createDevice(RWire.createDevice) } }
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertFalse(log.all.contains { $0.call == "mint" }, "the mint asked for a challenge while the redeem held the gate")
        held.release.release()
        _ = try await first.value
        _ = try await mint.value
    }

    /// K8: the mint adopts its key before the next attested call can make one (one pending slot).
    func testTheMintAdoptsBeforeTheNextCallAttests() async throws {
        var missed = 0
        for i in 0..<300 {
            let log = REventLog()
            let session = RPathSession(log: log)
            let held = session.hold(RCall.createDevice.path)
            let attester = RSlotAttester(log: log)
            let client = makeClient(session, attester: attester)
            let mint = Task { try await client.createDevice(RWire.createDevice) }
            await held.arrived.wait()
            let next = Task { try await client.createDuo(RWire.createDuo, key: RWire.key(i)) }
            try await Task.sleep(nanoseconds: 2_000_000)
            held.release.release()
            _ = try await mint.value
            _ = try await next.value
            if attester.storedKey(for: RWire.device.deviceId) == nil { missed += 1 }
        }
        XCTAssertEqual(missed, 0, "the mint's key was not adopted \(missed) times in 300")
    }

    /// K9: the mint reads its answer and adopts its key before it leaves the gate, even when its
    /// answer is slow to read (a large unknown field): a mint that left first would let the next
    /// call make its key in that while, and with one pending slot the mint's key is never adopted.
    func testTheMintAdoptsInsideTheGateEvenWhenItsAnswerIsSlowToRead() async throws {
        var json = String(decoding: RWire.json(RWire.device), as: UTF8.self)
        json.removeLast()
        json += #","pad":""# + String(repeating: "x", count: 2_000_000) + #""}"#
        let log = REventLog()
        let session = RPathSession(log: log)
        session.script(RCall.createDevice.path, [(201, Data(json.utf8))])
        let held = session.hold(RCall.createDevice.path)
        let attester = RSlotAttester(log: log)
        let client = makeClient(session, attester: attester)
        let mint = Task { try await RProbe.$call.withValue("mint") { try await client.createDevice(RWire.createDevice) } }
        await held.arrived.wait()
        let next = Task { try await RProbe.$call.withValue("next") { try await client.createDuo(RWire.createDuo, key: RWire.key(1)) } }
        try await Task.sleep(nanoseconds: 50_000_000)
        held.release.release()
        _ = try await mint.value
        _ = try await next.value
        let events = log.all
        let adopt = events.firstIndex { $0.call == "mint" && $0.what.hasPrefix("adopt") } ?? Int.max
        let nextFirst = events.firstIndex { $0.call == "next" } ?? Int.max
        XCTAssertLessThan(adopt, nextFirst, "the next call started before the mint adopted its key")
        XCTAssertNotNil(attester.storedKey(for: RWire.device.deviceId), "the mint's key was never adopted: \(attester.adoptMissed)")
    }

    func testTheGateIsFirstInFirstOut() async throws {
        let log = REventLog()
        let session = RPathSession(log: log)
        let held = session.hold(RCall.redeem.path)
        let client = makeClient(session, attester: RSlotAttester(log: log))
        let first = Task { try await RProbe.$call.withValue("w0") { try await RCall.redeem.run(client, key: 0) } }
        await held.arrived.wait()
        var waiters: [Task<Void, Error>] = []
        for i in 1...5 {
            let call: RCall = [.createDuo, .reconnect, .pushFirst, .createDevice, .createDuo][i - 1]
            waiters.append(Task { try await RProbe.$call.withValue("w\(i)") { try await call.run(client, key: i) } })
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        held.release.release()
        _ = try await first.value
        for w in waiters { try await w.value }
        var order: [String] = []
        for e in log.all where !order.contains(e.call) { order.append(e.call) }
        XCTAssertEqual(order, ["w0", "w1", "w2", "w3", "w4", "w5"])
    }

    /// While a gated call holds the gate with an attester that never answers, every call that is
    /// not gated goes through at once, and a gated one waits.
    func testNonGatedCallsNeverWaitBehindAHungAttester() async throws {
        let log = REventLog()
        let session = RPathSession(log: log)
        let attester = RSlotAttester(log: log)
        let hang = RLatch()
        attester.behaviour = { _ in await hang.wait() }
        let client = makeClient(session, attester: attester)
        let holder = Task { try await RProbe.$call.withValue("holder") { try await client.redeemInvite(RWire.redeem, key: RWire.key(1)) } }
        while !log.all.contains(where: { $0.what == "attester.attestNewKey.start" }) { await Task.yield() }
        for call in [RCall.fetchChanges, .sendNudge, .pushRepeat, .rotate, .me] {
            let r = await rWithin(1) { try await call.run(client, key: 2) }
            switch r {
            case .success?: break
            case .failure(let e)?: XCTFail("\(call) failed: \(e)")
            case nil: XCTFail("\(call) waited behind the hung attester")
            }
        }
        let gated = await rWithin(0.3) { try await RCall.createDuo.run(client, key: 3) }
        XCTAssertNil(gated, "a gated call waits while the gate is held")
        hang.release()
        _ = try await holder.value
    }

    // MARK: The retry machine (verify-gate's model)

    private static func run(_ call: RCall, replies: [RReply], challenges: [RChallenge] = [], supported: Bool = true, hasKey: Bool = true,
                            assertFails: Bool = false, attestFails: Bool = false, cancelAt: Int? = nil, honour: Bool = true) async -> RRun {
        let probe = RMachineProbe()
        probe.cancelAt = cancelAt
        probe.honour = honour
        let session = RMachineSession(probe: probe, call: call, replies: replies, challenges: challenges)
        let attester = RMachineAttester(probe: probe, supported: supported, hasKey: hasKey, assertFails: assertFails, attestFails: attestFails)
        let client = DuoAPIClient(baseURL: RWire.base, client: RWire.client, credentials: RShiftingCredentials([RWire.credential]),
                                  attester: attester, session: session)
        let ready = RLatch()
        let task = Task { () -> Result<String, Error> in
            await ready.wait()
            do { try await call.run(client, key: 77); return .success("ok") } catch { return .failure(error) }
        }
        probe.task = task
        ready.release()
        let outcome = await task.value
        return RRun(call: call, replies: replies, supported: supported, outcome: outcome, session: session, attester: attester, probe: probe)
    }

    /// Every invariant the header comment and the brief state, checked on one run.
    private static func violations(_ r: RRun) -> [String] {
        var v: [String] = []
        let sends = r.sends
        let headers = r.headerOf
        let withHeader = headers.compactMap { $0 }
        let device = RWire.credential.deviceID
        let action = r.call.action!
        let bindsDevice = action != "device_create"
        if sends.count > 5 { v.append("sends \(sends.count) > 5") }
        if withHeader.count > 3 { v.append("header sends \(withHeader.count) > 3") }
        if sends.count - withHeader.count > 2 { v.append("headerless sends \(sends.count - withHeader.count) > 2") }
        if r.session.challengeRequests > 3 { v.append("challenges \(r.session.challengeRequests) > 3") }
        if !r.supported {
            if sends.count > 2 { v.append("unsupported phone sent \(sends.count) > 2") }
            if r.session.challengeRequests > 0 { v.append("unsupported phone asked for a challenge") }
            if !r.attester.ops.isEmpty { v.append("unsupported attester was asked to attest") }
        }
        if let first = sends.first {
            for (i, s) in sends.enumerated() {
                if s.httpBody != first.httpBody { v.append("send \(i) body differs") }
                if s.url != first.url { v.append("send \(i) URL differs") }
                if s.httpMethod != first.httpMethod { v.append("send \(i) method differs") }
                var a = s.allHTTPHeaderFields ?? [:], b = first.allHTTPHeaderFields ?? [:]
                a["X-HD-Attest"] = nil; b["X-HD-Attest"] = nil
                if a != b { v.append("send \(i) headers other than X-HD-Attest differ") }
            }
            if r.call == .redeem && first.value(forHTTPHeaderField: "Idempotency-Key") != RWire.key(77).value { v.append("no Idempotency-Key") }
        }
        let ids = withHeader.map { $0.split(separator: ".", maxSplits: 3).map(String.init) }
        for p in ids where p.count != 4 || p[0] != "v1" || p[1] != "ios" { v.append("malformed header \(p)") }
        let challengeIDs = ids.map { $0[2] }
        if Set(challengeIDs).count != challengeIDs.count { v.append("a challenge was reused: \(challengeIDs)") }
        for id in challengeIDs where !r.session.issued.contains(id) { v.append("header names a challenge never issued: \(id)") }
        for (i, s) in sends.enumerated() {
            guard let h = headers[i] else { continue }
            let p = h.split(separator: ".", maxSplits: 3).map(String.init)
            guard let op = r.attester.ops.last(where: { $0.token?.token == p[3] }) else { v.append("send \(i): token not from the attester"); continue }
            var bearerDevice: String?
            if let auth = s.value(forHTTPHeaderField: "Authorization") {
                bearerDevice = String(auth.dropFirst("Bearer ".count).split(separator: ".", maxSplits: 1)[0])
            }
            if bindsDevice && bearerDevice != device { v.append("send \(i): bearer device \(bearerDevice ?? "nil")") }
            let expected = RWire.bind(p[2], action, device: bindsDevice ? bearerDevice : nil, body: s.httpBody ?? Data())
            if op.hash != expected { v.append("send \(i): the bind is not over this challenge, action, device and body") }
        }
        let attestationTokens = withHeader.map { $0.split(separator: ".", maxSplits: 3).map(String.init)[3] }.filter { $0.hasPrefix("QVRU") }
        if Set(attestationTokens).count != attestationTokens.count { v.append("an attestation token was sent twice") }
        for (i, op) in r.attester.ops.enumerated() where op.name == "assert" && op.token == nil {
            if i + 1 < r.attester.ops.count {
                let next = r.attester.ops[i + 1]
                if next.name != "attestNewKey" || next.hash != op.hash { v.append("a failed assertion was not followed by a new key over the same bind") }
            } else if r.probe.cancelledAtEvent == nil {
                v.append("a failed assertion was not followed by attestNewKey")
            }
        }
        let adopted = r.attester.adopted
        if adopted.count > 1 { v.append("adopted twice: \(adopted)") }
        let lastHeader = headers.last ?? nil
        let lastToken = lastHeader.map { $0.split(separator: ".", maxSplits: 3).map(String.init)[3] }
        let lastWasAttestation = lastToken?.hasPrefix("QVRU") == true
        let lastWas2xx: Bool = {
            guard sends.count <= r.replies.count, let lastReply = r.replies.dropFirst(max(0, sends.count - 1)).first else { return false }
            return [.ok, .undecodable].contains(lastReply)
        }()
        if let (key, dev) = adopted.first {
            if !lastWasAttestation { v.append("adopted \(key) though the last send carried no attestation") }
            if !lastWas2xx { v.append("adopted \(key) without a 2xx") }
            if let op = r.attester.ops.last(where: { $0.token?.token == lastToken }), op.token?.keyID != key { v.append("adopted \(key), not the key of the accepted attestation") }
            let expectedDevice = bindsDevice ? device : RWire.device.deviceId
            if dev != expectedDevice { v.append("adopted for \(dev), not \(expectedDevice)") }
            if r.call == .createDevice, r.replies[sends.count - 1] == .undecodable { v.append("createDevice adopted on an answer it could not read") }
        } else if lastWasAttestation, lastWas2xx, r.probe.cancelledAtEvent == nil {
            let reply = r.replies[sends.count - 1]
            if !(r.call == .createDevice && reply == .undecodable) { v.append("a 2xx with an attestation was not adopted") }
        }
        for i in sends.indices.dropFirst() {
            let prevReply = r.replies[i - 1], prevHeader = headers[i - 1]
            if prevReply == .invalid, prevHeader == nil { v.append("a headerless attest_invalid was retried") }
            if prevReply == .invalid, let ph = prevHeader, ph.contains(".QVRU"), headers[i] != nil { v.append("an attest_invalid on an attestation was followed by another header") }
            if ![.required, .invalid].contains(prevReply) { v.append("send \(i) after a \(prevReply) answer") }
        }
        return v
    }

    /// The verifier's exhaustive model ran 81,648 combinations; this keeps every dimension (the
    /// four attested actions, refusal sequences closed by every kind of answer, every attester
    /// behaviour and every challenge plan) and trims the product to about 11,800 runs: every
    /// short sequence (up to two refusals) against every attester and challenge plan, and every
    /// long one (three to five refusals) against the fully capable attester, which is the one
    /// that reaches the worst case, and against one more attester and plan in turn, so each of
    /// them still meets the longest sequences.
    func testTheRetryMachineHoldsItsRulesAcrossEveryDimension() async {
        var prefixes: [[RReply]] = [[]]
        var frontier: [[RReply]] = [[]]
        for _ in 0..<5 { frontier = frontier.flatMap { [$0 + [.required], $0 + [.invalid]] }; prefixes += frontier }
        let terminals: [RReply?] = [nil, .ok, .refused, .wrong2xx, .undecodable, .redirect]
        func closed(_ list: [[RReply]]) -> [[RReply]] { list.flatMap { s in terminals.map { t in t.map { s + [$0] } ?? s } } }
        let short = closed(prefixes.filter { $0.count <= 2 })
        let long = closed(prefixes.filter { $0.count > 2 })
        let attesters: [(Bool, Bool, Bool, Bool)] = [(false, false, false, false)] +
            [true, false].flatMap { hasKey in [true, false].flatMap { assertFails in [true, false].map { attestFails in (true, hasKey, assertFails, attestFails) } } }
        let plans: [[RChallenge]] = [[], [.fail503], [.ok, .offline], [.ok, .ok, .fail429], [.garbage], [.ok, .garbage]]
        var combos: [((Bool, Bool, Bool, Bool), [RChallenge])] = []
        for a in attesters { for p in plans { combos.append((a, p)) } }
        let capable = combos.firstIndex { $0.0 == (true, true, false, false) && $0.1.isEmpty }!
        var work: [(RCall, [RReply], (Bool, Bool, Bool, Bool), [RChallenge])] = []
        for call in [RCall.createDevice, .redeem, .pushFirst, .createDuo] {
            for seq in short { for (a, p) in combos { work.append((call, seq, a, p)) } }
            for (i, seq) in long.enumerated() {
                let other = (i * 7 + 3) % combos.count == capable ? (i * 7 + 4) % combos.count : (i * 7 + 3) % combos.count
                for (a, p) in [combos[capable], combos[other]] { work.append((call, seq, a, p)) }
            }
        }
        var bad = 0
        var samples: [String] = []
        var maxSends = 0, maxChallenges = 0
        let started = Date()
        for (call, seq, (s, k, af, tf), plan) in work {
            let r = await Self.run(call, replies: seq, challenges: plan, supported: s, hasKey: k, assertFails: af, attestFails: tf)
            maxSends = max(maxSends, r.sends.count)
            maxChallenges = max(maxChallenges, r.session.challengeRequests)
            let v = Self.violations(r)
            if !v.isEmpty {
                bad += 1
                if samples.count < 8 { samples.append("\(call) \(String(seq.map(\.rawValue))) sup=\(s) key=\(k) assertFails=\(af) attestFails=\(tf) ch=\(plan.map(\.rawValue)): \(v)") }
            }
        }
        print("RETRY-MACHINE runs=\(work.count) violating=\(bad) maxSends=\(maxSends) maxChallenges=\(maxChallenges) seconds=\(Date().timeIntervalSince(started))")
        XCTAssertEqual(bad, 0, samples.joined(separator: "\n"))
        XCTAssertEqual(maxSends, 5, "the worst case is reached")
        XCTAssertEqual(maxChallenges, 3)
    }

    /// Cancellation at every await of the machine, with doubles that honour it and with doubles
    /// that ignore it and answer.
    func testCancellationAtEveryAwait() async {
        let scenarios: [(RCall, [RReply], Bool, Bool, Bool, [RChallenge])] = [
            (.redeem, [.required, .invalid, .required, .required, .required], true, false, false, []),
            (.redeem, [.invalid, .invalid, .required, .ok], true, false, false, []),
            (.redeem, [.ok], true, true, false, []),
            (.createDevice, [.required, .invalid, .required, .ok], false, false, false, []),
            (.pushFirst, [.required, .ok], false, false, false, []),
            (.createDuo, [.ok], false, false, true, []),
            (.redeem, [.required, .ok], true, false, false, [.ok, .fail503]),
        ]
        var runs = 0, bad = 0
        var samples: [String] = []
        for (call, replies, hasKey, assertFails, attestFails, plan) in scenarios {
            let clean = await Self.run(call, replies: replies, challenges: plan, hasKey: hasKey, assertFails: assertFails, attestFails: attestFails)
            for k in 1...max(1, clean.probe.events) {
                for honour in [true, false] {
                    let r = await Self.run(call, replies: replies, challenges: plan, hasKey: hasKey, assertFails: assertFails, attestFails: attestFails,
                                           cancelAt: k, honour: honour)
                    runs += 1
                    var v: [String] = []
                    let after = r.probe.afterCancel
                    if !after.isEmpty { v.append("work after the cancellation: \(after)") }
                    let cancelledEvent = r.probe.log.first { Int($0.split(separator: ":")[0])! == k } ?? "?"
                    switch r.outcome {
                    case .failure(let e) where e is CancellationError: break
                    case .success:
                        if !(cancelledEvent.hasSuffix("send") && !honour) { v.append("success after cancellation at \(cancelledEvent)") }
                    case .failure(let e):
                        if !(cancelledEvent.hasSuffix("send") && !honour) { v.append("\(e) instead of CancellationError at \(cancelledEvent)") }
                    }
                    if !r.attester.adopted.isEmpty {
                        let ok = cancelledEvent.hasSuffix("send") && !honour && (try? r.outcome.get()) != nil
                        if !ok { v.append("adopted \(r.attester.adopted) after cancellation at \(cancelledEvent)") }
                    }
                    let lastHeaderless = r.headerOf.last.map { $0 == nil } ?? false
                    if lastHeaderless, let last = r.probe.log.last(where: { $0.hasSuffix("send") }), Int(last.split(separator: ":")[0])! > k {
                        v.append("a headerless send after the cancellation")
                    }
                    v += Self.violations(r).filter { !$0.contains("not followed") && !$0.contains("was not adopted") }
                    if !v.isEmpty {
                        bad += 1
                        if samples.count < 8 { samples.append("\(call) \(String(replies.map(\.rawValue))) cancel@\(k)(\(cancelledEvent)) honour=\(honour): \(v)") }
                    }
                }
            }
        }
        print("CANCEL-AT-EVERY-AWAIT runs=\(runs) violating=\(bad)")
        XCTAssertGreaterThan(runs, 50)
        XCTAssertEqual(bad, 0, samples.joined(separator: "\n"))
    }
}
#endif
