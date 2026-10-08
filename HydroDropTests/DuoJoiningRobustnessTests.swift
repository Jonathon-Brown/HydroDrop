#if DUO_V2
import CryptoKit
import XCTest
@testable import HydroDrop

// What the independent reviews of stage D found (2026-10-08), each pinned by a test that fails
// on the bug: the copy tables and Diagnostics counts the error lens asked for, the consent rules
// with the REAL `DuoIdentity` (an unreadable Keychain, a relaunch after a refused Reconnect), and
// the idempotency lens's model of the contract-v1 Worker with lost answers, cancellations and
// kills at every request, trimmed to a few hundred runs. Kept apart from `DuoJoiningServiceTests`
// so each file stays readable; every helper here is fileprivate.

// MARK: - Helpers

fileprivate final class RBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// What each attempt answers, in order: an error to throw, or nil for success; then success.
fileprivate final class RScript: @unchecked Sendable {
    private let box: RBox<[Error?]>
    init(_ outcomes: [Error?]) { box = RBox(outcomes) }
    func next() throws {
        var outcomes = box.value
        guard !outcomes.isEmpty else { return }
        let outcome = outcomes.removeFirst()
        box.value = outcomes
        if let outcome { throw outcome }
    }
}

/// Defaults that live in memory only, so hundreds of worlds leave no plist behind.
fileprivate final class RMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Any] = [:]
    init() { super.init(suiteName: "duo.stage-d.memory.unused")! }
    override func object(forKey defaultName: String) -> Any? { lock.lock(); defer { lock.unlock() }; return items[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { lock.lock(); items[defaultName] = value; lock.unlock() }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) { lock.lock(); items[defaultName] = nil; lock.unlock() }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? Bool) ?? false }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? Int) ?? 0 }
    override func double(forKey defaultName: String) -> Double { (object(forKey: defaultName) as? Double) ?? 0 }
    override func dictionaryRepresentation() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return items }
}

/// A Keychain that records every write and delete, and can be made unreadable, as it is before
/// the first unlock after a restart.
fileprivate final class RSpySecrets: DuoSecretStore, @unchecked Sendable {
    let base = DuoMemorySecretStore()
    private let lock = NSLock()
    private var entries: [String] = []
    private var unreadableNow = false
    var unreadable: Bool {
        get { lock.lock(); defer { lock.unlock() }; return unreadableNow }
        set { lock.lock(); unreadableNow = newValue; lock.unlock() }
    }
    var log: [String] { lock.lock(); defer { lock.unlock() }; return entries }
    func reset() { lock.lock(); entries = []; lock.unlock() }
    private func note(_ s: String) { lock.lock(); entries.append(s); lock.unlock() }
    func read(service: String, account: String) throws -> Data? {
        if unreadable, service == DuoSecrets.service { throw NSError(domain: NSOSStatusErrorDomain, code: -25308) }
        return try base.read(service: service, account: account)
    }
    func write(_ data: Data, service: String, account: String, accessibility: DuoSecretAccessibility) throws {
        note("W \(service)/\(account)")
        try base.write(data, service: service, account: account, accessibility: accessibility)
    }
    func delete(service: String, account: String) throws { note("D \(service)/\(account)"); try base.delete(service: service, account: account) }
    func deleteAll(service: String) throws { note("DA \(service)"); try base.deleteAll(service: service) }
}

fileprivate final class RCountingDeviceCheck: DuoDeviceCheckProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var isSupported: Bool { true }
    var calls: Int { lock.withLock { n } }
    func token() async -> String? { "rtok\(lock.withLock { () -> Int in n += 1; return n })" }
}

/// Holds the first and second calls to `createDuo` at their own gates; later ones go through.
fileprivate final class RTwoGates: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [Int: CheckedContinuation<Void, Never>] = [:]
    private var released: Set<Int> = []
    private var count = 0
    var entered: Int { lock.withLock { count } }
    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            count += 1
            let me = count
            if me > 2 || released.contains(me) { lock.unlock(); c.resume() } else { waiting[me] = c; lock.unlock() }
        }
    }
    func release(_ n: Int) {
        let c: CheckedContinuation<Void, Never>? = lock.withLock { released.insert(n); return waiting.removeValue(forKey: n) }
        c?.resume()
    }
}

/// `FakeDuoTransport` with `createDuo` and `updateMe` held at gates, only where a test sets one: a
/// gate nobody opens would turn a failing test into a hung one.
fileprivate final class RGatedTransport: DuoTransport, @unchecked Sendable {
    let base: FakeDuoTransport
    var createGate: RTwoGates?
    var updateMeGate: RTwoGates?
    var meGate: RTwoGates?
    var deviceGate: RTwoGates?
    init(_ base: FakeDuoTransport) { self.base = base }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse {
        if let createGate { await createGate.wait() }
        return try await base.createDuo(request, key: key)
    }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember {
        if let updateMeGate { await updateMeGate.wait() }
        return try await base.updateMe(request)
    }
    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse {
        if let deviceGate { await deviceGate.wait() }
        return try await base.createDevice(request)
    }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try await base.attestChallenge() }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { try await base.rotate(as: credential) }
    func me() async throws -> DuoWireGetMeResponse {
        if let meGate { await meGate.wait() }
        return try await base.me()
    }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { try await base.deleteMe(request, key: key) }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { try await base.registerPush(request, firstUpload: firstUpload) }
    func unregisterPush() async throws { try await base.unregisterPush() }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { try await base.createInvite(duoID: duoID, purpose: purpose, key: key) }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try await base.peekInvite(code: code) }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { try await base.redeemInvite(request, key: key) }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { try await base.reconnect(request, key: key) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try await base.fetchDuo(id: id) }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try await base.fetchChanges(duoID: duoID, since: since) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { try await base.pushDayStatuses(duoID: duoID, request) }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try await base.sendNudge(duoID: duoID, request) }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { try await base.leave(duoID: duoID, key: key) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try await base.block(duoID: duoID, key: key) }
}

/// An op queue whose drain sends everything it holds, or nothing (offline), recorded in order.
@MainActor
fileprivate final class RQueue: DuoOpQueueing {
    var queued: [DuoQueuedOp] = []
    let sendsOnDrain: Bool
    let events: RBox<[String]>
    private(set) var drains = 0
    private(set) var identityBoundDiscards = 0
    init(sendsOnDrain: Bool, events: RBox<[String]>) {
        self.sendsOnDrain = sendsOnDrain
        self.events = events
    }
    var pending: [DuoQueuedOp] { queued }
    func enqueue(_ op: DuoQueuedOp) { queued.append(op) }
    func drain() async {
        drains += 1
        events.value.append("drain")
        if sendsOnDrain { queued = [] }
    }
    func startMonitoring() {}
    func discardAll() { queued = [] }
    func discardIdentityBound() {
        identityBoundDiscards += 1
        queued.removeAll { $0.kind != .leave && $0.kind != .block }
    }
}

/// An identity with no credential whose launch changes what is allowed, as the real one does for
/// a phone with live cached duos and no credential (it makes the screen the disconnected question).
fileprivate final class RFlippingIdentity: DuoIdentityProviding, @unchecked Sendable {
    weak var host: DuoStore?
    var flipTo: DuoAvailability
    init(flipTo: DuoAvailability) { self.flipTo = flipTo }
    var credential: DuoCredential? { nil }
    var installDay: String { "2026-09-01" }
    func store(_ credential: DuoCredential) throws {}
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() {}
    func prepare() async -> DuoIdentityLaunch {
        let to = flipTo
        await MainActor.run { host?.availability = to }
        return .none
    }
    func continueAsRestored() async {}
}

fileprivate func rNames(_ calls: [FakeDuoTransport.Call]) -> [String] {
    calls.map { call in
        switch call {
        case .createDevice: return "createDevice"
        case .attestChallenge: return "attestChallenge"
        case .rotate: return "rotate"
        case .me: return "me"
        case .updateMe: return "updateMe"
        case .deleteMe: return "deleteMe"
        case .registerPush: return "registerPush"
        case .unregisterPush: return "unregisterPush"
        case .createDuo: return "createDuo"
        case .createInvite: return "createInvite"
        case .peekInvite: return "peekInvite"
        case .redeemInvite: return "redeemInvite"
        case .reconnect: return "reconnect"
        case .fetchDuo: return "fetchDuo"
        case .fetchChanges: return "fetchChanges"
        case .pushDayStatuses: return "pushDayStatuses"
        case .sendNudge: return "sendNudge"
        case .leave: return "leave"
        case .block: return "block"
        }
    }
}

fileprivate enum RF {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let expiry = Date(timeIntervalSince1970: 1_790_172_800)
    static let k = "ABCDEFGHJKMNPQRSTVWXYZ0123"
    static let createdID = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000c1")!
    static let joinedID = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000c2")!
    static let log = DuoLogSummary(totalsByDay: ["2026-09-21": 1000, "2026-09-20": 2000], goalML: 2000, earliestEntryDay: "2026-08-01")
    static let minted = DuoWireCreateDeviceResponse(memberId: "6d2a0000-0000-4000-8000-0000000000cc", deviceId: "6d2a0000-0000-4000-8000-0000000000dd",
                                                    deviceSecret: String(repeating: "t", count: 43), tier: .attested, supportId: "ABCD1234EFGH")
    static func header(_ id: UUID, role: DuoRole, state: DuoWireDuoState, seq: Int64) -> DuoWireHeader {
        DuoWireHeader(id: id.uuidString.lowercased(), myRole: role, state: state, createdAt: Date(timeIntervalSince1970: 1_789_900_000),
                      joinedAt: state == .pending ? nil : Date(timeIntervalSince1970: 1_789_950_000), endedAt: nil, endedBy: nil,
                      ownerDisplayName: "Jo", ownerSkin: "classic", partnerDisplayName: state == .pending ? nil : "Sam",
                      partnerSkin: state == .pending ? nil : "forest", partnerLastWriteDay: nil, partnerIsDemo: false,
                      invite: DuoWireHeaderInvite(hasOpenInvite: state == .pending, expiresAt: state == .pending ? expiry : nil), seq: seq)
    }
    static let wireInvite = DuoWireInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: expiry)
    static let createResponse = DuoWireCreateDuoResponse(duo: header(createdID, role: .owner, state: .pending, seq: 1), invite: wireInvite,
                                                         accepted: ["2026-09-21"], unchanged: [], rejected: [])
    static let joinedChanges = DuoWireChanges(duo: header(joinedID, role: .partner, state: .active, seq: 7), full: true, statuses: [], nudges: [],
                                              handled: [], cursor: 7)
    static let redeemResult = DuoWireChangesWithResult(changes: joinedChanges, accepted: [], unchanged: [], rejected: [])
    static func me(memberID: String = "6d2a0000-0000-4000-8000-0000000000aa", duos: [DuoWireHeader] = []) -> DuoWireGetMeResponse {
        DuoWireGetMeResponse(member: DuoWireMember(id: memberID, displayName: "Sam", skin: "forest", supportId: "WXYZ5678ABCD", tier: .attested, termsVersion: 1),
                             limits: DuoWireLimits(nudgesPerDay: 3, maxActiveDuos: 5), devices: [], duos: duos,
                             minClient: DuoWireMinClient(ios: "2.0", android: "1.1"))
    }
    static var pendingInvite: DuoPendingInvite { DuoPendingInvite(code: "H7K39QWX", k: k, receivedAt: now) }
    static func ctx(_ status: Int, _ details: DuoWireErrorDetails? = nil) -> DuoErrorContext {
        DuoErrorContext(httpStatus: status, requestID: "req-1", details: details)
    }
    static let general = "That did not work. Please try again. (ref req-1)"
    static let joiningPaused = "Joining is paused for a few minutes. Try again soon."
    static let servicePaused = "HydroDrop's duo service is not available right now. Your duo will catch up when it is."
    static let offline = "No connection right now. Try again in a bit."
    static let tooMany = "Too many tries. Wait a bit and try again."
    static let verify = "HydroDrop could not verify this phone. Try again in a few minutes."
    static let banned = "Duo Streaks are not available for this device. Contact support@hydrodrop.us."
    static let update = "Update HydroDrop to keep using Duo Streaks."
}

/// The shared kit with this stage's service, a person past the age and terms screens, and a
/// recorded background hold.
@MainActor
fileprivate struct RHarness {
    let kit: DuoTestKit
    let service: DuoJoiningService
    let events = RBox<[String]>([])

    init(credential: DuoCredential? = nil, subscribed: Bool = true) {
        let kit = DuoTestKit(credential: credential, isSubscribed: subscribed)
        if credential != nil { kit.identity.launch = .ready }
        kit.dependencies.cache.ageStatus = .allowed
        kit.dependencies.cache.acceptedTermsVersion = DuoProtocolConstants.termsVersion
        kit.store.latest = RF.log
        let service = DuoJoiningService(dependencies: kit.dependencies)
        let events = self.events
        service.holdInBackground = { _ in
            events.value.append("hold")
            return { events.value.append("release") }
        }
        kit.dependencies.joining = service
        self.kit = kit
        self.service = service
    }

    var t: FakeDuoTransport { kit.transport }
    var store: DuoStore { kit.store }
    var journal: [String] { kit.dependencies.cache.loadInflight(now: RF.now).entries.map(\.operation) }
    var errors: [String] { store.diagnostics.recentErrors.map(\.code) }

    func answerEverything() {
        let events = self.events
        t.onCreateDevice = { _ in events.value.append("createDevice"); return RF.minted }
        t.onCreateDuo = { _, _ in RF.createResponse }
        t.onRedeemInvite = { _, _ in RF.redeemResult }
        t.onReconnect = { _, _ in DuoWireReconnectResponse(memberId: "6d2a0000-0000-4000-8000-0000000000ff", supportId: "WXYZ5678ABCD", duos: [], supersededDevices: 1) }
        t.onPeekInvite = { _ in DuoWirePeekResponse(purpose: "invite", state: "open", expiresAt: RF.expiry, inviterDisplayName: "Alex", inviterSkin: "forest") }
        t.onCreateInvite = { _, _, _ in RF.wireInvite }
        t.onMe = { RF.me() }
        t.onUpdateMe = { _ in DuoWireMember(id: "m", supportId: "ABCD1234EFGH", tier: .attested, termsVersion: 1) }
        t.onFetchChanges = { _, _ in RF.joinedChanges }
    }
}

/// One launch over a real `DuoIdentity`: the store, the dependencies and the service are new, the
/// defaults, the Keychain and the identity's folder are what the last launch left.
@MainActor
fileprivate final class RRealPhone {
    let store: DuoStore
    let dependencies: DuoDependencies
    let identity: DuoIdentity
    let service: DuoJoiningService
    let ops = FakeOpQueue()

    init(defaults: UserDefaults, secrets: DuoSecretStore, directory: URL, transport: DuoTransport, deviceCheck: DuoDeviceCheckProviding = FakeDuoDeviceCheck(),
         attester: FakeDuoAttester = FakeDuoAttester()) {
        let cache = DuoCache(defaults: defaults)
        store = DuoStore(cache: cache, usesServer: true, reloadWidget: {})
        dependencies = DuoDependencies(host: store, cache: cache, secrets: DuoSecrets(store: secrets), clock: TestClock(RF.now), random: TestRandom(),
                                       client: DuoClientInfo(marketingVersion: "2.0", build: "57"), attester: attester, deviceCheck: deviceCheck)
        identity = DuoIdentity(dependencies: dependencies, directory: directory, holdInBackground: { _ in { } }, excludeFromBackup: { _ in })
        dependencies.identity = identity
        dependencies.transport = transport
        dependencies.ops = ops
        dependencies.isSubscribed = { true }
        service = DuoJoiningService(dependencies: dependencies)
        service.holdInBackground = { _ in { } }
        dependencies.joining = service
        store.install(dependencies)
        store.latest = RF.log
    }

    static func folder() -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("duo-d-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func consent(_ defaults: UserDefaults) {
        let cache = DuoCache(defaults: defaults)
        cache.ageStatus = .allowed
        cache.acceptedTermsVersion = DuoProtocolConstants.termsVersion
    }
}

