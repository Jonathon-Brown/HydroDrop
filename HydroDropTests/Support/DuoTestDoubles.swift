#if DUO_V2
import XCTest
@testable import HydroDrop

// Test doubles for every seam, shared by every stage's tests. A stage adds test files of its
// own and never edits this one: needing a new double is a reason to ask the foundation, not
// to fork a copy.

// MARK: - Clock and random

struct TestClock: DuoClock {
    var now: Date
    var calendar: Calendar

    init(_ now: Date = Date(timeIntervalSince1970: 1_790_000_000), timeZone: TimeZone = TimeZone(secondsFromGMT: 0)!) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        self.now = now
        self.calendar = calendar
    }
}

/// Hands out 0, 1, 2, ... as bytes and a new UUID each time (…0001, …0002), so a test can say
/// exactly what a request carried.
final class TestRandom: DuoRandom, @unchecked Sendable {
    private let lock = NSLock()
    private var nextByte: UInt8 = 0
    private var nextUUID: UInt8 = 0

    func bytes(_ count: Int) -> [UInt8] {
        lock.lock(); defer { lock.unlock() }
        return (0..<count).map { _ in defer { nextByte &+= 1 }; return nextByte }
    }

    func uuid() -> UUID {
        lock.lock(); defer { lock.unlock() }
        nextUUID &+= 1
        return UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, nextUUID))
    }
}

// MARK: - The transport

/// A transport that does what the test says. Each endpoint has a closure; one not set throws
/// `DuoTransportError.offline`. Every call is recorded, in order.
final class FakeDuoTransport: DuoTransport, @unchecked Sendable {
    enum Call: Equatable {
        case createDevice(DuoWireCreateDeviceRequest)
        case attestChallenge
        case rotate
        case me
        case updateMe(DuoWireUpdateMeRequest)
        case deleteMe(DuoWireDeleteMeRequest, DuoIdempotencyKey)
        case registerPush(DuoWireRegisterPushRequest, firstUpload: Bool)
        case unregisterPush
        case createDuo(DuoWireCreateDuoRequest, DuoIdempotencyKey)
        case createInvite(duoID: String, DuoWireInvitePurpose, DuoIdempotencyKey)
        case peekInvite(code: String)
        case redeemInvite(DuoWireRedeemRequest, DuoIdempotencyKey)
        case reconnect(DuoWireReconnectRequest, DuoIdempotencyKey)
        case fetchDuo(id: String)
        case fetchChanges(duoID: String, since: Int64)
        case pushDayStatuses(duoID: String, DuoWirePutStatusesRequest)
        case sendNudge(duoID: String, DuoWireSendNudgeRequest)
        case leave(duoID: String, DuoIdempotencyKey)
        case block(duoID: String, DuoIdempotencyKey)
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    var calls: [Call] { lock.lock(); defer { lock.unlock() }; return recorded }
    private func record(_ call: Call) { lock.lock(); recorded.append(call); lock.unlock() }
    private func recordRotatedAs(_ credential: DuoCredential) { lock.lock(); rotatedAsRecorded.append(credential); lock.unlock() }
    func reset() { lock.lock(); recorded = []; rotatedAsRecorded = []; lock.unlock() }

    var onCreateDevice: ((DuoWireCreateDeviceRequest) throws -> DuoWireCreateDeviceResponse)?
    var onAttestChallenge: (() throws -> DuoWireAttestChallenge)?
    var onRotate: (() throws -> DuoWireRotateResponse)?
    /// Takes the credential the rotate was sent as, for a test that must see which bearer it
    /// carried. When set it is used instead of `onRotate`.
    var onRotateAs: ((DuoCredential) throws -> DuoWireRotateResponse)?
    private var rotatedAsRecorded: [DuoCredential] = []
    /// The credential each rotate was sent as, in order.
    var rotatedAs: [DuoCredential] { lock.lock(); defer { lock.unlock() }; return rotatedAsRecorded }
    var onMe: (() throws -> DuoWireGetMeResponse)?
    var onUpdateMe: ((DuoWireUpdateMeRequest) throws -> DuoWireMember)?
    var onDeleteMe: ((DuoWireDeleteMeRequest, DuoIdempotencyKey) throws -> Void)?
    var onRegisterPush: ((DuoWireRegisterPushRequest, Bool) throws -> Void)?
    var onUnregisterPush: (() throws -> Void)?
    var onCreateDuo: ((DuoWireCreateDuoRequest, DuoIdempotencyKey) throws -> DuoWireCreateDuoResponse)?
    var onCreateInvite: ((String, DuoWireInvitePurpose, DuoIdempotencyKey) throws -> DuoWireInvite)?
    var onPeekInvite: ((String) throws -> DuoWirePeekResponse)?
    var onRedeemInvite: ((DuoWireRedeemRequest, DuoIdempotencyKey) throws -> DuoWireChangesWithResult)?
    var onReconnect: ((DuoWireReconnectRequest, DuoIdempotencyKey) throws -> DuoWireReconnectResponse)?
    var onFetchDuo: ((String) throws -> DuoWireHeader)?
    var onFetchChanges: ((String, Int64) throws -> DuoWireChanges)?
    var onPushDayStatuses: ((String, DuoWirePutStatusesRequest) throws -> DuoWireChangesWithResult)?
    var onSendNudge: ((String, DuoWireSendNudgeRequest) throws -> DuoWireSendNudgeResult)?
    var onLeave: ((String, DuoIdempotencyKey) throws -> DuoWireLeaveResponse)?
    var onBlock: ((String, DuoIdempotencyKey) throws -> Void)?

