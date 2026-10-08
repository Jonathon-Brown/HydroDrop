#if DUO_V2
import XCTest
@testable import HydroDrop

// MARK: - Test helpers (stage D)

/// A box a transport handler (which runs off the main actor) can write to and a test can read.
fileprivate final class DBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}

/// What each attempt of one endpoint answers, in order: an error to throw, or nil for success.
/// Once the list runs out every attempt succeeds.
fileprivate final class DScript: @unchecked Sendable {
    private let box: DBox<[Error?]>
    init(_ outcomes: [Error?]) { box = DBox(outcomes) }
    func next() throws {
        var outcomes = box.value
        guard !outcomes.isEmpty else { return }
        let outcome = outcomes.removeFirst()
        box.value = outcomes
        if let outcome { throw outcome }
    }
    func set(_ outcomes: [Error?]) { box.value = outcomes }
}

/// A DeviceCheck whose token is new on every call. The shared fake answers one constant, which
/// would hide a redeem that sent a new token, and so new bytes, under a recorded key.
fileprivate final class DChangingDeviceCheck: DuoDeviceCheckProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var isSupported: Bool { true }
    var calls: Int { lock.lock(); defer { lock.unlock() }; return count }
    func token() async -> String? {
        let n = lock.withLock { () -> Int in
            count += 1
            return count
        }
        return "dc-token-\(n)"
    }
}

/// The shared op queue double, with `startMonitoring` counted (the shared one ignores it).
@MainActor
fileprivate final class DMonitoredOps: DuoOpQueueing {
    let base = FakeOpQueue()
    private(set) var monitoring = 0
    var pending: [DuoQueuedOp] { base.pending }
    func enqueue(_ op: DuoQueuedOp) { base.enqueue(op) }
    func drain() async { await base.drain() }
    func startMonitoring() { monitoring += 1 }
    func discardAll() { base.discardAll() }
    func discardIdentityBound() { base.discardIdentityBound() }
}

/// Holds the first call until the test lets it go; any later call goes straight through, so a
/// bug that lets a second tap send fails its test instead of waiting on the gate for ever.
fileprivate final class DGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var entries = 0

    var entered: Int { lock.lock(); defer { lock.unlock() }; return entries }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            entries += 1
            if released || entries > 1 {
                lock.unlock()
                continuation.resume()
            } else {
                waiting.append(continuation)
                lock.unlock()
            }
        }
    }

    func release() {
        lock.lock()
        released = true
        let resumed = waiting
        waiting = []
        lock.unlock()
        resumed.forEach { $0.resume() }
    }
}

/// `FakeDuoTransport` with a gate in front of the mint and a main-actor hook that runs while a
/// chosen request is out: after the fake has answered it, before the service sees the answer.
fileprivate final class DHookedTransport: DuoTransport, @unchecked Sendable {
    let base: FakeDuoTransport
    var mintGate: DGate?
    var whileMintIsOut: (@MainActor @Sendable () -> Void)?
    var whileCreateIsOut: (@MainActor @Sendable () -> Void)?
    var whileRedeemIsOut: (@MainActor @Sendable () -> Void)?
    var whileReconnectIsOut: (@MainActor @Sendable () -> Void)?

    init(_ base: FakeDuoTransport) { self.base = base }

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse {
        if let mintGate { await mintGate.wait() }
        let answer = try await base.createDevice(request)
        if let whileMintIsOut { await whileMintIsOut() }
        return answer
    }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse {
        let answer = try await base.createDuo(request, key: key)
        if let whileCreateIsOut { await whileCreateIsOut() }
        return answer
    }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult {
        let answer = try await base.redeemInvite(request, key: key)
        if let whileRedeemIsOut { await whileRedeemIsOut() }
        return answer
    }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse {
        let answer = try await base.reconnect(request, key: key)
        if let whileReconnectIsOut { await whileReconnectIsOut() }
        return answer
    }

    func attestChallenge() async throws -> DuoWireAttestChallenge { try await base.attestChallenge() }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { try await base.rotate(as: credential) }
    func me() async throws -> DuoWireGetMeResponse { try await base.me() }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { try await base.updateMe(request) }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { try await base.deleteMe(request, key: key) }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { try await base.registerPush(request, firstUpload: firstUpload) }
    func unregisterPush() async throws { try await base.unregisterPush() }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { try await base.createInvite(duoID: duoID, purpose: purpose, key: key) }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try await base.peekInvite(code: code) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try await base.fetchDuo(id: id) }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try await base.fetchChanges(duoID: duoID, since: since) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { try await base.pushDayStatuses(duoID: duoID, request) }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try await base.sendNudge(duoID: duoID, request) }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { try await base.leave(duoID: duoID, key: key) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try await base.block(duoID: duoID, key: key) }
}

/// The calls, by name, for a test that says what was sent and in which order.
fileprivate func dNames(_ calls: [FakeDuoTransport.Call]) -> [String] {
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

/// Every body a recorded call would have carried, as the API client writes it.
fileprivate func dBodies(_ calls: [FakeDuoTransport.Call]) -> [String] {
    calls.compactMap { call -> Data? in
        switch call {
        case .createDevice(let request): return try? DuoWireCoding.encode(request)
        case .updateMe(let request): return try? DuoWireCoding.encode(request)
        case .deleteMe(let request, _): return try? DuoWireCoding.encode(request)
        case .registerPush(let request, _): return try? DuoWireCoding.encode(request)
        case .createDuo(let request, _): return try? DuoWireCoding.encode(request)
        case .createInvite(_, let purpose, _): return try? DuoWireCoding.encode(DuoWireCreateInviteRequest(purpose: purpose))
        case .peekInvite(let code): return try? DuoWireCoding.encode(DuoWirePeekRequest(code: code))
        case .redeemInvite(let request, _): return try? DuoWireCoding.encode(request)
        case .reconnect(let request, _): return try? DuoWireCoding.encode(request)
        case .pushDayStatuses(_, let request): return try? DuoWireCoding.encode(request)
        case .sendNudge(_, let request): return try? DuoWireCoding.encode(request)
        case .attestChallenge, .rotate, .me, .unregisterPush, .fetchDuo, .fetchChanges, .leave, .block: return nil
        }
    }.map { String(decoding: $0, as: UTF8.self) }
}

fileprivate extension FakeDuoTransport {
    var dMints: [DuoWireCreateDeviceRequest] { calls.compactMap { if case .createDevice(let request) = $0 { return request }; return nil } }
    var dCreates: [(request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey)] {
        calls.compactMap { if case .createDuo(let request, let key) = $0 { return (request, key) }; return nil }
    }
    var dRedeems: [(request: DuoWireRedeemRequest, key: DuoIdempotencyKey)] {
        calls.compactMap { if case .redeemInvite(let request, let key) = $0 { return (request, key) }; return nil }
    }
    var dReconnects: [(request: DuoWireReconnectRequest, key: DuoIdempotencyKey)] {
        calls.compactMap { if case .reconnect(let request, let key) = $0 { return (request, key) }; return nil }
    }
}

fileprivate enum DFixtures {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    /// `now` in the test clock's UTC calendar.
    static let today = "2026-09-21"
    static let inviteExpiry = Date(timeIntervalSince1970: 1_790_172_800)
    static let k = "ABCDEFGHJKMNPQRSTVWXYZ0123"
    static let createdID = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000c1")!
    static let joinedID = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000c2")!
    static let otherID = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000c3")!
    static let reconnectedMember = "6d2a0000-0000-4000-8000-0000000000ff"

    /// Five days with something in them, so the outbox makes five rows: today at 50, then 100,
    /// 25, 75 and 100; the two oldest days of the week are empty and are not sent.
    static let log = DuoLogSummary(totalsByDay: ["2026-09-21": 1000, "2026-09-20": 2000, "2026-09-19": 500, "2026-09-18": 1500, "2026-09-17": 2000],
                                   goalML: 2000, earliestEntryDay: "2026-08-01")

    static let minted = DuoWireCreateDeviceResponse(memberId: "6d2a0000-0000-4000-8000-0000000000cc", deviceId: "6d2a0000-0000-4000-8000-0000000000dd",
                                                    deviceSecret: String(repeating: "t", count: 43), tier: .attested, supportId: "ABCD1234EFGH")
    static var mintedCredential: DuoCredential {
        DuoCredential(memberID: minted.memberId, deviceID: minted.deviceId, deviceSecret: minted.deviceSecret)
    }

    static func header(_ id: UUID, role: DuoRole, state: DuoWireDuoState, seq: Int64, partnerLastWriteDay: String? = nil) -> DuoWireHeader {
        DuoWireHeader(id: id.uuidString.lowercased(), myRole: role, state: state, createdAt: Date(timeIntervalSince1970: 1_789_900_000),
                      joinedAt: state == .pending ? nil : Date(timeIntervalSince1970: 1_789_950_000),
                      endedAt: state == .ended ? Date(timeIntervalSince1970: 1_789_990_000) : nil, endedBy: state == .ended ? .partner : nil,
                      ownerDisplayName: "Jo", ownerSkin: "classic", partnerDisplayName: state == .pending ? nil : "Sam",
                      partnerSkin: state == .pending ? nil : "forest", partnerLastWriteDay: partnerLastWriteDay, partnerIsDemo: false,
                      invite: DuoWireHeaderInvite(hasOpenInvite: state == .pending, expiresAt: state == .pending ? inviteExpiry : nil), seq: seq)
    }

    static let wireInvite = DuoWireInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: inviteExpiry)

    /// Today and yesterday taken, the 17th unchanged, the 19th refused for good and the 18th for a
    /// version conflict, which re-bases instead and is not kept.
    static let createResponse = DuoWireCreateDuoResponse(
        duo: header(createdID, role: .owner, state: .pending, seq: 1), invite: wireInvite,
        accepted: ["2026-09-21", "2026-09-20"], unchanged: ["2026-09-17"],
        rejected: [DuoWireRejected(day: "2026-09-19", reason: .dayOutOfRange), DuoWireRejected(day: "2026-09-18", reason: .verConflict)]
    )

    static func joinedChanges(_ id: UUID = joinedID) -> DuoWireChanges {
        DuoWireChanges(duo: header(id, role: .partner, state: .active, seq: 7), full: true,
                       statuses: [DuoFixtures.wireRow(.owner, "2026-09-21", bucket: 100, ver: 3), DuoFixtures.wireRow(.owner, "2026-09-20", bucket: 50, ver: 2),
                                  DuoFixtures.wireRow(.partner, "2026-09-21", bucket: 50, ver: 1), DuoFixtures.wireRow(.partner, "2026-09-20", bucket: 100, ver: 1)],
                       nudges: [], handled: [], cursor: 7)
    }

    static let redeemResult = DuoWireChangesWithResult(changes: joinedChanges(), accepted: ["2026-09-21", "2026-09-20"], unchanged: [],
                                                       rejected: [DuoWireRejected(day: "2026-09-19", reason: .statusInconsistent)])

    static func me(memberID: String = "6d2a0000-0000-4000-8000-0000000000aa", duos: [DuoWireHeader]) -> DuoWireGetMeResponse {
        DuoWireGetMeResponse(member: DuoWireMember(id: memberID, displayName: "Sam", skin: "forest", supportId: "WXYZ5678ABCD", tier: .attested, termsVersion: 1),
                             limits: DuoWireLimits(nudgesPerDay: 3, maxActiveDuos: 5), devices: [], duos: duos,
                             minClient: DuoWireMinClient(ios: "2.0", android: "1.1"))
    }

    static func reconnected(duos: [DuoWireHeader], memberID: String = reconnectedMember) -> DuoWireReconnectResponse {
        DuoWireReconnectResponse(memberId: memberID, supportId: "WXYZ5678ABCD", duos: duos, supersededDevices: 1)
    }

    static let peek = DuoWirePeekResponse(purpose: "invite", state: "open", expiresAt: inviteExpiry, inviterDisplayName: "Alex", inviterSkin: "forest")

    static var pendingInvite: DuoPendingInvite { DuoPendingInvite(code: "H7K39QWX", k: k, receivedAt: now) }

    static func context(_ status: Int, details: DuoWireErrorDetails? = nil) -> DuoErrorContext {
        DuoErrorContext(httpStatus: status, requestID: "req-1", details: details)
    }

    static func member(termsVersion: Int) -> DuoMemberInfo {
        DuoMemberInfo(memberID: DuoFixtures.credential().memberID, displayName: "Jo", skin: "classic", supportID: "ABCD1234EFGH", tier: .attested,
                      termsVersion: termsVersion, nudgesPerDay: 3, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: now)
    }
}