// MARK: - The tests

@MainActor
final class DuoJoiningRobustnessTests: XCTestCase {

    // MARK: Copy tables (FD §4.4, §6.7), with what each failure leaves

    /// `create.existing`: the create's own failures, in the joining sheets' wording.
    func testEveryCreateFailureIsSaidInTheInviteWordsAndNotedOnce() async {
        let table: [(Error, String?)] = [
            (DuoTransportError.maintenance(RF.ctx(503)), RF.joiningPaused),
            (DuoTransportError.unreadable(httpStatus: 502, requestID: nil), RF.joiningPaused),
            (DuoTransportError.unreadable(httpStatus: 201, requestID: nil), RF.joiningPaused),
            (DuoTransportError.offline, RF.offline),
            (DuoTransportError.rateLimited(RF.ctx(429)), RF.tooMany),
            (DuoTransportError.nameRejected(RF.ctx(422)), "Please choose a different name."),
            (DuoTransportError.duoLimit(RF.ctx(409, DuoWireErrorDetails(max: 5, activeDuos: 5))), "You are already in 5 duos. Leave one first, then open the invite again."),
            (DuoTransportError.attestRequired(RF.ctx(403)), RF.verify),
            (DuoTransportError.banned(RF.ctx(403)), RF.banned),
            (DuoTransportError.upgradeRequired(RF.ctx(426)), RF.update),
            (DuoTransportError.schema(RF.ctx(400)), RF.general),
            (CancellationError(), nil),
        ]
        for (error, words) in table {
            let h = RHarness(credential: DuoFixtures.credential())
            h.answerEverything()
            h.t.onCreateDuo = { _, _ in throw error }
            let created = await h.service.createDuo(named: "Jo", skin: "classic")
            XCTAssertNil(created)
            XCTAssertEqual(h.store.sheetError, words, "\(error)")
            XCTAssertEqual(h.errors.count, error is CancellationError ? 0 : 1, "noted once, a cancel never: \(error)")
            XCTAssertFalse(h.store.isWorking, "\(error)")
        }
    }

    /// A failed mint is noted and said, whichever flow it was minting for, and its hold is given back.
    func testAFailedMintIsNotedAndSaidInEveryFlow() async {
        let table: [(Error, String?)] = [
            (DuoTransportError.banned(RF.ctx(403)), RF.banned),
            (DuoTransportError.rateLimited(RF.ctx(429)), RF.tooMany),
            (DuoTransportError.attestInvalid(RF.ctx(403)), RF.verify),
            (DuoTransportError.maintenance(RF.ctx(503)), RF.joiningPaused),
            (DuoTransportError.offline, RF.offline),
            (CancellationError(), nil),
        ]
        for flow in ["create", "join", "reconnect"] {
            for (error, words) in table {
                let h = RHarness()
                h.answerEverything()
                let events = h.events
                h.t.onCreateDevice = { _ in events.value.append("createDevice"); throw error }
                switch flow {
                case "create": _ = await h.service.createDuo(named: "Jo", skin: "classic")
                case "join": _ = await h.service.join(RF.pendingInvite, named: "Jo", skin: "classic")
                default: _ = await h.service.reconnect(code: "H7K39QWX")
                }
                XCTAssertEqual(h.store.sheetError, words, "\(flow) \(error)")
                XCTAssertEqual(h.errors.count, error is CancellationError ? 0 : 1, "\(flow) \(error)")
                XCTAssertEqual(rNames(h.t.calls), ["createDevice"], "nothing after a mint that failed: \(flow)")
                XCTAssertTrue(h.kit.identity.stored.isEmpty)
                XCTAssertEqual(h.events.value, ["hold", "createDevice", "release"], "\(flow) \(error)")
                XCTAssertFalse(h.store.isWorking)
            }
        }
    }

    func testTheMintAndItsSaveAreHeldAgainstSuspensionAndNothingElseIs() async {
        let h = RHarness()
        h.answerEverything()
        _ = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertEqual(h.events.value, ["hold", "createDevice", "release"])
        XCTAssertEqual(h.kit.identity.stored.count, 1, "the save happened inside the hold")
        // An identity that exists needs no hold.
        let existing = RHarness(credential: DuoFixtures.credential())
        existing.answerEverything()
        _ = await existing.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertEqual(existing.events.value, [])
    }

    func testEveryPeekFailureIsSaidInTheInviteWordsAndACancelSaysNothing() async {
        let table: [(Error, String?)] = [
            (DuoTransportError.inviteUnknown(RF.ctx(404)), "That invite is no longer open. Ask for a new one."),
            (DuoTransportError.blocked(RF.ctx(403)), "This person can't be paired with you."),
            (DuoTransportError.maintenance(RF.ctx(503)), RF.joiningPaused),
            (DuoTransportError.unreadable(httpStatus: 500, requestID: nil), RF.joiningPaused),
            (DuoTransportError.rateLimited(RF.ctx(429)), RF.tooMany),
            (DuoTransportError.offline, RF.offline),
            (DuoTransportError.schema(RF.ctx(400)), RF.general),
            (CancellationError(), nil),
        ]
        for (error, words) in table {
            let h = RHarness()
            h.t.onPeekInvite = { _ in throw error }
            let peek = await h.service.peek(code: "H7K39QWX")
            XCTAssertNil(peek)
            XCTAssertEqual(h.store.sheetError, words, "\(error)")
            XCTAssertEqual(h.errors.count, error is CancellationError ? 0 : 1, "\(error)")
            XCTAssertEqual(h.t.calls.count, 1)
        }
    }

    /// The code makers speak on the Duo screen's sheets, not the joining ones: a 503 is the service
    /// being paused, not joining.
    func testEveryNewCodeFailureIsSaidInTheGeneralWordsAndItsWorkEnds() async {
        let table: [(Error, String?)] = [
            (DuoTransportError.maintenance(RF.ctx(503)), RF.servicePaused),
            (DuoTransportError.unreadable(httpStatus: 502, requestID: nil), RF.servicePaused),
            (DuoTransportError.offline, RF.offline),
            (DuoTransportError.rateLimited(RF.ctx(429)), RF.tooMany),
            (DuoTransportError.conflict(RF.ctx(409)), RF.general),
            (DuoTransportError.notPartner(RF.ctx(403)), RF.general),
            (DuoTransportError.targetActive(RF.ctx(409)), RF.general),
            (DuoTransportError.deviceLimit(RF.ctx(409, DuoWireErrorDetails(max: 5))), RF.general),
            (DuoTransportError.upgradeRequired(RF.ctx(426)), RF.update),
            (CancellationError(), nil),
        ]
        for which in ["newInvite", "reconnectCode", "linkCode"] {
            for (error, words) in table {
                let h = RHarness(credential: DuoFixtures.credential())
                var duo = DuoFixtures.duo(joined: which != "newInvite")
                duo.partnerLastWriteDay = "2026-09-10"
                h.store.upsert(duo)
                h.t.onCreateInvite = { _, _, _ in throw error }
                switch which {
                case "newInvite": _ = await h.service.newInvite(for: duo)
                case "reconnectCode": _ = await h.service.createReconnectCode(for: duo)
                default: _ = await h.service.createLinkCode()
                }
                XCTAssertEqual(rNames(h.t.calls), ["createInvite"], "\(which)")
                XCTAssertEqual(h.store.sheetError, words, "\(which) \(error)")
                XCTAssertEqual(h.errors.count, error is CancellationError ? 0 : 1, "\(which) \(error)")
                XCTAssertFalse(h.store.isWorking, "\(which) \(error)")
            }
        }
    }

    func testEveryReconnectEndsItsWork() async {
        for error in [DuoTransportError.memberNotFresh(RF.ctx(409)), .maintenance(RF.ctx(503)), .offline] {
            let h = RHarness(credential: DuoFixtures.credential())
            h.answerEverything()
            h.t.onReconnect = { _, _ in throw error }
            _ = await h.service.reconnect(code: "H7K39QWX")
            XCTAssertFalse(h.store.isWorking, "\(error)")
        }
        let ok = RHarness(credential: DuoFixtures.credential())
        ok.answerEverything()
        let reconnected = await ok.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(reconnected)
        XCTAssertFalse(ok.store.isWorking)
    }

    // MARK: The journal