    private func run<T>(_ call: Call, _ handler: (() throws -> T)?) throws -> T {
        record(call)
        guard let handler else { throw DuoTransportError.offline }
        return try handler()
    }

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { try run(.createDevice(request), onCreateDevice.map { h in { try h(request) } }) }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try run(.attestChallenge, onAttestChallenge) }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse {
        recordRotatedAs(credential)
        return try run(.rotate, onRotateAs.map { h in { try h(credential) } } ?? onRotate)
    }
    func me() async throws -> DuoWireGetMeResponse { try run(.me, onMe) }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { try run(.updateMe(request), onUpdateMe.map { h in { try h(request) } }) }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { try run(.deleteMe(request, key), onDeleteMe.map { h in { try h(request, key) } }) }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { try run(.registerPush(request, firstUpload: firstUpload), onRegisterPush.map { h in { try h(request, firstUpload) } }) }
    func unregisterPush() async throws { try run(.unregisterPush, onUnregisterPush) }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { try run(.createDuo(request, key), onCreateDuo.map { h in { try h(request, key) } }) }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { try run(.createInvite(duoID: duoID, purpose, key), onCreateInvite.map { h in { try h(duoID, purpose, key) } }) }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try run(.peekInvite(code: code), onPeekInvite.map { h in { try h(code) } }) }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { try run(.redeemInvite(request, key), onRedeemInvite.map { h in { try h(request, key) } }) }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { try run(.reconnect(request, key), onReconnect.map { h in { try h(request, key) } }) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try run(.fetchDuo(id: id), onFetchDuo.map { h in { try h(id) } }) }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try run(.fetchChanges(duoID: duoID, since: since), onFetchChanges.map { h in { try h(duoID, since) } }) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { try run(.pushDayStatuses(duoID: duoID, request), onPushDayStatuses.map { h in { try h(duoID, request) } }) }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try run(.sendNudge(duoID: duoID, request), onSendNudge.map { h in { try h(duoID, request) } }) }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { try run(.leave(duoID: duoID, key), onLeave.map { h in { try h(duoID, key) } }) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try run(.block(duoID: duoID, key), onBlock.map { h in { try h(duoID, key) } }) }
}

// MARK: - The HTTP session

/// Counts every request the app makes and answers as the test says (not at all, by default:
/// a connection error). A test of the whole wiring uses it to show nothing is sent.
final class RecordingSession: DuoHTTPSession, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    var requests: [URLRequest] { lock.lock(); defer { lock.unlock() }; return recorded }
    var respond: ((URLRequest) throws -> (Data, HTTPURLResponse))?

    private func record(_ request: URLRequest) { lock.lock(); recorded.append(request); lock.unlock() }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        record(request)
        guard let respond else { throw URLError(.notConnectedToInternet) }
        let (data, response) = try respond(request)
        return (data, response)
    }
}

// MARK: - Identity, attestation, DeviceCheck

final class FakeDuoIdentity: DuoIdentityProviding, @unchecked Sendable {
    var credential: DuoCredential?
    var installDay = "2026-09-01"
    var launch: DuoIdentityLaunch = .none
    private(set) var stored: [DuoCredential] = []
    private(set) var discardCount = 0
    private(set) var continued = 0
    private(set) var prepared = 0