/// A real store over a throwaway cache, every service a fake but this stage's, a person who has
/// passed the birth-year screen and accepted the rules, and a week of the log.
@MainActor
fileprivate struct DHarness {
    let kit: DuoTestKit
    let service: DuoJoiningService
    let ops: DMonitoredOps
    /// Every background hold the service took and gave back, in order.
    let holds = DBox<[String]>([])

    init(credential: DuoCredential? = nil, subscribed: Bool = false, age: DuoAgeStatus = .allowed, termsAccepted: Bool = true) {
        let kit = DuoTestKit(credential: credential, isSubscribed: subscribed)
        // The real identity answers `.ready` for a credential and its marker on an ordinary launch.
        if credential != nil { kit.identity.launch = .ready }
        kit.dependencies.cache.ageStatus = age
        kit.dependencies.cache.acceptedTermsVersion = termsAccepted ? DuoProtocolConstants.termsVersion : 0
        kit.store.latest = DFixtures.log
        let ops = DMonitoredOps()
        kit.dependencies.ops = ops
        let service = DuoJoiningService(dependencies: kit.dependencies)
        let holds = self.holds
        service.holdInBackground = { reason in
            holds.value.append("hold")
            return { holds.value.append("release") }
        }
        kit.dependencies.joining = service
        self.kit = kit
        self.ops = ops
        self.service = service
    }

    var transport: FakeDuoTransport { kit.transport }
    var store: DuoStore { kit.store }
    var cache: DuoCache { kit.dependencies.cache }
    var journal: [DuoInflightJournal.Entry] { cache.loadInflight(now: DFixtures.now).entries }

    /// Every endpoint a joining flow can reach, answering as the happy path does.
    func answerEverything() {
        transport.onCreateDevice = { _ in DFixtures.minted }
        transport.onCreateDuo = { _, _ in DFixtures.createResponse }
        transport.onRedeemInvite = { _, _ in DFixtures.redeemResult }
        transport.onReconnect = { _, _ in DFixtures.reconnected(duos: []) }
        transport.onPeekInvite = { _ in DFixtures.peek }
        transport.onCreateInvite = { _, _, _ in DFixtures.wireInvite }
        transport.onMe = { DFixtures.me(duos: []) }
        transport.onUpdateMe = { _ in DuoWireMember(id: "m", supportId: "ABCD1234EFGH", tier: .attested, termsVersion: 1) }
    }
}

// MARK: - The tests

@MainActor
final class DuoJoiningServiceTests: XCTestCase {

    // MARK: Create

    func testCreateMintsAnIdentityThenCreatesTheDuoAndKeepsWhatTheAnswerSaid() async throws {
        let h = DHarness()
        h.answerEverything()
        let created = await h.service.createDuo(named: "   ", skin: "classic")
        let duo = try XCTUnwrap(created)

        XCTAssertEqual(dNames(h.transport.calls), ["createDevice", "createDuo"], "the mint is the tap's first request, the create its second")
        XCTAssertEqual(h.transport.dMints, [DuoWireCreateDeviceRequest(appVersion: "2.0 (57)", termsVersion: 1, deviceCheckToken: "RGV2aWNlQ2hlY2s=")])
        XCTAssertEqual(h.kit.identity.stored, [DFixtures.mintedCredential])
        XCTAssertEqual(h.store.memberInfo?.memberID, DFixtures.minted.memberId)
        XCTAssertEqual(h.store.memberInfo?.supportID, "ABCD1234EFGH")
        XCTAssertEqual(h.store.memberInfo?.tier, .attested)
        XCTAssertEqual(h.store.memberInfo?.updatedAt, .distantPast, "partial, so the next GET /me fills it in")

        let sent = try XCTUnwrap(h.transport.dCreates.first).request
        let bytes = String(decoding: try DuoWireCoding.encode(sent), as: UTF8.self)
        XCTAssertTrue(bytes.contains("\"display_name\":null"), "a name of spaces is no name, sent as null: \(bytes)")
        XCTAssertTrue(bytes.contains("\"e2ee_capable\":true"))
        XCTAssertEqual(sent.myToday, DFixtures.today)
        XCTAssertEqual(sent.statuses.map(\.day), ["2026-09-21", "2026-09-20", "2026-09-19", "2026-09-18", "2026-09-17"])
        XCTAssertEqual(sent.statuses.map(\.progressBucket), [50, 100, 25, 75, 100])
        XCTAssertLessThanOrEqual(sent.statuses.count, 7)
        XCTAssertTrue(sent.statuses.allSatisfy { $0.baseVer == 0 }, "a duo being made has no rows to compare against")

        XCTAssertEqual(duo.id, DFixtures.createdID)
        XCTAssertEqual(duo.myRole, .owner)
        XCTAssertTrue(duo.isPending)
        XCTAssertEqual(duo.invite, DuoInvite(code: "H7K39QWX", display: "H7K3-9QWX", expiresAt: DFixtures.inviteExpiry))
        XCTAssertEqual(duo.openInviteExpiresAt, DFixtures.inviteExpiry)
        XCTAssertEqual(duo.cursor, 1)
        XCTAssertTrue(duo.syncedOnce, "the create is the duo's first accepted batch")
        XCTAssertTrue(duo.e2eeCapable)
        XCTAssertEqual(Set(duo.statuses.map(\.day)), ["2026-09-21", "2026-09-20", "2026-09-17"], "accepted and unchanged rows are mine as sent")
        XCTAssertTrue(duo.statuses.allSatisfy { $0.role == .owner && $0.updatedAt == DFixtures.now })
        XCTAssertEqual(duo.vers, ["owner-2026-09-21": 1, "owner-2026-09-20": 1], "every accepted row inserts at ver 1, and only those")
        let refused = h.cache.loadRejectedDays()[DFixtures.createdID.uuidString.lowercased()]
        XCTAssertEqual(refused?.rows.keys.sorted(), ["2026-09-19"], "a lasting refusal is kept; a version conflict is not")
        XCTAssertEqual(refused?.rows["2026-09-19"]?.progressBucket, 25)

        let k = try XCTUnwrap(h.kit.dependencies.secrets.linkSecret(forDuo: duo.id))
        XCTAssertTrue(DuoInviteCode.isLinkSecret(k))
        XCTAssertFalse(dBodies(h.transport.calls).contains { $0.contains(k) }, "k never leaves the phone")
        XCTAssertEqual(h.store.duos.map(\.id), [DFixtures.createdID])
        XCTAssertEqual(h.kit.push.reasons, [.duoStarted])
        XCTAssertEqual(h.ops.monitoring, 1)
        XCTAssertEqual(h.store.myDisplayName, "")
        XCTAssertNil(h.store.sheetError)
        XCTAssertFalse(h.store.isWorking)
        XCTAssertEqual(h.store.availability, .available)
        XCTAssertTrue(h.journal.isEmpty, "a 201 that was read settles the request")
    }