    func testTheClientsOwnNoCredentialNeverSettlesARecord() async {
        // Status 0: nothing left the phone, so nothing was judged.
        let h = RHarness(credential: DuoFixtures.credential())
        h.t.onCreateDuo = { _, _ in throw DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0)) }
        _ = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertEqual(h.journal, ["POST /duos"])
        XCTAssertEqual(h.kit.identity.discardCount, 0)
    }

    // MARK: The terms

    func testAcceptWhileTheRestoreQuestionIsUpSendsAndSaysNothing() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.store.needsTerms = true
        h.kit.identity.launch = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        let accepted = await h.service.acceptTerms()
        XCTAssertFalse(accepted)
        XCTAssertNil(h.store.sheetError, "the screen asks the restore question")
        XCTAssertTrue(h.t.calls.isEmpty)
        XCTAssertTrue(h.store.needsTerms)
        h.kit.identity.launch = .unavailable
        _ = await h.service.acceptTerms()
        XCTAssertEqual(h.store.sheetError, "That did not work. Please try again.")
    }

    func testAnAcceptThatWorksTakesTheEarlierFailuresWordsAway() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.store.needsTerms = true
        let script = RScript([DuoTransportError.offline])
        h.t.onUpdateMe = { _ in try script.next(); return DuoWireMember(id: "m", supportId: "ABCD1234EFGH", tier: .attested, termsVersion: 1) }
        let first = await h.service.acceptTerms()
        XCTAssertFalse(first)
        XCTAssertEqual(h.store.sheetError, RF.offline)
        let second = await h.service.acceptTerms()
        XCTAssertTrue(second)
        XCTAssertNil(h.store.sheetError)
        XCTAssertFalse(h.store.needsTerms)
    }

    func testAcceptAndCreateNeverRunAtOnce() async {
        // An Accept whose PATCH is out: a Create now could meet 428 again, so it is refused.
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        let gated = RGatedTransport(h.t)
        gated.updateMeGate = RTwoGates()
        h.kit.dependencies.transport = gated
        let service = h.service
        let accept = Task { await service.acceptTerms() }
        for _ in 0..<1_000 where gated.updateMeGate!.entered == 0 { await Task.yield() }
        let created = await service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(created)
        XCTAssertTrue(rNames(h.t.calls).allSatisfy { $0 == "updateMe" }, "nothing else sent while the Accept is out: \(rNames(h.t.calls))")
        gated.updateMeGate!.release(1)
        let accepted = await accept.value
        XCTAssertTrue(accepted)

        // And the other way round: an Accept during a Create's request is refused.
        let other = RHarness(credential: DuoFixtures.credential())
        other.answerEverything()
        let gatedCreate = RGatedTransport(other.t)
        gatedCreate.createGate = RTwoGates()
        other.kit.dependencies.transport = gatedCreate
        let otherService = other.service
        let create = Task { await otherService.createDuo(named: "Jo", skin: "classic") }
        for _ in 0..<1_000 where gatedCreate.createGate!.entered == 0 { await Task.yield() }
        let acceptedDuring = await otherService.acceptTerms()
        XCTAssertFalse(acceptedDuring)
        XCTAssertFalse(rNames(other.t.calls).contains("updateMe"))
        gatedCreate.createGate!.release(1)
        _ = await create.value
    }

    // MARK: The pending invite and the busy guard

    func testAPendingInviteKeptInAnotherSpellingIsDroppedByTheJoin() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.service.receive(DuoParsedInvite(code: "h7k3-9qwx", k: nil), now: RF.now)
        let pending = h.store.pendingInvite!
        let joined = await h.service.join(pending, named: "Sam", skin: "classic")
        XCTAssertNotNil(joined)
        XCTAssertNil(h.store.pendingInvite)
    }

    func testTheBusyGuardDoesNotOutliveAWipe() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        let gated = RGatedTransport(h.t)
        let gate = RTwoGates()
        gated.createGate = gate
        h.kit.dependencies.transport = gated
        let service = h.service
        let store = h.store
        let first = Task { await service.createDuo(named: "Jo", skin: "classic") }
        for _ in 0..<1_000 where gate.entered == 0 { await Task.yield() }
        store.resetLocalState()
        // The person's first tap after Delete my Duo data goes, though the dropped request is out.
        RHarness.reconsent(h)
        let second = Task { await service.createDuo(named: "Jo", skin: "classic") }
        for _ in 0..<1_000 where gate.entered < 2 { await Task.yield() }
        guard gate.entered == 2 else {
            // Let both go before failing, so a refused second tap fails the test rather than hanging it.
            gate.release(1)
            gate.release(2)
            _ = await first.value
            _ = await second.value
            return XCTFail("the second tap after the wipe was refused")
        }
        XCTAssertTrue(store.isWorking)
        // The dropped first one ends: it neither puts `isWorking` down nor frees the guard of the second.
        gate.release(1)
        let dropped = await first.value
        XCTAssertNil(dropped)
        XCTAssertTrue(store.isWorking, "the wiped flow leaves the newer one's spinner alone")
        let third = await service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(third, "the second is still out, so a third tap is refused")
        XCTAssertEqual(gate.entered, 2)
        gate.release(2)
        let made = await second.value
        XCTAssertNotNil(made)
        XCTAssertFalse(store.isWorking)
        XCTAssertEqual(store.duos.count, 1)
    }

    // MARK: Consent: a refusal, the restore question, a disconnected phone

    func testARefusedPersonHoldingAnIdentityMakesNoCodeAndSendsNoName() async throws {
        for keychainOnly in [true, false] {
            let h = RHarness(credential: DuoFixtures.credential())
            h.answerEverything()
            if keychainOnly { try h.kit.dependencies.secrets.markAgeRefused() } else { h.kit.dependencies.cache.ageStatus = .refused }
            var silent = DuoFixtures.duo()
            silent.partnerLastWriteDay = "2026-09-10"
            h.store.upsert(DuoFixtures.duo(id: RF.createdID, joined: false))
            h.store.upsert(silent)
            _ = await h.service.newInvite(for: DuoFixtures.duo(id: RF.createdID, joined: false))
            _ = await h.service.createReconnectCode(for: silent)
            _ = await h.service.createLinkCode()
            await h.service.changeMyName("Kid")
            XCTAssertTrue(h.t.calls.isEmpty, "keychain only \(keychainOnly)")
            XCTAssertTrue(h.kit.ops.queued.isEmpty)
            XCTAssertEqual(h.store.myDisplayName, "", "nothing is kept for someone who was refused")
            // And the consent taps, through the service directly, with the cache still saying allowed.
            let created = await h.service.createDuo(named: "Kid", skin: "classic")
            XCTAssertNil(created)
            XCTAssertTrue(h.t.calls.isEmpty)
        }
    }

    func testANameIsQueuedOnlyForAReadyIdentityThatMayWrite() async {
        let launches: [(DuoIdentityLaunch, DuoAvailability, Bool)] = [
            (.ready, .available, true),
            (.needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo")), .available, false),
            (.unavailable, .available, false),
            (.disconnected, .disconnected, false),
            (.ready, .upgradeRequired, false),
            (.ready, .banned, false),
        ]
        for (launch, availability, queued) in launches {
            let h = RHarness(credential: DuoFixtures.credential())
            h.kit.identity.launch = launch
            h.store.availability = availability
            await h.service.changeMyName("New Owner")
            XCTAssertEqual(h.kit.ops.queued.count, queued ? 1 : 0, "\(launch) \(availability)")
            XCTAssertEqual(h.store.myDisplayName, "New Owner", "the name stays on this phone either way")
            XCTAssertTrue(h.t.calls.isEmpty)
        }
    }

    func testADisconnectedPhoneNeverPeeksWithItsRevokedBearer() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.store.availability = .disconnected
        let peek = await h.service.peek(code: "H7K39QWX")
        XCTAssertNil(peek)
        XCTAssertTrue(h.t.calls.isEmpty, "a revoked bearer earns only device_revoked")
        XCTAssertNil(h.store.sheetError, "the Duo screen already says the phone was disconnected")
        // The throwaway a Reconnect minted is a fresh member: its peek goes.
        h.kit.identity.credential = DuoCredential(memberID: RF.minted.memberId, deviceID: RF.minted.deviceId, deviceSecret: RF.minted.deviceSecret)
        h.kit.dependencies.cache.throwawayDeviceID = RF.minted.deviceId
        let again = await h.service.peek(code: "H7K39QWX")
        XCTAssertNotNil(again)
        XCTAssertEqual(rNames(h.t.calls), ["peekInvite"])
    }

    /// Asking the identity may change what is allowed, and writes are judged again after it.
    func testWritesAreJudgedAgainAfterTheLaunchIsAsked() async {
        for flipTo in [DuoAvailability.disconnected, .banned, .upgradeRequired] {
            let h = RHarness()
            h.answerEverything()
            let flipping = RFlippingIdentity(flipTo: flipTo)
            flipping.host = h.store
            h.kit.dependencies.identity = flipping
            let created = await h.service.createDuo(named: "Jo", skin: "classic")
            let joined = await h.service.join(RF.pendingInvite, named: "Jo", skin: "classic")
            XCTAssertNil(created)
            XCTAssertNil(joined)
            XCTAssertTrue(h.t.calls.isEmpty, "\(flipTo): nothing minted after the launch said no")
        }
    }

    // MARK: The real identity

    /// The Keychain cannot be read (the first unlock after a restart): the credential reads as none,
    /// yet a mint would put a second identity beside the real one. Nothing is sent, attested, asked of
    /// DeviceCheck or written; once it reads, the real credential goes.
    func testAnUnreadableKeychainNeverMintsAndTheRealCredentialGoesOnceItReads() async throws {
        let defaults = RMemoryDefaults()
        RRealPhone.consent(defaults)
        let secrets = RSpySecrets()
        let folder = RRealPhone.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = FakeDuoTransport()
        transport.onCreateDevice = { _ in RF.minted }
        transport.onCreateDuo = { _, _ in RF.createResponse }
        let seed = RRealPhone(defaults: defaults, secrets: secrets.base, directory: folder, transport: transport)
        let real = DuoFixtures.credential()
        try seed.identity.store(real)
        secrets.unreadable = true
        secrets.reset()
        let deviceCheck = RCountingDeviceCheck()
        let attester = FakeDuoAttester()
        let phone = RRealPhone(defaults: defaults, secrets: secrets, directory: folder, transport: transport, deviceCheck: deviceCheck, attester: attester)
        for _ in 0..<3 {
            let created = await phone.service.createDuo(named: "Jo", skin: "classic")
            XCTAssertNil(created)
            XCTAssertEqual(phone.store.sheetError, "That did not work. Please try again.")
            let joined = await phone.service.join(RF.pendingInvite, named: "Jo", skin: "classic")
            XCTAssertNil(joined)
            let reconnected = await phone.service.reconnect(code: "H7K39QWX")
            XCTAssertFalse(reconnected)
        }
        XCTAssertTrue(transport.calls.isEmpty, "nothing sent: \(rNames(transport.calls))")
        XCTAssertEqual(deviceCheck.calls, 0)
        XCTAssertEqual(attester.attestedNewKeys, 0)
        XCTAssertTrue(secrets.log.isEmpty, "nothing written: \(secrets.log)")
        secrets.unreadable = false
        let created = await phone.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNotNil(created)
        XCTAssertEqual(rNames(transport.calls), ["createDuo"], "the real credential, no second identity")
    }

    /// D68: a refused Reconnect, then iOS ends the app. The throwaway stays the stored credential,
    /// remembered across the relaunch, so the phone reads as disconnected again (its cached duos are
    /// another member's) and the next tap reuses it: no second mint, which would cost the day.
    func testARefusedReconnectThenARelaunchStaysDisconnectedAndReusesTheThrowaway() async throws {
        let defaults = RMemoryDefaults()
        RRealPhone.consent(defaults)
        let secrets = DuoMemorySecretStore()
        let folder = RRealPhone.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = FakeDuoTransport()
        transport.onCreateDevice = { _ in RF.minted }
        let script = RScript([DuoTransportError.inviteUnknown(RF.ctx(404))])
        transport.onReconnect = { _, _ in
            try script.next()
            return DuoWireReconnectResponse(memberId: DuoFixtures.credential().memberID, supportId: "WXYZ5678ABCD",
                                            duos: [RF.header(DuoFixtures.duoID, role: .owner, state: .active, seq: 20)], supersededDevices: 1)
        }
        transport.onMe = { RF.me(memberID: DuoFixtures.credential().memberID) }

        let first = RRealPhone(defaults: defaults, secrets: secrets, directory: folder, transport: transport)
        try first.identity.store(DuoFixtures.credential())            // the identity another phone then took over
        first.store.upsert(DuoFixtures.duo(cursor: 9, syncedOnce: true))
        first.store.availability = .disconnected                       // its first read met device_revoked
        let refused = await first.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(refused)
        XCTAssertEqual(first.identity.credential?.deviceID, RF.minted.deviceId, "the throwaway is stored")
        XCTAssertEqual(DuoCache(defaults: defaults).throwawayDeviceID, RF.minted.deviceId)

        let relaunched = RRealPhone(defaults: defaults, secrets: secrets, directory: folder, transport: transport)
        XCTAssertEqual(relaunched.store.availability, .disconnected, "still disconnected from those duos after a relaunch")
        XCTAssertEqual(relaunched.store.duos.map(\.hasEnded), [false], "the cached duo is still live")
        let launch = await relaunched.identity.prepare()
        XCTAssertEqual(launch, .ready)
        let reconnected = await relaunched.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(reconnected)
        XCTAssertEqual(rNames(transport.calls).filter { $0 == "createDevice" }.count, 1, "the same throwaway, no second mint")
        XCTAssertEqual(relaunched.identity.credential?.deviceID, RF.minted.deviceId)
        XCTAssertEqual(relaunched.identity.credential?.memberID, DuoFixtures.credential().memberID)
        XCTAssertNil(DuoCache(defaults: defaults).throwawayDeviceID, "a throwaway no more")
        XCTAssertEqual(relaunched.store.availability, .available)
        XCTAssertEqual(relaunched.store.duo(DuoFixtures.duoID)?.syncedOnce, false)

        // And the launch after that is an ordinary one.
        let third = RRealPhone(defaults: defaults, secrets: secrets, directory: folder, transport: transport)
        XCTAssertNotEqual(third.store.availability, .disconnected)
    }

    /// A throwaway that goes on to carry a Create or a Join of its own is the person's identity from
    /// then on: left marked, the next launch would take its own new duo for another member's and
    /// read the phone as disconnected.
    func testAThrowawayThatCarriesACreateOrAJoinIsThePersonsIdentityFromThenOn() async {
        let throwaway = DuoCredential(memberID: RF.minted.memberId, deviceID: RF.minted.deviceId, deviceSecret: RF.minted.deviceSecret)
        for flow in ["create", "join"] {
            let h = RHarness(credential: throwaway)
            h.answerEverything()
            h.kit.dependencies.cache.throwawayDeviceID = RF.minted.deviceId
            if flow == "create" { _ = await h.service.createDuo(named: "Jo", skin: "classic") } else { _ = await h.service.join(RF.pendingInvite, named: "Jo", skin: "classic") }
            XCTAssertNil(h.kit.dependencies.cache.throwawayDeviceID, flow)
        }
        // A refused one leaves it marked.
        let refused = RHarness(credential: throwaway)
        refused.answerEverything()
        refused.kit.dependencies.cache.throwawayDeviceID = RF.minted.deviceId
        refused.t.onCreateDuo = { _, _ in throw DuoTransportError.nameRejected(RF.ctx(422)) }
        _ = await refused.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertEqual(refused.kit.dependencies.cache.throwawayDeviceID, RF.minted.deviceId)
    }

    /// The reconnect's answer is lost after the throwaway was stored: a relaunch still reads as
    /// disconnected, and the next tap replays the same request with the same throwaway.
    func testALostReconnectAnswerThenARelaunchReplaysWithTheSameThrowaway() async throws {
        let defaults = RMemoryDefaults()
        RRealPhone.consent(defaults)
        let secrets = DuoMemorySecretStore()
        let folder = RRealPhone.folder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let transport = FakeDuoTransport()
        transport.onCreateDevice = { _ in RF.minted }
        let script = RScript([CancellationError()])
        transport.onReconnect = { _, _ in
            try script.next()
            return DuoWireReconnectResponse(memberId: DuoFixtures.credential().memberID, supportId: "WXYZ5678ABCD", duos: [], supersededDevices: 1)
        }
        transport.onMe = { RF.me(memberID: DuoFixtures.credential().memberID) }
        let first = RRealPhone(defaults: defaults, secrets: secrets, directory: folder, transport: transport)
        try first.identity.store(DuoFixtures.credential())
        first.store.upsert(DuoFixtures.duo())
        first.store.availability = .disconnected
        _ = await first.service.reconnect(code: "H7K39QWX")
        let relaunched = RRealPhone(defaults: defaults, secrets: secrets, directory: folder, transport: transport)
        XCTAssertEqual(relaunched.store.availability, .disconnected)
        let reconnected = await relaunched.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(reconnected)
        let keys = transport.calls.compactMap { call -> DuoIdempotencyKey? in if case .reconnect(_, let key) = call { return key }; return nil }
        guard keys.count == 2 else { return XCTFail("two reconnects, not \(keys.count)") }
        XCTAssertEqual(keys[0], keys[1], "the replay the server answers from its record")
        XCTAssertEqual(rNames(transport.calls).filter { $0 == "createDevice" }.count, 1)
    }

    // MARK: The op queue (D8, D9)

    /// D9: a Leave or a Block still queued would end a duo started now with the same partner, or
    /// make refused an invite they made earlier. The queue is drained first; one that cannot be
    /// sent stops the start with the general line and nothing sent.
    func testAQueuedExitThatCannotBeSentStopsANewStartAndOneThatGoesLetsItThrough() async throws {
        for kind in [DuoOpKind.leave, .block] {
            for flow in ["create", "join", "reconnect"] {
                for sends in [false, true] {
                    let h = RHarness(credential: DuoFixtures.credential())
                    h.answerEverything()
                    let queue = RQueue(sendsOnDrain: sends, events: h.events)
                    h.kit.dependencies.ops = queue
                    queue.enqueue(kind == .leave ? try DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "q1", now: RF.now)
                                                 : try DuoQueuedOp.block(duoID: DuoFixtures.duoID, key: "q1", now: RF.now))
                    var started = false
                    switch flow {
                    case "create": started = await h.service.createDuo(named: "Jo", skin: "classic") != nil
                    case "join": started = await h.service.join(RF.pendingInvite, named: "Jo", skin: "classic") != nil
                    default: started = await h.service.reconnect(code: "H7K39QWX")
                    }
                    // A reconnect that worked drains once more, for the exits held behind a throwaway (D11).
                    XCTAssertEqual(queue.drains, flow == "reconnect" && sends ? 2 : 1, "drained once first: \(kind) \(flow)")
                    XCTAssertEqual(started, sends, "\(kind) \(flow) sends=\(sends)")
                    if sends {
                        XCTAssertFalse(h.t.calls.isEmpty)
                    } else {
                        XCTAssertTrue(h.t.calls.isEmpty, "nothing sent while the exit waits: \(kind) \(flow)")
                        XCTAssertEqual(h.store.sheetError, "That did not work. Please try again.")
                        XCTAssertFalse(h.store.isWorking)
                    }
                }
            }
        }
        // A rename waiting in the queue is no reason to refuse anything.
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        let queue = RQueue(sendsOnDrain: false, events: h.events)
        h.kit.dependencies.ops = queue
        queue.enqueue(try DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: .value("Jo")), key: "q2", now: RF.now))
        let created = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNotNil(created)
    }

    /// On a disconnected phone the queue is drained before the throwaway is minted, so a Leave goes
    /// out under the credential it was made with (a superseded device keeps its exits), and a Leave
    /// still waiting leaves the phone disconnected with nothing minted.
    func testADisconnectedPhoneDrainsBeforeItMintsAndAWaitingLeaveMintsNothing() async throws {
        let stuck = RHarness(credential: DuoFixtures.credential())
        stuck.answerEverything()
        stuck.store.upsert(DuoFixtures.duo())
        stuck.store.availability = .disconnected
        let waiting = RQueue(sendsOnDrain: false, events: stuck.events)
        stuck.kit.dependencies.ops = waiting
        waiting.enqueue(try DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "q1", now: RF.now))
        let refused = await stuck.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(refused)
        XCTAssertTrue(stuck.t.calls.isEmpty)
        XCTAssertEqual(stuck.store.availability, .disconnected)
        XCTAssertEqual(stuck.kit.identity.credential, DuoFixtures.credential(), "the revoked credential is kept, nothing minted")

        let goes = RHarness(credential: DuoFixtures.credential())
        goes.answerEverything()
        goes.store.upsert(DuoFixtures.duo())
        goes.store.availability = .disconnected
        let draining = RQueue(sendsOnDrain: true, events: goes.events)
        goes.kit.dependencies.ops = draining
        draining.enqueue(try DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "q1", now: RF.now))
        let reconnected = await goes.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(reconnected)
        XCTAssertEqual(goes.events.value.prefix(3), ["drain", "hold", "createDevice"], "the queue goes first, under the old credential")
    }

    /// D8: a rename or a push-token upload queued under an earlier identity must not go out under
    /// the member a mint just made; a Leave or a Block stays. Nothing is dropped without a mint.
    func testAMintDropsTheQueuesIdentityBoundEntriesAndNothingElseDoes() async throws {
        let rename = try DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: .value("Old")), key: "q2", now: RF.now)
        let upload = try DuoQueuedOp.registerPush(DuoWireRegisterPushRequest(token: "aa", apnsEnv: "sandbox", tz: "UTC", wakeStartMin: nil,
                                                                            wakeEndMin: nil, notificationsEnabled: false), firstUpload: true, key: "q3", now: RF.now)
        // A fresh mint, for each consent flow.
        for flow in ["create", "join", "reconnect"] {
            let h = RHarness()
            h.answerEverything()
            h.kit.ops.enqueue(rename)
            h.kit.ops.enqueue(upload)
            switch flow {
            case "create": _ = await h.service.createDuo(named: "Jo", skin: "classic")
            case "join": _ = await h.service.join(RF.pendingInvite, named: "Jo", skin: "classic")
            default: _ = await h.service.reconnect(code: "H7K39QWX")
            }
            XCTAssertEqual(h.kit.ops.identityBoundDiscards, 1, flow)
            XCTAssertTrue(h.kit.ops.queued.isEmpty, flow)
        }
        // The throwaway that replaces a disconnected phone's revoked credential.
        let d = RHarness(credential: DuoFixtures.credential())
        d.answerEverything()
        d.store.upsert(DuoFixtures.duo())
        d.store.availability = .disconnected
        d.kit.ops.enqueue(rename)
        _ = await d.service.reconnect(code: "H7K39QWX")
        XCTAssertEqual(d.kit.ops.identityBoundDiscards, 1)
        XCTAssertTrue(d.kit.ops.queued.isEmpty)
        // An identity that exists mints nothing and drops nothing.
        let existing = RHarness(credential: DuoFixtures.credential())
        existing.answerEverything()
        existing.kit.ops.enqueue(rename)
        _ = await existing.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertEqual(existing.kit.ops.identityBoundDiscards, 0)
        XCTAssertEqual(existing.kit.ops.queued.map(\.kind), [.updateMe])
        // A mint whose answer was lost changed no identity either.
        let lost = RHarness()
        lost.answerEverything()
        lost.kit.ops.enqueue(rename)
        lost.t.onCreateDevice = { _ in throw DuoTransportError.offline }
        _ = await lost.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertEqual(lost.kit.ops.identityBoundDiscards, 0)
    }

    // MARK: The idempotency lens's probes, now that a lost join is found without the journal

    func testProbeF1_ALostGetMeAfterTheSecondAnswerDoesNotLoseTheJoin() async {
        let (world, script, _, duoID, code) = IdemProbe.joinWorld(seed: 101)
        let invite = DuoPendingInvite(code: code, k: nil, receivedAt: world.clock.now)
        script.on("POST /invites/redeem", 1, .dropAfter)
        _ = await world.tap { await $0.service.join(invite, named: "Jo", skin: "classic") }
        script.on("GET /me", 1, .dropBefore)
        _ = await world.tap { await $0.service.join(invite, named: "Joanna", skin: "classic") }
        XCTAssertNil(IdemProbe.held(world, duoID), "GET /me was lost, so nothing is known yet")
        _ = await world.tap { await $0.service.join(invite, named: "Joanna", skin: "classic") }
        XCTAssertNotNil(IdemProbe.held(world, duoID), "the next tap asks again and finds the seat")
        XCTAssertEqual(world.server.locked { world.server.duos[duoID]?.partner }, world.phone.identity.credential?.memberID)
    }

    func testProbeF1c_TheSameTapADayLaterFindsTheSeat() async {
        let (world, script, _, duoID, code) = IdemProbe.joinWorld(seed: 109)
        script.on("POST /invites/redeem", 1, .dropAfter)
        _ = await world.tap { await $0.service.join(DuoPendingInvite(code: code, k: nil, receivedAt: world.clock.now), named: "Jo", skin: "classic") }
        world.clock.advance(23.5 * 3600)
        world.phone.store.latest = world.log
        let again = await world.tap { await $0.service.join(DuoPendingInvite(code: code, k: nil, receivedAt: world.clock.now), named: "Jo", skin: "classic") }
        XCTAssertNotNil(again ?? nil)
        XCTAssertNotNil(IdemProbe.held(world, duoID))
    }

    func testProbeF1b_AfterARelaunchALinkJoinIsFound() async {
        let (world, script, _, duoID, code) = IdemProbe.joinWorld(seed: 102)
        world.phone.service.receive(DuoParsedInvite(code: code, k: String(repeating: "B", count: 26)), now: world.clock.now)
        script.on("POST /invites/redeem", 1, .killAfter)
        let first = await world.tap { await $0.service.join(world.phone.store.pendingInvite!, named: "Jo", skin: "classic") }
        XCTAssertNil(first, "the process died with the redeem out")
        let again = world.phone.store.pendingInvite!
        XCTAssertNil(again.k, "k is memory only")
        _ = await world.tap { await $0.service.join(again, named: "Jo", skin: "classic") }
        XCTAssertNotNil(IdemProbe.held(world, duoID))
    }

    func testProbeF2_ALostThenBLostThenAAgainHoldsBoth() async {
        let world = IdemWorld(seed: 103, root: IdemProbe.root)
        let script = IdemScript()
        world.session.planner = script.planner()
        let x = world.server.seedMember(name: "Sam", physical: "phone2", lastSeen: world.clock.now)
        let y = world.server.seedMember(name: "Kit", physical: "phone3", lastSeen: world.clock.now)
        let (duoA, codeA) = world.server.seedPendingDuo(owner: x.member)
        let (duoB, codeB) = world.server.seedPendingDuo(owner: y.member)
        let a = DuoPendingInvite(code: codeA, k: nil, receivedAt: world.clock.now)
        let b = DuoPendingInvite(code: codeB, k: nil, receivedAt: world.clock.now)
        script.on("POST /invites/redeem", 1, .dropAfter)
        _ = await world.tap { await $0.service.join(a, named: "Jo", skin: "classic") }
        script.on("POST /invites/redeem", 2, .dropAfter)
        _ = await world.tap { await $0.service.join(b, named: "Jo", skin: "classic") }
        _ = await world.tap { await $0.service.join(a, named: "Jo", skin: "classic") }
        let member = world.phone.identity.credential?.memberID
        XCTAssertEqual(world.server.locked { world.server.duos[duoA]?.partner }, member)
        XCTAssertEqual(world.server.locked { world.server.duos[duoB]?.partner }, member)
        XCTAssertNotNil(IdemProbe.held(world, duoA))
        XCTAssertNotNil(IdemProbe.held(world, duoB), "the server seated this free person twice; both are shown")
    }

    func testProbeF2b_ALostThenARefusedBFindsA() async {
        let world = IdemWorld(seed: 104, root: IdemProbe.root)
        let script = IdemScript()
        world.session.planner = script.planner()
        let x = world.server.seedMember(name: "Sam", physical: "phone2", lastSeen: world.clock.now)
        let y = world.server.seedMember(name: "Kit", physical: "phone3", lastSeen: world.clock.now)
        let z = world.server.seedMember(name: "Lee", physical: "phone4", lastSeen: world.clock.now)
        let (duoA, codeA) = world.server.seedPendingDuo(owner: x.member)
        let (duoB, codeB) = world.server.seedPendingDuo(owner: y.member)
        world.server.locked {
            world.server.duos[duoB]?.partner = z.member
            world.server.duos[duoB]?.state = .active
            world.server.invites[codeB]?.state = "open"
        }
        script.on("POST /invites/redeem", 1, .dropAfter)
        _ = await world.tap { await $0.service.join(DuoPendingInvite(code: codeA, k: nil, receivedAt: world.clock.now), named: "Jo", skin: "classic") }
        _ = await world.tap { await $0.service.join(DuoPendingInvite(code: codeB, k: nil, receivedAt: world.clock.now), named: "Jo", skin: "classic") }
        XCTAssertNotNil(IdemProbe.held(world, duoA), "B's refusal asked GET /me, which found A")
    }

    // MARK: The fuzz (a few hundred runs of the idempotency lens's harness)

    func testFuzzCreateUnderLostAnswersAndKills() async {
        var secondDuo = 0, mismatches = 0, leftAfterSuccess = 0, lostCreates = 0, succeeded = 0
        for seed in 1...UInt64(IdemProbe.runs) {
            let world = IdemWorld(seed: seed, root: IdemProbe.root)
            let rng = IdemRNGBox(seed: seed)
            var tapsSoFar = 0
            world.session.planner = IdemProbe.planner(rng, active: { tapsSoFar <= 8 })
            if rng.chance(0.3) { world.deviceCheck.killOnCall = 1 + Int(rng.next() % 3) }
            var name: String? = "Jo"
            var created: DuoState?
            for tap in 1...14 {
                tapsSoFar = tap
                if tap > 1 {
                    if rng.chance(0.2) { name = rng.pick(["Jo", "Joanna", nil, "J"]) }
                    if rng.chance(0.3) { world.clock.advance(Double(rng.next() % 7200)) }
                    if rng.chance(0.1) { world.clock.advance(86400) }
                    if rng.chance(0.15) {
                        var log = world.log
                        log.totalsByDay[DayKey.key(for: world.clock.now, calendar: world.clock.calendar), default: 0] += 250
                        world.log = log
                        world.phone.store.latest = log
                    }
                }
                let n = name
                guard let result = await world.tap({ await $0.service.createDuo(named: n, skin: "classic") }) else { continue }
                if let duo = result { created = duo; break }
            }
            let s = world.server
            let (mine, mism) = s.locked { () -> ([IdemServer.Duo], Int) in
                let minted = Set(s.mints)
                return (s.duos.values.filter { minted.contains($0.owner) }, s.mismatches)
            }
            mismatches += mism
            if mine.count > 1 { secondDuo += 1 }
            if created != nil {
                succeeded += 1
                if world.journal.entries.contains(where: { $0.operation == "POST /duos" }) { leftAfterSuccess += 1 }
            } else if !mine.isEmpty {
                lostCreates += 1
            }
        }
        print("STAGE D FUZZ CREATE runs=\(IdemProbe.runs) succeeded=\(succeeded) secondDuo=\(secondDuo) mismatches=\(mismatches) lostCreates=\(lostCreates) journalLeftAfterSuccess=\(leftAfterSuccess)")
        XCTAssertEqual(secondDuo, 0, "a second duo for one create intent")
        XCTAssertEqual(mismatches, 0, "422 idempotency_mismatch")
        XCTAssertEqual(leftAfterSuccess, 0)
        XCTAssertEqual(lostCreates, 0, "a duo the server made that the phone never shows")
    }

    func testFuzzJoinUnderLostAnswersAndKills() async {
        var lost = 0, phantom = 0, mismatches = 0, leftAfterSuccess = 0, succeeded = 0
        for seed in 1...UInt64(IdemProbe.runs) {
            let world = IdemWorld(seed: seed &+ 10_000, root: IdemProbe.root)
            let rng = IdemRNGBox(seed: seed &+ 10_000)
            let owner = world.server.seedMember(name: "Sam", physical: "phone2", lastSeen: world.clock.now)
            let (duoID, code) = world.server.seedPendingDuo(owner: owner.member)
            let k = String(repeating: "A", count: 26)
            world.phone.service.receive(DuoParsedInvite(code: code, k: k), now: world.clock.now)
            var tapsSoFar = 0
            world.session.planner = IdemProbe.planner(rng, active: { tapsSoFar <= 8 })
            if rng.chance(0.3) { world.deviceCheck.killOnCall = 1 + Int(rng.next() % 3) }
            var name: String? = "Jo"
            var joined: DuoState?
            var relaunchedSinceLink = false
            var lastLaunch = world.launches
            for tap in 1...14 {
                tapsSoFar = tap
                if world.launches != lastLaunch { relaunchedSinceLink = true; lastLaunch = world.launches }
                if tap > 1 {
                    if rng.chance(0.2) { name = rng.pick(["Jo", "Joanna", nil]) }
                    if rng.chance(0.3) { world.clock.advance(Double(rng.next() % 7200)) }
                    if rng.chance(0.15) {
                        var log = world.log
                        log.totalsByDay[DayKey.key(for: world.clock.now, calendar: world.clock.calendar), default: 0] += 250
                        world.log = log
                        world.phone.store.latest = log
                    }
                }
                if relaunchedSinceLink, rng.chance(0.5) {
                    world.phone.service.receive(DuoParsedInvite(code: code, k: k), now: world.clock.now)
                    relaunchedSinceLink = false
                }
                let invite = world.phone.store.pendingInvite ?? DuoPendingInvite(code: code, k: nil, receivedAt: world.clock.now)
                let n = name
                guard let result = await world.tap({ await $0.service.join(invite, named: n, skin: "classic") }) else { continue }
                if let duo = result { joined = duo; break }
            }
            let s = world.server
            let (seated, mism) = s.locked { (s.duos[duoID]?.partner, s.mismatches) }
            mismatches += mism
            let held = UUID(uuidString: duoID).flatMap { world.phone.store.duo($0) }
            if seated != nil, held == nil || held?.hasEnded == true { lost += 1 }
            if seated == nil, held != nil { phantom += 1 }
            if joined != nil {
                succeeded += 1
                if world.journal.entries.contains(where: { $0.operation == "POST /invites/redeem" }) { leftAfterSuccess += 1 }
            }
        }
        print("STAGE D FUZZ JOIN runs=\(IdemProbe.runs) succeeded=\(succeeded) lostJoins=\(lost) phantomJoins=\(phantom) mismatches=\(mismatches) journalLeftAfterSuccess=\(leftAfterSuccess)")
        XCTAssertEqual(lost, 0, "a join the server accepted that the phone never shows")
        XCTAssertEqual(phantom, 0)
        XCTAssertEqual(mismatches, 0, "422 idempotency_mismatch")
        XCTAssertEqual(leftAfterSuccess, 0)
    }

    func testFuzzReconnectUnderLostAnswersAndKills() async {
        var reconnected = 0, endedOnPhone = 0, notReseated = 0, mismatches = 0, leftAfterSuccess = 0, stillDisconnected = 0
        for seed in 1...UInt64(IdemProbe.runs) {
            let (world, _, duoID, code) = await IdemProbe.disconnectedPhone(seed: seed &+ 50_000)
            let rng = IdemRNGBox(seed: seed &+ 50_000)
            var tapsSoFar = 0
            world.session.planner = IdemProbe.planner(rng, active: { tapsSoFar <= 6 })
            var lastLaunch = world.launches
            var ok = false
            for tap in 1...12 {
                tapsSoFar = tap
                if world.launches != lastLaunch {
                    // The app's launch read (stage C), before the person taps anything.
                    _ = await world.tap { _ in await IdemProbe.stageCRead(world) }
                    lastLaunch = world.launches
                }
                world.clock.advance(Double(30 + rng.next() % 600))
                let typed = (tap == 1 && rng.chance(0.3)) ? "ZZZZ9999" : code
                if let r = await world.tap({ await $0.service.reconnect(code: typed) }), r { ok = true; break }
            }
            let d = UUID(uuidString: duoID).flatMap { world.phone.store.duo($0) }
            mismatches += world.server.locked { world.server.mismatches }
            if ok {
                reconnected += 1
                if world.journal.entries.contains(where: { $0.operation == "POST /invites/reconnect" }) { leftAfterSuccess += 1 }
                if d?.syncedOnce == true { notReseated += 1 }
            } else if world.phone.store.availability == .disconnected {
                stillDisconnected += 1
            }
            if d?.hasEnded == true { endedOnPhone += 1 }
        }
        print("STAGE D FUZZ RECONNECT runs=\(IdemProbe.runs) reconnected=\(reconnected) notReconnectedStillDisconnected=\(stillDisconnected) duoEndedOnPhone=\(endedOnPhone) notReseated=\(notReseated) mismatches=\(mismatches) journalLeftAfterSuccess=\(leftAfterSuccess)")
        XCTAssertEqual(endedOnPhone, 0, "a throwaway's read ended the person's duo, or a reconnect left it ended")
        XCTAssertEqual(notReseated, 0)
        XCTAssertEqual(mismatches, 0)
        XCTAssertEqual(leftAfterSuccess, 0)
    }
}