    init(credential: DuoCredential? = nil) { self.credential = credential }

    func store(_ credential: DuoCredential) throws { stored.append(credential); self.credential = credential }
    func replaceSecret(_ secret: String, version: Int) throws { credential?.deviceSecret = secret; credential?.secretVersion = version }
    func discard() { discardCount += 1; credential = nil }
    func prepare() async -> DuoIdentityLaunch { prepared += 1; return launch }
    func continueAsRestored() async { continued += 1 }
}

final class FakeDuoAttester: DuoAttesting, @unchecked Sendable {
    var isSupported = true
    var keys: Set<String> = []
    private(set) var attestedNewKeys = 0
    private(set) var assertions: [String] = []
    private(set) var adopted: [(String, String)] = []

    func hasKey(forDevice deviceID: String) -> Bool { keys.contains(deviceID) }
    func attestNewKey(clientDataHash: Data) async throws -> DuoAttestationToken {
        attestedNewKeys += 1
        return DuoAttestationToken(token: "attestation-\(attestedNewKeys)", keyID: "key-\(attestedNewKeys)", kind: .attestation)
    }
    func assert(clientDataHash: Data, deviceID: String) async throws -> DuoAttestationToken {
        assertions.append(deviceID)
        return DuoAttestationToken(token: "assertion-\(assertions.count)", keyID: "key-\(deviceID)", kind: .assertion)
    }
    func adoptPendingKey(_ keyID: String, forDevice deviceID: String) { adopted.append((keyID, deviceID)); keys.insert(deviceID) }
    func forgetKeys(forDevice deviceID: String) { keys.remove(deviceID) }
}

struct FakeDuoDeviceCheck: DuoDeviceCheckProviding {
    var isSupported = true
    var value: String? = "RGV2aWNlQ2hlY2s="
    func token() async -> String? { value }
}

// MARK: - The services, as fakes

@MainActor
final class FakeSyncing: DuoSyncing {
    private(set) var calls: [String] = []
    private(set) var summaries: [DuoLogSummary] = []
    var backgroundResult = false

    func activate(logReader: DuoLogReading) { calls.append("activate") }
    func logChanged(_ summary: DuoLogSummary) { calls.append("logChanged"); summaries.append(summary) }
    func refresh() async { calls.append("refresh") }
    func flush() async { calls.append("flush") }
    func backgroundRefresh() async -> Bool { calls.append("backgroundRefresh"); return backgroundResult }
    func pushArrived(_ payload: DuoPushPayload) async { calls.append("pushArrived") }
    func sendNudge(_ preset: DuoNudgePreset, in duo: DuoState) async { calls.append("sendNudge:\(preset.rawValue)") }
}

@MainActor
final class FakeJoining: DuoJoining {
    private(set) var calls: [String] = []
    /// What each call answers, settable so a view's test can drive every state through this one
    /// double instead of forking a fake of its own (a copy would collide with the next stage's).
    var createResult: DuoState?
    var joinResult: DuoState?
    var peekResult: DuoPeek?
    var inviteResult: DuoInvite?
    var reconnectCodeResult: DuoInvite?
    var linkCodeResult: DuoInvite?
    var reconnectResult = true
    var acceptTermsResult = true

    func createDuo(named: String?, skin: String) async -> DuoState? { calls.append("createDuo:\(named ?? "nil"):\(skin)"); return createResult }
    func peek(code: String) async -> DuoPeek? { calls.append("peek:\(code)"); return peekResult }
    func receive(_ invite: DuoParsedInvite, now: Date) { calls.append("receive:\(invite.code)") }
    func discardPendingInvite() { calls.append("discardPendingInvite") }
    func join(_ invite: DuoPendingInvite, named: String?, skin: String) async -> DuoState? { calls.append("join:\(invite.code)"); return joinResult }
    func newInvite(for duo: DuoState) async -> DuoInvite? { calls.append("newInvite"); return inviteResult }
    func createReconnectCode(for duo: DuoState) async -> DuoInvite? { calls.append("createReconnectCode"); return reconnectCodeResult }
    func createLinkCode() async -> DuoInvite? { calls.append("createLinkCode"); return linkCodeResult }
    func reconnect(code: String) async -> Bool { calls.append("reconnect:\(code)"); return reconnectResult }
    func changeMyName(_ name: String?) async { calls.append("changeMyName:\(name ?? "nil")") }
    func acceptTerms() async -> Bool { calls.append("acceptTerms"); return acceptTermsResult }
}