    func testTheCreateIsWrittenToTheJournalBeforeItIsSent() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        let cache = h.cache
        let seen = DBox<[String]>([])
        h.transport.onCreateDuo = { request, key in
            let entry = cache.loadInflight(now: DFixtures.now).entries.first
            seen.value = [entry?.operation ?? "none", entry?.key == key ? "same key" : "another key",
                          entry?.body == (try? DuoWireCoding.encode(request)) ? "same bytes" : "other bytes"]
            return DFixtures.createResponse
        }
        _ = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertEqual(seen.value, ["POST /duos", "same key", "same bytes"])
        XCTAssertEqual(dNames(h.transport.calls), ["createDuo"], "an identity that is ready is not minted again")
        XCTAssertEqual(h.store.myDisplayName, "Jo")
    }

    func testTheDuoLimitRefusesBeforeAnythingIsSent() async {
        let free = DHarness(credential: DuoFixtures.credential())
        free.answerEverything()
        free.store.upsert(DuoFixtures.duo())
        let created = await free.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(created)
        XCTAssertTrue(free.transport.calls.isEmpty)
        XCTAssertEqual(free.store.sheetError, "You are already in a duo. Leave it first, then open the invite again.")
        free.store.sheetError = nil
        let joined = await free.service.join(DFixtures.pendingInvite, named: "Jo", skin: "classic")
        XCTAssertNil(joined)
        XCTAssertTrue(free.transport.calls.isEmpty)
        XCTAssertEqual(free.store.sheetError, "You are already in a duo. Leave it first, then open the invite again.")
        XCTAssertFalse(free.store.isWorking)

        // An ended duo takes no place.
        let ended = DHarness(credential: DuoFixtures.credential())
        ended.answerEverything()
        ended.store.upsert(DuoFixtures.duo(ended: true))
        let afterEnded = await ended.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNotNil(afterEnded)

        // A subscriber with five, and someone whose subscription lapsed with three.
        let full = DHarness(credential: DuoFixtures.credential(), subscribed: true)
        full.answerEverything()
        for _ in 0..<5 { full.store.upsert(DuoFixtures.duo(id: UUID())) }
        let sixth = await full.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(sixth)
        XCTAssertEqual(full.store.sheetError, "You are already in 5 duos. Leave one first, then open the invite again.")
        let lapsed = DHarness(credential: DuoFixtures.credential())
        lapsed.answerEverything()
        for _ in 0..<3 { lapsed.store.upsert(DuoFixtures.duo(id: UUID())) }
        let fourth = await lapsed.service.join(DFixtures.pendingInvite, named: "Jo", skin: "classic")
        XCTAssertNil(fourth)
        XCTAssertEqual(lapsed.store.sheetError, "You are already in 3 duos. Leave one first, then open the invite again.")
        XCTAssertTrue(full.transport.calls.isEmpty && lapsed.transport.calls.isEmpty)
    }

    func testLiveDuosCachedWithNoIdentityAreNotCountedAsTheLimitAndOnlyReconnectGoes() async {
        // A backup that brought the App Group's defaults without the Keychain item: duos no identity
        // here can act for. Neither the limit's words nor a new identity beside them is right.
        for subscribed in [false, true] {
            let h = DHarness(subscribed: subscribed)
            h.answerEverything()
            h.store.upsert(DuoFixtures.duo())
            let created = await h.service.createDuo(named: "Jo", skin: "classic")
            XCTAssertNil(created)
            XCTAssertEqual(h.store.sheetError, "That did not work. Please try again.", "subscribed \(subscribed)")
            h.store.sheetError = nil
            let joined = await h.service.join(DFixtures.pendingInvite, named: "Jo", skin: "classic")
            XCTAssertNil(joined)
            XCTAssertEqual(h.store.sheetError, "That did not work. Please try again.")
            XCTAssertTrue(h.transport.calls.isEmpty)
            XCTAssertTrue(h.kit.identity.stored.isEmpty)
            XCTAssertFalse(h.store.isWorking)
            // The way back is "I had a duo".
            let reconnected = await h.service.reconnect(code: "H7K39QWX")
            XCTAssertTrue(reconnected)
        }
    }

    func testNothingIsSentOrKeptUntilTheBirthYearScreenSaidYes() async throws {
        // Unknown, refused in the cache, and refused in the Keychain only (a reinstall, or a first
        // read that failed) while the cache still says allowed.
        for (age, keychainRefusal) in [(DuoAgeStatus.unknown, false), (.refused, false), (.allowed, true)] {
            let h = DHarness(age: age)
            h.answerEverything()
            if keychainRefusal { try h.kit.dependencies.secrets.markAgeRefused() }
            let deviceCheck = DChangingDeviceCheck()
            h.kit.dependencies.deviceCheck = deviceCheck
            let created = await h.service.createDuo(named: "Jo", skin: "classic")
            let joined = await h.service.join(DFixtures.pendingInvite, named: "Jo", skin: "classic")
            let reconnected = await h.service.reconnect(code: "H7K39QWX")
            XCTAssertNil(created)
            XCTAssertNil(joined)
            XCTAssertFalse(reconnected)
            XCTAssertTrue(h.transport.calls.isEmpty, "\(age) \(keychainRefusal)")
            XCTAssertEqual(deviceCheck.calls, 0, "\(age)")
            XCTAssertEqual(h.kit.attester.attestedNewKeys, 0)
            XCTAssertTrue(h.kit.secretStore.accounts(service: DuoSecrets.service).isEmpty, "\(age)")
            XCTAssertTrue(h.kit.identity.stored.isEmpty)
            XCTAssertEqual(h.kit.identity.prepared, 0, "not even the identity is asked")
            XCTAssertTrue(h.journal.isEmpty)
            XCTAssertNil(h.store.sheetError)
            XCTAssertFalse(h.store.needsTerms)
        }
    }

    func testAnAvailabilityThatForbidsWritesRefusesAndOnlyAReconnectMaySendWhenDisconnected() async {
        let refusing: [DuoAvailability] = [.upgradeRequired, .banned, .disconnected, .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))]
        for availability in refusing {
            let h = DHarness()
            h.answerEverything()
            h.store.availability = availability
            let created = await h.service.createDuo(named: "Jo", skin: "classic")
            let joined = await h.service.join(DFixtures.pendingInvite, named: "Jo", skin: "classic")
            XCTAssertNil(created)
            XCTAssertNil(joined)
            XCTAssertTrue(h.transport.calls.isEmpty, "\(availability)")
            let reconnected = await h.service.reconnect(code: "H7K39QWX")
            if availability == .disconnected {
                XCTAssertTrue(reconnected, "the disconnected phone is the one a reconnect is for")
            } else {
                XCTAssertFalse(reconnected)
                XCTAssertTrue(h.transport.calls.isEmpty, "\(availability)")
            }
        }
    }

    func testRulesNotAcceptedSendNothingAndTheMintCarriesOnlyTheAcceptedVersion() async throws {
        let h = DHarness(termsAccepted: false)
        h.answerEverything()
        let created = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(created)
        XCTAssertTrue(h.store.needsTerms, "the sheet that is up shows the rules")
        h.store.needsTerms = false
        let joined = await h.service.join(DFixtures.pendingInvite, named: "Jo", skin: "classic")
        XCTAssertNil(joined)
        XCTAssertTrue(h.store.needsTerms)
        h.store.needsTerms = false
        let reconnected = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(reconnected)
        XCTAssertTrue(h.store.needsTerms)
        XCTAssertTrue(h.transport.calls.isEmpty)
        XCTAssertNil(h.store.sheetError)
        XCTAssertEqual(h.cache.acceptedTermsVersion, 0, "a tap is not an acceptance of rules it never showed")

        // Accepted on the rules screen: recorded by the store, nothing sent without an identity.
        let accepted = await h.store.acceptTerms()
        XCTAssertTrue(accepted)
        XCTAssertFalse(h.store.needsTerms)
        XCTAssertTrue(h.transport.calls.isEmpty)
        let afterAccepting = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNotNil(afterAccepting)
        XCTAssertEqual(h.transport.dMints.map(\.termsVersion), [h.cache.acceptedTermsVersion])
        XCTAssertEqual(h.cache.acceptedTermsVersion, 1)
    }

    func testPendingExistsAdoptsTheDuoALostAnswerMade() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        let lost = DFixtures.otherID
        h.transport.onCreateDuo = { _, _ in
            throw DuoTransportError.pendingExists(DFixtures.context(409, details: DuoWireErrorDetails(duoId: lost.uuidString.lowercased())))
        }
        h.transport.onFetchChanges = { _, _ in
            DuoWireChanges(duo: DFixtures.header(lost, role: .owner, state: .pending, seq: 1), full: true,
                           statuses: [DuoFixtures.wireRow(.owner, "2026-09-21", bucket: 50, ver: 1)], nudges: [], handled: [], cursor: 1)
        }
        let created = await h.service.createDuo(named: "Jo", skin: "classic")
        let duo = try XCTUnwrap(created)
        XCTAssertEqual(h.transport.calls.last, .fetchChanges(duoID: lost.uuidString.lowercased(), since: 0))
        XCTAssertEqual(dNames(h.transport.calls), ["createDuo", "fetchChanges"])
        XCTAssertEqual(duo.id, lost)
        XCTAssertNil(duo.invite, "the server never gives a code back")
        XCTAssertTrue(duo.syncedOnce)
        XCTAssertTrue(duo.e2eeCapable)
        XCTAssertEqual(duo.vers, ["owner-2026-09-21": 1])
        XCTAssertEqual(h.store.duos.map(\.id), [lost])
        XCTAssertNil(h.store.sheetError)
        XCTAssertEqual(h.kit.push.reasons, [.duoStarted])
        XCTAssertEqual(h.store.myDisplayName, "Jo")
        XCTAssertTrue(h.journal.isEmpty)
    }

    func testATermsRefusalShowsTheTermsAgainAndAcceptingThenTappingAgainCreates() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.store.memberInfo = DFixtures.member(termsVersion: 0)
        let script = DScript([DuoTransportError.termsRequired(DFixtures.context(428, details: DuoWireErrorDetails(termsVersion: 1)))])
        h.transport.onCreateDuo = { _, _ in try script.next(); return DFixtures.createResponse }
        let refused = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(refused)
        XCTAssertTrue(h.store.needsTerms)
        XCTAssertNil(h.store.sheetError, "the sheet shows the terms, not an error")
        XCTAssertTrue(h.journal.isEmpty, "a 428 settles the request")

        let accepted = await h.store.acceptTerms()
        XCTAssertTrue(accepted)
        XCTAssertTrue(h.transport.calls.contains(.updateMe(DuoWireUpdateMeRequest(termsVersion: .value(1)))))
        XCTAssertFalse(h.store.needsTerms)
        XCTAssertEqual(h.store.memberInfo?.termsVersion, 1)
        let created = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNotNil(created)
        let keys = h.transport.dCreates.map { $0.key }
        guard keys.count == 2 else { return XCTFail("two creates, not \(keys.count)") }
        XCTAssertNotEqual(keys[0], keys[1])

        // Terms newer than this build can record are an update, never a sheet that cannot end.
        let newer = DHarness(credential: DuoFixtures.credential())
        newer.transport.onCreateDuo = { _, _ in throw DuoTransportError.termsRequired(DFixtures.context(428, details: DuoWireErrorDetails(termsVersion: 2))) }
        _ = await newer.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertFalse(newer.store.needsTerms)
        XCTAssertEqual(newer.store.availability, .upgradeRequired)
        XCTAssertEqual(newer.store.sheetError, "Update HydroDrop to keep using Duo Streaks.")
    }

    func testALostAnswerIsReplayedUnderItsKeyAndAChangedNameIsANewRequest() async throws {
        let h = DHarness(credential: DuoFixtures.credential(), subscribed: true)
        let uncertain: [Error] = [DuoTransportError.offline, DuoTransportError.unreadable(httpStatus: 201, requestID: nil),
                                  DuoTransportError.maintenance(DFixtures.context(503)), DuoTransportError.maintenance(DFixtures.context(401)),
                                  DuoTransportError.rateLimited(DFixtures.context(429)), CancellationError()]
        let script = DScript(uncertain.map { Optional($0) })
        h.transport.onCreateDuo = { _, _ in try script.next(); return DFixtures.createResponse }
        for _ in 0...uncertain.count { _ = await h.service.createDuo(named: "Jo", skin: "classic") }
        let attempts = h.transport.dCreates
        guard attempts.count == uncertain.count + 1 else { return XCTFail("\(uncertain.count + 1) creates, not \(attempts.count)") }
        XCTAssertTrue(attempts.allSatisfy { $0.key == attempts[0].key }, "no outcome above says the request did not land")
        XCTAssertTrue(attempts.allSatisfy { $0.request == attempts[0].request })
        XCTAssertEqual(h.store.duos.map(\.id), [DFixtures.createdID])
        XCTAssertTrue(h.journal.isEmpty)

        // Another lost answer, then the person changes their name: different bytes, a new key.
        script.set([DuoTransportError.offline])
        _ = await h.service.createDuo(named: "Jo", skin: "classic")
        let lostKey = try XCTUnwrap(h.transport.dCreates.last).key
        XCTAssertNotEqual(lostKey, attempts[0].key, "a settled request is never replayed")
        XCTAssertEqual(h.journal.map(\.key), [lostKey])
        _ = await h.service.createDuo(named: "Joanna", skin: "classic")
        let renamed = try XCTUnwrap(h.transport.dCreates.last)
        XCTAssertNotEqual(renamed.key, lostKey)
        XCTAssertEqual(renamed.request.displayName, "Joanna")
    }

    func testADefiniteRefusalClearsTheRecordSoTheNextTapIsANewRequest() async throws {
        let refusals: [DuoTransportError] = [.nameRejected(DFixtures.context(422)), .schema(DFixtures.context(400)),
                                             .idempotencyMismatch(DFixtures.context(422)), .duoLimit(DFixtures.context(409)),
                                             .attestInvalid(DFixtures.context(403)), .unauthenticated(DFixtures.context(401))]
        for refusal in refusals {
            let h = DHarness(credential: DuoFixtures.credential(), subscribed: true)
            h.answerEverything()
            let script = DScript([refusal])
            h.transport.onCreateDuo = { _, _ in try script.next(); return DFixtures.createResponse }
            let refused = await h.service.createDuo(named: "Jo", skin: "classic")
            XCTAssertNil(refused)
            XCTAssertTrue(h.journal.isEmpty, "\(refusal)")
            let created = await h.service.createDuo(named: "Jo", skin: "classic")
            XCTAssertNotNil(created, "\(refusal)")
            let keys = h.transport.dCreates.map { $0.key }
            guard keys.count == 2 else { XCTFail("two creates, not \(keys.count): \(refusal)"); continue }
            XCTAssertNotEqual(keys[0], keys[1], "\(refusal)")
        }
    }

    func testACancelledTapKeepsTheRecordSaysNothingAndSchedulesNothing() async {
        let h = DHarness(credential: DuoFixtures.credential())
        h.transport.onCreateDuo = { _, _ in throw CancellationError() }
        let created = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(created)
        XCTAssertNil(h.store.sheetError)
        XCTAssertEqual(h.journal.map(\.operation), ["POST /duos"])
        XCTAssertTrue(h.store.diagnostics.recentErrors.isEmpty)
        XCTAssertTrue(h.kit.sleeper.delays.isEmpty, "nothing is scheduled to send it again")
        XCTAssertEqual(h.store.availability, .unknown)
        XCTAssertEqual(h.kit.identity.discardCount, 0)
        XCTAssertEqual(dNames(h.transport.calls), ["createDuo"])
    }

    func testAWipeWhileTheCreateIsOutDropsItsAnswer() async {
        let h = DHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        let hooked = DHookedTransport(h.transport)
        let store = h.store
        hooked.whileCreateIsOut = { store.resetLocalState() }
        h.kit.dependencies.transport = hooked
        let created = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(created)
        XCTAssertTrue(store.duos.isEmpty, "a late answer must not bring back a duo the person just deleted")
        XCTAssertEqual(store.myDisplayName, "")
        XCTAssertNil(store.sheetError)
        XCTAssertNil(h.kit.defaults.object(forKey: DuoCache.inflightKey), "nothing writes the journal back after a wipe")
        XCTAssertNil(h.kit.dependencies.secrets.linkSecret(forDuo: DFixtures.createdID))
        XCTAssertTrue(h.kit.push.reasons.isEmpty)
        XCTAssertEqual(h.ops.monitoring, 0)
    }

    func testAWipeWhileTheMintIsOutKeepsNoIdentity() async {
        let h = DHarness()
        h.answerEverything()
        let hooked = DHookedTransport(h.transport)
        let store = h.store
        hooked.whileMintIsOut = { store.resetLocalState() }
        h.kit.dependencies.transport = hooked
        let created = await h.service.createDuo(named: "Jo", skin: "classic")
        XCTAssertNil(created)
        XCTAssertTrue(h.kit.identity.stored.isEmpty)
        XCTAssertNil(store.memberInfo)
        XCTAssertEqual(dNames(h.transport.calls), ["createDevice"])
    }

    func testASecondTapWhileTheFirstIsOutSendsNothing() async {
        let h = DHarness()
        h.answerEverything()
        let hooked = DHookedTransport(h.transport)
        let gate = DGate()
        hooked.mintGate = gate
        h.kit.dependencies.transport = hooked
        let service = h.service
        let first = Task { await service.createDuo(named: "Jo", skin: "classic") }
        for _ in 0..<1_000 where gate.entered == 0 { await Task.yield() }
        XCTAssertEqual(gate.entered, 1)
        let second = await service.createDuo(named: "Jo", skin: "classic")
        let joined = await service.join(DFixtures.pendingInvite, named: "Jo", skin: "classic")
        let reconnected = await service.reconnect(code: "H7K39QWX")
        XCTAssertNil(second)
        XCTAssertNil(joined)
        XCTAssertFalse(reconnected)
        gate.release()
        let created = await first.value
        XCTAssertNotNil(created)
        XCTAssertEqual(h.transport.dMints.count, 1, "two taps at once never mint two identities")
        XCTAssertEqual(dNames(h.transport.calls), ["createDevice", "createDuo"])
    }

    // MARK: Peek

    func testPeekNormalisesTheCodeAndNeverSendsOneThatIsNotACode() async {
        let h = DHarness()
        h.answerEverything()
        let peek = await h.service.peek(code: "h7k3-9qwo")
        XCTAssertEqual(h.transport.calls, [.peekInvite(code: "H7K39QW0")])
        XCTAssertEqual(peek, DuoPeek(purpose: .invite, inviterName: "Alex", inviterSkin: "forest", targetName: nil, expiresAt: DFixtures.inviteExpiry))
        XCTAssertNil(h.store.sheetError)
        h.transport.reset()
        let notACode = await h.service.peek(code: "H7K3-9QWU")
        XCTAssertNil(notACode)
        XCTAssertTrue(h.transport.calls.isEmpty)
        XCTAssertEqual(h.store.sheetError, "That does not look like a duo code")
    }

    func testPeekWithoutAnIdentityIsAnonymousAndMakesNone() async {
        let h = DHarness()
        let identity = h.kit.identity
        let bearers = DBox<[Bool]>([])
        h.transport.onPeekInvite = { _ in bearers.value.append(identity.credential != nil); return DFixtures.peek }
        let deviceCheck = DChangingDeviceCheck()
        h.kit.dependencies.deviceCheck = deviceCheck
        let peek = await h.service.peek(code: "H7K39QWX")
        XCTAssertNotNil(peek)
        XCTAssertEqual(bearers.value, [false])
        XCTAssertEqual(dNames(h.transport.calls), ["peekInvite"], "a peek never mints")
        XCTAssertTrue(h.kit.identity.stored.isEmpty)
        XCTAssertEqual(deviceCheck.calls, 0)
        XCTAssertEqual(h.kit.attester.attestedNewKeys, 0)
        XCTAssertTrue(h.kit.secretStore.accounts(service: DuoSecrets.service).isEmpty)
    }

    func testAStaleCredentialIsLetGoAndThePeekIsTriedOnceMoreAnonymously() async {
        let h = DHarness(credential: DuoFixtures.credential())
        let identity = h.kit.identity
        let bearers = DBox<[Bool]>([])
        h.transport.onPeekInvite = { _ in
            bearers.value.append(identity.credential != nil)
            if identity.credential != nil { throw DuoTransportError.unauthenticated(DFixtures.context(401)) }
            return DFixtures.peek
        }
        let peek = await h.service.peek(code: "H7K39QWX")
        XCTAssertNotNil(peek)
        XCTAssertEqual(bearers.value, [true, false])
        XCTAssertEqual(h.kit.identity.discardCount, 1)
        XCTAssertNil(h.store.sheetError)

        // A second refusal on the retry is said, never tried a third time.
        let twice = DHarness(credential: DuoFixtures.credential())
        twice.transport.onPeekInvite = { _ in throw DuoTransportError.unauthenticated(DFixtures.context(401)) }
        let refused = await twice.service.peek(code: "H7K39QWX")
        XCTAssertNil(refused)
        XCTAssertEqual(twice.transport.calls.count, 2)
        XCTAssertEqual(twice.store.sheetError, "That did not work. Please try again. (ref req-1)")

        // The client's own "no credential" at status 0 forgot nothing, so nothing is retried.
        let unsent = DHarness(credential: DuoFixtures.credential())
        unsent.transport.onPeekInvite = { _ in throw DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0)) }
        _ = await unsent.service.peek(code: "H7K39QWX")
        XCTAssertEqual(unsent.transport.calls.count, 1)
        XCTAssertEqual(unsent.kit.identity.discardCount, 0)
    }

    func testAPeekWithAnIdentityWaitsForTheLaunchAndSendsNothingWhileItIsUnsettled() async {
        let restoring = DHarness(credential: DuoFixtures.credential())
        restoring.answerEverything()
        restoring.kit.identity.launch = .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))
        let whileAsked = await restoring.service.peek(code: "H7K39QWX")
        XCTAssertNil(whileAsked)
        XCTAssertTrue(restoring.transport.calls.isEmpty, "the bearer may be a previous owner's")
        XCTAssertNil(restoring.store.sheetError)

        let unknown = DHarness(credential: DuoFixtures.credential())
        unknown.answerEverything()
        unknown.kit.identity.launch = .unavailable
        let unsure = await unknown.service.peek(code: "H7K39QWX")
        XCTAssertNil(unsure)
        XCTAssertTrue(unknown.transport.calls.isEmpty)
        XCTAssertEqual(unknown.store.sheetError, "That did not work. Please try again.")
    }

    func testAReceivedCodeIsKeptUntilItIsDiscarded() {
        let h = DHarness()
        h.service.receive(DuoParsedInvite(code: "H7K39QWX", k: DFixtures.k), now: DFixtures.now)
        XCTAssertEqual(h.store.pendingInvite, DuoPendingInvite(code: "H7K39QWX", k: DFixtures.k, receivedAt: DFixtures.now))
        XCTAssertEqual(h.store.pendingInvite?.k, DFixtures.k)
        h.service.discardPendingInvite()
        XCTAssertNil(h.store.pendingInvite)
        XCTAssertTrue(h.transport.calls.isEmpty)
    }

    // MARK: Join

    func testJoinSeedsTheWholeDuoKeepsTheSecretAndForgetsTheInvite() async throws {
        let h = DHarness()
        h.answerEverything()
        h.service.receive(DuoParsedInvite(code: "H7K39QWX", k: DFixtures.k), now: DFixtures.now)
        let invite = try XCTUnwrap(h.store.pendingInvite)
        let joined = await h.service.join(invite, named: " Sam ", skin: "forest")
        let duo = try XCTUnwrap(joined)

        XCTAssertEqual(dNames(h.transport.calls), ["createDevice", "redeemInvite"])
        let sent = try XCTUnwrap(h.transport.dRedeems.first).request
        XCTAssertEqual(sent.code, "H7K39QWX")
        XCTAssertEqual(sent.displayName, "Sam")
        XCTAssertEqual(sent.skin, "forest")
        XCTAssertEqual(sent.myToday, DFixtures.today)
        XCTAssertTrue(sent.e2eeCapable, "a link carried k")
        XCTAssertEqual(sent.deviceCheckToken, "RGV2aWNlQ2hlY2s=")
        XCTAssertEqual(sent.statuses.map(\.day), ["2026-09-21", "2026-09-20", "2026-09-19", "2026-09-18", "2026-09-17"])
        XCTAssertTrue(sent.statuses.allSatisfy { $0.baseVer == 0 })

        XCTAssertEqual(duo.id, DFixtures.joinedID)
        XCTAssertEqual(duo.myRole, .partner)
        XCTAssertTrue(duo.partnerHasJoined)
        XCTAssertTrue(duo.syncedOnce)
        XCTAssertEqual(duo.cursor, 7)
        XCTAssertEqual(Set(duo.statuses.map(\.recordName)), ["owner-2026-09-21", "owner-2026-09-20", "partner-2026-09-21", "partner-2026-09-20"])
        XCTAssertEqual(duo.vers, ["owner-2026-09-21": 3, "owner-2026-09-20": 2, "partner-2026-09-21": 1, "partner-2026-09-20": 1])
        XCTAssertTrue(duo.e2eeCapable)
        XCTAssertEqual(h.kit.dependencies.secrets.linkSecret(forDuo: duo.id), DFixtures.k)
        XCTAssertFalse(dBodies(h.transport.calls).contains { $0.contains(DFixtures.k) }, "k is kept, never sent")
        XCTAssertNil(h.store.pendingInvite)
        XCTAssertEqual(h.store.myDisplayName, "Sam")
        XCTAssertEqual(h.store.duos.map(\.id), [DFixtures.joinedID])
        XCTAssertEqual(h.kit.push.reasons, [.duoStarted])
        XCTAssertEqual(h.ops.monitoring, 1)
        XCTAssertEqual(h.cache.loadRejectedDays()[DFixtures.joinedID.uuidString.lowercased()]?.rows["2026-09-19"]?.role, .partner)
        XCTAssertTrue(h.journal.isEmpty, "the token goes with the record once the request is answered")
        XCTAssertNil(h.store.sheetError)
        XCTAssertFalse(h.store.isWorking)
    }

    func testATypedCodeJoinsWithoutTheSecretAndSaysSo() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        let joined = await h.service.join(DuoPendingInvite(code: "h7k3-9qwx", k: nil, receivedAt: DFixtures.now), named: nil, skin: "classic")
        let duo = try XCTUnwrap(joined)
        let sent = try XCTUnwrap(h.transport.dRedeems.first).request
        XCTAssertEqual(sent.code, "H7K39QWX")
        XCTAssertFalse(sent.e2eeCapable)
        XCTAssertNil(sent.displayName)
        XCTAssertFalse(duo.e2eeCapable)
        XCTAssertNil(h.kit.dependencies.secrets.linkSecret(forDuo: duo.id))
        XCTAssertEqual(dNames(h.transport.calls), ["redeemInvite"])
    }

    func testEveryJoinFailureIsSaidInTheApprovedWords() async {
        // The third column: whether the answer may mean a lost answer already seated this person,
        // which `GET /me` is asked about (D70). It lists nothing here, so the refusal stands.
        let table: [(DuoTransportError, String, Bool)] = [
            (.inviteUnknown(DFixtures.context(404)), "That invite is no longer open. Ask for a new one.", true),
            (.inviteTaken(DFixtures.context(409)), "This invite is not open to you anymore. Someone else may have joined first. Ask for a new one.", true),
            (.unreadable(httpStatus: 404, requestID: nil), "Joining is paused for a few minutes. Try again soon.", true),
            (.inviteOwn(DFixtures.context(409)), "That is your own invite. Send it to the person you want to team up with.", false),
            (.duoLimit(DFixtures.context(409, details: DuoWireErrorDetails(max: 1, activeDuos: 1))),
             "You are already in a duo. Leave it first, then open the invite again.", false),
            (.duoLimit(DFixtures.context(409, details: DuoWireErrorDetails(max: 5, activeDuos: 3))),
             "You are already in 3 duos. Leave one first, then open the invite again.", false),
            (.alreadyInDuo(DFixtures.context(409, details: DuoWireErrorDetails(max: 5))),
             "You are already in 5 duos. Leave one first, then open the invite again.", false),
            (.blocked(DFixtures.context(403)), "This person can't be paired with you.", false),
            (.wrongPurpose(DFixtures.context(409)), "That code is for something else. Ask for a duo invite.", false),
            (.attestRequired(DFixtures.context(403)), "HydroDrop could not verify this phone. Try again in a few minutes.", false),
            (.attestInvalid(DFixtures.context(403)), "HydroDrop could not verify this phone. Try again in a few minutes.", false),
            (.rateLimited(DFixtures.context(429)), "Too many tries. Wait a bit and try again.", false),
            (.maintenance(DFixtures.context(503)), "Joining is paused for a few minutes. Try again soon.", false),
            (.unreadable(httpStatus: 502, requestID: nil), "Joining is paused for a few minutes. Try again soon.", false),
            (.offline, "No connection right now. Try again in a bit.", false),
            (.nameRejected(DFixtures.context(422)), "Please choose a different name.", false),
            (.upgradeRequired(DFixtures.context(426)), "Update HydroDrop to keep using Duo Streaks.", false),
            (.banned(DFixtures.context(403)), "Duo Streaks are not available for this device. Contact support@hydrodrop.us.", false),
            (.schema(DFixtures.context(400)), "That did not work. Please try again. (ref req-1)", false),
            (.idempotencyMismatch(DFixtures.context(422)), "That did not work. Please try again. (ref req-1)", false),
            (.unauthenticated(DFixtures.context(401)), "That did not work. Please try again. (ref req-1)", false),
        ]
        for (error, words, asksMe) in table {
            let h = DHarness(credential: DuoFixtures.credential())
            h.store.pendingInvite = DFixtures.pendingInvite
            h.transport.onRedeemInvite = { _, _ in throw error }
            h.transport.onMe = { DFixtures.me(duos: []) }
            let joined = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
            XCTAssertNil(joined, "\(error)")
            XCTAssertEqual(h.store.sheetError, words, "\(error)")
            XCTAssertEqual(dNames(h.transport.calls), asksMe ? ["redeemInvite", "me"] : ["redeemInvite"], "\(error)")
            XCTAssertEqual(h.store.diagnostics.recentErrors.count, 1, "noted once: \(error)")
            XCTAssertEqual(h.store.diagnostics.recentErrors.first?.code, error.code?.rawValue ?? (error == .offline ? "offline" : "unreadable"))
            XCTAssertTrue(h.store.duos.isEmpty)
            XCTAssertFalse(h.store.isWorking)
            XCTAssertNotNil(h.store.pendingInvite, "the invite stays for another try: \(error)")
        }

        // A 428 has no words: the sheet shows the terms and sends again after Accept.
        let terms = DHarness(credential: DuoFixtures.credential())
        terms.transport.onRedeemInvite = { _, _ in throw DuoTransportError.termsRequired(DFixtures.context(428, details: DuoWireErrorDetails(termsVersion: 1))) }
        let joined = await terms.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertNil(joined)
        XCTAssertNil(terms.store.sheetError)
        XCTAssertTrue(terms.store.needsTerms)
    }

    func testAJoinWhoseAnswerWasLostIsFoundThroughGetMe() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        let script = DScript([DuoTransportError.offline, DuoTransportError.inviteTaken(DFixtures.context(409))])
        h.transport.onRedeemInvite = { _, _ in try script.next(); return DFixtures.redeemResult }
        h.transport.onMe = { DFixtures.me(duos: [DFixtures.header(DFixtures.joinedID, role: .partner, state: .active, seq: 7)]) }
        h.transport.onFetchChanges = { _, _ in DFixtures.joinedChanges() }
        h.store.pendingInvite = DFixtures.pendingInvite

        let lost = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertNil(lost)
        XCTAssertEqual(h.store.sheetError, "No connection right now. Try again in a bit.")
        XCTAssertEqual(h.journal.map(\.operation), ["POST /invites/redeem"])

        let found = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        let duo = try XCTUnwrap(found)
        XCTAssertEqual(dNames(h.transport.calls), ["redeemInvite", "redeemInvite", "me", "fetchChanges"])
        XCTAssertEqual(h.transport.calls.last, .fetchChanges(duoID: DFixtures.joinedID.uuidString.lowercased(), since: 0))
        let redeems = h.transport.dRedeems
        guard redeems.count == 2 else { return XCTFail("two redeems, not \(redeems.count)") }
        XCTAssertEqual(redeems[0].key, redeems[1].key, "the same tap replays the lost request")
        XCTAssertEqual(duo.id, DFixtures.joinedID)
        XCTAssertTrue(duo.syncedOnce)
        XCTAssertNil(h.store.sheetError)
        XCTAssertNil(h.store.pendingInvite)
        // GET /me cannot say which invite a seat came by, so a found seat never takes this link's
        // secret and reads as joined without one (D13).
        XCTAssertFalse(duo.e2eeCapable)
        XCTAssertNil(h.kit.dependencies.secrets.linkSecret(forDuo: duo.id))
        XCTAssertEqual(h.store.myDisplayName, "Sam")
        XCTAssertTrue(h.journal.isEmpty)
    }

    func testANotFoundAnswerKeepsEveryLiveDuoGetMeListsThatThePhoneLacks() async throws {
        // No earlier attempt is remembered at all: the answer alone asks GET /me (D70). Two lost joins
        // and a lost create have seated this free person three times; one duo is held already, one
        // ended and one was cleared.
        let fourth = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000c4")!
        let cleared = UUID(uuidString: "6d2a0000-0000-4000-8000-0000000000c5")!
        let headers = [DFixtures.header(DFixtures.joinedID, role: .partner, state: .active, seq: 7),
                       DFixtures.header(DFixtures.otherID, role: .partner, state: .active, seq: 3),
                       DFixtures.header(DFixtures.createdID, role: .owner, state: .pending, seq: 1),
                       DFixtures.header(fourth, role: .partner, state: .ended, seq: 9),
                       DFixtures.header(cleared, role: .partner, state: .active, seq: 2),
                       DFixtures.header(DuoFixtures.duoID, role: .owner, state: .active, seq: 4)]
        let h = DHarness(credential: DuoFixtures.credential(), subscribed: false)
        h.store.upsert(DuoFixtures.duo(ended: true))
        h.cache.markCleared(cleared, now: DFixtures.now)
        h.store.pendingInvite = DFixtures.pendingInvite
        h.transport.onRedeemInvite = { _, _ in throw DuoTransportError.inviteUnknown(DFixtures.context(404)) }
        h.transport.onMe = { DFixtures.me(duos: headers) }
        h.transport.onFetchChanges = { id, _ in
            let header = headers.first { $0.id == id }!
            return DuoWireChanges(duo: header, full: true, statuses: [], nudges: [], handled: [], cursor: header.seq)
        }
        let joined = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        let duo = try XCTUnwrap(joined)
        XCTAssertEqual(duo.myRole, .partner)
        XCTAssertEqual(Set(dNames(h.transport.calls)), ["redeemInvite", "me", "fetchChanges"])
        XCTAssertEqual(h.transport.calls.filter { if case .fetchChanges = $0 { return true }; return false }.count, 3)
        XCTAssertNotNil(h.store.duo(DFixtures.joinedID))
        XCTAssertNotNil(h.store.duo(DFixtures.otherID), "both seats: the server already seated this person in both")
        XCTAssertEqual(h.store.duo(DFixtures.createdID)?.myRole, .owner, "and the duo a lost create made")
        XCTAssertEqual(h.store.duo(DFixtures.createdID)?.e2eeCapable, false, "no adopted duo is taken to be end-to-end capable (D13)")
        XCTAssertNil(h.store.duo(fourth), "an ended one is not a seat")
        XCTAssertNil(h.store.duo(cleared), "a cleared one stays cleared")
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.hasEnded, true, "one already held is left as it is")
        XCTAssertEqual(h.store.duo(DFixtures.joinedID)?.e2eeCapable, false, "which seat this invite was for is not known")
        XCTAssertEqual(h.store.duo(DFixtures.otherID)?.e2eeCapable, false)
        XCTAssertNil(h.kit.dependencies.secrets.linkSecret(forDuo: DFixtures.joinedID))
        XCTAssertNil(h.kit.dependencies.secrets.linkSecret(forDuo: DFixtures.otherID))
        XCTAssertNil(h.store.sheetError)
        XCTAssertNil(h.store.pendingInvite)
        XCTAssertTrue(h.journal.isEmpty)
        XCTAssertTrue(h.store.diagnostics.recentErrors.isEmpty, "the 404 was explained, not failed")
        XCTAssertFalse(h.store.isWorking)

        // One seat found is not surely this invite's either (a lost join of another invite took it),
        // so it is not given this link's secret (D13).
        let one = DHarness(credential: DuoFixtures.credential())
        one.transport.onRedeemInvite = { _, _ in throw DuoTransportError.inviteTaken(DFixtures.context(409)) }
        one.transport.onMe = { DFixtures.me(duos: [headers[0]]) }
        one.transport.onFetchChanges = { _, _ in DFixtures.joinedChanges() }
        let single = await one.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertEqual(single?.id, DFixtures.joinedID)
        XCTAssertEqual(single?.e2eeCapable, false)
        XCTAssertNil(one.kit.dependencies.secrets.linkSecret(forDuo: DFixtures.joinedID))
    }

    func testWhenGetMeCannotAnswerItsWordsAreShownAndNothingIsClearedSoTheNextTapAsksAgain() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        h.store.pendingInvite = DFixtures.pendingInvite
        h.transport.onRedeemInvite = { _, _ in throw DuoTransportError.inviteUnknown(DFixtures.context(404)) }
        let me = DScript([DuoTransportError.offline, CancellationError()])
        h.transport.onMe = { try me.next(); return DFixtures.me(duos: [DFixtures.header(DFixtures.joinedID, role: .partner, state: .active, seq: 7)]) }
        h.transport.onFetchChanges = { _, _ in DFixtures.joinedChanges() }

        let first = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertNil(first)
        XCTAssertEqual(h.store.sheetError, "No connection right now. Try again in a bit.", "GET /me's words, not the 404's")
        XCTAssertNotNil(h.store.pendingInvite)
        XCTAssertEqual(h.journal.map(\.operation), ["POST /invites/redeem"], "not settled before the check has answered")
        XCTAssertEqual(h.store.diagnostics.recentErrors.map(\.code), ["invite_unknown", "offline"], "both answers noted, each once")
        XCTAssertFalse(h.store.isWorking)

        // A cancelled GET /me says nothing at all.
        let second = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertNil(second)
        XCTAssertNil(h.store.sheetError)
        XCTAssertNotNil(h.store.pendingInvite)

        // The next tap asks again, and finds the seat.
        let third = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertEqual(third?.id, DFixtures.joinedID)
        XCTAssertEqual(dNames(h.transport.calls).filter { $0 == "me" }.count, 3)
        XCTAssertTrue(h.journal.isEmpty)
        XCTAssertNil(h.store.pendingInvite)
    }

    func testASeatWhoseRowsCannotBeReadIsKeptFromItsHeaderToBeReadWhole() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        h.transport.onRedeemInvite = { _, _ in throw DuoTransportError.inviteTaken(DFixtures.context(409)) }
        h.transport.onMe = { DFixtures.me(duos: [DFixtures.header(DFixtures.joinedID, role: .partner, state: .active, seq: 7)]) }
        h.transport.onFetchChanges = { _, _ in throw DuoTransportError.offline }
        let joined = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        let duo = try XCTUnwrap(joined)
        XCTAssertFalse(duo.syncedOnce, "nothing is written for it before a whole read")
        XCTAssertEqual(duo.cursor, 0)
        XCTAssertEqual(h.store.diagnostics.recentErrors.map(\.code), ["offline"])
        XCTAssertNil(h.store.sheetError)
    }

    func testAnIdentityMintedInThisTapAsksNoGetMeAndBlockedNeverDoes() async {
        // A brand-new identity has redeemed nothing, so it has no seat to find.
        let fresh = DHarness()
        fresh.answerEverything()
        fresh.transport.onRedeemInvite = { _, _ in throw DuoTransportError.inviteUnknown(DFixtures.context(404)) }
        _ = await fresh.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertEqual(dNames(fresh.transport.calls), ["createDevice", "redeemInvite"])
        XCTAssertEqual(fresh.store.sheetError, "That invite is no longer open. Ask for a new one.")
        XCTAssertTrue(fresh.journal.isEmpty, "with no check to wait for, the 404 settles the record")

        // `blocked` is the caller's own bit and never a lost seat (D34).
        let blocked = DHarness(credential: DuoFixtures.credential())
        blocked.answerEverything()
        blocked.transport.onRedeemInvite = { _, _ in throw DuoTransportError.blocked(DFixtures.context(403)) }
        _ = await blocked.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertEqual(dNames(blocked.transport.calls), ["redeemInvite"])
        XCTAssertTrue(blocked.journal.isEmpty, "a refusal a replay would repeat")
    }

    func testAnAdoptionSendsTheNameTypedForThisTapWhenTheServerHoldsAnother() async throws {
        // The lost join carried "Jonathon Brown"; the person has since typed "JB". The server's
        // name is kept on the card until the queued PATCH /me lands; the typed one is sent.
        let h = DHarness(credential: DuoFixtures.credential())
        h.kit.dependencies.activeSkin = { "forest" }
        h.transport.onRedeemInvite = { _, _ in throw DuoTransportError.inviteTaken(DFixtures.context(409)) }
        h.transport.onMe = {
            DuoWireGetMeResponse(member: DuoWireMember(id: DuoFixtures.credential().memberID, displayName: "Jonathon Brown", skin: "classic",
                                                       supportId: "ABCD1234EFGH", tier: .attested, termsVersion: 1),
                                 limits: DuoWireLimits(nudgesPerDay: 3, maxActiveDuos: 5), devices: [],
                                 duos: [DFixtures.header(DFixtures.joinedID, role: .partner, state: .active, seq: 7)],
                                 minClient: DuoWireMinClient(ios: "2.0", android: "1.1"))
        }
        h.transport.onFetchChanges = { _, _ in DFixtures.joinedChanges() }
        _ = await h.service.join(DFixtures.pendingInvite, named: "JB", skin: "forest")
        XCTAssertEqual(h.store.myDisplayName, "JB")
        let op = try XCTUnwrap(h.ops.base.queued.first)
        XCTAssertEqual(op.body, try DuoWireCoding.encode(DuoWireUpdateMeRequest(displayName: .value("JB"), skin: .value("forest"))))

        // The same name: nothing to send.
        let same = DHarness(credential: DuoFixtures.credential())
        same.transport.onRedeemInvite = { _, _ in throw DuoTransportError.inviteTaken(DFixtures.context(409)) }
        same.transport.onMe = { DFixtures.me(duos: [DFixtures.header(DFixtures.joinedID, role: .partner, state: .active, seq: 7)]) }
        same.transport.onFetchChanges = { _, _ in DFixtures.joinedChanges() }
        _ = await same.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertTrue(same.ops.base.queued.isEmpty)
    }

    func testTheRedeemReplaysItsRecordedBytesAndKeyThoughDeviceCheckGivesANewTokenEachTime() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        let deviceCheck = DChangingDeviceCheck()
        h.kit.dependencies.deviceCheck = deviceCheck
        let script = DScript([DuoTransportError.offline])
        h.transport.onRedeemInvite = { _, _ in try script.next(); return DFixtures.redeemResult }

        _ = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        let waiting = try XCTUnwrap(h.journal.first)
        XCTAssertEqual(waiting.operation, "POST /invites/redeem")
        XCTAssertEqual(try DuoWireCoding.decode(DuoWireRedeemRequest.self, from: waiting.body).deviceCheckToken, "dc-token-1",
                       "the token waits inside the record of its request (D62)")
        let joined = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertNotNil(joined)
        let redeems = h.transport.dRedeems
        guard redeems.count == 2 else { return XCTFail("two redeems, not \(redeems.count)") }
        XCTAssertEqual(redeems[1].key, redeems[0].key, "a new key would make the server's replay of a lost 201 impossible")
        XCTAssertEqual(redeems[1].request, redeems[0].request, "the recorded bytes, old token and all")
        XCTAssertEqual(redeems[1].request.deviceCheckToken, "dc-token-1")
        XCTAssertEqual(deviceCheck.calls, 1, "a replay asks DeviceCheck for nothing")
        XCTAssertTrue(h.journal.isEmpty, "and the token goes with the record once answered")

        // A new name is a new request: a new key and a new token.
        let renamed = DHarness(credential: DuoFixtures.credential())
        let renamedCheck = DChangingDeviceCheck()
        renamed.kit.dependencies.deviceCheck = renamedCheck
        let renamedScript = DScript([DuoTransportError.offline, DuoTransportError.offline])
        renamed.transport.onRedeemInvite = { _, _ in try renamedScript.next(); return DFixtures.redeemResult }
        _ = await renamed.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        _ = await renamed.service.join(DFixtures.pendingInvite, named: "Sammy", skin: "classic")
        let attempts = renamed.transport.dRedeems
        guard attempts.count == 2 else { return XCTFail("two redeems, not \(attempts.count)") }
        XCTAssertNotEqual(attempts[1].key, attempts[0].key)
        XCTAssertEqual(attempts.map { $0.request.deviceCheckToken }, ["dc-token-1", "dc-token-2"])
        XCTAssertEqual(attempts[1].request.displayName, "Sammy")
        XCTAssertEqual(renamed.journal.count, 1, "one record for the path, the latest")
        XCTAssertEqual(renamed.journal.first?.key, attempts[1].key)
    }

    func testAReplayRefusedForItsAttestationIsRedeemedOnceMoreAsANewRequest() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        let deviceCheck = DChangingDeviceCheck()
        h.kit.dependencies.deviceCheck = deviceCheck
        let script = DScript([DuoTransportError.offline, DuoTransportError.attestInvalid(DFixtures.context(403))])
        h.transport.onRedeemInvite = { _, _ in try script.next(); return DFixtures.redeemResult }
        _ = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        let joined = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertNotNil(joined)
        let redeems = h.transport.dRedeems
        guard redeems.count == 3 else { return XCTFail("three redeems, not \(redeems.count)") }
        XCTAssertEqual(redeems[1].key, redeems[0].key)
        XCTAssertNotEqual(redeems[2].key, redeems[0].key)
        XCTAssertEqual(redeems.map { $0.request.deviceCheckToken }, ["dc-token-1", "dc-token-1", "dc-token-2"])
        XCTAssertNil(h.store.sheetError)

        // A first attempt refused for its attestation is not sent again here: the API client
        // already made its own retries.
        let fresh = DHarness(credential: DuoFixtures.credential())
        fresh.transport.onRedeemInvite = { _, _ in throw DuoTransportError.attestRequired(DFixtures.context(403)) }
        _ = await fresh.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertEqual(fresh.transport.dRedeems.count, 1)
        XCTAssertEqual(fresh.store.sheetError, "HydroDrop could not verify this phone. Try again in a few minutes.")
    }

    func testAWipeWhileTheJoinIsOutDropsItsAnswer() async {
        let h = DHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.store.pendingInvite = DFixtures.pendingInvite
        let hooked = DHookedTransport(h.transport)
        let store = h.store
        hooked.whileRedeemIsOut = { store.resetLocalState() }
        h.kit.dependencies.transport = hooked
        let joined = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        XCTAssertNil(joined)
        XCTAssertTrue(store.duos.isEmpty)
        XCTAssertEqual(store.myDisplayName, "")
        XCTAssertNil(h.kit.dependencies.secrets.linkSecret(forDuo: DFixtures.joinedID))
        XCTAssertNil(h.kit.defaults.object(forKey: DuoCache.inflightKey))
        XCTAssertNil(h.kit.defaults.object(forKey: DuoCache.rejectedDaysKey))
    }

    // MARK: Reconnect

    func testReconnectOnAFreshInstallMintsThenTakesTheIdentityTheCodeIsFor() async throws {
        let h = DHarness()
        h.answerEverything()
        let theirs = DFixtures.header(DFixtures.otherID, role: .owner, state: .active, seq: 12)
        h.transport.onReconnect = { _, _ in DFixtures.reconnected(duos: [theirs]) }
        h.transport.onMe = { DFixtures.me(memberID: DFixtures.reconnectedMember, duos: [theirs]) }
        let reconnected = await h.service.reconnect(code: "h7k3 9qwx")
        XCTAssertTrue(reconnected)
        XCTAssertEqual(dNames(h.transport.calls), ["createDevice", "reconnect", "me"], "the tap on Reconnect is the consent to mint")
        XCTAssertEqual(h.transport.dReconnects.first?.request, DuoWireReconnectRequest(code: "H7K39QWX"))
        XCTAssertEqual(h.kit.identity.stored, [
            DFixtures.mintedCredential,
            DuoCredential(memberID: DFixtures.reconnectedMember, deviceID: DFixtures.minted.deviceId, deviceSecret: DFixtures.minted.deviceSecret),
        ], "the same device and secret, now the member's: nothing rotates")
        let duo = try XCTUnwrap(h.store.duo(DFixtures.otherID))
        XCTAssertFalse(duo.syncedOnce)
        XCTAssertEqual(duo.cursor, 0)
        XCTAssertEqual(h.store.memberInfo?.memberID, DFixtures.reconnectedMember)
        XCTAssertEqual(h.kit.push.reasons, [.duoStarted])
        XCTAssertNil(h.store.sheetError)
        XCTAssertTrue(h.journal.isEmpty)
    }

    func testReconnectRefusalsAreSaidInTheApprovedWords() async {
        let table: [(DuoTransportError, String)] = [
            (.memberNotFresh(DFixtures.context(409)), "Finish or leave the duo you started on this phone first."),
            (.inviteUnknown(DFixtures.context(404)), "That invite is no longer open. Ask for a new one."),
            // A duo invite typed into the reconnect field: "Ask for a duo invite" would point the wrong way.
            (.wrongPurpose(DFixtures.context(409)), "That did not work. Please try again. (ref req-1)"),
            (.rateLimited(DFixtures.context(429)), "Too many tries. Wait a bit and try again."),
            (.maintenance(DFixtures.context(503)), "Joining is paused for a few minutes. Try again soon."),
            (.attestInvalid(DFixtures.context(403)), "HydroDrop could not verify this phone. Try again in a few minutes."),
            (.deviceLimit(DFixtures.context(409, details: DuoWireErrorDetails(max: 5))), "That did not work. Please try again. (ref req-1)"),
            (.offline, "No connection right now. Try again in a bit."),
            (.banned(DFixtures.context(403)), "Duo Streaks are not available for this device. Contact support@hydrodrop.us."),
        ]
        for (error, words) in table {
            let h = DHarness(credential: DuoFixtures.credential())
            h.transport.onReconnect = { _, _ in throw error }
            // GET /me says the device is still this member's: no earlier attempt landed.
            h.transport.onMe = { DFixtures.me(memberID: DuoFixtures.credential().memberID, duos: []) }
            let reconnected = await h.service.reconnect(code: "H7K39QWX")
            XCTAssertFalse(reconnected)
            XCTAssertEqual(h.store.sheetError, words, "\(error)")
            XCTAssertEqual(h.kit.identity.stored, [], "\(error)")
            XCTAssertFalse(h.store.isWorking, "\(error)")
            XCTAssertEqual(h.store.diagnostics.recentErrors.count, 1, "noted once: \(error)")
            XCTAssertEqual(dNames(h.transport.calls), error == .inviteUnknown(DFixtures.context(404)) ? ["reconnect", "me"] : ["reconnect"])
        }
        let h = DHarness()
        let notACode = await h.service.reconnect(code: "nope")
        XCTAssertFalse(notACode)
        XCTAssertEqual(h.store.sheetError, "That does not look like a duo code")
        XCTAssertTrue(h.transport.calls.isEmpty)
    }

    func testAReconnectThatLandedAndLostItsAnswerIsFoundThroughGetMe() async throws {
        // An earlier reconnect moved this device and its answer was lost; this attempt hears the
        // code is gone. GET /me answers as the member the device now belongs to.
        let h = DHarness(credential: DuoFixtures.credential())
        h.store.upsert(DuoFixtures.duo(cursor: 9, syncedOnce: true))
        h.transport.onReconnect = { _, _ in throw DuoTransportError.inviteUnknown(DFixtures.context(404)) }
        h.transport.onMe = { DFixtures.me(memberID: DFixtures.reconnectedMember, duos: [DFixtures.header(DuoFixtures.duoID, role: .owner, state: .active, seq: 20)]) }
        let reconnected = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(reconnected)
        XCTAssertEqual(h.kit.identity.credential?.memberID, DFixtures.reconnectedMember)
        XCTAssertEqual(h.kit.identity.credential?.deviceID, DuoFixtures.credential().deviceID, "nothing rotates")
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.syncedOnce, false)
        XCTAssertEqual(h.store.memberInfo?.memberID, DFixtures.reconnectedMember)
        XCTAssertNil(h.store.sheetError)
        XCTAssertTrue(h.journal.isEmpty)
        XCTAssertEqual(dNames(h.transport.calls), ["reconnect", "me"])

        // GET /me cannot say: its words, the record kept, nothing else changed.
        let unsure = DHarness(credential: DuoFixtures.credential())
        unsure.transport.onReconnect = { _, _ in throw DuoTransportError.inviteUnknown(DFixtures.context(404)) }
        unsure.transport.onMe = { throw DuoTransportError.maintenance(DFixtures.context(503)) }
        let no = await unsure.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(no)
        XCTAssertEqual(unsure.store.sheetError, "Joining is paused for a few minutes. Try again soon.")
        XCTAssertEqual(unsure.store.diagnostics.recentErrors.map(\.code), ["invite_unknown", "maintenance"], "both answers noted, each once")
        XCTAssertEqual(unsure.journal.map(\.operation), ["POST /invites/reconnect"])
        XCTAssertEqual(unsure.kit.identity.stored, [])
    }

    func testReconnectOnADisconnectedPhoneLetsTheRevokedCredentialGoAndBringsTheDuosBack() async throws {
        let stale = DuoFixtures.credential()
        let h = DHarness(credential: stale)
        h.answerEverything()
        h.store.upsert(DuoFixtures.duo(cursor: 9, syncedOnce: true))
        h.store.availability = .disconnected
        let cleared = DFixtures.otherID
        h.cache.markCleared(cleared, now: DFixtures.now)
        h.cache.saveSeenDeviceIDs(["old-device"])
        h.cache.savePushUpload(DuoPushUploadState(tokenHash: "h", environment: .sandbox, zone: "UTC", windowStart: nil, windowEnd: nil,
                                                  enabled: true, uploadedAt: DFixtures.now))
        h.kit.attester.keys = [stale.deviceID]
        let markerWhileOut = DBox<String?>(nil)
        let cache = h.cache
        h.transport.onReconnect = { _, _ in
            markerWhileOut.value = cache.throwawayDeviceID
            return DFixtures.reconnected(duos: [DFixtures.header(DuoFixtures.duoID, role: .owner, state: .active, seq: 20),
                                                DFixtures.header(cleared, role: .partner, state: .ended, seq: 4)], memberID: stale.memberID)
        }
        let reconnected = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(reconnected)
        XCTAssertEqual(dNames(h.transport.calls), ["createDevice", "reconnect", "me"])
        XCTAssertEqual(h.kit.identity.discardCount, 0, "the revoked credential is replaced by the throwaway, never left with none")
        XCTAssertEqual(h.kit.identity.stored, [
            DFixtures.mintedCredential,
            DuoCredential(memberID: stale.memberID, deviceID: DFixtures.minted.deviceId, deviceSecret: DFixtures.minted.deviceSecret),
        ])
        XCTAssertEqual(markerWhileOut.value, DFixtures.minted.deviceId, "remembered before the reconnect is sent (D68)")
        XCTAssertNil(h.cache.throwawayDeviceID, "and a throwaway no more once it answers 200")
        XCTAssertEqual(h.holds.value, ["hold", "release"], "the mint is held against the app being suspended")
        let back = try XCTUnwrap(h.store.duo(DuoFixtures.duoID))
        XCTAssertFalse(back.syncedOnce, "rows read by an older identity are read whole before anything is written (KV11)")
        XCTAssertEqual(back.cursor, 0)
        XCTAssertFalse(back.hasEnded)
        XCTAssertNil(h.store.duo(cleared), "a cleared duo stays cleared")
        XCTAssertEqual(h.store.availability, .available)
        XCTAssertNil(h.cache.loadSeenDeviceIDs(), "the device list belonged to the identity let go (D45)")
        XCTAssertNil(h.cache.loadPushUpload())
        XCTAssertFalse(h.kit.attester.keys.contains(stale.deviceID))
        XCTAssertEqual(h.kit.push.reasons, [.duoStarted])
        XCTAssertFalse(h.store.isWorking)
    }

    func testAReconnectBringsBackADuoThisPhoneEndedOnItsOwnGuess() async throws {
        // Ended here after a `duo_unknown` read with a stranger's bearer (`ended_by = unknown`); the
        // server lists it live. A Leave not yet sent (`pendingOp`, mine) and a cleared duo stay as they are.
        let h = DHarness(credential: DuoFixtures.credential())
        var guessed = DuoFixtures.duo(ended: true)
        guessed.endedBy = .unknown
        h.store.upsert(guessed)
        let leaving = DFixtures.otherID
        var left = DuoFixtures.duo(id: leaving, ended: true)
        left.endedBy = .owner
        left.pendingOp = .leave
        h.store.upsert(left)
        h.transport.onReconnect = { _, _ in
            DFixtures.reconnected(duos: [DFixtures.header(DuoFixtures.duoID, role: .owner, state: .active, seq: 20),
                                         DFixtures.header(leaving, role: .owner, state: .active, seq: 8)])
        }
        h.transport.onMe = { DFixtures.me(memberID: DFixtures.reconnectedMember, duos: []) }
        let reconnected = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(reconnected)
        let back = try XCTUnwrap(h.store.duo(DuoFixtures.duoID))
        XCTAssertFalse(back.hasEnded)
        XCTAssertNil(back.endedBy)
        XCTAssertFalse(back.syncedOnce)
        XCTAssertEqual(h.store.duo(leaving)?.hasEnded, true, "an offline Leave is never undone here")
        XCTAssertEqual(h.store.duo(leaving)?.pendingOp, .leave)
    }

    func testAFailedReconnectLeavesThePhoneDisconnectedAndTheNextTapUsesTheSameThrowaway() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        h.answerEverything()
        h.store.upsert(DuoFixtures.duo())
        h.store.availability = .disconnected
        let script = DScript([DuoTransportError.inviteUnknown(DFixtures.context(404)), DuoTransportError.maintenance(DFixtures.context(503))])
        h.transport.onReconnect = { _, _ in try script.next(); return DFixtures.reconnected(duos: []) }

        let first = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(first)
        XCTAssertEqual(h.store.availability, .disconnected)
        XCTAssertEqual(h.store.sheetError, "That invite is no longer open. Ask for a new one.")
        XCTAssertEqual(h.kit.identity.credential, DFixtures.mintedCredential, "the throwaway stays the stored credential")
        XCTAssertEqual(h.cache.throwawayDeviceID, DFixtures.minted.deviceId, "and is remembered across a relaunch (D68)")
        XCTAssertFalse(dNames(h.transport.calls).contains("me"), "a throwaway minted in this tap was never moved: no GET /me")
        XCTAssertFalse(h.store.isWorking)
        let second = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(second)
        XCTAssertEqual(h.store.availability, .disconnected, "a paused service does not take the card's question away")
        XCTAssertEqual(h.store.sheetError, "Joining is paused for a few minutes. Try again soon.")
        let third = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertTrue(third)
        XCTAssertEqual(h.store.availability, .available)
        XCTAssertNil(h.cache.throwawayDeviceID)

        XCTAssertEqual(h.kit.identity.discardCount, 0)
        XCTAssertEqual(h.transport.dMints.count, 1, "never minted twice: a second returning mint would cost the day")
        let keys = h.transport.dReconnects.map { $0.key }
        guard keys.count == 3 else { return XCTFail("three reconnects, not \(keys.count)") }
        XCTAssertNotEqual(keys[1], keys[0], "a 404 settles the request")
        XCTAssertEqual(keys[2], keys[1], "a 503 does not")
    }

    func testAWipeWhileTheReconnectIsOutDropsItsAnswer() async {
        let h = DHarness()
        h.answerEverything()
        h.transport.onReconnect = { _, _ in DFixtures.reconnected(duos: [DFixtures.header(DFixtures.otherID, role: .owner, state: .active, seq: 3)]) }
        let hooked = DHookedTransport(h.transport)
        let store = h.store
        hooked.whileReconnectIsOut = { store.resetLocalState() }
        h.kit.dependencies.transport = hooked
        let reconnected = await h.service.reconnect(code: "H7K39QWX")
        XCTAssertFalse(reconnected)
        XCTAssertTrue(store.duos.isEmpty)
        XCTAssertEqual(h.kit.identity.stored, [DFixtures.mintedCredential], "the reconnect's answer is not kept")
        XCTAssertEqual(dNames(h.transport.calls), ["createDevice", "reconnect"])
    }

    // MARK: Codes for a duo that exists

    func testANewCodeReplacesTheOldOneAndTheLinkKeepsItsSecret() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        var pending = DuoFixtures.duo(joined: false)
        pending.invite = DuoInvite(code: "AAAA1111", display: "AAAA-1111", expiresAt: DFixtures.now)
        h.store.upsert(pending)
        try h.kit.dependencies.secrets.saveLinkSecret(DFixtures.k, forDuo: pending.id)
        let fresh = DuoWireInvite(code: "N3WC0DE2", display: "N3WC-0DE2", expiresAt: DFixtures.inviteExpiry)
        h.transport.onCreateInvite = { _, _, _ in fresh }
        let invite = await h.service.newInvite(for: pending)
        XCTAssertEqual(invite, DuoInvite(code: "N3WC0DE2", display: "N3WC-0DE2", expiresAt: DFixtures.inviteExpiry))
        guard case .createInvite(let duoID, let purpose, _) = try XCTUnwrap(h.transport.calls.first) else { return XCTFail("no invite asked for") }
        XCTAssertEqual(duoID, pending.wireID)
        XCTAssertEqual(purpose, .invite)
        XCTAssertEqual(h.store.duo(pending.id)?.invite, invite)
        XCTAssertEqual(h.store.duo(pending.id)?.openInviteExpiresAt, DFixtures.inviteExpiry)
        XCTAssertEqual(h.kit.dependencies.secrets.linkSecret(forDuo: pending.id), DFixtures.k)
        XCTAssertTrue(h.journal.isEmpty)

        // A reinstalled owner keeps no secret: one is made.
        let reinstalled = DHarness(credential: DuoFixtures.credential())
        reinstalled.store.upsert(DuoFixtures.duo(joined: false))
        reinstalled.transport.onCreateInvite = { _, _, _ in fresh }
        _ = await reinstalled.service.newInvite(for: DuoFixtures.duo(joined: false))
        let made = try XCTUnwrap(reinstalled.kit.dependencies.secrets.linkSecret(forDuo: DuoFixtures.duoID))
        XCTAssertTrue(DuoInviteCode.isLinkSecret(made))

        // A lost answer is replayed with the same key, so the server answers with the code it made.
        let lost = DHarness(credential: DuoFixtures.credential())
        lost.store.upsert(DuoFixtures.duo(joined: false))
        let script = DScript([DuoTransportError.offline])
        lost.transport.onCreateInvite = { _, _, _ in try script.next(); return fresh }
        _ = await lost.service.newInvite(for: DuoFixtures.duo(joined: false))
        XCTAssertEqual(lost.journal.map(\.operation), ["POST /duos/\(DuoFixtures.duoID.uuidString.lowercased())/invites"])
        _ = await lost.service.newInvite(for: DuoFixtures.duo(joined: false))
        let keys = lost.transport.calls.compactMap { call -> DuoIdempotencyKey? in
            if case .createInvite(_, _, let key) = call { return key }
            return nil
        }
        guard keys.count == 2 else { return XCTFail("two invites asked for, not \(keys.count)") }
        XCTAssertEqual(keys[0], keys[1])
    }

    func testANewCodeForADuoThatWentLiveSaysTheGeneralLineAndOneThatEndedSaysNothing() async {
        let live = DHarness(credential: DuoFixtures.credential())
        live.store.upsert(DuoFixtures.duo(joined: false))
        live.transport.onCreateInvite = { _, _, _ in throw DuoTransportError.conflict(DFixtures.context(409)) }
        let conflict = await live.service.newInvite(for: DuoFixtures.duo(joined: false))
        XCTAssertNil(conflict)
        XCTAssertEqual(live.store.sheetError, "That did not work. Please try again. (ref req-1)")
        XCTAssertEqual(live.store.duo(DuoFixtures.duoID)?.hasEnded, false, "a duo that went live is not ended")
        XCTAssertFalse(live.store.isWorking)

        for error in [DuoTransportError.duoUnknown(DFixtures.context(404)), .duoEnded(DFixtures.context(409))] {
            let h = DHarness(credential: DuoFixtures.credential())
            h.store.upsert(DuoFixtures.duo(joined: false))
            h.transport.onCreateInvite = { _, _, _ in throw error }
            let invite = await h.service.newInvite(for: DuoFixtures.duo(joined: false))
            XCTAssertNil(invite)
            XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.hasEnded, true, "\(error)")
            XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.endedBy, .unknown)
            XCTAssertNil(h.store.sheetError, "§6.7: marked ended, no alert: \(error)")
            XCTAssertEqual(h.store.diagnostics.recentErrors.count, 1)
            XCTAssertEqual(h.kit.push.clearedLast, 1, "no live duo is left, so the token goes")
            XCTAssertFalse(h.store.isWorking)
        }

        // A duo already live has no code to replace, and nothing is asked.
        let active = DHarness(credential: DuoFixtures.credential())
        active.store.upsert(DuoFixtures.duo())
        let none = await active.service.newInvite(for: DuoFixtures.duo())
        XCTAssertNil(none)
        XCTAssertTrue(active.transport.calls.isEmpty)
    }

    func testAReconnectCodeIsAskedForOnlyWhenThePartnerHasBeenSilent() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        var recent = DuoFixtures.duo()
        recent.partnerLastWriteDay = "2026-09-20"
        h.store.upsert(recent)
        let early = await h.service.createReconnectCode(for: recent)
        XCTAssertNil(early)
        XCTAssertTrue(h.transport.calls.isEmpty)

        var silent = recent
        silent.partnerLastWriteDay = "2026-09-10"
        h.store.upsert(silent)
        h.transport.onCreateInvite = { _, _, _ in
            DuoWireInvite(code: "R3C0NN3C", display: "R3C0-NN3C", expiresAt: DFixtures.inviteExpiry, targetDisplayName: "Sam")
        }
        let code = await h.service.createReconnectCode(for: silent)
        XCTAssertEqual(code?.code, "R3C0NN3C")
        guard case .createInvite(let duoID, let purpose, _) = try XCTUnwrap(h.transport.calls.first) else { return XCTFail("no code asked for") }
        XCTAssertEqual(duoID, silent.wireID)
        XCTAssertEqual(purpose, .reconnect)
        XCTAssertNil(h.store.duo(silent.id)?.invite, "shown, not kept on the duo")

        // No approved words yet for these two: the general line, with its reference.
        for error in [DuoTransportError.targetActive(DFixtures.context(409)), .notPartner(DFixtures.context(403))] {
            let refused = DHarness(credential: DuoFixtures.credential())
            refused.store.upsert(silent)
            refused.transport.onCreateInvite = { _, _, _ in throw error }
            let none = await refused.service.createReconnectCode(for: silent)
            XCTAssertNil(none)
            XCTAssertEqual(refused.store.sheetError, "That did not work. Please try again. (ref req-1)", "\(error)")
            XCTAssertEqual(refused.store.duo(silent.id)?.hasEnded, false)
        }
    }

    func testALinkCodeNamesTheNilDuoAndItsLimitIsTheGeneralLine() async {
        let h = DHarness(credential: DuoFixtures.credential())
        h.transport.onCreateInvite = { _, _, _ in DuoWireInvite(code: "M1NKC0DE", display: "M1NK-C0DE", expiresAt: DFixtures.inviteExpiry, targetDisplayName: "Jo") }
        let code = await h.service.createLinkCode()
        XCTAssertEqual(code?.code, "M1NKC0DE")
        guard case .createInvite(let duoID, let purpose, _)? = h.transport.calls.first else { return XCTFail("no code asked for") }
        XCTAssertEqual(duoID, "00000000-0000-0000-0000-000000000000")
        XCTAssertEqual(purpose, .linkDevice)

        let limited = DHarness(credential: DuoFixtures.credential())
        limited.transport.onCreateInvite = { _, _, _ in throw DuoTransportError.deviceLimit(DFixtures.context(409, details: DuoWireErrorDetails(max: 5))) }
        let none = await limited.service.createLinkCode()
        XCTAssertNil(none)
        XCTAssertEqual(limited.store.sheetError, "That did not work. Please try again. (ref req-1)")

        let lost = DHarness(credential: DuoFixtures.credential())
        _ = await lost.service.createLinkCode()
        XCTAssertEqual(lost.journal.map(\.operation), ["POST /duos/00000000-0000-0000-0000-000000000000/invites"])

        let noIdentity = DHarness()
        noIdentity.answerEverything()
        let nothing = await noIdentity.service.createLinkCode()
        XCTAssertNil(nothing)
        XCTAssertTrue(noIdentity.transport.calls.isEmpty)
    }

    // MARK: Name and terms

    func testARenameIsQueuedAsPatchMeWithNullForNoNameAndTheActiveSkin() async throws {
        let h = DHarness(credential: DuoFixtures.credential())
        h.kit.dependencies.activeSkin = { "forest" }
        await h.service.changeMyName("   ")
        let first = try XCTUnwrap(h.ops.base.queued.first)
        XCTAssertEqual(first.kind, .updateMe)
        XCTAssertEqual(first.method, "PATCH")
        XCTAssertEqual(first.path, "/me")
        XCTAssertEqual(first.body, try DuoWireCoding.encode(DuoWireUpdateMeRequest(displayName: .null, skin: .value("forest"))))
        XCTAssertTrue(String(decoding: first.body, as: UTF8.self).contains("\"display_name\":null"))
        XCTAssertEqual(h.ops.base.drains, 1)
        XCTAssertEqual(h.store.myDisplayName, "")

        await h.service.changeMyName(" Jo ")
        let second = try XCTUnwrap(h.ops.base.queued.last)
        XCTAssertEqual(second.body, try DuoWireCoding.encode(DuoWireUpdateMeRequest(displayName: .value("Jo"), skin: .value("forest"))))
        XCTAssertNotEqual(second.key, first.key)
        XCTAssertEqual(h.store.myDisplayName, "Jo")
        XCTAssertTrue(h.transport.calls.isEmpty, "it goes through the op queue")

        let noIdentity = DHarness()
        await noIdentity.service.changeMyName("Jo")
        XCTAssertTrue(noIdentity.ops.base.queued.isEmpty)
        XCTAssertEqual(noIdentity.ops.base.drains, 0)
        XCTAssertEqual(noIdentity.store.myDisplayName, "Jo", "kept for the next create or join")
    }

    func testAcceptingTheTermsWithAndWithoutAnIdentity() async {
        let none = DHarness()
        none.store.needsTerms = true
        let acceptedWithout = await none.service.acceptTerms()
        XCTAssertTrue(acceptedWithout)
        XCTAssertFalse(none.store.needsTerms)
        XCTAssertTrue(none.transport.calls.isEmpty, "the mint will carry the version")

        let identified = DHarness(credential: DuoFixtures.credential())
        identified.answerEverything()
        identified.store.needsTerms = true
        identified.store.memberInfo = DFixtures.member(termsVersion: 0)
        let accepted = await identified.service.acceptTerms()
        XCTAssertTrue(accepted)
        XCTAssertEqual(identified.transport.calls, [.updateMe(DuoWireUpdateMeRequest(termsVersion: .value(1)))])
        XCTAssertFalse(identified.store.needsTerms)
        XCTAssertEqual(identified.store.memberInfo?.termsVersion, 1)

        let offline = DHarness(credential: DuoFixtures.credential())
        offline.store.needsTerms = true
        let failed = await offline.service.acceptTerms()
        XCTAssertFalse(failed)
        XCTAssertTrue(offline.store.needsTerms)
        XCTAssertEqual(offline.store.sheetError, "No connection right now. Try again in a bit.")
    }

    // MARK: Consent across every flow

    func testNothingIsSentBeforeAConsentTapAndKNeverLeavesThePhone() async throws {
        // Every entry point that is not Create, Join or Reconnect, on a phone with no identity:
        // nothing is sent, attested, asked of DeviceCheck or kept in the Keychain.
        let quiet = DHarness()
        quiet.answerEverything()
        let deviceCheck = DChangingDeviceCheck()
        quiet.kit.dependencies.deviceCheck = deviceCheck
        quiet.store.upsert(DuoFixtures.duo(joined: false))
        quiet.service.receive(DuoParsedInvite(code: "H7K39QWX", k: DFixtures.k), now: DFixtures.now)
        quiet.service.discardPendingInvite()
        await quiet.service.changeMyName("Jo")
        _ = await quiet.service.acceptTerms()
        _ = await quiet.service.newInvite(for: DuoFixtures.duo(joined: false))
        _ = await quiet.service.createReconnectCode(for: DuoFixtures.duo())
        _ = await quiet.service.createLinkCode()
        XCTAssertTrue(quiet.transport.calls.isEmpty)
        XCTAssertEqual(deviceCheck.calls, 0)
        XCTAssertEqual(quiet.kit.attester.attestedNewKeys, 0)
        XCTAssertTrue(quiet.kit.secretStore.accounts(service: DuoSecrets.service).isEmpty)
        XCTAssertTrue(quiet.kit.identity.stored.isEmpty)
        XCTAssertTrue(quiet.journal.isEmpty)

        // Each flow that sends, with a secret in play: none of it ever reaches a body.
        let h = DHarness(credential: DuoFixtures.credential(), subscribed: true)
        h.answerEverything()
        _ = await h.service.createDuo(named: "Jo", skin: "classic")
        let made = try XCTUnwrap(h.kit.dependencies.secrets.linkSecret(forDuo: DFixtures.createdID))
        let createdDuo = try XCTUnwrap(h.store.duo(DFixtures.createdID))
        _ = await h.service.newInvite(for: createdDuo)
        _ = await h.service.join(DFixtures.pendingInvite, named: "Sam", skin: "classic")
        _ = await h.service.peek(code: "H7K39QWX")
        _ = await h.service.reconnect(code: "H7K39QWX")
        let bodies = dBodies(h.transport.calls)
        XCTAssertEqual(dNames(h.transport.calls), ["createDuo", "createInvite", "redeemInvite", "peekInvite", "reconnect", "me"])
        XCTAssertFalse(bodies.contains { $0.contains(made) || $0.contains(DFixtures.k) })
    }
}
#endif