// MARK: - The idempotency lens's model of the Worker (ported from its harness, trimmed)

// A model of the contract-v1 Worker, just enough of it for the joining flows, written by the
// idempotency reviewer from HydroDrop-Server at tag contract-v1 (src/db/idempotency.ts,
// src/routes/duos.ts, redeem.ts, reconnect.ts, devices.ts, src/auth/bearer.ts):
// - one idempotency record per (device_id, key), with method, path and SHA-256(body); a found
//   record with another method, path or body is 422 idempotency_mismatch; only a success is
//   recorded; a replay rebuilds its answer from the record's ref; 24 hours;
// - the attestation gate does nothing (ATTEST_MODE off);
// - POST /devices is not idempotent: bit0 per physical device (DeviceCheck), a returning mint
//   starts low and is held to 1 a day per address, 20 a day per address, 3 a minute;
// - the redeem's pre-read answers a redeemed code 404 invite_unknown;
// - the reconnect moves the calling device to the target member, deletes the throwaway member,
//   supersedes the target's other devices; a code whose target is the caller's member is a 200
//   no-op; a redeemed one is 404; a target seen in the last 72 hours is 404.
fileprivate final class IdemServer: @unchecked Sendable {
    struct Member { var id: String; var supportID: String; var terms: Int; var name: String?; var skin: String? }
    struct Device {
        var id: String; var member: String; var secret: String; var tier: DuoTier
        var revoked = false; var superseded = false; var lastSeen: Date; var createdAt: Date; var physical: String
    }
    struct Duo {
        var id: String; var owner: String; var partner: String?; var state: DuoWireDuoState
        var createdAt: Date; var joinedAt: Date?; var seq: Int64
        var rows: [String: DuoWireStatusRow] = [:]
    }
    struct Invite { var code: String; var duo: String?; var creator: String; var purpose: String; var state: String; var expiresAt: Date; var target: String? }
    struct Record { var method: String; var path: String; var bodyHash: String; var status: Int; var ref: String; var createdAt: Date }

    private let lock = NSLock()
    let clock: IdemClock
    private var rng: SplitMix

    var members: [String: Member] = [:]
    var devices: [String: Device] = [:]
    var duos: [String: Duo] = [:]
    var invites: [String: Invite] = [:]
    var records: [String: Record] = [:]
    var bit0: Set<String> = []
    var bindingTimes: [Date] = []
    var dayCounts: [String: Int] = [:]
    var mismatches = 0
    var mints: [String] = []
    var mintRefusals: [String] = []

    init(clock: IdemClock, seed: UInt64) {
        self.clock = clock
        rng = SplitMix(seed: seed ^ 0x5EED)
    }

    func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    private func uuid() -> String {
        var b = (0..<16).map { _ in UInt8(truncatingIfNeeded: rng.next()) }
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15])).uuidString.lowercased()
    }
    private func secret() -> String {
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return String((0..<43).map { _ in alphabet[Int(rng.next() % 64)] })
    }
    private func code() -> String {
        let alphabet = Array(DuoInviteCode.alphabet)
        return String((0..<8).map { _ in alphabet[Int(rng.next() % 32)] })
    }

    @discardableResult
    func seedMember(name: String?, physical: String, lastSeen: Date) -> (member: String, device: String, secret: String) {
        locked {
            let m = uuid(), d = uuid(), s = secret()
            members[m] = Member(id: m, supportID: String(("HD" + m.filter(\.isHexDigit).uppercased()).prefix(12)), terms: 1, name: name, skin: "classic")
            devices[d] = Device(id: d, member: m, secret: s, tier: .attested, lastSeen: lastSeen, createdAt: lastSeen, physical: physical)
            bit0.insert(physical)
            return (m, d, s)
        }
    }

    func seedPendingDuo(owner: String) -> (duo: String, code: String) {
        locked {
            let id = uuid(), c = code()
            duos[id] = Duo(id: id, owner: owner, partner: nil, state: .pending, createdAt: clock.now, joinedAt: nil, seq: 1)
            invites[c] = Invite(code: c, duo: id, creator: owner, purpose: "invite", state: "open", expiresAt: clock.now.addingTimeInterval(48 * 3600), target: nil)
            return (id, c)
        }
    }

    func seedActiveDuo(owner: String, partner: String) -> String {
        locked {
            let id = uuid()
            duos[id] = Duo(id: id, owner: owner, partner: partner, state: .active, createdAt: clock.now.addingTimeInterval(-20 * 86400),
                           joinedAt: clock.now.addingTimeInterval(-19 * 86400), seq: 5)
            return id
        }
    }

    func seedReconnectCode(duo: String, creator: String, target: String) -> String {
        locked {
            let c = code()
            invites[c] = Invite(code: c, duo: duo, creator: creator, purpose: "reconnect", state: "open", expiresAt: clock.now.addingTimeInterval(48 * 3600), target: target)
            return c
        }
    }

    func rotateSecret(device: String) { locked { devices[device]?.secret = secret() } }

    func handle(_ request: URLRequest) -> (Int, Data) { locked { route(request) } }

    private func route(_ request: URLRequest) -> (Int, Data) {
        let now = clock.now
        let method = request.httpMethod ?? "GET"
        let path = request.url!.path
        let body = request.httpBody ?? Data()
        guard path.hasPrefix("/v1/") else { return err("schema", 400) }
        let route = String(path.dropFirst(3))
        let parts = route.split(separator: "/").map(String.init)
        switch (method, parts.count, parts.first) {
        case ("POST", 2, "attest") where parts[1] == "challenge":
            return ok(201, DuoWireAttestChallenge(challengeId: uuid(), challenge: "Y2hhbGxlbmdl", expiresAt: now.addingTimeInterval(300)))
        case ("POST", 1, "devices"):
            return mint(body, now: now)
        default: break
        }
        guard let auth = request.value(forHTTPHeaderField: "Authorization"), auth.hasPrefix("Bearer ") else {
            if method == "POST", route == "/invites/peek" { return ok(200, DuoWirePeekResponse(purpose: "invite", state: "open")) }
            return err("unauthenticated", 401)
        }
        let token = auth.dropFirst("Bearer ".count)
        guard let dot = token.firstIndex(of: ".") else { return err("unauthenticated", 401) }
        let deviceID = String(token[..<dot]), secretSent = String(token[token.index(after: dot)...])
        guard var device = devices[deviceID] else { return err("unauthenticated", 401) }
        if device.secret != secretSent || device.revoked || device.superseded { return err("device_revoked", 401) }
        guard members[device.member] != nil else { return err("unauthenticated", 401) }
        device.lastSeen = now
        devices[deviceID] = device
        let caller = device.member
        let key = request.value(forHTTPHeaderField: "Idempotency-Key")
        func idempotent(_ fresh: () -> (Int, Data, String?), replay: (Record) -> (Int, Data)) -> (Int, Data) {
            guard let key else { return err("schema", 400) }
            let hash = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
            let id = "\(deviceID)|\(key)"
            if let r = records[id], now.timeIntervalSince(r.createdAt) < 24 * 3600 {
                guard r.method == method, r.path == path, r.bodyHash == hash else {
                    mismatches += 1
                    return err("idempotency_mismatch", 422)
                }
                return replay(r)
            }
            let (status, data, ref) = fresh()
            if (200...299).contains(status), let ref {
                records[id] = Record(method: method, path: path, bodyHash: hash, status: status, ref: ref, createdAt: now)
            }
            return (status, data)
        }
        switch (method, parts.count, parts.first) {
        case ("GET", 1, "me"):
            return ok(200, me(caller, deviceID: deviceID))
        case ("PATCH", 1, "me"):
            if let req = try? DuoWireCoding.decode(DuoWireUpdateMeRequest.self, from: body), case .value(let t) = req.termsVersion { members[caller]?.terms = t }
            let m = members[caller]!
            return ok(200, DuoWireMember(id: m.id, displayName: m.name, skin: m.skin, supportId: m.supportID, tier: device.tier, termsVersion: m.terms))
        case ("POST", 1, "duos"):
            return idempotent({ createDuo(body, caller: caller, now: now) }, replay: { replayCreate($0, body: body, caller: caller) })
        case ("GET", 3, "duos") where parts[2] == "changes":
            guard let duo = duos[parts[1]], duo.owner == caller || duo.partner == caller else { return err("duo_unknown", 404) }
            return ok(200, feed(duo, caller: caller))
        case ("POST", 2, "invites") where parts[1] == "redeem":
            return idempotent({ redeem(body, caller: caller, now: now) }, replay: { replayRedeem($0, body: body, caller: caller) })
        case ("POST", 2, "invites") where parts[1] == "reconnect":
            return idempotent({ reconnect(body, caller: caller, deviceID: deviceID, now: now) }, replay: { _ in reconnectAnswer(member: devices[deviceID]!.member, superseded: 0) })
        case ("POST", 2, "invites") where parts[1] == "peek":
            return ok(200, DuoWirePeekResponse(purpose: "invite", state: "open"))
        default:
            return err("schema", 400)
        }
    }

    private func dayKey(_ name: String) -> String { "\(name)|\(DayKey.key(for: clock.now, calendar: clock.calendar))" }

    private func mint(_ body: Data, now: Date) -> (Int, Data) {
        bindingTimes = bindingTimes.filter { now.timeIntervalSince($0) < 60 } + [now]
        if bindingTimes.count > 3 { mintRefusals.append("binding"); return err("rate_limited", 429) }
        guard let req = try? DuoWireCoding.decode(DuoWireCreateDeviceRequest.self, from: body) else { return err("schema", 400) }
        let physical = req.deviceCheckToken.flatMap { $0.split(separator: "|").dropFirst().first.map(String.init) } ?? "unknown"
        let returning = bit0.contains(physical)
        if returning {
            if dayCounts[dayKey("returning"), default: 0] >= 1 { mintRefusals.append("returning"); return err("rate_limited", 429) }
            dayCounts[dayKey("returning"), default: 0] += 1
        }
        if dayCounts[dayKey("address"), default: 0] >= 20 { mintRefusals.append("address"); return err("rate_limited", 429) }
        dayCounts[dayKey("address"), default: 0] += 1
        let m = uuid(), d = uuid(), s = secret()
        let support = String(("HD" + m.filter(\.isHexDigit).uppercased()).prefix(12))
        members[m] = Member(id: m, supportID: support, terms: req.termsVersion, name: nil, skin: nil)
        devices[d] = Device(id: d, member: m, secret: s, tier: returning ? .low : .attested, lastSeen: now, createdAt: now, physical: physical)
        bit0.insert(physical)
        mints.append(m)
        return ok(201, DuoWireCreateDeviceResponse(memberId: m, deviceId: d, deviceSecret: s, tier: returning ? .low : .attested, supportId: support))
    }

    private func liveCount(_ member: String) -> Int {
        duos.values.filter { ($0.owner == member || $0.partner == member) && $0.state != .ended }.count
    }

    private func createDuo(_ body: Data, caller: String, now: Date) -> (Int, Data, String?) {
        guard let req = try? DuoWireCoding.decode(DuoWireCreateDuoRequest.self, from: body) else { let e = err("schema", 400); return (e.0, e.1, nil) }
        if let pending = duos.values.first(where: { $0.owner == caller && $0.state == .pending }) {
            let e = err("pending_exists", 409, details: ["duo_id": pending.id]); return (e.0, e.1, nil)
        }
        if liveCount(caller) >= 5 { let e = err("duo_limit", 409, details: ["max": 5, "active_duos": liveCount(caller)]); return (e.0, e.1, nil) }
        let id = uuid(), c = code()
        var duo = Duo(id: id, owner: caller, partner: nil, state: .pending, createdAt: now, joinedAt: nil, seq: 1)
        for row in req.statuses {
            duo.rows["owner|\(row.day)"] = DuoWireStatusRow(role: .owner, day: row.day, goalMet: row.goalMet, progressBucket: row.progressBucket, updatedAt: now, ver: 1)
        }
        duos[id] = duo
        members[caller]?.name = req.displayName
        invites[c] = Invite(code: c, duo: id, creator: caller, purpose: "invite", state: "open", expiresAt: now.addingTimeInterval(48 * 3600), target: nil)
        let answer = DuoWireCreateDuoResponse(duo: header(duo, caller: caller), invite: DuoWireInvite(code: c, display: DuoInviteCode.display(c), expiresAt: now.addingTimeInterval(48 * 3600)),
                                             accepted: req.statuses.map(\.day), unchanged: [], rejected: [])
        let r = ok(201, answer)
        return (r.0, r.1, "\(id):\(c)")
    }

    private func replayCreate(_ record: Record, body: Data, caller: String) -> (Int, Data) {
        let parts = record.ref.split(separator: ":").map(String.init)
        guard let duo = duos[parts[0]] else { return err("maintenance", 503) }
        let req = try? DuoWireCoding.decode(DuoWireCreateDuoRequest.self, from: body)
        return ok(record.status, DuoWireCreateDuoResponse(duo: header(duo, caller: caller),
                                                          invite: DuoWireInvite(code: parts[1], display: DuoInviteCode.display(parts[1]), expiresAt: record.createdAt.addingTimeInterval(48 * 3600)),
                                                          accepted: req?.statuses.map(\.day) ?? [], unchanged: [], rejected: []))
    }

    private func silent(_ member: String, now: Date) -> Bool {
        devices.values.filter { $0.member == member && !$0.revoked }.allSatisfy { now.timeIntervalSince($0.lastSeen) > 72 * 3600 }
    }

    private func redeem(_ body: Data, caller: String, now: Date) -> (Int, Data, String?) {
        func refuse(_ code: String, _ status: Int) -> (Int, Data, String?) { let e = err(code, status); return (e.0, e.1, nil) }
        guard let req = try? DuoWireCoding.decode(DuoWireRedeemRequest.self, from: body) else { return refuse("schema", 400) }
        guard let invite = invites[req.code], invite.state == "open", invite.expiresAt > now else { return refuse("invite_unknown", 404) }
        guard invite.purpose == "invite" else { return refuse("wrong_purpose", 409) }
        guard invite.creator != caller else { return refuse("invite_own", 409) }
        guard let duoID = invite.duo, var duo = duos[duoID], duo.state == .pending, duo.partner == nil else { return refuse("invite_taken", 409) }
        if liveCount(caller) >= 5 { return refuse("duo_limit", 409) }
        duo.partner = caller
        duo.state = .active
        duo.joinedAt = now
        duo.seq += 1
        for row in req.statuses {
            duo.rows["partner|\(row.day)"] = DuoWireStatusRow(role: .partner, day: row.day, goalMet: row.goalMet, progressBucket: row.progressBucket, updatedAt: now, ver: 1)
        }
        duos[duoID] = duo
        invites[req.code]?.state = "redeemed"
        members[caller]?.name = req.displayName
        let r = ok(201, DuoWireChangesWithResult(changes: feed(duo, caller: caller), accepted: req.statuses.map(\.day), unchanged: [], rejected: []))
        return (r.0, r.1, duoID)
    }

    private func replayRedeem(_ record: Record, body: Data, caller: String) -> (Int, Data) {
        guard let duo = duos[record.ref], duo.owner == caller || duo.partner == caller else { return err("maintenance", 503) }
        let req = try? DuoWireCoding.decode(DuoWireRedeemRequest.self, from: body)
        return ok(record.status, DuoWireChangesWithResult(changes: feed(duo, caller: caller), accepted: req?.statuses.map(\.day) ?? [], unchanged: [], rejected: []))
    }

    private func reconnect(_ body: Data, caller: String, deviceID: String, now: Date) -> (Int, Data, String?) {
        func refuse(_ code: String, _ status: Int) -> (Int, Data, String?) { let e = err(code, status); return (e.0, e.1, nil) }
        guard let req = try? DuoWireCoding.decode(DuoWireReconnectRequest.self, from: body) else { return refuse("schema", 400) }
        guard let invite = invites[req.code], invite.state != "void", invite.expiresAt > now else { return refuse("invite_unknown", 404) }
        guard invite.purpose == "reconnect" || invite.purpose == "link_device" else { return refuse("wrong_purpose", 409) }
        guard let target = invite.target else { return refuse("invite_unknown", 404) }
        if target == caller {
            let r = reconnectAnswer(member: caller, superseded: 0)
            return (r.0, r.1, nil)
        }
        guard invite.state == "open" else { return refuse("invite_unknown", 404) }
        if let d = invite.duo, let duo = duos[d], duo.state != .active { return refuse("invite_unknown", 404) }
        if !silent(target, now: now) { return refuse("invite_unknown", 404) }
        let fresh = liveCount(caller) == 0 && devices.values.filter { $0.member == caller }.count == 1
        guard fresh else { return refuse("member_not_fresh", 409) }
        devices[deviceID]?.member = target
        var superseded = 0
        for (id, d) in devices where d.member == target && id != deviceID && !d.revoked && !d.superseded {
            devices[id]?.superseded = true
            superseded += 1
        }
        members[caller] = nil
        invites[req.code]?.state = "redeemed"
        for (id, duo) in duos where (duo.owner == target || duo.partner == target) && duo.state == .active { duos[id]?.seq += 1 }
        let r = reconnectAnswer(member: target, superseded: superseded)
        return (r.0, r.1, target)
    }

    private func reconnectAnswer(member: String, superseded: Int) -> (Int, Data) {
        guard let m = members[member] else { return err("maintenance", 503) }
        let mine = duos.values.filter { $0.owner == member || $0.partner == member }.sorted { $0.id < $1.id }
        return ok(200, DuoWireReconnectResponse(memberId: member, supportId: m.supportID, duos: mine.map { header($0, caller: member) }, supersededDevices: superseded))
    }

    func header(_ duo: Duo, caller: String) -> DuoWireHeader {
        let owner = members[duo.owner], partner = duo.partner.flatMap { members[$0] }
        let open = invites.values.first { $0.duo == duo.id && $0.purpose == "invite" && $0.state == "open" }
        return DuoWireHeader(id: duo.id, myRole: duo.owner == caller ? .owner : .partner, state: duo.state, createdAt: duo.createdAt, joinedAt: duo.joinedAt,
                             endedAt: nil, endedBy: nil, ownerDisplayName: owner?.name, ownerSkin: owner?.skin ?? "classic",
                             partnerDisplayName: partner?.name, partnerSkin: duo.partner == nil ? nil : (partner?.skin ?? "classic"),
                             partnerLastWriteDay: nil, partnerIsDemo: false,
                             invite: DuoWireHeaderInvite(hasOpenInvite: duo.state == .pending && open != nil, expiresAt: duo.state == .pending ? open?.expiresAt : nil),
                             seq: duo.seq)
    }

    func feed(_ duo: Duo, caller: String) -> DuoWireChanges {
        DuoWireChanges(duo: header(duo, caller: caller), full: true, statuses: duo.rows.values.sorted { ($0.role.rawValue, $0.day) < ($1.role.rawValue, $1.day) },
                       nudges: [], handled: [], cursor: duo.seq)
    }

    private func me(_ caller: String, deviceID: String) -> DuoWireGetMeResponse {
        let m = members[caller]!
        let mine = duos.values.filter { $0.owner == caller || $0.partner == caller }.sorted { $0.id < $1.id }
        let devs = devices.values.filter { $0.member == caller && !$0.revoked }.sorted { $0.id < $1.id }
            .map { DuoWireDevice(id: $0.id, platform: "ios", createdAt: $0.createdAt, thisDevice: $0.id == deviceID, superseded: $0.superseded) }
        let tier = devices[deviceID]?.tier ?? .attested
        return DuoWireGetMeResponse(member: DuoWireMember(id: m.id, displayName: m.name, skin: m.skin, supportId: m.supportID, tier: tier, termsVersion: m.terms),
                                    limits: DuoWireLimits(nudgesPerDay: tier == .low ? 1 : 3, maxActiveDuos: 5), devices: devs,
                                    duos: mine.map { header($0, caller: caller) }, minClient: DuoWireMinClient(ios: "2.0", android: "2.0"))
    }

    static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(DuoWireTime.format(date))
        }
        return e
    }()

    private func ok<T: Encodable>(_ status: Int, _ value: T) -> (Int, Data) { (status, try! Self.encoder.encode(value)) }

    private func err(_ code: String, _ status: Int, details: [String: Any]? = nil) -> (Int, Data) {
        var e: [String: Any] = ["code": code, "message": code, "request_id": "rid-\(code)"]
        if let details { e["details"] = details }
        return (status, try! JSONSerialization.data(withJSONObject: ["error": e]))
    }
}

