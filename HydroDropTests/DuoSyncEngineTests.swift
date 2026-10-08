#if DUO_V2
import XCTest
@testable import HydroDrop

// The sync engine against the foundation's fakes (final design §3.1, §3.4, §6.4 to §6.8, §8.6,
// §9.5, §9.7, §10, D45). Every service but the engine is a fake, the sleeper returns at once and
// moves this file's clock by what it was asked to wait, so no test sleeps or reads a real clock.

// MARK: - Doubles of this file's own (stage C)

/// A clock a test can move, since the coalescer and `GET /me`'s hour are about time passing.
/// `TestClock` is a value fixed for the kit's life.
private final class CClock: DuoClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    let calendar: Calendar

    init(_ now: Date) {
        current = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        self.calendar = calendar
    }

    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
}

/// An op queue that counts `startMonitoring()`, which `FakeOpQueue` does not.
@MainActor
private final class CMonitorCountingQueue: DuoOpQueueing {
    private(set) var monitorStarts = 0
    private(set) var drains = 0
    var pending: [DuoQueuedOp] = []
    func enqueue(_ op: DuoQueuedOp) { pending.append(op) }
    func drain() async { drains += 1 }
    func startMonitoring() { monitorStarts += 1 }
    func discardAll() { pending = [] }
}

/// An identity that counts `prepare()`, which `FakeDuoIdentity` does not: the amendment that
/// `prepare()` is asked only with a duo cached is about the call itself, not about a request.
private final class CCountingIdentity: DuoIdentityProviding, @unchecked Sendable {
    var credential: DuoCredential?
    var installDay = "2026-01-01"
    var launch: DuoIdentityLaunch = .ready
    private(set) var prepares = 0
    init(credential: DuoCredential?) { self.credential = credential }
    func store(_ credential: DuoCredential) throws { self.credential = credential }
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() { credential = nil }
    func prepare() async -> DuoIdentityLaunch { prepares += 1; return launch }
    func continueAsRestored() async {}
}

/// A door a request waits at until the test opens it. Each waiter is resumed exactly once: the
/// list is emptied before anyone is resumed, and a door that is already open lets everyone by.
@MainActor
private final class CGate {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen = false
    private(set) var arrivals = 0

    func pass() async {
        arrivals += 1
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let waiting = waiters
        waiters = []
        waiting.forEach { $0.resume() }
    }
}

@MainActor
private final class CGates {
    enum Kind: Hashable { case fetch, put, nudge, me }
    var doors: [Kind: CGate] = [:]
    private(set) var inFlight: [Kind: Int] = [:]
    private(set) var mostInFlight: [Kind: Int] = [:]

    func enter(_ kind: Kind) async {
        inFlight[kind, default: 0] += 1
        mostInFlight[kind] = max(mostInFlight[kind] ?? 0, inFlight[kind] ?? 0)
        await doors[kind]?.pass()
    }

    func leave(_ kind: Kind) { inFlight[kind, default: 0] -= 1 }
}

/// `FakeDuoTransport` with doors in front of four endpoints, so a test can hold a request out
/// while something else happens. It records nothing itself: the inner fake records each call
/// when the door lets it through.
private final class CSuspendingTransport: DuoTransport, @unchecked Sendable {
    let inner: FakeDuoTransport
    let gates: CGates

    init(_ inner: FakeDuoTransport, gates: CGates) {
        self.inner = inner
        self.gates = gates
    }

    private func through<T>(_ kind: CGates.Kind, _ call: () async throws -> T) async throws -> T {
        await gates.enter(kind)
        do {
            let answer = try await call()
            await gates.leave(kind)
            return answer
        } catch {
            await gates.leave(kind)
            throw error
        }
    }

    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges {
        try await through(.fetch) { try await inner.fetchChanges(duoID: duoID, since: since) }
    }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult {
        try await through(.put) { try await inner.pushDayStatuses(duoID: duoID, request) }
    }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult {
        try await through(.nudge) { try await inner.sendNudge(duoID: duoID, request) }
    }
    func me() async throws -> DuoWireGetMeResponse { try await through(.me) { try await inner.me() } }

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { try await inner.createDevice(request) }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try await inner.attestChallenge() }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { try await inner.rotate(as: credential) }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { try await inner.updateMe(request) }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { try await inner.deleteMe(request, key: key) }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { try await inner.registerPush(request, firstUpload: firstUpload) }
    func unregisterPush() async throws { try await inner.unregisterPush() }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { try await inner.createDuo(request, key: key) }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite {
        try await inner.createInvite(duoID: duoID, purpose: purpose, key: key)
    }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try await inner.peekInvite(code: code) }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { try await inner.redeemInvite(request, key: key) }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { try await inner.reconnect(request, key: key) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try await inner.fetchDuo(id: id) }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { try await inner.leave(duoID: duoID, key: key) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try await inner.block(duoID: duoID, key: key) }
}

/// A small stand-in for the server's side of one duo's statuses: the `ver` CAS (§7.4, §10.3), an
/// `unchanged` for a row it already holds, and a feed of every row newer than `since`.
private final class CServer: @unchecked Sendable {
    let duoID: UUID
    let role: DuoRole
    let clock: CClock
    private(set) var rows: [String: DuoWireStatusRow] = [:]
    private var rowSeq: [String: Int64] = [:]
    var seq: Int64

    init(duoID: UUID = DuoFixtures.duoID, role: DuoRole = .owner, clock: CClock, seq: Int64 = 10) {
        self.duoID = duoID
        self.role = role
        self.clock = clock
        self.seq = seq
    }

    func hold(_ day: String, bucket: Int, ver: Int64, role: DuoRole? = nil) {
        let row = DuoWireStatusRow(role: role ?? self.role, day: day, goalMet: bucket == 100, progressBucket: bucket, updatedAt: clock.now, ver: ver)
        rows["\(row.role.rawValue)-\(day)"] = row
        seq += 1
        rowSeq["\(row.role.rawValue)-\(day)"] = seq
    }

    func changes(since: Int64) -> DuoWireChanges {
        let newer = rows.filter { (rowSeq[$0.key] ?? 0) > since }.values.sorted { $0.day < $1.day }
        return DuoWireChanges(duo: DuoFixtures.wireHeader(id: duoID, seq: seq), full: since == 0, statuses: Array(newer), nudges: [], handled: [],
                              cursor: seq)
    }

    func put(_ request: DuoWirePutStatusesRequest) -> DuoWireChangesWithResult {
        var accepted: [String] = [], unchanged: [String] = [], rejected: [DuoWireRejected] = []
        var bumped = false
        for status in request.statuses {
            let key = "\(role.rawValue)-\(status.day)"
            let stored = rows[key]
            if let stored, stored.goalMet == status.goalMet, stored.progressBucket == status.progressBucket {
                unchanged.append(status.day)
                continue
            }
            guard status.baseVer == (stored?.ver ?? 0) else {
                rejected.append(DuoWireRejected(day: status.day, reason: .verConflict, current: stored))
                continue
            }
            if !bumped { seq += 1; bumped = true }
            rows[key] = DuoWireStatusRow(role: role, day: status.day, goalMet: status.goalMet, progressBucket: status.progressBucket,
                                         updatedAt: clock.now, ver: (stored?.ver ?? 0) + 1)
            rowSeq[key] = seq
            accepted.append(status.day)
        }
        return DuoWireChangesWithResult(changes: changes(since: request.since), accepted: accepted, unchanged: unchanged, rejected: rejected)
    }
}

/// A real store and the real engine over the foundation's fakes, with a clock that moves.
@MainActor
private struct CHarness {
    static let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z
    static let today = "2026-09-21"

    let store: DuoStore
    let dependencies: DuoDependencies
    let engine: DuoSyncEngine
    let fake = FakeDuoTransport()
    let gates = CGates()
    let identity: FakeDuoIdentity
    let ops = FakeOpQueue()
    let push = FakePush()
    let announcer = FakeAnnouncer()
    let sleeper = SleepRecorder()
    let clock = CClock(CHarness.start)
    let defaults: UserDefaults