@MainActor
final class FakeExiting: DuoExiting {
    private(set) var calls: [String] = []
    func leave(_ duo: DuoState) async { calls.append("leave") }
    func block(_ duo: DuoState) async { calls.append("block") }
    func clear(_ duo: DuoState) { calls.append("clear") }
    func deleteMyData() async -> Bool { calls.append("deleteMyData"); return true }
    func startFresh() { calls.append("startFresh") }
}

@MainActor
final class FakeOpQueue: DuoOpQueueing {
    private(set) var queued: [DuoQueuedOp] = []
    private(set) var drains = 0
    private(set) var discards = 0
    var pending: [DuoQueuedOp] { queued }
    func enqueue(_ op: DuoQueuedOp) { queued.append(op) }
    func drain() async { drains += 1 }
    func startMonitoring() {}
    func discardAll() { discards += 1; queued = [] }
    private(set) var identityBoundDiscards = 0
    func discardIdentityBound() { identityBoundDiscards += 1; queued.removeAll { $0.kind != .leave && $0.kind != .block } }
}

@MainActor
final class FakePush: DuoPushRegistering {
    private(set) var reasons: [DuoPushUploadReason] = []
    private(set) var tokens: [Data] = []
    private(set) var clearedLast = 0
    private(set) var finished: [(DuoQueuedOp, Bool)] = []
    func tokenArrived(_ token: Data, environment: DuoAPNsEnvironment) { tokens.append(token) }
    func reevaluate(_ reason: DuoPushUploadReason) { reasons.append(reason) }
    func noLiveDuoRemains() { clearedLast += 1 }
    func opFinished(_ op: DuoQueuedOp, succeeded: Bool) { finished.append((op, succeeded)) }
}

@MainActor
final class FakeAnnouncer: DuoAnnouncing {
    private(set) var delivered: [[DuoAnnouncement]] = []
    private(set) var removedFor: [UUID] = []
    var refusedKeys: [String] = []
    var remoteKeys: Set<String> = []
    private(set) var removedAll = 0

    func deliver(_ announcements: [DuoAnnouncement], now: Date) async -> [String] { delivered.append(announcements); return refusedKeys }
    func hasDeliveredRemote(forKey key: String) async -> Bool { remoteKeys.contains(key) }
    func removeDelivered(for duoID: UUID) { removedFor.append(duoID) }
    func removeAllDelivered() { removedAll += 1 }
}

@MainActor
final class FakeBackground: DuoBackgrounding {
    private(set) var scheduled = 0
    func scheduleRefresh() { scheduled += 1 }
}

@MainActor
final class FakeLogReader: DuoLogReading {
    var summary: DuoLogSummary
    init(_ summary: DuoLogSummary = .empty) { self.summary = summary }
    func read(now: Date) -> DuoLogSummary { summary }
}

/// Records every delay a service asks to wait, and returns at once.
@MainActor
final class SleepRecorder {
    private(set) var delays: [TimeInterval] = []
    func sleep(_ seconds: TimeInterval) async throws { delays.append(seconds) }
}

// MARK: - The kit

/// A real `DuoStore` over a throwaway cache with every service a fake. A stage's test swaps
/// the one service it is testing for the real class: `kit.dependencies.sync = DuoSyncEngine(dependencies: kit.dependencies)`.
@MainActor
struct DuoTestKit {
    let store: DuoStore
    let dependencies: DuoDependencies
    let transport: FakeDuoTransport
    let identity: FakeDuoIdentity
    let attester: FakeDuoAttester
    let secretStore: DuoMemorySecretStore
    let clock: TestClock
    let random: TestRandom
    let defaults: UserDefaults
    let sync = FakeSyncing()
    let joining = FakeJoining()
    let exiting = FakeExiting()
    let ops = FakeOpQueue()
    let push = FakePush()
    let announcer = FakeAnnouncer()
    let background = FakeBackground()
    let sleeper = SleepRecorder()