fileprivate final class IdemClock: DuoClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    let calendar: Calendar
    init(_ start: Date) {
        current = start
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: 0)!
        calendar = c
    }
    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

fileprivate struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
    mutating func chance(_ p: Double) -> Bool { Double(next() % 1_000_000) / 1_000_000 < p }
    mutating func pick<T>(_ items: [T]) -> T { items[Int(next() % UInt64(items.count))] }
}

fileprivate final class IdemRandom: DuoRandom, @unchecked Sendable {
    private let lock = NSLock()
    private var rng: SplitMix
    init(seed: UInt64) { rng = SplitMix(seed: seed) }
    func bytes(_ count: Int) -> [UInt8] { lock.lock(); defer { lock.unlock() }; return (0..<count).map { _ in UInt8(truncatingIfNeeded: rng.next()) } }
    func uuid() -> UUID {
        var b = bytes(16)
        b[6] = (b[6] & 0x0F) | 0x40
        b[8] = (b[8] & 0x3F) | 0x80
        return UUID(uuid: (b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7], b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]))
    }
}

fileprivate final class IdemRNGBox: @unchecked Sendable {
    private let lock = NSLock()
    private var rng: SplitMix
    init(seed: UInt64) { rng = SplitMix(seed: seed &* 7919) }
    func next() -> UInt64 { lock.withLock { rng.next() } }
    func chance(_ p: Double) -> Bool { lock.withLock { rng.chance(p) } }
    func pick<T>(_ items: [T]) -> T { lock.withLock { rng.pick(items) } }
}