    var cache: DuoCache { store.cache }

    /// `lateBy` is how much later than asked the sleeper wakes, for the coalescer's real wake time.
    init(credential: DuoCredential? = DuoFixtures.credential(), launch: DuoIdentityLaunch = .ready, gated: Bool = false, lateBy: TimeInterval = 0) {
        defaults = CMemoryDefaults()
        store = DuoStore(cache: DuoCache(defaults: defaults), usesServer: true, reloadWidget: {})
        identity = FakeDuoIdentity(credential: credential)
        identity.launch = launch
        identity.installDay = "2026-01-01"
        dependencies = DuoDependencies(host: store, cache: store.cache, secrets: DuoSecrets(store: DuoMemorySecretStore()), clock: clock,
                                       random: TestRandom(), client: DuoClientInfo(marketingVersion: "2.0", build: "57"),
                                       attester: FakeDuoAttester(), deviceCheck: FakeDuoDeviceCheck())
        dependencies.identity = identity
        dependencies.transport = gated ? CSuspendingTransport(fake, gates: gates) : fake
        dependencies.ops = ops
        dependencies.push = push
        dependencies.announcer = announcer
        dependencies.activeSkin = { "classic" }
        let sleeper = sleeper, clock = clock
        dependencies.sleep = { seconds in
            try await sleeper.sleep(seconds)
            clock.advance(seconds + lateBy)
        }
        engine = DuoSyncEngine(dependencies: dependencies)
        dependencies.sync = engine
        store.install(dependencies)
    }

    /// A `GET /me` answered within the hour, so a test about something else is not also about it.
    func knowMember(skin: String? = "classic", nudgesPerDay: Int = 3) {
        store.memberInfo = DuoMemberInfo(memberID: "m", displayName: "Jo", skin: skin, supportID: "ABCD1234EFGH", tier: .attested, termsVersion: 1,
                                         nudgesPerDay: nudgesPerDay, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: clock.now)
    }

    func log(_ totals: [String: Int], goal: Int = 2000) {
        let summary = DuoLogSummary(totalsByDay: totals, goalML: goal, earliestEntryDay: "2026-01-01")
        store.latest = summary
        engine.logChanged(summary)
    }

    func serve(_ server: CServer) {
        fake.onFetchChanges = { _, since in server.changes(since: since) }
        fake.onPushDayStatuses = { _, request in server.put(request) }
    }

    var puts: [DuoWirePutStatusesRequest] {
        fake.calls.compactMap { if case .pushDayStatuses(_, let request) = $0 { return request }; return nil }
    }

    var fetches: [Int64] {
        fake.calls.compactMap { if case .fetchChanges(_, let since) = $0 { return since }; return nil }
    }

    var nudgesSent: [DuoWireSendNudgeRequest] {
        fake.calls.compactMap { if case .sendNudge(_, let request) = $0 { return request }; return nil }
    }

    var mes: Int { fake.calls.filter { $0 == .me }.count }

    func idle() async { await engine.waitUntilIdle() }
}

private func failure(_ code: DuoErrorCode, status: Int, retryAfter: Int? = nil, details: DuoWireErrorDetails? = nil) -> DuoTransportError {
    DuoTransportError(code: code, context: DuoErrorContext(httpStatus: status, requestID: "req-1", retryAfter: retryAfter, details: details))
}

private func meAnswer(devices: [DuoWireDevice] = [], duos: [DuoWireHeader] = [], skin: String? = "classic") -> DuoWireGetMeResponse {
    DuoWireGetMeResponse(member: DuoWireMember(id: "m", displayName: "Jo", skin: skin, supportId: "ABCD1234EFGH", tier: .attested, termsVersion: 1),
                         limits: DuoWireLimits(nudgesPerDay: 3, maxActiveDuos: 5), devices: devices, duos: duos,
                         minClient: DuoWireMinClient(ios: "2.0", android: "2.0"))
}

private func device(_ id: String, thisDevice: Bool = false, superseded: Bool = false) -> DuoWireDevice {
    DuoWireDevice(id: id, platform: "ios", createdAt: Date(timeIntervalSince1970: 1_789_000_000), thisDevice: thisDevice, superseded: superseded)
}

private let otherDuoID = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000002")!
private let thirdDuoID = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000003")!

// MARK: - The tests

@MainActor
final class DuoSyncEngineTests: XCTestCase {
    private let today = CHarness.today

    private func owner(_ day: String, _ bucket: Int) -> DuoDayStatus { DuoFixtures.status(.owner, day, bucket: bucket) }