    /// `isSubscribed`, the skin and the window are what a test says they are.
    init(now: Date = Date(timeIntervalSince1970: 1_790_000_000), credential: DuoCredential? = nil, isSubscribed: Bool = false,
         secretStore: DuoMemorySecretStore = DuoMemorySecretStore()) {
        let suite = "DuoTestKit.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let cache = DuoCache(defaults: defaults)
        store = DuoStore(cache: cache, usesServer: true, reloadWidget: {})
        self.secretStore = secretStore
        clock = TestClock(now)
        random = TestRandom()
        transport = FakeDuoTransport()
        identity = FakeDuoIdentity(credential: credential)
        attester = FakeDuoAttester()
        dependencies = DuoDependencies(host: store, cache: cache, secrets: DuoSecrets(store: secretStore), clock: clock, random: random,
                                       client: DuoClientInfo(marketingVersion: "2.0", build: "57"), attester: attester,
                                       deviceCheck: FakeDuoDeviceCheck())
        dependencies.identity = identity
        dependencies.transport = transport
        dependencies.isSubscribed = { isSubscribed }
        dependencies.activeSkin = { "classic" }
        dependencies.knownSkins = ["classic", "forest", "grape", "sunrise", "midnight"]
        dependencies.sync = sync
        dependencies.joining = joining
        dependencies.exiting = exiting
        dependencies.ops = ops
        dependencies.push = push
        dependencies.announcer = announcer
        dependencies.background = background
        let sleeper = self.sleeper
        dependencies.sleep = { seconds in try await sleeper.sleep(seconds) }
        store.install(dependencies)
    }
}

// MARK: - Builders

enum DuoFixtures {
    static let duoID = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!

    static func duo(id: UUID = duoID, role: DuoRole = .owner, joined: Bool = true, ended: Bool = false,
                    statuses: [DuoDayStatus] = [], cursor: Int64 = 0, syncedOnce: Bool = true,
                    partner: String = "Sam", now: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> DuoState {
        DuoState(id: id, myRole: role, createdAt: now.addingTimeInterval(-86_400 * 5), ownerDisplayName: "Jo", partnerDisplayName: partner,
                 ownerSkin: "classic", partnerSkin: "forest", statuses: statuses, partnerHasJoined: joined,
                 endedAt: ended ? now : nil, joinedAt: joined ? now.addingTimeInterval(-86_400 * 4) : nil, cursor: cursor,
                 endedBy: ended ? .partner : nil, syncedOnce: syncedOnce)
    }

    static func status(_ role: DuoRole, _ day: String, bucket: Int, at: Date = Date(timeIntervalSince1970: 1_790_000_000)) -> DuoDayStatus {
        DuoDayStatus(role: role, day: day, goalMet: bucket == 100, progressBucket: bucket, updatedAt: at)
    }

    static func wireHeader(id: UUID = duoID, role: DuoRole = .owner, state: DuoWireDuoState = .active, seq: Int64 = 5) -> DuoWireHeader {
        DuoWireHeader(id: id.uuidString.lowercased(), myRole: role, state: state, createdAt: Date(timeIntervalSince1970: 1_789_000_000),
                      joinedAt: state == .pending ? nil : Date(timeIntervalSince1970: 1_789_100_000),
                      endedAt: state == .ended ? Date(timeIntervalSince1970: 1_789_900_000) : nil,
                      endedBy: state == .ended ? .partner : nil, ownerDisplayName: "Jo", ownerSkin: "classic",
                      partnerDisplayName: "Sam", partnerSkin: "forest", partnerLastWriteDay: "2026-09-27", partnerIsDemo: false,
                      invite: DuoWireHeaderInvite(hasOpenInvite: state == .pending, expiresAt: nil), seq: seq)
    }

    static func wireChanges(id: UUID = duoID, state: DuoWireDuoState = .active, cursor: Int64 = 5, full: Bool = false,
                            statuses: [DuoWireStatusRow] = [], nudges: [DuoWireNudge] = [], handled: [DuoWireHandled] = []) -> DuoWireChanges {
        DuoWireChanges(duo: wireHeader(id: id, state: state, seq: cursor), full: full, statuses: statuses, nudges: nudges, handled: handled, cursor: cursor)
    }

    static func wireRow(_ role: DuoRole, _ day: String, bucket: Int, ver: Int64) -> DuoWireStatusRow {
        DuoWireStatusRow(role: role, day: day, goalMet: bucket == 100, progressBucket: bucket, updatedAt: Date(timeIntervalSince1970: 1_790_000_000), ver: ver)
    }

    static func credential() -> DuoCredential {
        DuoCredential(memberID: "6d2a0000-0000-4000-8000-0000000000aa", deviceID: "6d2a0000-0000-4000-8000-0000000000bb",
                      deviceSecret: String(repeating: "s", count: 43), secretVersion: 1)
    }
}
#endif