/// What happens to one request on its way.
fileprivate enum IdemFault: String, CaseIterable {
    case none
    case dropBefore, dropAfter, unreadableAfter, edge503, cancelBefore, cancelAfter, killBefore, killAfter
    static let lossy: [IdemFault] = [.dropBefore, .dropAfter, .unreadableAfter, .edge503, .cancelBefore, .cancelAfter, .killBefore, .killAfter]
}

fileprivate struct IdemRequestInfo {
    var method: String
    var route: String
}

fileprivate final class IdemKillSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (() -> Void)?
    func arm(_ h: @escaping () -> Void) { lock.withLock { handler = h } }
    func kill() {
        let h = lock.withLock { () -> (() -> Void)? in let h = handler; handler = nil; return h }
        h?()
    }
}

/// The session the real `DuoAPIClient` is handed: the model server behind a fault planner. A kill
/// hangs the request for ever: nothing after it runs in that process.
fileprivate final class IdemSession: DuoHTTPSession, @unchecked Sendable {
    let server: IdemServer
    let killSwitch: IdemKillSwitch
    private let lock = NSLock()
    var planner: ((IdemRequestInfo) -> IdemFault)?
    private var hung: [CheckedContinuation<Void, Never>] = []

    init(server: IdemServer, killSwitch: IdemKillSwitch) {
        self.server = server
        self.killSwitch = killSwitch
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let info = IdemRequestInfo(method: request.httpMethod ?? "GET", route: String(request.url!.path.dropFirst(3)))
        let fault = planner?(info) ?? .none
        func answer(_ status: Int, _ data: Data) -> (Data, URLResponse) {
            (data, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
                                   headerFields: ["Content-Type": "application/json", "X-Request-Id": "rid-1"])!)
        }
        switch fault {
        case .none:
            let (status, data) = server.handle(request)
            return answer(status, data)
        case .dropBefore:
            throw URLError(.notConnectedToInternet)
        case .dropAfter:
            _ = server.handle(request)
            throw URLError(.timedOut)
        case .unreadableAfter:
            let (status, data) = server.handle(request)
            return answer(status, data.prefix(max(0, data.count / 2)))
        case .edge503:
            return (Data("<html>503</html>".utf8), HTTPURLResponse(url: request.url!, statusCode: 503, httpVersion: "HTTP/1.1",
                                                                  headerFields: ["Content-Type": "text/html"])!)
        case .cancelBefore:
            throw CancellationError()
        case .cancelAfter:
            _ = server.handle(request)
            throw CancellationError()
        case .killBefore:
            await hang()
            throw CancellationError()
        case .killAfter:
            _ = server.handle(request)
            await hang()
            throw CancellationError()
        }
    }

    func hang() async {
        killSwitch.kill()
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in lock.withLock { hung.append(c) } }
    }
}

/// A DeviceCheck whose token names the physical phone (the server's bit0 is per phone), is new on
/// every call, and can be where the process dies.
fileprivate final class IdemDeviceCheck: DuoDeviceCheckProviding, @unchecked Sendable {
    let physical: String
    let session: IdemSession
    private let lock = NSLock()
    private var n = 0
    var killOnCall: Int?
    init(physical: String, session: IdemSession) {
        self.physical = physical
        self.session = session
    }
    var isSupported: Bool { true }
    func token() async -> String? {
        let call = lock.withLock { () -> Int in n += 1; return n }
        if killOnCall == call { await session.hang() }
        return "dc|\(physical)|\(call)"
    }
}

/// One launch of the app over what the world keeps on disk.
@MainActor
fileprivate final class IdemPhone {
    let store: DuoStore
    let dependencies: DuoDependencies
    let identity: DuoIdentity
    let client: DuoAPIClient
    let service: DuoJoiningService
    let ops = FakeOpQueue()

    init(world: IdemWorld) {
        let cache = DuoCache(defaults: world.defaults)
        store = DuoStore(cache: cache, usesServer: true, reloadWidget: {})
        dependencies = DuoDependencies(host: store, cache: cache, secrets: DuoSecrets(store: world.secretStore), clock: world.clock, random: world.random,
                                       client: DuoClientInfo(marketingVersion: "2.0", build: "57"), attester: FakeDuoAttester(),
                                       deviceCheck: world.deviceCheck)
        identity = DuoIdentity(dependencies: dependencies, directory: world.directory, holdInBackground: { _ in { } }, excludeFromBackup: { _ in })
        dependencies.identity = identity
        client = DuoAPIClient(baseURL: URL(string: "https://api.test/v1")!, client: dependencies.client, credentials: identity,
                              attester: dependencies.attester, session: world.session)
        dependencies.transport = client
        dependencies.ops = ops
        dependencies.push = FakePush()
        dependencies.isSubscribed = { false }
        dependencies.activeSkin = { "classic" }
        service = DuoJoiningService(dependencies: dependencies)
        service.holdInBackground = { _ in { } }
        dependencies.joining = service
        store.install(dependencies)
        store.latest = world.log
    }
}

@MainActor
fileprivate final class IdemWorld {
    let clock: IdemClock
    let server: IdemServer
    let defaults = RMemoryDefaults()
    let secretStore = DuoMemorySecretStore()
    let directory: URL
    let random: IdemRandom
    let killSwitch = IdemKillSwitch()
    let session: IdemSession
    let deviceCheck: IdemDeviceCheck
    var log: DuoLogSummary
    var phone: IdemPhone!
    private(set) var launches = 0

    init(seed: UInt64, root: URL) {
        // At the real time, so `DuoStore.init`'s prune (which reads `Date()`) keeps what this wrote.
        clock = IdemClock(Date(timeIntervalSince1970: (Date().timeIntervalSince1970 / 60).rounded(.down) * 60))
        server = IdemServer(clock: clock, seed: seed)
        random = IdemRandom(seed: seed)
        directory = root.appendingPathComponent("w\(seed)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        session = IdemSession(server: server, killSwitch: killSwitch)
        deviceCheck = IdemDeviceCheck(physical: "phone1", session: session)
        let today = DayKey.key(for: clock.now, calendar: clock.calendar)
        let yesterday = DayKey.key(for: clock.now.addingTimeInterval(-86400), calendar: clock.calendar)
        log = DuoLogSummary(totalsByDay: [today: 900, yesterday: 2100], goalML: 2000, earliestEntryDay: "2026-01-01")
        let cache = DuoCache(defaults: defaults)
        cache.ageStatus = .allowed
        cache.acceptedTermsVersion = DuoProtocolConstants.termsVersion
        launch()
    }

    func launch() {
        launches += 1
        phone = IdemPhone(world: self)
    }

    /// Runs one tap's flow; nil when the process died during it (the world has relaunched).
    func tap<T>(_ body: @escaping @MainActor (IdemPhone) async -> T) async -> T? {
        let phone = self.phone!
        let result: T? = await withCheckedContinuation { (c: CheckedContinuation<T?, Never>) in
            let once = IdemOnce(c)
            killSwitch.arm { once.resume(nil) }
            Task { @MainActor in
                let value = await body(phone)
                once.resume(value)
            }
        }
        killSwitch.arm {}
        if result == nil { launch() }
        return result
    }

    var journal: DuoInflightJournal { DuoCache(defaults: defaults).loadInflight(now: clock.now) }
}

fileprivate final class IdemOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var c: CheckedContinuation<T?, Never>?
    init(_ c: CheckedContinuation<T?, Never>) { self.c = c }
    func resume(_ value: T?) {
        let taken = lock.withLock { () -> CheckedContinuation<T?, Never>? in let t = c; c = nil; return t }
        taken?.resume(returning: value)
    }
}

/// A planner that faults the n-th request to a route and lets everything else through.
fileprivate final class IdemScript: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var plan: [String: [Int: IdemFault]] = [:]
    func on(_ route: String, _ occurrence: Int, _ fault: IdemFault) { lock.withLock { plan[route, default: [:]][occurrence] = fault } }
    func planner() -> (IdemRequestInfo) -> IdemFault {
        { [self] info in
            lock.withLock {
                let key = "\(info.method) \(info.route)"
                counts[key, default: 0] += 1
                return plan[key]?[counts[key]!] ?? .none
            }
        }
    }
}

@MainActor
fileprivate enum IdemProbe {
    static let root = FileManager.default.temporaryDirectory.appendingPathComponent("duo-d-idem", isDirectory: true)
    static let runs = 300
    static let p = 0.35

    static func planner(_ rng: IdemRNGBox, active: @escaping () -> Bool) -> (IdemRequestInfo) -> IdemFault {
        { _ in
            guard active() else { return .none }
            return rng.chance(p) ? rng.pick(IdemFault.lossy) : .none
        }
    }

    static func joinWorld(seed: UInt64) -> (IdemWorld, IdemScript, String, String, String) {
        let world = IdemWorld(seed: seed, root: root)
        let script = IdemScript()
        world.session.planner = script.planner()
        let owner = world.server.seedMember(name: "Sam", physical: "phone2", lastSeen: world.clock.now)
        let (duoID, code) = world.server.seedPendingDuo(owner: owner.member)
        return (world, script, owner.member, duoID, code)
    }

    static func held(_ world: IdemWorld, _ duoID: String) -> DuoState? { UUID(uuidString: duoID).flatMap { world.phone.store.duo($0) } }

    /// The disconnected phone of FD §3.4 and §3.5: a restore carried this identity to another phone,
    /// which rotated it; the partner makes a reconnect code; the first read of this launch finds the
    /// identity taken.
    static func disconnectedPhone(seed: UInt64) async -> (IdemWorld, String, String, String) {
        let world = IdemWorld(seed: seed, root: root)
        let s = world.server
        let o = s.seedMember(name: "Jo", physical: "phone1", lastSeen: world.clock.now.addingTimeInterval(-100 * 3600))
        let p = s.seedMember(name: "Sam", physical: "phone2", lastSeen: world.clock.now)
        let duo = s.seedActiveDuo(owner: o.member, partner: p.member)
        try! world.phone.identity.store(DuoCredential(memberID: o.member, deviceID: o.device, deviceSecret: o.secret))
        s.rotateSecret(device: o.device)
        let header = s.locked { s.header(s.duos[duo]!, caller: o.member) }
        var cached = DuoMapping.duo(from: header, previous: nil, now: world.clock.now)!
        cached.syncedOnce = true
        cached.cursor = 5
        world.phone.store.upsert(cached)
        let code = s.seedReconnectCode(duo: duo, creator: p.member, target: o.member)
        world.launch()
        await stageCRead(world)
        return (world, o.member, duo, code)
    }

    /// Stage C's read pass, as far as these runs need it: refused while banned, disconnected or
    /// asking the restore question; `prepare()` first; each live duo read from its cursor, or from 0
    /// when `syncedOnce` is false; `.ended` marks it ended.
    @discardableResult
    static func stageCRead(_ world: IdemWorld) async -> [String] {
        let phone = world.phone!
        let host = phone.store
        switch host.availability {
        case .banned, .disconnected, .needsRestoreChoice: return ["reads refused"]
        default: break
        }
        guard !host.duos.isEmpty, phone.identity.credential != nil else { return ["nothing to read"] }
        guard await phone.identity.prepare() == .ready else { return ["not ready"] }
        var notes: [String] = []
        for duo in host.duos where !duo.hasEnded {
            let since = duo.syncedOnce ? duo.cursor : 0
            do {
                let changes = try await phone.client.fetchChanges(duoID: duo.wireID, since: since)
                if let applied = DuoFeedReducer.apply(changes, to: duo, myToday: world.clock.today, now: world.clock.now)?.duo { host.upsert(applied) }
                notes.append("ok")
            } catch {
                let verdict = phone.dependencies.noteFailure(error, duoID: duo.id)
                if verdict == .ended {
                    host.update(duo.id) { if $0.endedAt == nil { $0.endedAt = world.clock.now; $0.endedBy = .unknown } }
                }
                notes.append("\(verdict)")
            }
        }
        return notes
    }
}

fileprivate extension RHarness {
    /// A wipe takes the accepted terms with it; the person accepts them again before the next tap.
    static func reconsent(_ h: RHarness) {
        h.kit.dependencies.cache.acceptedTermsVersion = DuoProtocolConstants.termsVersion
    }
}

// MARK: - Round three: the re-verifier's findings (D10 to D17) and its killers