    /// Lets work started without being awaited (a test's own `Task`) reach its next door.
    private func settle(until condition: () -> Bool) async {
        for _ in 0..<500 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), "the condition never held")
    }

    // MARK: Consent

    func testWithNoCredentialNothingIsSentQueuedScheduledOrAnnounced() async {
        let h = CHarness(credential: nil, launch: .none)
        h.store.upsert(DuoFixtures.duo())
        h.engine.activate(logReader: FakeLogReader(DuoLogSummary(totalsByDay: [today: 2000], goalML: 2000, earliestEntryDay: nil)))
        h.log([today: 2000])
        await h.engine.refresh()
        await h.engine.flush()
        _ = await h.engine.backgroundRefresh()
        await h.engine.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 99, kind: .joined))
        await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo())
        await h.idle()
        XCTAssertTrue(h.fake.calls.isEmpty, "no request before a Create, Join or Reconnect tap (§3.1): \(h.fake.calls)")
        XCTAssertEqual(h.ops.drains, 0)
        XCTAssertTrue(h.ops.queued.isEmpty)
        XCTAssertTrue(h.sleeper.delays.isEmpty)
        XCTAssertTrue(h.announcer.delivered.isEmpty)
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.allNudges.count, 0, "not even an optimistic copy")
    }

    func testAStrayRefreshWhileTheRestoreQuestionIsUpSendsNothing() async {
        let prompt = DuoRestorePrompt(partnerName: "Sam", myName: "Jo")
        let asked = CHarness(launch: .needsRestoreChoice(prompt))
        asked.store.upsert(DuoFixtures.duo())
        asked.log([today: 2000])
        await asked.engine.refresh()
        await asked.engine.flush()
        await asked.idle()
        XCTAssertTrue(asked.fake.calls.isEmpty)

        // And while the screen still says so, whatever `prepare()` answers.
        let showing = CHarness()
        showing.store.upsert(DuoFixtures.duo())
        showing.store.availability = .needsRestoreChoice(prompt)
        showing.log([today: 2000])
        await showing.engine.refresh()
        await showing.engine.flush()
        await showing.engine.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 99, kind: .joined))
        await showing.engine.sendNudge(.waterBreak, in: DuoFixtures.duo())
        _ = await showing.engine.backgroundRefresh()
        await showing.idle()
        XCTAssertTrue(showing.fake.calls.isEmpty, "\(showing.fake.calls)")
        XCTAssertEqual(showing.ops.drains, 0)
    }

    func testWithNoDuoCachedTheIdentityIsNotAskedAndOnlyAQueueThatHoldsSomethingIsDrained() async throws {
        let h = CHarness()
        let identity = CCountingIdentity(credential: DuoFixtures.credential())
        h.dependencies.identity = identity
        await h.engine.refresh()
        _ = await h.engine.backgroundRefresh()
        await h.engine.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 3, kind: .joined))
        await h.idle()
        XCTAssertEqual(identity.prepares, 0, "an unsettled phone's first prepare() sends GET /me as the previous owner")
        XCTAssertTrue(h.fake.calls.isEmpty, "a credential with no duo costs no GET /me (§12.1)")
        XCTAssertEqual(h.ops.drains, 0)

        h.ops.enqueue(DuoQueuedOp.unregisterPush(key: "k", now: h.clock.now))
        await h.engine.refresh()
        XCTAssertEqual(h.ops.drains, 1, "what the queue holds is still sent")
        XCTAssertEqual(identity.prepares, 0)
        XCTAssertTrue(h.fake.calls.isEmpty)
    }

    // MARK: Activation

    func testActivationWithNoCredentialTouchesNothing() {
        let h = CHarness(credential: nil, launch: .none)
        let queue = CMonitorCountingQueue()
        h.dependencies.ops = queue
        h.engine.activate(logReader: FakeLogReader())
        h.engine.activate(logReader: FakeLogReader())
        XCTAssertEqual(queue.monitorStarts, 0)
        XCTAssertEqual(queue.drains, 0)
        XCTAssertTrue(h.fake.calls.isEmpty)
    }

    func testActivationWithACredentialStartsMonitoringOnceHoweverOftenItIsCalled() async {
        let h = CHarness()
        let queue = CMonitorCountingQueue()
        h.dependencies.ops = queue
        h.store.upsert(DuoFixtures.duo())
        h.knowMember()
        h.engine.activate(logReader: FakeLogReader())
        h.engine.activate(logReader: FakeLogReader())
        await h.engine.refresh()
        h.engine.activate(logReader: FakeLogReader())
        await h.idle()
        XCTAssertEqual(queue.monitorStarts, 1)
        XCTAssertEqual(h.fake.calls.filter { if case .fetchChanges = $0 { return false }; return true }, [], "activation itself sends nothing")
    }

    // MARK: Read before write

    func testTheFirstReadIsSinceZeroAndNoWriteGoesOutBeforeIt() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(syncedOnce: false))
        let server = CServer(clock: h.clock)
        h.serve(server)
        h.log([today: 2000])
        await h.idle()
        XCTAssertTrue(h.fake.calls.isEmpty, "an unread duo is owed nothing (KV11)")
        await h.engine.flush()
        XCTAssertTrue(h.fake.calls.isEmpty)

        await h.engine.refresh()
        await h.idle()
        XCTAssertEqual(h.fetches, [0])
        guard let fetch = h.fake.calls.firstIndex(where: { if case .fetchChanges = $0 { return true }; return false }),
              let write = h.fake.calls.firstIndex(where: { if case .pushDayStatuses = $0 { return true }; return false }) else {
            return XCTFail("expected a read and then a write: \(h.fake.calls)")
        }
        XCTAssertLessThan(fetch, write)
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.syncedOnce, true)
    }

    func testAReadThatFailsLeavesTheDuoUnwrittenThroughEveryRetry() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(syncedOnce: false))
        h.fake.onFetchChanges = { _, _ in throw DuoTransportError.offline }
        h.log([today: 2000])
        await h.engine.refresh()
        _ = await h.engine.backgroundRefresh()
        await h.idle()
        XCTAssertTrue(h.puts.isEmpty, "\(h.fake.calls)")
        XCTAssertEqual(Set(h.fetches), [0])
    }

    func testAnAnswerThatArrivesAfterTheDuoWasReseatedIsNotTakenAsARead() async {
        let h = CHarness(gated: true)
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let door = CGate()
        h.gates.doors[.fetch] = door
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since + 2) }
        let refresh = Task { await h.engine.refresh() }
        await settle { door.arrivals == 1 }
        // A reconnect while the read was out: this phone must read the duo whole again (§10.3).
        h.store.update(DuoFixtures.duoID) { $0 = DuoMapping.reseated($0) }
        door.open()
        await refresh.value
        await h.idle()
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.syncedOnce, false, "an answer to since 10 is not a read of the whole duo")
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.cursor, 0)
        await h.engine.refresh()
        await h.idle()
        XCTAssertEqual(h.fetches.last, 0)
    }

    // MARK: The cursor

    func testTheCursorOnlyMovesForwardAndAnOlderAnswerIsNotApplied() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onFetchChanges = { _, _ in DuoFixtures.wireChanges(cursor: 15, statuses: [DuoFixtures.wireRow(.partner, "2026-09-21", bucket: 75, ver: 3)]) }
        await h.engine.refresh()
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.cursor, 15)
        // An answer computed before the one just applied (a cursor behind it) changes nothing.
        h.fake.onFetchChanges = { _, _ in DuoFixtures.wireChanges(cursor: 12, statuses: [DuoFixtures.wireRow(.partner, "2026-09-21", bucket: 25, ver: 2)]) }
        await h.engine.refresh()
        let duo = h.store.duo(DuoFixtures.duoID)
        XCTAssertEqual(duo?.cursor, 15)
        XCTAssertEqual(duo?.status(of: .partner, on: today)?.progressBucket, 75)
        XCTAssertEqual(duo?.vers["partner-\(today)"], 3)
        XCTAssertEqual(h.fetches, [10, 15])
    }

    func testAWriteAnswerOlderThanAReadThatCrossedItDoesNotPutOldRowsBack() async {
        let h = CHarness(gated: true)
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let door = CGate()
        h.gates.doors[.put] = door
        h.fake.onPushDayStatuses = { _, request in
            DuoWireChangesWithResult(changes: DuoFixtures.wireChanges(cursor: 11, statuses: [DuoFixtures.wireRow(.partner, "2026-09-21", bucket: 25, ver: 1),
                                                                                       DuoFixtures.wireRow(.owner, "2026-09-21", bucket: 50, ver: 1)]),
                                     accepted: request.statuses.map(\.day), unchanged: [], rejected: [])
        }
        h.fake.onFetchChanges = { _, _ in DuoFixtures.wireChanges(cursor: 14, statuses: [DuoFixtures.wireRow(.partner, "2026-09-21", bucket: 100, ver: 4)]) }
        h.log([today: 1000])
        await settle { door.arrivals == 1 }
        await h.engine.refresh()
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.status(of: .partner, on: today)?.progressBucket, 100)
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since) }
        door.open()
        await h.idle()
        let duo = h.store.duo(DuoFixtures.duoID)
        XCTAssertEqual(duo?.status(of: .partner, on: today)?.progressBucket, 100, "the partner's newer row stays")
        XCTAssertEqual(duo?.vers["partner-\(today)"], 4)
        XCTAssertEqual(duo?.cursor, 14)
    }

    // MARK: Refused days

    func testAPoisonedDayIsNotSentAgainUntilWhatIsWantedChanges() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onPushDayStatuses = { _, request in
            DuoWireChangesWithResult(changes: DuoFixtures.wireChanges(cursor: request.since), accepted: [], unchanged: [],
                                     rejected: request.statuses.map { DuoWireRejected(day: $0.day, reason: .dayAfterToday) })
        }
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since) }
        h.log([today: 1000])
        await h.idle()
        XCTAssertEqual(h.puts.count, 1)
        XCTAssertTrue(h.cache.loadRejectedDays()[DuoFixtures.duoID.uuidString.lowercased()]?.blocks(owner(today, 50)) == true)
        h.clock.advance(120)
        await h.engine.flush()
        h.log([today: 1000])
        await h.engine.refresh()
        await h.idle()
        XCTAssertEqual(h.puts.count, 1, "the refused row is not sent on every flush")
        h.clock.advance(120)
        h.log([today: 1500])
        await h.idle()
        XCTAssertEqual(h.puts.count, 2)
        XCTAssertEqual(h.puts.last?.statuses.first?.progressBucket, 75)
    }

    func testATodayTheServerRefusedForItsMyTodayIsPoisoned() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onPushDayStatuses = { _, _ in throw failure(.dayOutOfRange, status: 422, details: DuoWireErrorDetails(field: "my_today")) }
        h.log([today: 1000])
        await h.idle()
        XCTAssertEqual(h.puts.count, 1)
        XCTAssertEqual(h.cache.loadRejectedDays()[DuoFixtures.duoID.uuidString.lowercased()]?.blocks(owner(today, 50)), true)
        h.clock.advance(120)
        await h.engine.flush()
        await h.idle()
        XCTAssertEqual(h.puts.count, 1)
        XCTAssertTrue(h.sleeper.delays.isEmpty, "a 422 is not retried")
    }

    // MARK: The ver CAS

    func testAConflictIsReBasedAndTriedOnceMoreInTheSameSlotAndNoMore() async {
        let h = CHarness()
        h.knowMember()
        var duo = DuoFixtures.duo(statuses: [owner(today, 25)], cursor: 10)
        duo.vers = ["owner-\(today)": 37]
        h.store.upsert(duo)
        var answers = [40, 41]
        h.fake.onPushDayStatuses = { _, request in
            let ver = Int64(answers.isEmpty ? 42 : answers.removeFirst())
            return DuoWireChangesWithResult(changes: DuoFixtures.wireChanges(cursor: request.since), accepted: [], unchanged: [],
                                            rejected: [DuoWireRejected(day: request.statuses[0].day, reason: .verConflict,
                                                                       current: DuoFixtures.wireRow(.owner, "2026-09-21", bucket: ver == 40 ? 75 : 100, ver: ver))])
        }
        h.log([today: 1000])
        await h.idle()
        XCTAssertEqual(h.puts.map { $0.statuses.map(\.baseVer) }, [[37], [40]], "base_ver 37, then the server's 40 (KV11)")
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.vers["owner-\(today)"], 41)
        XCTAssertEqual(h.puts.count, 2, "one retry in the slot, never a third request")
    }

    func testAReplayOfAWriteThatAlreadyLandedMakesNoSecondOrThirdRequest() async {
        // X7: the server answers the replay with the very row that was wanted.
        let h = CHarness()
        h.knowMember()
        var duo = DuoFixtures.duo(statuses: [owner(today, 25)], cursor: 10)
        duo.vers = ["owner-\(today)": 3]
        h.store.upsert(duo)
        h.fake.onPushDayStatuses = { _, request in
            DuoWireChangesWithResult(changes: DuoFixtures.wireChanges(cursor: request.since), accepted: [], unchanged: [],
                                     rejected: [DuoWireRejected(day: "2026-09-21", reason: .verConflict,
                                                                current: DuoFixtures.wireRow(.owner, "2026-09-21", bucket: 50, ver: 4))])
        }
        h.log([today: 1000])
        await h.idle()
        XCTAssertEqual(h.puts.count, 1)
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.vers["owner-\(today)"], 4)
        h.clock.advance(120)
        await h.engine.flush()
        await h.idle()
        XCTAssertEqual(h.puts.count, 1, "the re-diff is empty")
    }

    func testAConflictWithoutCurrentSendsTheDayAgainFromVerZero() async {
        let h = CHarness()
        h.knowMember()
        var duo = DuoFixtures.duo(statuses: [owner(today, 25)], cursor: 10)
        duo.vers = ["owner-\(today)": 37]
        h.store.upsert(duo)
        var first = true
        h.fake.onPushDayStatuses = { _, request in
            defer { first = false }
            if first {
                return DuoWireChangesWithResult(changes: DuoFixtures.wireChanges(cursor: request.since), accepted: [], unchanged: [],
                                                rejected: [DuoWireRejected(day: "2026-09-21", reason: .verConflict)])
            }
            return DuoWireChangesWithResult(changes: DuoFixtures.wireChanges(cursor: request.since + 1, statuses: [DuoFixtures.wireRow(.owner, "2026-09-21", bucket: 50, ver: 1)]),
                                            accepted: ["2026-09-21"], unchanged: [], rejected: [])
        }
        h.log([today: 1000])
        await h.idle()
        XCTAssertEqual(h.puts.map { $0.statuses.map(\.baseVer) }, [[37], [0]])
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.vers["owner-\(today)"], 1)
    }

    func testOnlyTheFourFieldsOfThisPhonesOwnDaysEverLeave() async throws {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(role: .partner, statuses: [DuoFixtures.status(.owner, today, bucket: 100)], cursor: 10))
        let server = CServer(role: .partner, clock: h.clock)
        h.serve(server)
        h.log([today: 1000, "2026-09-20": 2000])
        await h.idle()
        let request = try XCTUnwrap(h.puts.first)
        let body = try XCTUnwrap(String(data: DuoWireCoding.encode(request), encoding: .utf8))
        XCTAssertEqual(body, #"{"my_today":"2026-09-21","since":10,"statuses":[{"base_ver":0,"day":"2026-09-21","goal_met":false,"progress_bucket":50},{"base_ver":0,"day":"2026-09-20","goal_met":true,"progress_bucket":100}]}"#)
    }

    // MARK: The coalescer

    func testWritesAreSpacedThirtySecondsApartAndAnOwedWriteCountsFromWhenItWoke() async {
        // The sleeper wakes 40 seconds late, as an owed write can on a busy phone (KV19).
        let h = CHarness(lateBy: 40)
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let server = CServer(clock: h.clock)
        h.serve(server)
        h.log([today: 500])
        await h.idle()
        XCTAssertEqual(h.puts.count, 1, "the first write goes at once")
        h.clock.advance(5)
        h.log([today: 1000])
        h.log([today: 1500])
        await h.idle()
        XCTAssertEqual(h.sleeper.delays, [25], "one owed write, at the thirty seconds")
        XCTAssertEqual(h.puts.count, 2)
        XCTAssertEqual(h.puts.last?.statuses.first?.progressBucket, 75, "the latest state, not every step on the way")
        // It woke at +70, not at +30, and the next thirty seconds count from there: a write at
        // +70 still has to wait. Counted from +30 it would have gone at once.
        h.log([today: 2000])
        await h.idle()
        XCTAssertEqual(h.sleeper.delays, [25, 30])
        XCTAssertEqual(h.puts.count, 3)
    }

    func testAFlushWithNothingOwedSendsNothingAndCountsForNothing() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(statuses: [owner(today, 50)], cursor: 10))
        h.log([today: 1000])
        await h.engine.flush()
        await h.idle()
        XCTAssertTrue(h.puts.isEmpty)
        XCTAssertTrue(h.sleeper.delays.isEmpty)
    }

    // MARK: Retries through the sleeper

    func testAReadThatMeetsMaintenanceIsRetriedThreeTimesThenWaitsForTheNextForeground() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onFetchChanges = { _, _ in throw failure(.maintenance, status: 503, retryAfter: 45) }
        await h.engine.refresh()
        await h.idle()
        XCTAssertEqual(h.fetches.count, 4)
        XCTAssertEqual(h.sleeper.delays, [45, 45, 45])
        XCTAssertEqual(h.store.availability, .maintenance)
        // A push inside the server's wait (the last answer asked for 45 s) is held to its end, and
        // reads once then (C15); it is not the next foreground, so no new run of retries starts.
        await h.engine.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 99, kind: .joined))
        XCTAssertEqual(h.fetches.count, 4, "nothing is sent inside the wait")
        await h.idle()
        XCTAssertEqual(h.fetches.count, 5)
        XCTAssertEqual(h.sleeper.delays, [45, 45, 45, 45])
        // The next foreground starts a new run, after the wait the last answer asked for.
        await h.engine.refresh()
        await h.idle()
        XCTAssertEqual(h.fetches.count, 9)
        XCTAssertEqual(h.sleeper.delays.count, 8)
    }

    func testARateLimitedWriteWaitsWhatTheServerSaysAtMostThreeTimes() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onPushDayStatuses = { _, _ in throw failure(.rateLimited, status: 429, retryAfter: 90) }
        h.log([today: 1000])
        await h.idle()
        XCTAssertEqual(h.puts.count, 4)
        XCTAssertEqual(h.sleeper.delays, [90, 90, 90])
        // The last answer asked for 90 s. A drink 30 s into it sends nothing (C15, which reversed
        // this test's old "a drink still sends"): the write is owed at the end of the wait.
        h.clock.advance(30)
        h.log([today: 1500])
        XCTAssertEqual(h.puts.count, 4, "nothing inside the wait the server asked for")
        h.log([today: 1600])
        await h.idle()
        XCTAssertEqual(h.sleeper.delays, [90, 90, 90, 60], "one owed write, at the end of the wait")
        XCTAssertEqual(h.puts.count, 5)
        XCTAssertEqual(h.puts.last?.statuses.first?.progressBucket, 75, "the latest state")
        // Past the wait, with the run of retries spent, a drink sends once and starts no new run.
        h.clock.advance(120)
        h.log([today: 2000])
        await h.idle()
        XCTAssertEqual(h.puts.count, 6)
        XCTAssertEqual(h.sleeper.delays.count, 4, "no new run of retries before the next foreground")
    }

    func testACancelledReadSchedulesNothingAndLeavesNoTrace() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onFetchChanges = { _, _ in throw CancellationError() }
        await h.engine.refresh()
        await h.idle()
        XCTAssertTrue(h.sleeper.delays.isEmpty, "a cancelled task invites no re-send (§6.7)")
        XCTAssertTrue(h.store.diagnostics.recentErrors.isEmpty)
        XCTAssertEqual(h.fetches.count, 1)
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.hasEnded, false)
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.cursor, 10)
    }

    func testACancelledWriteSchedulesNothingAndLeavesNoTrace() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onPushDayStatuses = { _, _ in throw CancellationError() }
        h.log([today: 1000])
        await h.idle()
        XCTAssertEqual(h.puts.count, 1)
        XCTAssertTrue(h.sleeper.delays.isEmpty, "a cancelled task invites no re-send (§6.7)")
        XCTAssertTrue(h.store.diagnostics.recentErrors.isEmpty)
        XCTAssertTrue(h.store.duo(DuoFixtures.duoID)?.statuses.isEmpty == true, "nothing became known from a write whose fate is unknown")
    }

    // MARK: Nudges

    func testANudgeIsAppendedBeforeItIsSentAndTheServersRowReplacesIt() async throws {
        let h = CHarness(gated: true)
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let serverTime = h.clock.now.addingTimeInterval(-3)
        let door = CGate()
        h.gates.doors[.nudge] = door
        h.fake.onSendNudge = { _, request in
            DuoWireSendNudgeResult(response: DuoWireSendNudgeResponse(nudge: DuoWireNudge(id: request.id, fromRole: .owner, presetId: request.presetId,
                                                                                         createdAt: serverTime), remainingToday: 2),
                                   wasAlreadySent: false)
        }
        let tap = Task { await h.engine.sendNudge(.sipWithMe, in: DuoFixtures.duo()) }
        await settle { door.arrivals == 1 }
        let heldWhenSent = h.store.duo(DuoFixtures.duoID)?.allNudges.map(\.id) ?? []
        door.open()
        await tap.value
        let sent = try XCTUnwrap(h.nudgesSent.first)
        XCTAssertTrue(DuoNudge.isNudgeRecordName(sent.id))
        XCTAssertEqual(sent.id, sent.id.uppercased().replacingOccurrences(of: "NUDGE-", with: "nudge-"), "iOS writes the UUID upper case")
        XCTAssertEqual(sent.presetId, "sipWithMe")
        XCTAssertEqual(sent.senderDay, today)
        XCTAssertEqual(heldWhenSent, [sent.id], "the copy is on the card before the request leaves")
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.allNudges, [DuoNudge(id: sent.id, fromRole: .owner, presetID: "sipWithMe", createdAt: serverTime)])
    }

    func testANudgeThatCannotGetThroughIsTriedWithTheSameIdAt30_60_120AndThenAtTheNextForeground() async throws {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onSendNudge = { _, _ in throw DuoTransportError.offline }
        await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo())
        XCTAssertEqual(h.nudgesSent.count, 1, "the tap returns after its one attempt; the retries run on their own (C16)")
        await h.idle()
        XCTAssertEqual(h.nudgesSent.count, 4)
        XCTAssertEqual(Set(h.nudgesSent.map(\.id)).count, 1, "the same id every time")
        XCTAssertEqual(h.sleeper.delays, [30, 60, 120])
        let id = try XCTUnwrap(h.nudgesSent.first?.id)
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.allNudges.map(\.id), [id], "the copy is kept")

        let clock = h.clock
        h.fake.onSendNudge = { _, request in
            DuoWireSendNudgeResult(response: DuoWireSendNudgeResponse(nudge: DuoWireNudge(id: request.id, fromRole: .owner, presetId: request.presetId,
                                                                                         createdAt: clock.now), remainingToday: 2), wasAlreadySent: true)
        }
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since) }
        await h.engine.refresh()
        await h.idle()
        XCTAssertEqual(h.nudgesSent.count, 5)
        XCTAssertEqual(h.nudgesSent.last?.id, id)
        await h.engine.refresh()
        await h.idle()
        XCTAssertEqual(h.nudgesSent.count, 5, "confirmed, so never sent again")
    }

    func testANudgeWhoseFateIsUnknownIsKeptAndResentWithoutAnythingScheduled() async {
        for unknown: Error in [CancellationError(), DuoTransportError.unreadable(httpStatus: 201, requestID: nil)] {
            let h = CHarness()
            h.knowMember()
            h.store.upsert(DuoFixtures.duo(cursor: 10))
            h.fake.onSendNudge = { _, _ in throw unknown }
            await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo())
            XCTAssertEqual(h.nudgesSent.count, 1, "\(unknown)")
            XCTAssertTrue(h.sleeper.delays.isEmpty, "nothing is scheduled for \(unknown)")
            XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.allNudges.count, 1, "the in-flight copy is kept for \(unknown)")
            h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since) }
            await h.engine.refresh()
            await h.idle()
            XCTAssertEqual(h.nudgesSent.count, 2, "the next foreground sends the same id again")
            XCTAssertEqual(Set(h.nudgesSent.map(\.id)).count, 1)
        }
    }

    func testAny4xxRemovesTheCopyAndIsNotRetried() async {
        for refusal in [failure(.rateLimited, status: 429, retryAfter: 60), failure(.schema, status: 400), failure(.presetUnknown, status: 422),
                        failure(.duoPending, status: 409), DuoTransportError.unreadable(httpStatus: 404, requestID: nil)] {
            let h = CHarness()
            h.knowMember()
            h.store.upsert(DuoFixtures.duo(cursor: 10))
            h.fake.onSendNudge = { _, _ in throw refusal }
            await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo())
            await h.engine.refresh()
            await h.idle()
            XCTAssertEqual(h.nudgesSent.count, 1, "\(refusal)")
            XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.allNudges.count, 0, "the copy is removed for \(refusal)")
            XCTAssertNil(h.store.notice, "nothing is said for \(refusal)")
        }
    }

    func testAPartnerWhoAlreadyMetTheirGoalAndTheDaysLimitAreToldInWords() async {
        let rows: [(DuoTransportError, String)] = [
            (failure(.partnerAlreadyMet, status: 409), "Sam already met their goal. Nothing to nudge."),
            (failure(.nudgeLimit, status: 429, retryAfter: 3600), "That is all your nudges for today."),
        ]
        for (refusal, words) in rows {
            let h = CHarness()
            h.knowMember()
            h.store.upsert(DuoFixtures.duo(cursor: 10))
            h.fake.onSendNudge = { _, _ in throw refusal }
            await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo())
            XCTAssertEqual(h.store.notice, words)
            XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.allNudges.count, 0)
            XCTAssertTrue(h.sleeper.delays.isEmpty)
        }
    }

    func testANudgeToADuoThatHasEndedMarksItEnded() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onSendNudge = { _, _ in throw failure(.duoEnded, status: 409) }
        await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo())
        let duo = h.store.duo(DuoFixtures.duoID)
        XCTAssertNotNil(duo?.endedAt)
        XCTAssertEqual(duo?.endedBy, .unknown)
        XCTAssertNil(h.store.notice)
        XCTAssertEqual(h.announcer.removedFor, [DuoFixtures.duoID])
        XCTAssertEqual(h.push.clearedLast, 1)
    }

    func testTwoQuickTapsCannotBothBeTheThirdNudgeOfTheDay() async {
        let h = CHarness(gated: true)
        h.knowMember(nudgesPerDay: 3)
        var duo = DuoFixtures.duo(cursor: 10)
        duo.nudges = (1...2).map { DuoNudge(id: "nudge-00000000-0000-4000-8000-0000000000e\($0)", fromRole: .owner, presetID: "cheers",
                                            createdAt: h.clock.now.addingTimeInterval(-600)) }
        h.store.upsert(duo)
        let door = CGate()
        h.gates.doors[.nudge] = door
        let clock = h.clock
        h.fake.onSendNudge = { _, request in
            DuoWireSendNudgeResult(response: DuoWireSendNudgeResponse(nudge: DuoWireNudge(id: request.id, fromRole: .owner, presetId: request.presetId,
                                                                                         createdAt: clock.now), remainingToday: 0), wasAlreadySent: false)
        }
        let first = Task { await h.engine.sendNudge(.waterBreak, in: duo) }
        await settle { door.arrivals == 1 }
        await h.engine.sendNudge(.cheers, in: duo)
        XCTAssertEqual(door.arrivals, 1, "the second tap found the first one's copy and stopped")
        door.open()
        await first.value
        XCTAssertEqual(h.nudgesSent.count, 1)
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.allNudges.count, 3)
    }

    // MARK: Pushes

    func testAPushIsFetchedOnlyWhenItIsAheadOfTheCursorAndOnlyForItsDuo() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.store.upsert(DuoFixtures.duo(id: otherDuoID, cursor: 30))
        h.fake.onFetchChanges = { id, since in DuoFixtures.wireChanges(id: UUID(uuidString: id)!, cursor: since + 1) }
        await h.engine.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 10, kind: .nudge(id: "nudge-00000000-0000-4000-8000-000000000009", preset: nil)))
        await h.engine.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 7, kind: .goalMet(day: today, iHaveToo: false)))
        XCTAssertTrue(h.fake.calls.isEmpty, "a push at or behind the cursor is already read (KV17)")
        await h.engine.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 11, kind: .digest(kinds: ["goal_met"], days: [today], nudgeIDs: [], preset: nil, count: 1)))
        XCTAssertEqual(h.fake.calls, [.fetchChanges(duoID: DuoFixtures.duoID.uuidString.lowercased(), since: 10)])
        await h.engine.pushArrived(DuoPushPayload(duoID: otherDuoID, seq: nil, kind: .unknown("new_kind")))
        XCTAssertEqual(h.fake.calls.last, .fetchChanges(duoID: otherDuoID.uuidString.lowercased(), since: 30), "a push with no seq is always worth a read")
        XCTAssertEqual(h.mes, 0)
    }

    func testAPushForADuoThisPhoneDoesNotHoldAsksMeAndReadsTheNewDuoWhole() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onMe = { meAnswer(duos: [DuoFixtures.wireHeader(), DuoFixtures.wireHeader(id: otherDuoID)]) }
        h.fake.onFetchChanges = { id, since in DuoFixtures.wireChanges(id: UUID(uuidString: id)!, cursor: since + 1) }
        await h.engine.pushArrived(DuoPushPayload(duoID: otherDuoID, seq: 2, kind: .joined))
        XCTAssertEqual(h.mes, 1, "even with a fresh member record")
        XCTAssertNotNil(h.store.duo(otherDuoID))
        XCTAssertTrue(h.fake.calls.contains(.fetchChanges(duoID: otherDuoID.uuidString.lowercased(), since: 0)))
        XCTAssertEqual(h.store.duo(otherDuoID)?.syncedOnce, true, "read whole, so now it may be written")
    }

    func testAPushForAnEndedDuoReadsNothing() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(ended: true, cursor: 10))
        await h.engine.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 12, kind: .ended(.partner)))
        XCTAssertTrue(h.fake.calls.isEmpty)
    }

    // MARK: Ended

    func testADuoTheServerNoLongerHasIsMarkedEndedWithNoAlertAndTheTokenGoesWithTheLastOne() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onFetchChanges = { _, _ in throw failure(.duoUnknown, status: 404) }
        await h.engine.refresh()
        let duo = h.store.duo(DuoFixtures.duoID)
        XCTAssertEqual(duo?.endedAt, h.clock.now)
        XCTAssertEqual(duo?.endedBy, .unknown)
        XCTAssertNil(h.store.notice, "no alert (§6.7)")
        XCTAssertEqual(h.announcer.removedFor, [DuoFixtures.duoID])
        XCTAssertEqual(h.push.clearedLast, 1)
        XCTAssertTrue(h.sleeper.delays.isEmpty)
    }

    func testAnotherLiveDuoKeepsTheToken() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.store.upsert(DuoFixtures.duo(id: otherDuoID, cursor: 10))
        h.fake.onFetchChanges = { id, since in
            if id == DuoFixtures.duoID.uuidString.lowercased() { throw failure(.duoEnded, status: 409) }
            return DuoFixtures.wireChanges(id: otherDuoID, cursor: since)
        }
        await h.engine.refresh()
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.hasEnded, true)
        XCTAssertEqual(h.store.duo(otherDuoID)?.hasEnded, false)
        XCTAssertEqual(h.push.clearedLast, 0)
    }

    func testAFeedThatSaysTheLastDuoEndedLetsTheTokenGo() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onFetchChanges = { _, _ in DuoFixtures.wireChanges(state: .ended, cursor: 12) }
        await h.engine.refresh()
        XCTAssertEqual(h.store.duo(DuoFixtures.duoID)?.hasEnded, true)
        XCTAssertEqual(h.push.clearedLast, 1)
    }

    // MARK: GET /me and D45

    func testMeIsAskedAtMostHourlyAndOnlyWithACachedDuo() async {
        let h = CHarness()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onMe = { meAnswer() }
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since) }
        await h.engine.refresh()
        XCTAssertEqual(h.mes, 1)
        XCTAssertEqual(h.store.memberInfo?.supportID, "ABCD1234EFGH")
        h.clock.advance(DuoProtocolConstants.meRefreshInterval - 1)
        await h.engine.refresh()
        XCTAssertEqual(h.mes, 1)
        h.clock.advance(1)
        await h.engine.refresh()
        XCTAssertEqual(h.mes, 2)
        XCTAssertEqual(h.fake.calls.firstIndex(of: .me), 0, "the member record comes before the reads")
    }

    func testTheFirstDeviceListIsSavedSilentlyAndADeviceAddedLaterRaisesTheNotice() async {
        let h = CHarness()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since) }
        h.fake.onMe = { meAnswer(devices: [device("this", thisDevice: true), device("ipad")]) }
        await h.engine.refresh()
        XCTAssertFalse(h.store.newDeviceNotice, "the first list is the baseline")
        XCTAssertEqual(h.cache.loadSeenDeviceIDs(), ["this", "ipad"])
        h.clock.advance(DuoProtocolConstants.meRefreshInterval)
        h.fake.onMe = { meAnswer(devices: [device("this", thisDevice: true), device("ipad"), device("new-phone")]) }
        await h.engine.refresh()
        XCTAssertTrue(h.store.newDeviceNotice)
        XCTAssertEqual(h.cache.loadSeenDeviceIDs(), ["this", "ipad"], "the list is saved when the person dismisses the notice")
        h.store.dismissNewDeviceNotice()
        h.clock.advance(DuoProtocolConstants.meRefreshInterval)
        await h.engine.refresh()
        XCTAssertFalse(h.store.newDeviceNotice)
    }

    func testThisPhoneAndASupersededDeviceNeverRaiseTheNotice() async {
        let h = CHarness()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.cache.saveSeenDeviceIDs(["ipad"])
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since) }
        h.fake.onMe = { meAnswer(devices: [device("this-new-id", thisDevice: true), device("ipad"), device("old-phone", superseded: true)]) }
        await h.engine.refresh()
        XCTAssertFalse(h.store.newDeviceNotice)
    }

    func testAListedDuoThatWasClearedOrHasEndedIsNotAddedAndANewLiveOneIsReadWhole() async {
        let h = CHarness()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.cache.markCleared(thirdDuoID, now: h.clock.now)
        let ended = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000004")!
        h.fake.onMe = { meAnswer(duos: [DuoFixtures.wireHeader(), DuoFixtures.wireHeader(id: otherDuoID), DuoFixtures.wireHeader(id: thirdDuoID),
                                       DuoFixtures.wireHeader(id: ended, state: .ended)]) }
        var reads: [String: Int64] = [:]
        h.fake.onFetchChanges = { id, since in
            reads[id] = since
            return DuoFixtures.wireChanges(id: UUID(uuidString: id)!, cursor: since + 1)
        }
        await h.engine.refresh()
        XCTAssertNil(h.store.duo(thirdDuoID), "a Clear is remembered (§12.2)")
        XCTAssertNil(h.store.duo(ended), "the server lists an ended duo for 30 days")
        XCTAssertNotNil(h.store.duo(otherDuoID))
        XCTAssertEqual(reads[otherDuoID.uuidString.lowercased()], 0)
        XCTAssertEqual(reads[DuoFixtures.duoID.uuidString.lowercased()], 10)
    }

    // MARK: Disconnected

    func testADisconnectedPhoneSendsNothingAndNoForegroundRepeatsThe401() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.fake.onFetchChanges = { _, _ in throw failure(.deviceRevoked, status: 401) }
        await h.engine.refresh()
        XCTAssertEqual(h.store.availability, .disconnected)
        let after = h.fake.calls.count
        await h.engine.refresh()
        await h.engine.flush()
        _ = await h.engine.backgroundRefresh()
        await h.engine.pushArrived(DuoPushPayload(duoID: DuoFixtures.duoID, seq: 99, kind: .joined))
        await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo())
        h.log([today: 2000])
        await h.idle()
        XCTAssertEqual(h.fake.calls.count, after, "\(h.fake.calls)")
        XCTAssertTrue(h.sleeper.delays.isEmpty)
    }

    // MARK: The skin

    func testASkinChangeIsQueuedOnceAsAPatch() async throws {
        let h = CHarness()
        h.knowMember(skin: "classic")
        h.store.upsert(DuoFixtures.duo(statuses: [owner(today, 100)], cursor: 10))
        var skin = "classic"
        h.dependencies.activeSkin = { skin }
        h.log([today: 500])
        XCTAssertTrue(h.ops.queued.isEmpty, "the server already has it")
        skin = "forest"
        h.log([today: 600])
        h.log([today: 700])
        h.log([today: 800])
        XCTAssertEqual(h.ops.queued.count, 1, "once per change")
        let op = try XCTUnwrap(h.ops.queued.first)
        XCTAssertEqual(op.kind, .updateMe)
        XCTAssertEqual(op.method, "PATCH")
        XCTAssertEqual(String(data: op.body, encoding: .utf8), #"{"skin":"forest"}"#)
        skin = "classic"
        h.log([today: 900])
        XCTAssertEqual(h.ops.queued.count, 2, "back to what the server holds now is a change too, after the queued one lands")
        XCTAssertTrue(h.fake.calls.isEmpty, "queued, never sent from here")

        let unknown = CHarness()
        unknown.store.upsert(DuoFixtures.duo())
        unknown.dependencies.activeSkin = { "forest" }
        unknown.log([today: 500])
        XCTAssertTrue(unknown.ops.queued.isEmpty, "with no GET /me yet there is nothing to compare with")
        let nobody = CHarness(credential: nil, launch: .none)
        nobody.store.upsert(DuoFixtures.duo())
        nobody.knowMember(skin: "classic")
        nobody.dependencies.activeSkin = { "forest" }
        nobody.log([today: 500])
        XCTAssertTrue(nobody.ops.queued.isEmpty)
        await h.idle()
        await unknown.idle()
        await nobody.idle()
    }

    // MARK: Background

    func testABackgroundRefreshReadsTheLogPublishesAndThenReads() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let server = CServer(clock: h.clock)
        h.serve(server)
        h.engine.activate(logReader: FakeLogReader(DuoLogSummary(totalsByDay: [today: 2000], goalML: 2000, earliestEntryDay: "2026-01-01")))
        let changed = await h.engine.backgroundRefresh()
        XCTAssertTrue(changed)
        XCTAssertEqual(h.store.latest?.totalsByDay, [today: 2000])
        XCTAssertEqual(h.fake.calls.map { call -> String in
            if case .pushDayStatuses = call { return "put" }
            if case .fetchChanges = call { return "fetch" }
            return "other"
        }, ["put", "fetch"])
        await h.idle()
        let again = await h.engine.backgroundRefresh()
        XCTAssertFalse(again, "nothing new")
    }

    func testTwoBackgroundRefreshesAtOnceShareOneAnswer() async {
        let h = CHarness(gated: true)
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let door = CGate()
        h.gates.doors[.fetch] = door
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since + 1, statuses: [DuoFixtures.wireRow(.partner, "2026-09-21", bucket: 50, ver: 1)]) }
        let first = Task { await h.engine.backgroundRefresh() }
        await settle { door.arrivals == 1 }
        let second = Task { await h.engine.backgroundRefresh() }
        for _ in 0..<50 { await Task.yield() }
        door.open()
        let answers = [await first.value, await second.value]
        XCTAssertEqual(answers, [true, true], "neither tells iOS nothing changed while the other reads the change")
        XCTAssertEqual(h.fetches.count, 1)
    }

    func testABackgroundReadOfALogThatCouldNotBeReadPublishesNothing() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(statuses: [owner(today, 100)], cursor: 10))
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since) }
        h.engine.activate(logReader: FakeLogReader(.empty))
        _ = await h.engine.backgroundRefresh()
        await h.idle()
        XCTAssertTrue(h.puts.isEmpty, "a summary with no goal would send today as missed")
    }

    // MARK: Single flight

    func testRefreshesThatOverlapGoOneAtATimeAndOnceMoreAfter() async {
        let h = CHarness(gated: true)
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let door = CGate()
        h.gates.doors[.fetch] = door
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: since + 1) }
        let first = Task { await h.engine.refresh() }
        await settle { door.arrivals == 1 }
        let second = Task { await h.engine.refresh() }
        let third = Task { await h.engine.refresh() }
        for _ in 0..<50 { await Task.yield() }
        XCTAssertEqual(door.arrivals, 1, "nothing else is sent while the first is out")
        door.open()
        await first.value
        await second.value
        await third.value
        XCTAssertEqual(h.fetches, [10, 11], "the two that came in while it ran made one more, after it")
        XCTAssertEqual(h.gates.mostInFlight[.fetch], 1)
    }

    // MARK: The goal-raise note

    func testAGoalRaiseWithALiveDuoIsNotedOnceAndNeverAgain() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        h.log([today: 500], goal: 2000)
        XCTAssertNil(h.store.notice, "the first summary after a launch has nothing to compare with")
        h.log([today: 500], goal: 2500)
        XCTAssertEqual(h.store.notice, DuoCopy.goalRaiseNotice)
        XCTAssertTrue(h.cache.goalRaiseNoticeShown)
        h.store.notice = nil
        h.log([today: 500], goal: 3000)
        XCTAssertNil(h.store.notice, "once, ever")
        let relaunched = CHarness()
        relaunched.store.upsert(DuoFixtures.duo(cursor: 10))
        relaunched.cache.goalRaiseNoticeShown = true
        relaunched.log([today: 500], goal: 2000)
        relaunched.log([today: 500], goal: 2600)
        XCTAssertNil(relaunched.store.notice)
        await h.idle()
        await relaunched.idle()
    }

    func testNoNoteForALowerGoalNoDuoAnEndedDuoOrOneNotYetRead() async {
        func noted(_ seed: DuoState?, from: Int, to: Int) async -> Bool {
            let h = CHarness()
            if let seed { h.store.upsert(seed) }
            h.log([today: 500], goal: from)
            h.log([today: 500], goal: to)
            await h.idle()
            return h.store.notice != nil || h.cache.goalRaiseNoticeShown
        }
        let lower = await noted(DuoFixtures.duo(), from: 2500, to: 2000)
        let noDuo = await noted(nil, from: 2000, to: 2500)
        let ended = await noted(DuoFixtures.duo(ended: true), from: 2000, to: 2500)
        let unread = await noted(DuoFixtures.duo(syncedOnce: false), from: 2000, to: 2500)
        let control = await noted(DuoFixtures.duo(), from: 2000, to: 2500)
        XCTAssertFalse(lower, "lower")
        XCTAssertFalse(noDuo, "no duo")
        XCTAssertFalse(ended, "ended")
        XCTAssertFalse(unread, "not read")
        XCTAssertTrue(control, "and the control: a raise with a read live duo")
    }

    // MARK: A wipe while a request is out

    func testAWipeWhileAReadIsOutDropsItsAnswer() async {
        let h = CHarness(gated: true)
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let door = CGate()
        h.gates.doors[.fetch] = door
        let sent = h.clock.now
        h.fake.onFetchChanges = { _, _ in
            DuoFixtures.wireChanges(cursor: 12, statuses: [DuoFixtures.wireRow(.partner, "2026-09-21", bucket: 100, ver: 2)],
                                    nudges: [DuoWireNudge(id: "nudge-00000000-0000-4000-8000-000000000007", fromRole: .partner, presetId: "cheers",
                                                          createdAt: sent)])
        }
        let refresh = Task { await h.engine.refresh() }
        await settle { door.arrivals == 1 }
        h.store.resetLocalState()
        door.open()
        await refresh.value
        await h.idle()
        XCTAssertTrue(h.store.duos.isEmpty, "a late answer brings back no duo and no partner's name")
        XCTAssertTrue(h.cache.loadLedger().seen.isEmpty)
        XCTAssertTrue(h.announcer.delivered.isEmpty)
        XCTAssertTrue(h.store.diagnostics.duos.isEmpty)
    }

    func testAWipeWhileMeIsOutDropsIt() async {
        let h = CHarness(gated: true)
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let door = CGate()
        h.gates.doors[.me] = door
        h.fake.onMe = { meAnswer(devices: [device("this", thisDevice: true)], duos: [DuoFixtures.wireHeader(), DuoFixtures.wireHeader(id: otherDuoID)]) }
        let refresh = Task { await h.engine.refresh() }
        await settle { door.arrivals == 1 }
        h.store.resetLocalState()
        door.open()
        await refresh.value
        await h.idle()
        XCTAssertNil(h.store.memberInfo)
        XCTAssertTrue(h.store.duos.isEmpty)
        XCTAssertNil(h.cache.loadSeenDeviceIDs())
        XCTAssertFalse(h.fake.calls.contains { if case .fetchChanges = $0 { return true }; return false })
    }

    // MARK: Announcements

    private func partnerNudge(_ h: CHarness, _ id: String = "nudge-00000000-0000-4000-8000-0000000000aa") -> DuoWireNudge {
        DuoWireNudge(id: id, fromRole: .partner, presetId: "sipWithMe", createdAt: h.clock.now.addingTimeInterval(-600))
    }

    func testWhatAReadFindsIsAnnouncedOnceAndARefusedOneIsOfferedAgain() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let nudge = partnerNudge(h)
        h.fake.onFetchChanges = { _, since in DuoFixtures.wireChanges(cursor: max(since, 11), nudges: [nudge]) }
        h.announcer.refusedKeys = [nudge.id]
        await h.engine.refresh()
        XCTAssertEqual(h.announcer.delivered.map { $0.map(\.key) }, [[nudge.id]])
        XCTAssertFalse(h.cache.loadLedger().hasSeen(nudge.id), "iOS refused it, so it was never announced")
        h.announcer.refusedKeys = []
        await h.engine.refresh()
        XCTAssertEqual(h.announcer.delivered.map { $0.map(\.key) }, [[nudge.id], [nudge.id]], "offered again, not lost")
        XCTAssertTrue(h.cache.loadLedger().hasSeen(nudge.id))
        await h.engine.refresh()
        XCTAssertEqual(h.announcer.delivered.count, 2, "and never a third time")
    }

    func testAnEventThePushesAlreadyToldIsNotAnnounced() async {
        let h = CHarness()
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let handled = partnerNudge(h)
        let shown = partnerNudge(h, "nudge-00000000-0000-4000-8000-0000000000bb")
        h.announcer.remoteKeys = [shown.id]
        h.fake.onFetchChanges = { _, since in
            DuoFixtures.wireChanges(cursor: max(since, 11), nudges: [handled, shown], handled: [DuoWireHandled(kind: "nudge", id: handled.id)])
        }
        await h.engine.refresh()
        await h.engine.refresh()
        XCTAssertTrue(h.announcer.delivered.isEmpty, "\(h.announcer.delivered)")
        XCTAssertTrue(h.cache.loadLedger().hasSeen(handled.id))
        XCTAssertTrue(h.cache.loadLedger().hasSeen(shown.id))
    }

    func testAReadAndAWriteThatCrossAnnounceAnEventOnce() async {
        let h = CHarness(gated: true)
        h.knowMember()
        h.store.upsert(DuoFixtures.duo(cursor: 10))
        let nudge = partnerNudge(h)
        let door = CGate()
        h.gates.doors[.put] = door
        h.fake.onPushDayStatuses = { _, request in
            DuoWireChangesWithResult(changes: DuoFixtures.wireChanges(cursor: 12, nudges: [nudge]), accepted: request.statuses.map(\.day), unchanged: [], rejected: [])
        }
        h.fake.onFetchChanges = { _, _ in DuoFixtures.wireChanges(cursor: 12, nudges: [nudge]) }
        h.log([today: 1000])
        await settle { door.arrivals == 1 }
        await h.engine.refresh()
        door.open()
        await h.idle()
        XCTAssertEqual(h.announcer.delivered.flatMap { $0 }.map(\.key), [nudge.id])
    }
}

/// Defaults in memory, so no test here writes a preference file.
private final class CMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Any] = [:]
    init() { super.init(suiteName: "DuoSyncEngineTests.memory")! }
    override func object(forKey defaultName: String) -> Any? { lock.lock(); defer { lock.unlock() }; return items[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { lock.lock(); items[defaultName] = value; lock.unlock() }
    override func set(_ value: Bool, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Int, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Double, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ value: Float, forKey defaultName: String) { set(value as Any?, forKey: defaultName) }
    override func set(_ url: URL?, forKey defaultName: String) { set(url as Any?, forKey: defaultName) }
    override func removeObject(forKey defaultName: String) { lock.lock(); items[defaultName] = nil; lock.unlock() }
    override func data(forKey defaultName: String) -> Data? { object(forKey: defaultName) as? Data }
    override func string(forKey defaultName: String) -> String? { object(forKey: defaultName) as? String }
    override func bool(forKey defaultName: String) -> Bool { (object(forKey: defaultName) as? Bool) ?? false }
    override func integer(forKey defaultName: String) -> Int { (object(forKey: defaultName) as? Int) ?? 0 }
    override func dictionaryRepresentation() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return items }
    override func removePersistentDomain(forName domainName: String) { lock.lock(); items = [:]; lock.unlock() }
}
#endif