/// A queue whose drain learns something about this phone from the exit it sends, as stage E's
/// does (`403 banned`, `426`, `device_revoked`), and lets the exit go.
@MainActor
fileprivate final class RLearningQueue: DuoOpQueueing {
    weak var host: DuoStore?
    let learns: DuoAvailability
    var queued: [DuoQueuedOp] = []
    private(set) var drains = 0
    init(host: DuoStore, learns: DuoAvailability) {
        self.host = host
        self.learns = learns
    }
    var pending: [DuoQueuedOp] { queued }
    func enqueue(_ op: DuoQueuedOp) { queued.append(op) }
    func drain() async {
        drains += 1
        if !queued.isEmpty {
            host?.availability = learns
            queued = []
        }
    }
    func startMonitoring() {}
    func discardAll() { queued = [] }
}

/// A queue that sends nothing and notes, at each drain, what it would have sent as.
@MainActor
fileprivate final class RNotingQueue: DuoOpQueueing {
    let note: () -> String
    var queued: [DuoQueuedOp] = []
    private(set) var seen: [String] = []
    private(set) var monitoring = 0
    init(note: @escaping () -> String) { self.note = note }
    var pending: [DuoQueuedOp] { queued }
    func enqueue(_ op: DuoQueuedOp) { queued.append(op) }
    func drain() async { seen.append(note()) }
    func startMonitoring() { monitoring += 1 }
    func discardAll() { queued = [] }
}

/// The fake identity, noting the throwaway marker each store finds, and able to refuse the store
/// as a Keychain can.
fileprivate final class RMarkerAtStore: DuoIdentityProviding, @unchecked Sendable {
    let base: FakeDuoIdentity
    let marker: () -> String?
    var refuses = false
    private(set) var markersAtStore: [String?] = []
    init(base: FakeDuoIdentity, marker: @escaping () -> String?) {
        self.base = base
        self.marker = marker
    }
    var credential: DuoCredential? { base.credential }
    var installDay: String { base.installDay }
    func store(_ credential: DuoCredential) throws {
        markersAtStore.append(marker())
        if refuses { throw NSError(domain: "stage-d", code: 1) }
        try base.store(credential)
        base.launch = .ready
    }
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() { base.discard() }
    func prepare() async -> DuoIdentityLaunch { await base.prepare() }
    func continueAsRestored() async {}
}

/// The fake identity whose launch says what `DuoIdentity`'s does when `GET /me` answers
/// `device_revoked`: the screen becomes the disconnected question, on the way.
fileprivate final class RLaunchSaysDisconnected: DuoIdentityProviding, @unchecked Sendable {
    let base: FakeDuoIdentity
    weak var host: DuoStore?
    init(base: FakeDuoIdentity, host: DuoStore) {
        self.base = base
        self.host = host
    }
    var credential: DuoCredential? { base.credential }
    var installDay: String { base.installDay }
    func store(_ credential: DuoCredential) throws {
        try base.store(credential)
        base.launch = .ready
    }
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() { base.discard() }
    func prepare() async -> DuoIdentityLaunch {
        let launch = base.launch
        if launch == .disconnected { await MainActor.run { host?.availability = .disconnected } }
        return launch
    }
    func continueAsRestored() async {}
}

fileprivate enum R3 {
    /// The throwaway a refused Reconnect left stored (D68).
    static let throwaway = DuoCredential(memberID: RF.minted.memberId, deviceID: RF.minted.deviceId, deviceSecret: RF.minted.deviceSecret)
    static let reconnectedMember = "6d2a0000-0000-4000-8000-0000000000ff"
    static let ownPending = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000e1")!
    static let seatA = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000e2")!
    static let otherK = "ZYXWVTSRQPNMKJHGFEDCBA9876"
    static func changes(_ header: DuoWireHeader) -> DuoWireChanges {
        DuoWireChanges(duo: header, full: true, statuses: [], nudges: [], handled: [], cursor: header.seq)
    }

    @MainActor
    static func start(_ flow: String, _ h: RHarness) async -> Bool {
        switch flow {
        case "create": return await h.service.createDuo(named: "Jo", skin: "classic") != nil
        case "join": return await h.service.join(RF.pendingInvite, named: "Jo", skin: "classic") != nil
        default: return await h.service.reconnect(code: "H7K39QWX")
        }
    }

    @MainActor
    static func holdTheThrowaway(_ h: RHarness) {
        h.kit.dependencies.cache.throwawayDeviceID = throwaway.deviceID
    }
}

@MainActor
final class DuoJoiningReverifyTests: XCTestCase {

    // MARK: D10: only an exit the stored credential could send refuses a start

    /// The re-verifier's end-to-end probe, with the fakes: a backup brought the duos and a queued
    /// Leave without the Keychain item. The queue keeps the Leave for the very Reconnect that D9
    /// refused, so every tap met the general line for good. The Reconnect goes now.
    func testAPhoneWithNoCredentialAndAQueuedLeaveReconnects() async throws {
        let h = RHarness()
        h.answerEverything()
        h.store.upsert(DuoFixtures.duo())
        var left = DuoFixtures.duo(id: RF.createdID)
        left.endedAt = RF.now
        left.endedBy = .owner
        left.pendingOp = .leave
        h.store.upsert(left)
        h.kit.ops.enqueue(try DuoQueuedOp.leave(duoID: RF.createdID, key: "q1", now: RF.now))
        h.store.availability = .disconnected
        h.t.onReconnect = { _, _ in
            DuoWireReconnectResponse(memberId: R3.reconnectedMember, supportId: "WXYZ5678ABCD", duos: [DuoFixtures.wireHeader()], supersededDevices: 0)
        }
        let reconnected = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(reconnected)
        XCTAssertEqual(Array(rNames(h.t.calls).prefix(2)), ["createDevice", "reconnect"])
        XCTAssertNil(h.store.sheetError)
        XCTAssertEqual(h.store.availability, .available)
        XCTAssertNil(h.kit.dependencies.cache.throwawayDeviceID)
        XCTAssertEqual(h.kit.identity.credential?.memberID, R3.reconnectedMember)
        XCTAssertEqual(h.kit.ops.queued.map(\.kind), [.leave], "the Leave waits for the reconnected member, it is not dropped")
    }

    /// The rule in every flow: no credential, or the throwaway, lets the start through; a
    /// credential the exit could go with refuses it with the general line and sends nothing.
    func testOnlyACredentialTheExitCouldGoWithMakesAQueuedExitRefuseTheStart() async throws {
        for holder in ["none", "throwaway", "own"] {
            for kind in [DuoOpKind.leave, .block] {
                for flow in ["create", "join", "reconnect"] {
                    let h = RHarness(credential: holder == "none" ? nil : holder == "throwaway" ? R3.throwaway : DuoFixtures.credential())
                    h.answerEverything()
                    if holder == "throwaway" { R3.holdTheThrowaway(h) }
                    h.kit.ops.enqueue(kind == .leave ? try DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "q1", now: RF.now)
                                                     : try DuoQueuedOp.block(duoID: DuoFixtures.duoID, key: "q1", now: RF.now))
                    let started = await R3.start(flow, h)
                    let label = "\(holder) \(kind) \(flow)"
                    XCTAssertEqual(started, holder != "own", label)
                    if holder == "own" {
                        XCTAssertTrue(h.t.calls.isEmpty, label)
                        XCTAssertEqual(h.store.sheetError, DuoUserMessage.generic, label)
                    } else {
                        XCTAssertFalse(h.t.calls.isEmpty, label)
                        XCTAssertNil(h.store.sheetError, label)
                    }
                    XCTAssertFalse(h.store.isWorking, label)
                }
            }
        }
    }

    // MARK: D11: exits held behind the throwaway go once the Reconnect has worked

    /// After a refused Reconnect the throwaway is the stored credential behind the old member's
    /// cards, and stage E holds a Leave or a Block tapped on one. The Reconnect that works drains
    /// the queue once more, with the marker gone and the reconnected member's credential stored, so
    /// the exit goes as the member it was tapped for. A Reconnect that did not work drains nothing
    /// more: the exit would go as the throwaway.
    func testAReconnectThatWorksDrainsTheHeldExitsAsTheReconnectedMember() async throws {
        let throwawayNote = "throwaway \(R3.throwaway.memberID)"
        let memberNote = "member \(R3.reconnectedMember)"
        for answer in ["200", "landed", "refused", "offline"] {
            let h = RHarness(credential: R3.throwaway)
            h.answerEverything()
            R3.holdTheThrowaway(h)
            h.store.upsert(DuoFixtures.duo())
            h.store.availability = .disconnected
            let dependencies = h.kit.dependencies
            let queue = RNotingQueue {
                "\(dependencies.credentialIsAThrowaway ? "throwaway" : "member") \(dependencies.identity.credential?.memberID ?? "none")"
            }
            dependencies.ops = queue
            queue.enqueue(try DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "q1", now: RF.now))
            switch answer {
            case "landed":
                h.t.onReconnect = { _, _ in throw DuoTransportError.inviteUnknown(RF.ctx(404)) }
                h.t.onMe = { RF.me(memberID: R3.reconnectedMember, duos: [DuoFixtures.wireHeader()]) }
            case "refused":
                h.t.onReconnect = { _, _ in throw DuoTransportError.inviteUnknown(RF.ctx(404)) }
                h.t.onMe = { RF.me(memberID: R3.throwaway.memberID) }
            case "offline":
                h.t.onReconnect = { _, _ in throw DuoTransportError.offline }
            default:
                break
            }
            let worked = await h.service.reconnect(code: "H7K39QWX")
            XCTAssertEqual(worked, answer == "200" || answer == "landed", answer)
            if worked {
                XCTAssertEqual(queue.seen, [throwawayNote, memberNote], answer)
            } else {
                XCTAssertEqual(queue.seen, [throwawayNote], "no drain after a Reconnect that did not work: \(answer)")
            }
        }
        // FakeOpQueue counts the same: two drains for a Reconnect that worked, one for a refusal.
        for refused in [false, true] {
            let h = RHarness(credential: DuoFixtures.credential())
            h.answerEverything()
            if refused { h.t.onReconnect = { _, _ in throw DuoTransportError.memberNotFresh(RF.ctx(409)) } }
            _ = await h.service.reconnect(code: "H7K39QWX")
            XCTAssertEqual(h.kit.ops.drains, refused ? 1 : 2, "refused=\(refused)")
        }
    }

    // MARK: D12, D13, D14: what the lost-seat adoption keeps and says

    /// A Join of a code that is really gone, on a phone whose earlier Create lost its answer. The
    /// adoption finds the person's own pending duo; it is kept, but it is not the join: the refusal
    /// is said and the invite they tapped stays.
    func testAJoinOfADeadCodeKeepsTheLostCreateAndSaysTheRefusal() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.store.pendingInvite = RF.pendingInvite
        h.t.onRedeemInvite = { _, _ in throw DuoTransportError.inviteUnknown(RF.ctx(404)) }
        let own = RF.header(R3.ownPending, role: .owner, state: .pending, seq: 1)
        h.t.onMe = { RF.me(memberID: DuoFixtures.credential().memberID, duos: [own]) }
        h.t.onFetchChanges = { _, _ in R3.changes(own) }
        let joined = await h.service.join(RF.pendingInvite, named: "Jo", skin: "classic")
        XCTAssertNil(joined, "the join did not happen: the code is gone")
        XCTAssertEqual(h.store.sheetError, "That invite is no longer open. Ask for a new one.")
        XCTAssertNotNil(h.store.pendingInvite, "the invite they tapped stays")
        XCTAssertEqual(h.store.duo(R3.ownPending)?.myRole, .owner, "the lost create is kept all the same")
        XCTAssertEqual(h.store.duo(R3.ownPending)?.e2eeCapable, false)
        XCTAssertTrue(h.journal.isEmpty, "the refusal settled the redeem")
        XCTAssertEqual(h.errors, ["invite_unknown"])
        XCTAssertTrue(h.kit.push.reasons.contains(.duoStarted))
        XCTAssertFalse(h.store.isWorking)

        // Listed before a partner seat, the person's own duo is still not the one returned.
        let mixed = RHarness(credential: DuoFixtures.credential())
        mixed.answerEverything()
        let seat = RF.header(R3.seatA, role: .partner, state: .active, seq: 3)
        mixed.t.onRedeemInvite = { _, _ in throw DuoTransportError.inviteTaken(RF.ctx(409)) }
        mixed.t.onMe = { RF.me(memberID: DuoFixtures.credential().memberID, duos: [own, seat]) }
        mixed.t.onFetchChanges = { id, _ in R3.changes(id == seat.id ? seat : own) }
        let found = await mixed.service.join(RF.pendingInvite, named: "Jo", skin: "classic")
        XCTAssertEqual(found?.id, R3.seatA)
        XCTAssertEqual(found?.myRole, .partner)
        XCTAssertNotNil(mixed.store.duo(R3.ownPending))
        XCTAssertNil(mixed.store.sheetError)

        // The throwaway that carried the lost create holds a duo of its own now: it is the person's
        // identity from then on, and the queue watches the network for it.
        let carried = RHarness(credential: R3.throwaway)
        carried.answerEverything()
        R3.holdTheThrowaway(carried)
        let queue = RNotingQueue { "" }
        carried.kit.dependencies.ops = queue
        carried.t.onRedeemInvite = { _, _ in throw DuoTransportError.inviteUnknown(RF.ctx(404)) }
        carried.t.onMe = { RF.me(memberID: R3.throwaway.memberID, duos: [own]) }
        carried.t.onFetchChanges = { _, _ in R3.changes(own) }
        let refused = await carried.service.join(RF.pendingInvite, named: "Jo", skin: "classic")
        XCTAssertNil(refused)
        XCTAssertNotNil(carried.store.duo(R3.ownPending))
        XCTAssertNil(carried.kit.dependencies.cache.throwawayDeviceID)
        XCTAssertEqual(queue.monitoring, 1)
    }

    /// A join of invite A lost its answer (a typed code, no `k`); a Join of invite B (a link with
    /// its own `k`) is refused as taken. The one seat found is A's, so B's secret is never kept
    /// for it, and no adopted seat says it is end-to-end capable.
    func testAnAdoptedSeatIsNeverGivenThisInvitesSecret() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        let b = DuoPendingInvite(code: "K7M39QWX", k: R3.otherK, receivedAt: RF.now)
        let seat = RF.header(R3.seatA, role: .partner, state: .active, seq: 3)
        h.t.onRedeemInvite = { _, _ in throw DuoTransportError.inviteTaken(RF.ctx(409)) }
        h.t.onMe = { RF.me(memberID: DuoFixtures.credential().memberID, duos: [seat]) }
        h.t.onFetchChanges = { _, _ in R3.changes(seat) }
        let joined = await h.service.join(b, named: "Jo", skin: "classic")
        XCTAssertEqual(joined?.id, R3.seatA)
        XCTAssertNil(h.kit.dependencies.secrets.linkSecret(forDuo: R3.seatA), "B's secret is not kept for a duo it may never have belonged to")
        XCTAssertEqual(h.store.duo(R3.seatA)?.e2eeCapable, false)
    }

    /// A 401 met while the adoption reads a seat's rows forgets the identity and ends the duos it
    /// held. The adoption stops there: no seat is kept as a live card with no identity behind it,
    /// not even one read before the 401, and the join says the failure.
    func testA401WhileReadingASeatStopsTheAdoption() async {
        for seats in [1, 2] {
            let h = RHarness(credential: DuoFixtures.credential())
            h.answerEverything()
            h.store.upsert(DuoFixtures.duo())
            let headers = seats == 1 ? [RF.header(RF.joinedID, role: .partner, state: .active, seq: 7)]
                                     : [RF.header(RF.joinedID, role: .partner, state: .active, seq: 7), RF.header(R3.seatA, role: .partner, state: .active, seq: 3)]
            h.t.onRedeemInvite = { _, _ in throw DuoTransportError.inviteUnknown(RF.ctx(404)) }
            h.t.onMe = { RF.me(memberID: DuoFixtures.credential().memberID, duos: headers) }
            let reads = RBox(0)
            h.t.onFetchChanges = { id, _ in
                reads.value += 1
                if reads.value == seats { throw DuoTransportError.unauthenticated(RF.ctx(401)) }
                return R3.changes(headers.first { $0.id == id } ?? headers[0])
            }
            let joined = await h.service.join(RF.pendingInvite, named: "Sam", skin: "classic")
            XCTAssertNil(joined, "seats=\(seats)")
            XCTAssertNil(h.kit.identity.credential, "the 401 forgot the identity")
            XCTAssertTrue(h.store.activeDuos.isEmpty, "no live card is left with no identity behind it: seats=\(seats)")
            XCTAssertNil(h.store.duo(RF.joinedID))
            XCTAssertNil(h.store.duo(R3.seatA))
            XCTAssertEqual(h.store.sheetError, RF.general, "seats=\(seats)")
            XCTAssertFalse(h.store.isWorking)
        }
    }

    // MARK: D15, D16: what the drain and the launch learn

    /// A ban or an update needed, learned from the exit the drain sent: nothing is minted or sent
    /// after it, in any flow, the disconnected Reconnect included.
    func testABanOrAnUpdateLearnedInTheDrainStopsTheFlowWithNothingSent() async throws {
        for learns in [DuoAvailability.banned, .upgradeRequired] {
            for flow in ["create", "join", "reconnect", "disconnected"] {
                let h = RHarness(credential: DuoFixtures.credential())
                h.answerEverything()
                let queue = RLearningQueue(host: h.store, learns: learns)
                h.kit.dependencies.ops = queue
                queue.enqueue(try DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "q1", now: RF.now))
                if flow == "disconnected" {
                    h.store.upsert(DuoFixtures.duo())
                    h.store.availability = .disconnected
                }
                let started = await R3.start(flow == "disconnected" ? "reconnect" : flow, h)
                let label = "\(learns) \(flow)"
                XCTAssertFalse(started, label)
                XCTAssertTrue(h.t.calls.isEmpty, "nothing minted or sent: \(label)")
                XCTAssertEqual(h.store.availability, learns, label)
                XCTAssertEqual(h.kit.identity.credential, DuoFixtures.credential(), label)
                XCTAssertNil(h.kit.dependencies.cache.throwawayDeviceID, label)
                XCTAssertFalse(h.store.isWorking, label)
            }
        }
    }

    /// The drain's exit can be the request that learns another phone took the identity. The
    /// Reconnect then goes as a disconnected phone's does, with a throwaway, not with the revoked
    /// bearer.
    func testADrainThatLearnsThePhoneWasDisconnectedReconnectsWithAThrowaway() async throws {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.store.upsert(DuoFixtures.duo())
        let queue = RLearningQueue(host: h.store, learns: .disconnected)
        h.kit.dependencies.ops = queue
        queue.enqueue(try DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "q1", now: RF.now))
        let reconnected = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(reconnected)
        XCTAssertEqual(Array(rNames(h.t.calls).prefix(2)), ["createDevice", "reconnect"])
        XCTAssertEqual(h.kit.identity.credential?.deviceID, RF.minted.deviceId)
    }

    /// A Reconnect tap that learns only in its own launch that the phone was disconnected used to
    /// send nothing and say nothing. It goes on: the throwaway is minted and the reconnect sent;
    /// the next tap reuses that throwaway and replays the same request.
    func testAReconnectTapThatLearnsInItsOwnLaunchThatThePhoneWasDisconnectedGoesOn() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.store.upsert(DuoFixtures.duo())
        h.kit.identity.launch = .disconnected
        h.kit.dependencies.identity = RLaunchSaysDisconnected(base: h.kit.identity, host: h.store)
        // A 503 reads as the service paused; the tap keeps the phone on the disconnected question.
        h.t.onReconnect = { _, _ in throw DuoTransportError.maintenance(RF.ctx(503)) }
        let first = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(first)
        XCTAssertEqual(rNames(h.t.calls), ["createDevice", "reconnect"], "the first tap mints the throwaway and sends")
        XCTAssertEqual(h.kit.dependencies.cache.throwawayDeviceID, RF.minted.deviceId)
        XCTAssertEqual(h.store.availability, .disconnected)
        XCTAssertEqual(h.store.sheetError, RF.joiningPaused)
        XCTAssertFalse(h.store.isWorking)
        let second = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(second)
        XCTAssertEqual(rNames(h.t.calls), ["createDevice", "reconnect", "reconnect"], "the second tap mints nothing more")
        let keys = h.t.calls.compactMap { call -> String? in
            if case .reconnect(_, let key) = call { return key.value }
            return nil
        }
        XCTAssertEqual(keys.count, 2)
        XCTAssertEqual(Set(keys).count, 1, "the lost request is replayed under its key")
    }

    /// D16's limits: a launch that moved the screen to the disconnected question after the mint it
    /// led to failed is not a reason for a second mint in the same tap, and a throwaway already
    /// stored is never minted over.
    func testALaunchThatSaysDisconnectedNeverMintsTwiceInATapOrOverAThrowaway() async {
        let none = RHarness()
        none.answerEverything()
        let flipping = RFlippingIdentity(flipTo: .disconnected)
        flipping.host = none.store
        none.kit.dependencies.identity = flipping
        none.t.onCreateDevice = { _ in throw DuoTransportError.offline }
        let a = await none.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(a)
        XCTAssertEqual(rNames(none.t.calls), ["createDevice"])
        XCTAssertEqual(none.store.sheetError, RF.offline)

        let held = RHarness(credential: R3.throwaway)
        held.answerEverything()
        R3.holdTheThrowaway(held)
        held.kit.identity.launch = .disconnected
        held.kit.dependencies.identity = RLaunchSaysDisconnected(base: held.kit.identity, host: held.store)
        let b = await held.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(b)
        XCTAssertTrue(held.t.calls.isEmpty)
        XCTAssertEqual(held.store.availability, .disconnected)
        XCTAssertEqual(held.kit.identity.credential, R3.throwaway)
    }

    // MARK: D17: the marker goes down before the throwaway is stored

    func testTheThrowawaysMarkerIsDownBeforeItIsStoredAndOnlyForAThrowaway() async {
        // The throwaway a disconnected phone mints.
        let d = RHarness(credential: DuoFixtures.credential())
        d.answerEverything()
        d.store.upsert(DuoFixtures.duo())
        d.store.availability = .disconnected
        let dCache = d.kit.dependencies.cache
        let dSpy = RMarkerAtStore(base: d.kit.identity, marker: { dCache.throwawayDeviceID })
        d.kit.dependencies.identity = dSpy
        d.t.onReconnect = { _, _ in throw DuoTransportError.offline }
        _ = await d.service.reconnect(code: "H7K39QWX")
        XCTAssertEqual(dSpy.markersAtStore, [RF.minted.deviceId], "the marker was down when the throwaway was stored")
        XCTAssertEqual(dCache.throwawayDeviceID, RF.minted.deviceId)

        // A Create's or a Join's identity is never marked, not even for a moment.
        for flow in ["create", "join"] {
            let h = RHarness()
            h.answerEverything()
            let cache = h.kit.dependencies.cache
            let spy = RMarkerAtStore(base: h.kit.identity, marker: { cache.throwawayDeviceID })
            h.kit.dependencies.identity = spy
            _ = await R3.start(flow, h)
            XCTAssertEqual(spy.markersAtStore, [String?.none], flow)
            XCTAssertNil(cache.throwawayDeviceID, flow)
        }

        // A store the Keychain refuses puts back the marker that was there before.
        for earlier in [String?.none, "6d2a0000-0000-4000-8000-0000000000ee"] {
            let r = RHarness(credential: DuoFixtures.credential())
            r.answerEverything()
            r.store.upsert(DuoFixtures.duo())
            r.store.availability = .disconnected
            let cache = r.kit.dependencies.cache
            cache.throwawayDeviceID = earlier
            let spy = RMarkerAtStore(base: r.kit.identity, marker: { cache.throwawayDeviceID })
            spy.refuses = true
            r.kit.dependencies.identity = spy
            let ok = await r.service.reconnect(code: "H7K39QWX")
            XCTAssertFalse(ok)
            XCTAssertEqual(spy.markersAtStore, [RF.minted.deviceId])
            XCTAssertEqual(cache.throwawayDeviceID, earlier, "the marker names no device that was never stored")
            XCTAssertEqual(r.kit.identity.credential, DuoFixtures.credential(), "the revoked credential stays")
            XCTAssertEqual(rNames(r.t.calls), ["createDevice"])
            XCTAssertEqual(r.store.sheetError, DuoUserMessage.generic)
            XCTAssertEqual(r.store.availability, .disconnected)
        }
    }

    // MARK: D18: the re-verifier's killers for the five mutants that survived round two

    /// M07: only a Reconnect's identity is a throwaway. A Create or a Join that minted and then
    /// failed leaves the person's own identity, with no marker: a marker left there would make the
    /// person's own duos read as disconnected after the next relaunch.
    func testKillM07_AnIdentityMintedForACreateOrAJoinIsNeverMarkedAThrowaway() async {
        for flow in ["create", "join"] {
            let h = RHarness()
            h.answerEverything()
            h.t.onCreateDuo = { _, _ in throw DuoTransportError.offline }
            h.t.onRedeemInvite = { _, _ in throw DuoTransportError.offline }
            _ = await R3.start(flow, h)
            XCTAssertEqual(h.kit.identity.credential?.deviceID, RF.minted.deviceId, flow)
            XCTAssertNil(h.kit.dependencies.cache.throwawayDeviceID, "\(flow): a Create's or a Join's identity is the person's own")
        }
    }

    /// M21 and M22: D3 brings back only a duo this phone ended on its own guess (`ended_by`
    /// unknown) with nothing still on its way for it. A duo the person left (their own role) or
    /// one whose Leave is still marked on the card stays ended though the server lists it live.
    func testKillM21M22_D3RevivesOnlyAGuessWithNothingPending() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.store.availability = .disconnected
        let guessed = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000f1")!
        let left = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000f2")!
        let leaving = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000f3")!
        var g = DuoFixtures.duo(id: guessed)
        g.endedAt = RF.now
        g.endedBy = .unknown
        var l = DuoFixtures.duo(id: left)
        l.endedAt = RF.now
        l.endedBy = .owner
        var p = DuoFixtures.duo(id: leaving)
        p.endedAt = RF.now
        p.endedBy = .unknown
        p.pendingOp = .leave
        h.store.upsert(g)
        h.store.upsert(l)
        h.store.upsert(p)
        h.t.onReconnect = { _, _ in
            DuoWireReconnectResponse(memberId: DuoFixtures.credential().memberID, supportId: "WXYZ5678ABCD",
                                     duos: [guessed, left, leaving].map { DuoFixtures.wireHeader(id: $0) }, supersededDevices: 1)
        }
        h.t.onMe = { throw DuoTransportError.offline }
        let ok = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(ok)
        XCTAssertEqual(h.store.duo(guessed)?.hasEnded, false, "the guess the server contradicts is taken back")
        XCTAssertEqual(h.store.duo(left)?.hasEnded, true, "a duo the person left stays ended")
        XCTAssertEqual(h.store.duo(leaving)?.hasEnded, true, "a Leave still marked on the card is not undone")
    }

    /// M58: the reconnect's 200 is about the device it was sent as. If the stored credential changed
    /// while it was out (another flow stored or dropped one), the answer is not written over it.
    func testKillM58_AReconnectAnswerForADeviceNoLongerStoredIsNotKept() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        let other = DuoCredential(memberID: "6d2a0000-0000-4000-8000-0000000000ee", deviceID: "6d2a0000-0000-4000-8000-0000000000ef",
                                  deviceSecret: String(repeating: "o", count: 43), secretVersion: 1)
        let identity = h.kit.identity
        h.t.onReconnect = { _, _ in
            identity.credential = other
            return DuoWireReconnectResponse(memberId: R3.reconnectedMember, supportId: "WXYZ5678ABCD",
                                            duos: [DuoFixtures.wireHeader()], supersededDevices: 1)
        }
        h.t.onMe = { throw DuoTransportError.offline }
        let ok = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(ok)
        XCTAssertEqual(h.kit.identity.credential, other, "the newer credential is not overwritten by the old device's answer")
        XCTAssertNil(h.store.duo(DuoFixtures.duoID), "nothing from that answer is kept")
        XCTAssertEqual(h.kit.ops.drains, 1, "and nothing is drained for it")
    }

    /// M64: a wipe while the adoption's GET /me is out drops everything after it: no words, nothing
    /// in Diagnostics, nothing put back in the journal.
    func testKillM64_AWipeWhileTheAdoptionAsksGetMeDropsEverythingAfterIt() async {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.t.onRedeemInvite = { _, _ in throw DuoTransportError.inviteUnknown(RF.ctx(404)) }
        h.t.onMe = { RF.me(memberID: DuoFixtures.credential().memberID) }
        let gated = RGatedTransport(h.t)
        let gate = RTwoGates()
        gated.meGate = gate
        h.kit.dependencies.transport = gated
        let service = h.service
        let task = Task { await service.join(RF.pendingInvite, named: "Sam", skin: "classic") }
        for _ in 0..<1_000 where gate.entered == 0 { await Task.yield() }
        guard gate.entered == 1 else {
            gate.release(1)
            _ = await task.value
            return XCTFail("GET /me was never asked")
        }
        h.store.resetLocalState()
        gate.release(1)
        let joined = await task.value
        XCTAssertNil(joined)
        XCTAssertNil(h.store.sheetError, "no words after the wipe")
        XCTAssertTrue(h.errors.isEmpty, "nothing written to Diagnostics after the wipe")
        XCTAssertTrue(h.journal.isEmpty)
    }

    // MARK: D18: the re-verifier's other probes

    /// D9 when the queue holds an exit that waits: the start is refused with the general line and
    /// nothing sent (the copy question is the coordinator's, decided).
    func testAQueuedLeaveThatWaitsIsSaidAsTheGeneralLine() async throws {
        let h = RHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.kit.ops.enqueue(try DuoQueuedOp.leave(duoID: DuoFixtures.duoID, key: "k1", now: RF.now))
        let made = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(made)
        XCTAssertEqual(h.store.sheetError, DuoUserMessage.generic)
        XCTAssertEqual(h.kit.ops.drains, 1)
        XCTAssertTrue(h.t.calls.isEmpty)
        XCTAssertFalse(h.store.isWorking)
    }

    /// The hold: taken once per mint and released on every path, a mint the wipe overtook and a
    /// cancelled one included.
    func testTheHoldIsReleasedOnEveryPath() async {
        for path in ["success", "offline", "cancelled", "storeFails", "wiped"] {
            let h = RHarness()
            h.answerEverything()
            h.t.onCreateDuo = { _, _ in throw DuoTransportError.offline }
            switch path {
            case "offline": h.t.onCreateDevice = { _ in throw DuoTransportError.offline }
            case "cancelled": h.t.onCreateDevice = { _ in throw CancellationError() }
            case "storeFails":
                let cache = h.kit.dependencies.cache
                let spy = RMarkerAtStore(base: h.kit.identity, marker: { cache.throwawayDeviceID })
                spy.refuses = true
                h.kit.dependencies.identity = spy
            default: break
            }
            if path == "wiped" {
                let gated = RGatedTransport(h.t)
                let gate = RTwoGates()
                gated.deviceGate = gate
                h.kit.dependencies.transport = gated
                let service = h.service
                let task = Task { await service.createDuo(named: "Jo", skin: "classic") }
                for _ in 0..<1_000 where gate.entered == 0 { await Task.yield() }
                h.store.resetLocalState()
                gate.release(1)
                _ = await task.value
            } else {
                _ = await h.service.createDuo(named: "Jo", skin: "classic")
            }
            XCTAssertEqual(h.events.value.filter { $0 == "hold" }.count, 1, path)
            XCTAssertEqual(h.events.value.filter { $0 == "release" }.count, 1, path)
            XCTAssertFalse(h.store.isWorking, path)
        }
    }
}
#endif
