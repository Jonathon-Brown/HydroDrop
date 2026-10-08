#if DUO_V2
import XCTest
@testable import HydroDrop

// The sync engine under the interleavings and failures the stage C reviews found (2026-10-08,
// stage-c-fixes.md, C1 to C21): their probes, written here to assert what the engine must do,
// a test aimed at each mutant that slipped past `DuoSyncEngineTests`, and trimmed versions of
// their randomized runs. Two harnesses, both the reviewers' and both private to this file:
//
// - `RH`: a transport whose every call is held until the test answers it, over a small server
//   (the ver CAS, a feed by seq, nudges by id, GET /me), and a sleeper that holds every wait
//   until it is released and throws when its task is cancelled, as `Task.sleep` does.
// - `RWorld`: the sync review's model of the Worker (the CAS, `unchanged`, the 48-hour downgrade
//   backstop, the day range, a full feed for a `since` behind `oldest_seq` or ahead of `seq`,
//   snapshots for a restore of its database), with a request's processing on the server and its
//   answer reaching the phone as two separate steps, so answers can be lost or arrive in any order.

// MARK: - Shared doubles

private final class RClock: DuoClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date
    let calendar: Calendar

    init(_ now: Date, zone: TimeZone = TimeZone(secondsFromGMT: 0)!) {
        current = now
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        self.calendar = calendar
    }

    var now: Date { lock.lock(); defer { lock.unlock() }; return current }
    func advance(_ seconds: TimeInterval) { lock.lock(); current = current.addingTimeInterval(seconds); lock.unlock() }
    /// Moves forward only.
    func reach(_ date: Date) { lock.lock(); current = max(current, date); lock.unlock() }
    /// Any way at all: a person setting the date.
    func force(_ date: Date) { lock.lock(); current = date; lock.unlock() }
}

/// Defaults in memory, so a run of hundreds of harnesses writes no preference files.
private final class RMemoryDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Any] = [:]
    init() { super.init(suiteName: "DuoSyncEngineRobustnessTests.memory")! }
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
    var keys: Set<String> { lock.lock(); defer { lock.unlock() }; return Set(items.keys) }
}

/// Holds every wait until released. Cancelling the waiting task throws at once, as `Task.sleep` does.
@MainActor
private final class RSleeper {
    struct Waiter { let id: Int; let seconds: TimeInterval; let continuation: CheckedContinuation<Void, Error> }
    let clock: RClock
    var immediate = false
    private(set) var waiters: [Int: Waiter] = [:]
    private(set) var asked: [TimeInterval] = []
    private(set) var cancelledCount = 0
    private(set) var mostWaiting = 0
    private var nextID = 0
    init(clock: RClock) { self.clock = clock }

    func sleep(_ seconds: TimeInterval) async throws {
        asked.append(seconds)
        if immediate { clock.advance(seconds); return }
        nextID += 1
        let id = nextID
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                waiters[id] = Waiter(id: id, seconds: seconds, continuation: continuation)
                mostWaiting = max(mostWaiting, waiters.count)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
    }

    private func cancel(_ id: Int) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        cancelledCount += 1
        waiter.continuation.resume(throwing: CancellationError())
    }

    /// Wakes one waiter, moving the clock on by what it asked (plus `late`).
    func release(_ id: Int, late: TimeInterval = 0) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        clock.advance(waiter.seconds + late)
        waiter.continuation.resume()
    }

    func releaseAll() { for id in waiters.keys.sorted() { release(id) } }
    var count: Int { waiters.count }
    var ids: [Int] { waiters.keys.sorted() }
    var waitingSeconds: [TimeInterval] { waiters.values.map(\.seconds).sorted() }
}

/// A door a call waits at, opened once; every waiter is resumed exactly once.
@MainActor
private final class RGate {
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

// MARK: - The held-call harness (the concurrency review's)

@MainActor
private final class RServer {
    struct Row { var row: DuoWireStatusRow; var seq: Int64 }
    struct Duo {
        var id: UUID
        var role: DuoRole
        var seq: Int64 = 10
        var rows: [String: Row] = [:]
        var nudges: [String: (DuoWireNudge, Int64)] = [:]
        var ended = false
    }
    let clock: RClock
    var duos: [String: Duo] = [:]
    var devices: [DuoWireDevice] = []
    var extraHeaders: [DuoWireHeader] = []
    private(set) var putsApplied = 0
    init(clock: RClock) { self.clock = clock }

    func add(_ id: UUID, role: DuoRole = .owner, seq: Int64 = 10) { duos[id.uuidString.lowercased()] = Duo(id: id, role: role, seq: seq) }

    func header(_ duo: Duo) -> DuoWireHeader {
        DuoWireHeader(id: duo.id.uuidString.lowercased(), myRole: duo.role, state: duo.ended ? .ended : .active, createdAt: Date(timeIntervalSince1970: 1_789_000_000),
                      joinedAt: Date(timeIntervalSince1970: 1_789_100_000), endedAt: duo.ended ? clock.now : nil, endedBy: duo.ended ? .partner : nil,
                      ownerDisplayName: "Jo", ownerSkin: "classic", partnerDisplayName: "Sam", partnerSkin: "forest", partnerLastWriteDay: "2026-09-21",
                      partnerIsDemo: false, invite: DuoWireHeaderInvite(hasOpenInvite: false, expiresAt: nil), seq: duo.seq)
    }

    func changes(_ wire: String, since: Int64) throws -> DuoWireChanges {
        guard let duo = duos[wire] else { throw DuoTransportError.duoUnknown(DuoErrorContext(httpStatus: 404)) }
        let full = since == 0 || since > duo.seq
        let rows = duo.rows.values.filter { full || $0.seq > since }.map(\.row).sorted { ($0.day, $0.role.rawValue) < ($1.day, $1.role.rawValue) }
        let nudges = duo.nudges.values.filter { full || $0.1 > since }.map(\.0)
        return DuoWireChanges(duo: header(duo), full: full, statuses: rows, nudges: nudges, handled: [], cursor: duo.seq)
    }

    /// Something the partner (or another device of mine) wrote.
    func write(_ wire: String, role: DuoRole, day: String, bucket: Int) {
        guard var duo = duos[wire] else { return }
        let key = "\(role.rawValue)-\(day)"
        let ver = (duo.rows[key]?.row.ver ?? 0) + 1
        duo.seq += 1
        duo.rows[key] = Row(row: DuoWireStatusRow(role: role, day: day, goalMet: bucket == 100, progressBucket: bucket, updatedAt: clock.now, ver: ver), seq: duo.seq)
        duos[wire] = duo
    }

    func partnerNudge(_ wire: String, id: String) {
        guard var duo = duos[wire] else { return }
        duo.seq += 1
        duo.nudges[id] = (DuoWireNudge(id: id, fromRole: duo.role.other, presetId: "cheers", createdAt: clock.now), duo.seq)
        duos[wire] = duo
    }

    func put(_ wire: String, _ request: DuoWirePutStatusesRequest) throws -> DuoWireChangesWithResult {
        guard var duo = duos[wire] else { throw DuoTransportError.duoUnknown(DuoErrorContext(httpStatus: 404)) }
        putsApplied += 1
        var accepted: [String] = [], unchanged: [String] = [], rejected: [DuoWireRejected] = []
        var bumped = false
        for status in request.statuses {
            let key = "\(duo.role.rawValue)-\(status.day)"
            let stored = duo.rows[key]?.row
            if let stored, stored.goalMet == status.goalMet, stored.progressBucket == status.progressBucket { unchanged.append(status.day); continue }
            guard status.baseVer == (stored?.ver ?? 0) else { rejected.append(DuoWireRejected(day: status.day, reason: .verConflict, current: stored)); continue }
            if !bumped { duo.seq += 1; bumped = true }
            duo.rows[key] = Row(row: DuoWireStatusRow(role: duo.role, day: status.day, goalMet: status.goalMet, progressBucket: status.progressBucket,
                                                      updatedAt: clock.now, ver: (stored?.ver ?? 0) + 1), seq: duo.seq)
            accepted.append(status.day)
        }
        duos[wire] = duo
        return DuoWireChangesWithResult(changes: try changes(wire, since: request.since), accepted: accepted, unchanged: unchanged, rejected: rejected)
    }

    func nudge(_ wire: String, _ request: DuoWireSendNudgeRequest) throws -> DuoWireSendNudgeResult {
        guard var duo = duos[wire] else { throw DuoTransportError.duoUnknown(DuoErrorContext(httpStatus: 404)) }
        if let (stored, _) = duo.nudges[request.id] {
            return DuoWireSendNudgeResult(response: DuoWireSendNudgeResponse(nudge: stored, remainingToday: 0), wasAlreadySent: true)
        }
        duo.seq += 1
        let nudge = DuoWireNudge(id: request.id, fromRole: duo.role, presetId: request.presetId, createdAt: clock.now)
        duo.nudges[request.id] = (nudge, duo.seq)
        duos[wire] = duo
        return DuoWireSendNudgeResult(response: DuoWireSendNudgeResponse(nudge: nudge, remainingToday: 0), wasAlreadySent: false)
    }

    func me() -> DuoWireGetMeResponse {
        DuoWireGetMeResponse(member: DuoWireMember(id: "m", displayName: "Jo", skin: "classic", supportId: "ABCD1234EFGH", tier: .attested, termsVersion: 1),
                             limits: DuoWireLimits(nudgesPerDay: 3, maxActiveDuos: 5), devices: devices,
                             duos: duos.values.map(header) + extraHeaders, minClient: DuoWireMinClient(ios: "2.0", android: "2.0"))
    }

    func myNudges(_ wire: String) -> [DuoWireNudge] {
        guard let duo = duos[wire] else { return [] }
        return duo.nudges.values.map(\.0).filter { $0.fromRole == duo.role }
    }
}

/// What the test does with a call it is holding.
private enum ROutcome: Equatable {
    case ok
    /// The server did it; the answer never arrived.
    case lost
    case offline
    case maintenance(Int)
    case rateLimited(Int)
    case cancelled
    /// The server did it; the 2xx could not be read.
    case unreadable2xx
    case unauthenticated
    case error(DuoTransportError)
    /// This answer, whatever the server holds: a stale one, say.
    case custom(DuoWireChangesWithResult)
}

@MainActor
private final class RSched {
    enum Kind: String { case fetch, put, nudge, me }
    struct Call {
        let n: Int
        let kind: Kind
        let wire: String
        var since: Int64 = 0
        var put: DuoWirePutStatusesRequest?
        var nudge: DuoWireSendNudgeRequest?
        let at: Date
        let continuation: CheckedContinuation<Any, Error>
    }
    struct Record: CustomStringConvertible {
        let n: Int, kind: Kind, wire: String, at: Date
        var since: Int64 = 0
        var put: DuoWirePutStatusesRequest?
        var nudge: DuoWireSendNudgeRequest?
        var description: String { "#\(n) \(kind.rawValue) \(wire.suffix(2)) t=\(Int(at.timeIntervalSince1970) - 1_790_000_000)" }
    }
    let server: RServer
    var auto: ROutcome?
    /// Answers in this order, one per call, before `auto` takes over.
    var script: [ROutcome] = []
    private(set) var held: [Call] = []
    private(set) var log: [Record] = []
    private(set) var inFlight: [Kind: Int] = [:]
    private(set) var mostInFlight: [Kind: Int] = [:]
    private(set) var violations: [String] = []
    private(set) var conflictPuts: Set<Int> = []
    var onSend: ((Record) -> Void)?
    private var n = 0
    private var answering = 0

    init(server: RServer) { self.server = server }

    func call<T>(_ kind: Kind, wire: String, since: Int64 = 0, put: DuoWirePutStatusesRequest? = nil, nudge: DuoWireSendNudgeRequest? = nil) async throws -> T {
        n += 1
        let record = Record(n: n, kind: kind, wire: wire, at: server.clock.now, since: since, put: put, nudge: nudge)
        log.append(record)
        inFlight[kind, default: 0] += 1
        mostInFlight[kind] = max(mostInFlight[kind] ?? 0, inFlight[kind] ?? 0)
        if kind == .nudge, let id = nudge?.id, held.contains(where: { $0.nudge?.id == id }) { violations.append("nudge \(id) sent twice at once") }
        onSend?(record)
        defer { inFlight[kind, default: 0] -= 1 }
        if let outcome = script.isEmpty ? auto : script.removeFirst() {
            await Task.yield()
            answering = record.n
            return try answer(kind: kind, wire: wire, since: since, put: put, nudge: nudge, outcome: outcome) as! T
        }
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            held.append(Call(n: record.n, kind: kind, wire: wire, since: since, put: put, nudge: nudge, at: record.at, continuation: continuation))
        }
        return value as! T
    }

    func answer(kind: Kind, wire: String, since: Int64, put: DuoWirePutStatusesRequest?, nudge: DuoWireSendNudgeRequest?, outcome: ROutcome) throws -> Any {
        func perform() throws -> Any {
            switch kind {
            case .fetch: return try server.changes(wire, since: since)
            case .put:
                let answer = try server.put(wire, put!)
                if answer.rejected.contains(where: { $0.reason == .verConflict }) { conflictPuts.insert(answering) }
                return answer
            case .nudge: return try server.nudge(wire, nudge!)
            case .me: return server.me()
            }
        }
        // The server looks a nudge's id up before it judges anything: a repeat of a stored one is
        // answered 200 with the stored row, whatever limit it would otherwise meet.
        if kind == .nudge, let id = nudge?.id, server.duos[wire]?.nudges[id] != nil {
            switch outcome {
            case .error, .rateLimited: return try perform()
            default: break
            }
        }
        switch outcome {
        case .ok: return try perform()
        case .lost: _ = try? perform(); throw DuoTransportError.offline
        case .offline: throw DuoTransportError.offline
        case .maintenance(let s): throw DuoTransportError.maintenance(DuoErrorContext(httpStatus: 503, retryAfter: s))
        case .rateLimited(let s): throw DuoTransportError.rateLimited(DuoErrorContext(httpStatus: 429, retryAfter: s))
        case .cancelled: throw CancellationError()
        case .unreadable2xx: _ = try? perform(); throw DuoTransportError.unreadable(httpStatus: 200, requestID: nil)
        case .unauthenticated: throw DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 401))
        case .error(let e): throw e
        case .custom(let answer): return answer
        }
    }

    /// Answers the held call at `index` (in arrival order).
    func complete(_ index: Int, _ outcome: ROutcome) {
        let call = held.remove(at: index)
        answering = call.n
        do {
            call.continuation.resume(returning: try answer(kind: call.kind, wire: call.wire, since: call.since, put: call.put, nudge: call.nudge, outcome: outcome))
        } catch {
            call.continuation.resume(throwing: error)
        }
    }

    func completeFirst(_ kind: Kind, _ outcome: ROutcome = .ok) {
        guard let index = held.firstIndex(where: { $0.kind == kind }) else { return }
        complete(index, outcome)
    }

    func completeAll(_ outcome: ROutcome = .ok) { while !held.isEmpty { complete(0, outcome) } }
    var heldKinds: [Kind] { held.map(\.kind) }
    func count(_ kind: Kind) -> Int { log.filter { $0.kind == kind }.count }
    var puts: [Record] { log.filter { $0.kind == .put } }
}

@MainActor
private final class RTransport: DuoTransport {
    let sched: RSched
    init(_ sched: RSched) { self.sched = sched }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try await sched.call(.fetch, wire: duoID, since: since) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult {
        try await sched.call(.put, wire: duoID, since: request.since, put: request)
    }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try await sched.call(.nudge, wire: duoID, nudge: request) }
    func me() async throws -> DuoWireGetMeResponse { try await sched.call(.me, wire: "me") }
    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { throw DuoTransportError.offline }
    func attestChallenge() async throws -> DuoWireAttestChallenge { throw DuoTransportError.offline }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { throw DuoTransportError.offline }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { throw DuoTransportError.offline }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { throw DuoTransportError.offline }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { throw DuoTransportError.offline }
    func unregisterPush() async throws { throw DuoTransportError.offline }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { throw DuoTransportError.offline }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { throw DuoTransportError.offline }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { throw DuoTransportError.offline }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { throw DuoTransportError.offline }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { throw DuoTransportError.offline }
    func fetchDuo(id: String) async throws -> DuoWireHeader { throw DuoTransportError.offline }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { throw DuoTransportError.offline }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { throw DuoTransportError.offline }
}

/// An announcer that can refuse, whose `hasDeliveredRemote` answers from a set, and whose
/// `deliver` can be held at a door.
@MainActor
private final class RAnnouncer: DuoAnnouncing {
    private(set) var delivered: [String] = []
    private(set) var refused: [String] = []
    var refuseNext = 0
    var remote: Set<String> = []
    var deliverGate: RGate?
    func deliver(_ announcements: [DuoAnnouncement], now: Date) async -> [String] {
        if let deliverGate { await deliverGate.pass() } else { await Task.yield() }
        var out: [String] = []
        for announcement in announcements {
            if refuseNext > 0 { refuseNext -= 1; out.append(announcement.key); refused.append(announcement.key) } else { delivered.append(announcement.key) }
        }
        return out
    }
    func hasDeliveredRemote(forKey key: String) async -> Bool { await Task.yield(); return remote.contains(key) }
    func removeDelivered(for duoID: UUID) {}
    func removeAllDelivered() {}
}

@MainActor
private final class RQueue: DuoOpQueueing {
    var pending: [DuoQueuedOp] = []
    private(set) var drains = 0
    func enqueue(_ op: DuoQueuedOp) { pending.append(op) }
    func drain() async { drains += 1; await Task.yield() }
    func startMonitoring() {}
    func discardAll() { pending = [] }
}

/// An identity whose `prepare()` can be held at a door, and that counts its calls.
private final class RIdentity: DuoIdentityProviding, @unchecked Sendable {
    var credential: DuoCredential?
    var installDay: String
    var launch: DuoIdentityLaunch = .ready
    private(set) var prepares = 0
    @MainActor var prepareGate: RGate?
    init(credential: DuoCredential?, installDay: String) { self.credential = credential; self.installDay = installDay }
    func store(_ credential: DuoCredential) throws { self.credential = credential }
    func replaceSecret(_ secret: String, version: Int) throws {}
    func discard() { credential = nil }
    @MainActor func prepare() async -> DuoIdentityLaunch {
        prepares += 1
        if let prepareGate { await prepareGate.pass() }
        return launch
    }
    func continueAsRestored() async {}
}

/// Unique UUIDs without a shared counter (`TestRandom` wraps at 255).
private final class RRandom: DuoRandom, @unchecked Sendable {
    func bytes(_ count: Int) -> [UInt8] { (0..<count).map { _ in UInt8.random(in: 0...255) } }
    func uuid() -> UUID { UUID() }
}

@MainActor
private struct RH {
    static let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z
    static let today = "2026-09-21"
    let store: DuoStore
    let defaults: RMemoryDefaults
    let dependencies: DuoDependencies
    let engine: DuoSyncEngine
    let clock = RClock(RH.start)
    let server: RServer
    let sched: RSched
    let sleeper: RSleeper
    let identity: RIdentity
    let ops = RQueue()
    let push = FakePush()
    let announcer = RAnnouncer()
    var cache: DuoCache { store.cache }

    init(credential: DuoCredential? = DuoFixtures.credential(), defaults: RMemoryDefaults = RMemoryDefaults(), installDay: String = "2026-01-01") {
        self.defaults = defaults
        store = DuoStore(cache: DuoCache(defaults: defaults), usesServer: true, reloadWidget: {})
        server = RServer(clock: clock)
        sched = RSched(server: server)
        sleeper = RSleeper(clock: clock)
        identity = RIdentity(credential: credential, installDay: installDay)
        dependencies = DuoDependencies(host: store, cache: store.cache, secrets: DuoSecrets(store: DuoMemorySecretStore()), clock: clock,
                                       random: RRandom(), client: DuoClientInfo(marketingVersion: "2.0", build: "57"),
                                       attester: FakeDuoAttester(), deviceCheck: FakeDuoDeviceCheck())
        dependencies.identity = identity
        dependencies.transport = RTransport(sched)
        dependencies.ops = ops
        dependencies.push = push
        dependencies.announcer = announcer
        dependencies.activeSkin = { "classic" }
        let sleeper = sleeper
        dependencies.sleep = { seconds in try await sleeper.sleep(seconds) }
        engine = DuoSyncEngine(dependencies: dependencies)
        dependencies.sync = engine
        store.install(dependencies)
    }

    /// A second engine over the same saved state: a relaunch.
    func relaunched() -> DuoSyncEngine {
        let engine = DuoSyncEngine(dependencies: dependencies)
        dependencies.sync = engine
        return engine
    }

    func knowMember(nudgesPerDay: Int = 3) {
        store.memberInfo = DuoMemberInfo(memberID: "m", displayName: "Jo", skin: "classic", supportID: "ABCD1234EFGH", tier: .attested, termsVersion: 1,
                                         nudgesPerDay: nudgesPerDay, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: clock.now)
    }

    func addDuo(_ id: UUID, cursor: Int64 = 10, syncedOnce: Bool = true) {
        store.upsert(DuoFixtures.duo(id: id, cursor: cursor, syncedOnce: syncedOnce, now: clock.now))
        server.add(id, seq: cursor)
    }

    func log(_ totals: [String: Int], goal: Int = 2000) {
        let summary = DuoLogSummary(totalsByDay: totals, goalML: goal, earliestEntryDay: "2026-01-01")
        store.latest = summary
        engine.logChanged(summary)
    }

    /// Lets every task that can run, run.
    func spin(_ n: Int = 200) async { for _ in 0..<n { await Task.yield() } }
}

@MainActor
private final class RFlag { var value = false; var result: Bool? }

private let rDuoA = UUID(uuidString: "6d2a0000-0000-4000-8000-00000000000a")!
private let rDuoB = UUID(uuidString: "6d2a0000-0000-4000-8000-00000000000b")!
private let rDuoC = UUID(uuidString: "6d2a0000-0000-4000-8000-00000000000c")!
private extension UUID { var wire: String { uuidString.lowercased() } }

// MARK: - Probes and targeted cases

@MainActor
final class DuoSyncEngineRobustnessTests: XCTestCase {
    private let today = RH.today

    // MARK: C7, a background run is cancellable and bounded (probes P1, P1b, P10)

    func testACancelledBackgroundRunAnswersAtOnceAndSendsNothingMore() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.addDuo(rDuoB)
        h.engine.activate(logReader: FakeLogReader(DuoLogSummary(totalsByDay: [today: 1000], goalML: 2000, earliestEntryDay: "2026-01-01")))
        let done = RFlag()
        let run = Task { () -> Bool in
            let changed = await h.engine.backgroundRefresh()
            done.value = true
            return changed
        }
        await h.spin()
        XCTAssertEqual(h.sched.heldKinds, [.put], "the publish half is out")
        let sentBeforeCancel = h.sched.log.count
        // iOS's expiration handler cancels the task that called backgroundRefresh().
        run.cancel()
        await h.spin(50)
        XCTAssertTrue(done.value, "answered at once, with the network still holding the write")
        for _ in 0..<20 {
            h.sched.completeAll(.ok)
            await h.spin()
        }
        XCTAssertEqual(h.sched.log.count, sentBeforeCancel, "nothing more is sent once nobody waits for the run: \(h.sched.log)")
        _ = await run.value
        await h.engine.waitUntilIdle()
    }

    func testAHungReadDoesNotHoldACancelledBackgroundRun() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let done = RFlag()
        let run = Task { _ = await h.engine.backgroundRefresh(); done.value = true }
        await h.spin()
        XCTAssertEqual(h.sched.heldKinds, [.fetch])
        run.cancel()
        await h.spin(50)
        XCTAssertTrue(done.value, "a fetch the network never answers does not hold the background task")
        h.sched.completeAll(.ok)
        await run.value
        await h.engine.waitUntilIdle()
    }

    func testABackgroundRunNeverReportsAWipeAsNewData() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let flag = RFlag()
        let run = Task { flag.result = await h.engine.backgroundRefresh() }
        await h.spin()
        h.store.resetLocalState()
        h.sched.completeAll(.ok)
        await h.spin()
        await run.value
        XCTAssertEqual(flag.result, false)
    }

    func testABackgroundRunAnotherCallerStillWaitsOnIsNotStopped() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.server.write(rDuoA.wire, role: .partner, day: today, bucket: 50)
        let first = Task { await h.engine.backgroundRefresh() }
        await h.spin()
        let second = Task { await h.engine.backgroundRefresh() }
        await h.spin()
        first.cancel()
        await h.spin()
        h.sched.completeAll(.ok)
        let answer = await second.value
        _ = await first.value
        XCTAssertTrue(answer, "the run went on for the caller still waiting")
        XCTAssertEqual(h.store.duo(rDuoA)?.status(of: .partner, on: today)?.progressBucket, 50)
    }

    // MARK: C14, the retry budget (probes P2, P2b, P5, P5b, P6; mutants M29, M30)

    func testASuccessBetweenFailuresGivesTheReadsTheirRetriesBack() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sleeper.immediate = true
        h.sched.auto = .maintenance(45)
        await h.engine.refresh()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sleeper.asked, [45, 45, 45], "three in a row, then wait")
        h.sched.auto = .ok
        h.server.write(rDuoA.wire, role: .partner, day: today, bucket: 50)
        await h.engine.pushArrived(DuoPushPayload(duoID: rDuoA, seq: 999, kind: .joined))
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.store.duo(rDuoA)?.statuses.count, 1, "the read went through (at the end of the wait it was held to)")
        let afterSuccess = h.sleeper.asked.count
        h.sched.auto = .maintenance(45)
        await h.engine.pushArrived(DuoPushPayload(duoID: rDuoA, seq: 9999, kind: .joined))
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sleeper.asked.count - afterSuccess, 3, "a new run of failures, after a success, has its three retries")
    }

    func testASuccessBetweenFailuresGivesTheWritesTheirRetriesBack() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sleeper.immediate = true
        h.sched.auto = .rateLimited(60)
        h.log([today: 500])
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sleeper.asked.filter { $0 == 60 }.count, 3)
        h.sched.auto = .ok
        h.clock.advance(61)
        h.log([today: 1000])
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.server.putsApplied, 1, "a write went through")
        h.sched.auto = .rateLimited(60)
        h.clock.advance(31)
        h.log([today: 1500])
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sleeper.asked.filter { $0 == 60 }.count, 6, "the failure after a success has its retries")
    }

    func testACancelledReadNeitherSpendsNorReturnsTheBudget() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sleeper.immediate = true
        h.sched.script = [.maintenance(45), .maintenance(45), .cancelled]
        h.sched.auto = .maintenance(45)
        await h.engine.refresh()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sleeper.asked.count, 2, "two retries, then the cancelled one schedules nothing")
        await h.engine.pushArrived(DuoPushPayload(duoID: rDuoA, seq: 999, kind: .joined))
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sleeper.asked.count, 3, "the cancel did not give the run its budget back: three retries in a row in all")
    }

    func testAWipeEndsARetryThatIsWaitingAndGivesTheNextIdentityAFreshBudget() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .maintenance(172_800)
        await h.engine.refresh()
        await h.spin()
        XCTAssertEqual(h.sleeper.asked, [172_800])
        h.store.resetLocalState()
        h.identity.discard()
        // A fresh start: a new identity and a new duo, before the old retry wakes.
        h.identity.credential = DuoFixtures.credential()
        h.knowMember()
        h.addDuo(rDuoB)
        h.sched.auto = .ok
        await h.engine.refresh()
        await h.spin()
        XCTAssertEqual(h.sleeper.cancelledCount, 1, "the old identity's retry is cancelled by the first thing that runs after the wipe")
        let readsOfB = h.sched.log.filter { $0.kind == .fetch && $0.wire == rDuoB.wire }.count
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.log.filter { $0.kind == .fetch && $0.wire == rDuoB.wire }.count, readsOfB, "and never reads for the new one")
        // The new identity meets maintenance: its budget is whole, and the old wait does not hold it.
        h.sleeper.immediate = true
        h.sched.auto = .maintenance(45)
        await h.engine.pushArrived(DuoPushPayload(duoID: rDuoB, seq: 999, kind: .joined))
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sleeper.asked.filter { $0 == 45 }.count, 3)
    }

    func testARetryThatIsWokenNoLongerAfterAWipeDoesNothing() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .offline
        await h.engine.refresh()
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 1)
        h.store.resetLocalState()
        h.addDuo(rDuoB)
        h.sched.auto = .ok
        let before = h.sched.log.count
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.log.count, before, "it slept through the wipe: it belongs to the identity that is gone")
    }

    func testANewRetryReplacesTheOneWaitingAndARefreshCancelsIt() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .offline
        await h.engine.refresh()
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 1)
        await h.engine.pushArrived(DuoPushPayload(duoID: rDuoA, seq: 999, kind: .joined))
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 1, "the push's failure replaced the waiting retry, never two")
        XCTAssertEqual(h.sleeper.cancelledCount, 1)
        h.sched.auto = .ok
        await h.engine.refresh()
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 0, "a refresh that went through cancelled the retry it replaced")
        XCTAssertEqual(h.sleeper.cancelledCount, 2)
    }

    // MARK: C8, GET /me's answer after a 401 elsewhere (probe P3)

    func testAMemberRecordAnsweredAfterTheIdentityWasForgottenIsDropped() async {
        let h = RH()
        h.addDuo(rDuoA)
        h.server.devices = [DuoWireDevice(id: "old-device", platform: "ios", createdAt: RH.start, thisDevice: true, superseded: false)]
        var lister = h.server.header(RServer.Duo(id: rDuoC, role: .owner))
        lister.seq = 3
        h.server.extraHeaders = [lister]
        let refresh = Task { await h.engine.refresh() }
        await h.spin()
        XCTAssertEqual(h.sched.heldKinds, [.me])
        h.log([today: 1000])
        await h.spin()
        XCTAssertEqual(h.sched.heldKinds, [.me, .put])
        h.sched.completeFirst(.put, .unauthenticated)
        await h.spin()
        XCTAssertNil(h.identity.credential, "noteFailure(.reidentify) discarded the credential")
        h.sched.completeFirst(.me, .ok)
        await refresh.value
        await h.engine.waitUntilIdle()
        XCTAssertNil(h.store.memberInfo, "the forgotten member's record is not written back")
        XCTAssertNil(h.cache.loadSeenDeviceIDs(), "nor its device list")
        XCTAssertNil(h.store.duo(rDuoC), "nor a duo it listed")
    }

    func testAMemberRecordAnsweredForACredentialAReconnectReplacedIsDropped() async {
        let h = RH()
        h.addDuo(rDuoA)
        h.server.devices = [DuoWireDevice(id: "x", platform: "ios", createdAt: RH.start, thisDevice: true, superseded: false)]
        let refresh = Task { await h.engine.refresh() }
        await h.spin()
        h.identity.credential = DuoCredential(memberID: "another-member", deviceID: DuoFixtures.credential().deviceID, deviceSecret: "t", secretVersion: 1)
        h.sched.completeFirst(.me, .ok)
        await refresh.value
        XCTAssertNil(h.store.memberInfo)
    }

    // MARK: C9, an announcement found early in a pass is not lost with the pass (probe P4)

    func testANudgeFoundEarlyInAPassIsDeliveredBeforeTheNextRead() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.addDuo(rDuoB)
        let nudgeID = "nudge-00000000-0000-4000-8000-0000000000aa"
        h.server.partnerNudge(rDuoA.wire, id: nudgeID)
        let refresh = Task { await h.engine.refresh() }
        await h.spin()
        h.sched.completeFirst(.fetch, .ok)
        await h.spin()
        XCTAssertEqual(h.sched.heldKinds, [.fetch], "duo B's fetch is out (a slow network)")
        XCTAssertEqual(h.announcer.delivered, [nudgeID], "delivered right after its duo's feed, before the next request")
        refresh.cancel()
        h.sched.completeAll(.cancelled)
        await refresh.value
    }

    // MARK: C16, nudges (probes P7, P8)

    func testATapReturnsAfterItsOneAttemptAndTheRetriesRunOnTheirOwn() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let done = RFlag()
        let tap = Task { await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoA)); done.value = true }
        await h.spin()
        h.sched.completeFirst(.nudge, .offline)
        await h.spin()
        XCTAssertTrue(done.value, "the button is free after the first attempt")
        XCTAssertEqual(h.sleeper.asked, [30])
        h.sleeper.releaseAll(); await h.spin()
        h.sched.completeFirst(.nudge, .offline); await h.spin()
        h.sleeper.releaseAll(); await h.spin()
        h.sched.completeFirst(.nudge, .offline); await h.spin()
        h.sleeper.releaseAll(); await h.spin()
        h.sched.completeFirst(.nudge, .ok); await h.spin()
        XCTAssertEqual(h.sleeper.asked, [30, 60, 120])
        XCTAssertEqual(Set(h.sched.log.compactMap { $0.nudge?.id }).count, 1, "one id throughout")
        XCTAssertEqual(h.server.myNudges(rDuoA.wire).count, 1)
        await tap.value
        await h.engine.waitUntilIdle()
    }

    func testANudgeWaitingToRetryIsNotSentAfterAWipeEvenIfItsDuoComesBack() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let tap = Task { await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        h.sched.completeFirst(.nudge, .offline)
        await tap.value
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 1, "waiting 30 s to retry")
        h.store.resetLocalState()
        h.store.upsert(DuoFixtures.duo(id: rDuoA, now: h.clock.now)) // a reconnect seats the same duo again
        h.sleeper.releaseAll()
        await h.spin()
        XCTAssertEqual(h.sched.count(.nudge), 1, "the nudge from before the wipe is not sent again")
        await h.engine.waitUntilIdle()
    }

    func testANudgeKeptAcrossARelaunchIsSentAgainWithItsIdAtTheNextForeground() async {
        // C5: the request is in the in-flight journal, not only in memory.
        let h = RH()
        h.knowMember(nudgesPerDay: 1)
        h.addDuo(rDuoA)
        let tap = Task { await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        h.sched.completeFirst(.nudge, .offline)
        await tap.value
        let id = h.sched.log.compactMap { $0.nudge?.id }.first
        XCTAssertNotNil(id)
        // The app is killed in the 30 s wait. A new engine over the same saved state.
        let engine = h.relaunched()
        h.sched.auto = .ok
        await engine.refresh()
        await engine.waitUntilIdle()
        XCTAssertEqual(h.sched.log.compactMap { $0.nudge?.id }, [id, id], "the same request, again")
        XCTAssertEqual(h.server.myNudges(h.store.duo(rDuoA)!.wireID).map(\.id), [id!])
        XCTAssertTrue(h.cache.loadInflight(now: h.clock.now).entries.isEmpty, "the record goes with the answer")
        let copies = h.store.duo(rDuoA)?.allNudges.filter { $0.fromRole == .owner } ?? []
        XCTAssertEqual(copies.map(\.id), [id!], "one copy, confirmed")
    }

    func testANudgeIsNotSentToADuoWithALeaveWaitingAndItsCopyGoes() async {
        // C11: a pending leave or block drops the waiting nudge.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let tap = Task { await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        h.sched.completeFirst(.nudge, .cancelled)
        await tap.value
        h.store.update(rDuoA) { $0.pendingOp = .leave }
        h.sched.auto = .ok
        await h.engine.refresh()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.nudge), 1, "not sent again")
        XCTAssertTrue(h.cache.loadInflight(now: h.clock.now).entries.isEmpty)
    }

    func testAPushIsNotAForegroundAndDoesNotResendWaitingNudges() async {
        // Mutant M16: waiting nudges resent by every pass.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let tap = Task { await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        h.sched.completeFirst(.nudge, .cancelled)
        await tap.value
        h.sched.auto = .ok
        await h.engine.pushArrived(DuoPushPayload(duoID: rDuoA, seq: 999, kind: .joined))
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.nudge), 1)
        await h.engine.refresh()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.nudge), 2)
    }

    // MARK: C23, a copy whose journal entry is gone (seed 70007 of the re-verification fuzz)

    private func myCopies(_ h: RH, _ id: UUID) -> [DuoNudge] { h.store.duo(id)?.allNudges.filter { $0.fromRole == .owner } ?? [] }

    func testANudgeTheJournalDroppedLeavesTheCardAtTheNextForeground() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let tap = Task { await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        h.sched.completeFirst(.nudge, .offline)
        await tap.value
        for _ in 0..<3 {
            h.sleeper.releaseAll(); await h.spin()
            h.sched.completeFirst(.nudge, .offline); await h.spin()
        }
        XCTAssertEqual(h.sched.count(.nudge), 4, "the first attempt and three retries")
        XCTAssertEqual(myCopies(h, rDuoA).count, 1, "waiting for the next foreground")
        h.clock.advance(24 * 3600)
        h.sched.auto = .ok
        await h.engine.refresh()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.nudge), 4, "the journal dropped it: nothing sends it again")
        XCTAssertEqual(myCopies(h, rDuoA).count, 0, "and the card no longer says it was sent")
    }

    func testARetryWakingAfterTheJournalDroppedItsNudgeTakesTheCopyAway() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let tap = Task { await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        h.sched.completeFirst(.nudge, .offline)
        await tap.value
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 1, "the 30 s retry waits")
        h.clock.advance(24 * 3600)         // the phone slept through it
        h.sleeper.releaseAll()
        await h.spin()
        XCTAssertEqual(h.sched.count(.nudge), 1)
        XCTAssertEqual(myCopies(h, rDuoA).count, 0)
        h.sched.auto = .ok
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
    }

    func testANudgeTheServerHoldsStaysWhenItsJournalEntryWouldHaveGone() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let tap = Task { await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        h.sched.completeFirst(.nudge, .lost)          // it landed, and the answer was lost
        await tap.value
        await h.spin()
        XCTAssertEqual(h.server.myNudges(rDuoA.wire).count, 1)
        h.sched.auto = .ok
        await h.engine.refresh()                       // the feed brings the server's row
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 0, "the server holds it: no retry waits")
        h.clock.advance(24 * 3600)
        await h.engine.refresh()
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.nudge), 1, "never sent again")
        XCTAssertEqual(myCopies(h, rDuoA).map(\.id), h.server.myNudges(rDuoA.wire).map(\.id), "and it stays on the card")
    }

    // MARK: C10, a skin change is queued only where it could be written

    func testASkinChangeIsQueuedOnlyWithWritesAllowedAndALiveDuoWithNothingPending() async {
        func patchesQueued(_ setUp: (RH) -> Void) async -> Int {
            let h = RH()
            h.knowMember()
            h.dependencies.activeSkin = { "forest" }
            h.addDuo(rDuoA)
            setUp(h)
            h.log([RH.today: 500])
            await h.spin()
            let patches = h.ops.pending.filter { $0.kind == .updateMe }.count
            h.sched.auto = .ok
            h.sched.completeAll(.ok)
            h.sleeper.immediate = true
            h.sleeper.releaseAll()
            await h.engine.waitUntilIdle()
            return patches
        }
        let live = await patchesQueued { _ in }
        XCTAssertEqual(live, 1, "a live duo, writes allowed: the new skin is queued")
        let upgrade = await patchesQueued { $0.store.availability = .upgradeRequired }
        XCTAssertEqual(upgrade, 0, "nothing is queued while writes are not allowed")
        let ended = await patchesQueued { h in h.store.update(rDuoA) { $0.endedAt = h.clock.now; $0.endedBy = .owner } }
        XCTAssertEqual(ended, 0, "nor with only an ended duo")
        let leaving = await patchesQueued { $0.store.update(rDuoA) { $0.pendingOp = .leave } }
        XCTAssertEqual(leaving, 0, "nor with only a duo whose leave is waiting")
    }

    // MARK: C12, a full read keeps the copies of nudges still on their way (probe P13)

    func testAFullReadKeepsTheWaitingCopiesSoTheLimitHolds() async {
        let h = RH()
        h.knowMember(nudgesPerDay: 3)
        h.addDuo(rDuoA, cursor: 10, syncedOnce: false)
        for preset in [DuoNudgePreset.waterBreak, .cheers] {
            let tap = Task { await h.engine.sendNudge(preset, in: DuoFixtures.duo(id: rDuoA)) }
            await h.spin()
            h.sched.completeFirst(.nudge, .cancelled)
            await tap.value
        }
        XCTAssertEqual(h.store.duo(rDuoA)?.allNudges.count, 2)
        let refresh = Task { await h.engine.refresh() }
        await h.spin()
        h.sched.completeFirst(.fetch, .ok)
        await h.spin()
        XCTAssertEqual(h.store.duo(rDuoA)?.allNudges.count, 2, "the full feed did not take the copies")
        let third = Task { await h.engine.sendNudge(.soClose, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        let fourth = Task { await h.engine.sendNudge(.sipWithMe, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        h.sched.auto = .ok
        h.sched.completeAll(.ok)
        await h.spin()
        await refresh.value; await third.value; await fourth.value
        await h.engine.waitUntilIdle()
        XCTAssertEqual(Set(h.sched.log.compactMap { $0.nudge?.id }).count, 3, "three nudges for a limit of three")
    }

    // MARK: C13, an owed write that was overtaken (probes P11, P15)

    func testAnOwedWriteThatWasOvertakenNeverWritesInsideTheThirtySeconds() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .ok
        h.log([today: 250])
        await h.spin()
        h.clock.advance(5)
        h.log([today: 500])
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 1, "the owed write waits")
        // The phone was suspended: the wall clock moved on, the owed write's sleep did not.
        h.clock.advance(60)
        h.log([today: 750])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 2)
        XCTAssertEqual(h.sleeper.count, 0, "the overtaken owed write was cancelled")
        h.clock.advance(1)
        h.log([today: 1000])
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 1, "one owed write, never two")
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
        let times = h.sched.puts.map { $0.at.timeIntervalSince(RH.start) }
        for (earlier, later) in zip(times, times.dropFirst()) { XCTAssertGreaterThanOrEqual(later - earlier, 30, "\(times)") }
    }

    func testWaitingTasksStayBoundedThroughHundredsOfFailingTriggers() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.addDuo(rDuoB)
        h.sched.auto = .maintenance(60)
        for i in 0..<120 {
            switch i % 4 {
            case 0: h.log([today: 100 + i])
            case 1: await h.engine.pushArrived(DuoPushPayload(duoID: rDuoA, seq: 10_000 + Int64(i), kind: .joined))
            case 2: await h.engine.refresh()
            default: await h.engine.flush()
            }
            await h.spin(20)
            h.clock.advance(3)
        }
        XCTAssertLessThanOrEqual(h.sleeper.mostWaiting, 3, "one read, one write and one owed write at most")
        XCTAssertLessThan(h.sched.log.count, 20, "the server's wait holds every automatic trigger (C15): \(h.sched.log.count) requests")
        h.sleeper.immediate = true
        h.sched.auto = .ok
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
    }

    // MARK: C15, a wait the server asked for holds every automatic trigger (probe P12)

    func testARateLimitHoldsEveryDrinkUntilItIsOverAndTheOwedWriteFiresThen() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .rateLimited(600)
        h.log([today: 250])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1)
        XCTAssertEqual(h.sleeper.asked, [600])
        for i in 1...5 {
            h.clock.advance(31)
            h.log([today: 250 + 100 * i])
            await h.engine.refresh()
            await h.engine.pushArrived(DuoPushPayload(duoID: rDuoA, seq: 999 + Int64(i), kind: .joined))
            await h.spin()
        }
        XCTAssertEqual(h.sched.puts.count, 1, "nothing written inside the ten minutes the server asked for")
        h.sched.auto = .ok
        h.sleeper.releaseAll()
        await h.spin()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.puts.count, 2, "the owed write at the end of the wait, with the latest state")
        XCTAssertEqual(h.sched.puts.last?.put?.statuses.first?.progressBucket, 25)
    }

    func testAReadHeldByTheServersWaitIsReadAtItsEnd() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.script = [.maintenance(300)]
        h.sched.auto = .ok
        await h.engine.refresh()
        await h.spin()
        XCTAssertEqual(h.sched.count(.fetch), 1)
        h.clock.advance(60)
        await h.engine.refresh()
        await h.engine.pushArrived(DuoPushPayload(duoID: rDuoA, seq: 999, kind: .joined))
        _ = await h.engine.backgroundRefresh()
        XCTAssertEqual(h.sched.count(.fetch), 1, "a foreground, a push and a background run all wait")
        XCTAssertEqual(h.sleeper.count, 1)
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.fetch), 2)
    }

    func testNoConnectionIsNotAWaitTheServerAskedFor() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.script = [.offline]
        h.sched.auto = .ok
        await h.engine.refresh()
        await h.spin()
        await h.engine.refresh()
        XCTAssertEqual(h.sched.count(.fetch), 2, "the next foreground reads at once")
        await h.engine.waitUntilIdle()
    }

    // MARK: P14, two conflicts in a row make exactly two requests

    func testTwoConflictsInARowMakeExactlyTwoRequests() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        // Another device of mine keeps moving today on, below what this log wants.
        h.server.write(rDuoA.wire, role: .owner, day: today, bucket: 25)
        let server = h.server
        h.sched.onSend = { record in if record.kind == .put { server.write(rDuoA.wire, role: .owner, day: RH.today, bucket: 25) } }
        h.sched.auto = .ok
        h.log([today: 1000])
        await h.spin()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.puts.count, 2, "one write and one re-based retry, never a third")
    }

    // MARK: Mutants M01, M22, M23, M25, M26, M34/M6/M7, M35, M37, M12

    func testAWipeWhileAReadIsOutLeavesTheAvailabilityAsItWas() async {
        // M01: no wipe check right after a fetch's answer (noteSuccess would make a paused service available).
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let refresh = Task { await h.engine.refresh() }
        await h.spin()
        h.store.availability = .maintenance
        h.store.resetLocalState()
        XCTAssertEqual(h.store.availability, .maintenance)
        h.sched.completeFirst(.fetch, .ok)
        await refresh.value
        XCTAssertEqual(h.store.availability, .maintenance, "a late answer after a wipe changes nothing")
    }

    func testAWipeWhileAWriteIsOutLeavesNoTraceOfIt() async {
        // M22: no wipe check right after a write's answer (Diagnostics would record the write).
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.log([today: 1000])
        await h.spin()
        XCTAssertEqual(h.sched.heldKinds, [.put])
        h.store.resetLocalState()
        h.sched.completeFirst(.put, .ok)
        await h.engine.waitUntilIdle()
        XCTAssertTrue(h.store.diagnostics.duos.isEmpty)
        XCTAssertTrue(h.store.duos.isEmpty)
        XCTAssertEqual(h.defaults.keys.subtracting(DuoCache.keptKeys), [], "the wipe's on-disk state stays the wipe's")
    }

    func testAWriteAnsweredDuoEndedEndsTheCard() async {
        // M23.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .error(.duoEnded(DuoErrorContext(httpStatus: 409)))
        h.log([today: 1000])
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.store.duo(rDuoA)?.hasEnded, true)
        XCTAssertEqual(h.store.duo(rDuoA)?.endedBy, .unknown)
    }

    func testAWipeWhileTheNotifierWorksWritesNothingBack() async {
        // M25: deliver ignoring a wipe during the announcer call would write the ledger after it.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.server.partnerNudge(rDuoA.wire, id: "nudge-00000000-0000-4000-8000-0000000000aa")
        let gate = RGate()
        h.announcer.deliverGate = gate
        h.announcer.refuseNext = 1
        h.sched.auto = .ok
        let refresh = Task { await h.engine.refresh() }
        await h.spin()
        XCTAssertEqual(gate.arrivals, 1)
        h.store.resetLocalState()
        gate.open()
        await refresh.value
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.defaults.keys.subtracting(DuoCache.keptKeys), [], "no ledger written after the wipe")
    }

    func testAWipeForgetsTheAnnouncementsHeldInMemory() async {
        // M26: a refused announcement names a partner; after a wipe it is never offered again.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let nudgeID = "nudge-00000000-0000-4000-8000-0000000000aa"
        h.server.partnerNudge(rDuoA.wire, id: nudgeID)
        h.announcer.refuseNext = 1
        h.sched.auto = .ok
        await h.engine.refresh()
        XCTAssertEqual(h.announcer.refused, [nudgeID])
        h.store.resetLocalState()
        // The same duo seated again with the nudge in its cache, as a reconnect would.
        h.knowMember()
        var duo = DuoFixtures.duo(id: rDuoA, cursor: 99, now: h.clock.now)
        duo.nudges = [DuoNudge(id: nudgeID, fromRole: .partner, presetID: "cheers", createdAt: h.clock.now)]
        h.store.upsert(duo)
        await h.engine.refresh()
        await h.engine.waitUntilIdle()
        XCTAssertTrue(h.announcer.delivered.isEmpty, "\(h.announcer.delivered)")
    }

    func testTheVerdictsOfAnAnswerThatWasDroppedAreNotApplied() async {
        // M34 and the sync review's M6/M7: a write's answer that `answerFits` drops (a newer read
        // got there first) takes its verdicts with it: a conflict's stale `current` would take the
        // ver back, and a refused downgrade would be held for hours though nothing was judged.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let yesterday = "2026-09-20"
        h.server.write(rDuoA.wire, role: .owner, day: today, bucket: 25)  // seq 11, ver 1
        let first = Task { await h.engine.refresh() }
        await h.spin()
        h.sched.completeAll(.ok)
        await first.value
        XCTAssertEqual(h.store.duo(rDuoA)?.vers["owner-\(today)"], 1)
        h.log([today: 1000, yesterday: 1000])
        await h.spin()
        XCTAssertEqual(h.sched.heldKinds, [.put])
        // My other device writes today (ver 2, 75) and this phone reads it (cursor 12) before the
        // write's answer comes back, computed at seq 11.
        h.server.write(rDuoA.wire, role: .owner, day: today, bucket: 75)
        let second = Task { await h.engine.refresh() }
        await h.spin()
        h.sched.completeFirst(.fetch, .ok)
        await second.value
        XCTAssertEqual(h.store.duo(rDuoA)?.vers["owner-\(today)"], 2)
        let stale = DuoWireChangesWithResult(
            changes: DuoWireChanges(duo: h.server.header(h.server.duos[rDuoA.wire]!), full: false, statuses: [], nudges: [], handled: [], cursor: 11),
            accepted: [], unchanged: [],
            rejected: [DuoWireRejected(day: today, reason: .verConflict,
                                       current: DuoWireStatusRow(role: .owner, day: today, goalMet: false, progressBucket: 25, updatedAt: h.clock.now, ver: 1)),
                       DuoWireRejected(day: yesterday, reason: .downgradeRefused,
                                       current: DuoWireStatusRow(role: .owner, day: yesterday, goalMet: true, progressBucket: 100, updatedAt: h.clock.now, ver: 1))])
        h.sched.completeFirst(.put, .custom(stale))
        await h.spin()
        XCTAssertEqual(h.store.duo(rDuoA)?.vers["owner-\(today)"], 2, "the dropped answer's `current` did not take the ver back")
        XCTAssertEqual(h.store.duo(rDuoA)?.status(of: .owner, on: today)?.progressBucket, 75)
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        h.sched.auto = .ok
        h.clock.advance(31)
        await h.engine.flush()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.puts.last?.put?.statuses.map(\.day).contains(yesterday), true,
                       "a refusal nobody judged (its answer was dropped) holds nothing back")
    }

    func testAWriteThatWasAcceptedWithNoConflictIsNotSentTwiceInItsSlot() async {
        // M35: a second write in the slot only after a re-based conflict. An answer that accepted
        // the row but did not carry it leaves it unknown, owed again, and still no second request
        // in the slot: the next trigger re-diffs.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let accepted = DuoWireChangesWithResult(
            changes: DuoWireChanges(duo: h.server.header(h.server.duos[rDuoA.wire]!), full: false, statuses: [], nudges: [], handled: [], cursor: 10),
            accepted: [today], unchanged: [], rejected: [])
        h.sched.script = [.custom(accepted)]
        h.log([today: 1000])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1, "one request in the slot")
        XCTAssertEqual(h.sleeper.count, 0, "and nothing scheduled")
        // Whatever a wrong engine still holds is answered, so it fails here instead of hanging.
        h.sched.auto = .ok
        h.sched.completeAll(.ok)
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
    }

    func testAWipeWhileTheIdentityIsAskedEndsThePass() async {
        // M37: the epoch must be read before `prepare()`, not after.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let gate = RGate()
        h.identity.prepareGate = gate
        let refresh = Task { await h.engine.refresh() }
        await h.spin()
        XCTAssertEqual(gate.arrivals, 1)
        h.store.resetLocalState()
        h.addDuo(rDuoB)
        gate.open()
        await h.spin()
        XCTAssertTrue(h.sched.log.isEmpty, "a pass begun before the wipe sends nothing after it: \(h.sched.log)")
        // Whatever a wrong engine sent is answered, so it fails here instead of hanging.
        h.sched.auto = .ok
        h.sched.completeAll(.ok)
        await refresh.value
    }

    func testAWipeWhileAWritePassAsksTheIdentityEndsThatPass() async {
        // M37 for the write pass: its epoch is read before `prepare()` too.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let gate = RGate()
        h.identity.prepareGate = gate
        h.log([today: 500])
        await h.spin()
        XCTAssertEqual(gate.arrivals, 1, "the write pass waits on the identity")
        h.store.resetLocalState()
        h.addDuo(rDuoB)
        h.store.latest = DuoLogSummary(totalsByDay: [today: 900], goalML: 2000, earliestEntryDay: "2026-01-01")
        gate.open()
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 0, "a write pass begun before the wipe sends nothing after it")
        h.sched.auto = .ok
        h.sched.completeAll(.ok)
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
    }

    func testADrinkDuringAWritePassLongerThanThirtySecondsIsStillSent() async {
        // M12: the stale flag's re-request must not be dropped.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.log([today: 500])
        await h.spin()
        XCTAssertEqual(h.sched.heldKinds, [.put])
        h.clock.advance(40)
        h.log([today: 1500])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1, "the pass is still out")
        h.sched.auto = .ok
        h.sched.completeAll(.ok)
        await h.spin()
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.puts.last?.put?.statuses.first?.progressBucket, 75, "the drink reached the server")
    }

    func testTheThirtySecondsCountFromWhenAWriteWentOutNotWhenItWasLetThrough() async {
        // Found by the 500-run stress (seeds 84, 471, 40140): a pass let through at 0 s that only
        // sent at 33 s, after the identity was asked, was followed by another let through at 33 s.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let gate = RGate()
        h.identity.prepareGate = gate
        h.log([today: 500])
        await h.spin()
        XCTAssertEqual(gate.arrivals, 1, "the pass waits on the identity")
        h.clock.advance(33)
        gate.open()
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1)
        h.sched.completeAll(.ok)
        await h.spin()
        h.log([today: 1000])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1, "a drink in the same second waits thirty seconds from the write, not from the yes")
        h.sched.auto = .ok
        h.sched.completeAll(.ok)
        await h.spin()
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.puts.count, 2, "and is sent then")
        if h.sched.puts.count == 2 { XCTAssertGreaterThanOrEqual(h.sched.puts[1].at.timeIntervalSince(h.sched.puts[0].at), 30) }
    }

    func testAWipeKeepsTheThirtySecondsSinceTheLastWrite() async {
        // Found by the 500-run wipe stress (seeds 20047, 20175, 20234): a fresh coalescer after a
        // wipe let a write through in the same second as the two before it.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .ok
        h.log([today: 500])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1)
        h.store.resetLocalState()
        h.identity.discard()
        h.identity.credential = DuoFixtures.credential()
        h.knowMember()
        h.addDuo(rDuoA)
        h.log([today: 1000])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1, "the next write waits out the thirty seconds")
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.puts.count, 2, "and is sent then")
        if h.sched.puts.count == 2 { XCTAssertGreaterThanOrEqual(h.sched.puts[1].at.timeIntervalSince(h.sched.puts[0].at), 30) }
    }

    // MARK: C21, a queued leave or block holds every write

    func testAQueuedLeaveHoldsEveryWriteForEveryDuoWhileReadsGoOn() async throws {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.addDuo(rDuoB)
        h.store.update(rDuoA) { $0.endedAt = h.clock.now; $0.endedBy = .owner; $0.pendingOp = .leave }
        h.ops.enqueue(try DuoQueuedOp.leave(duoID: rDuoA, key: "k", now: h.clock.now))
        h.sched.auto = .ok
        h.log([today: 1000])
        await h.engine.flush()
        await h.engine.refresh()
        await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoB))
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 0, "nothing waits to write while the leave is queued")
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.put), 0, "no PUT for the duo being left, nor for its possible sibling")
        XCTAssertEqual(h.sched.count(.nudge), 0)
        XCTAssertGreaterThan(h.sched.count(.fetch), 0, "reads go on")
        XCTAssertEqual(h.store.duo(rDuoB)?.allNudges.count, 1, "the nudge waits, kept")
        // The leave goes out: the next foreground writes again and sends the waiting nudge.
        h.ops.pending = []
        await h.engine.refresh()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.put), 1)
        XCTAssertEqual(h.sched.puts.first?.wire, rDuoB.wire)
        XCTAssertEqual(h.sched.count(.nudge), 1)
    }

    func testALeaveQueuedWhileAWritePassRunsStopsItBeforeTheNextDuo() async throws {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.addDuo(rDuoB)
        h.log([today: 1000])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1, "the pass's first write is out")
        let first = try XCTUnwrap(h.sched.puts.first?.wire)
        let left = first == rDuoA.wire ? rDuoA : rDuoB
        h.store.update(left) { $0.endedAt = h.clock.now; $0.endedBy = .owner; $0.pendingOp = .leave }
        h.ops.enqueue(try DuoQueuedOp.leave(duoID: left, key: "k", now: h.clock.now))
        h.sched.completeAll(.ok)
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1, "the other duo is not written once a leave waits")
        h.sched.auto = .ok
        h.sched.completeAll(.ok)
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
    }

    // MARK: C24, a reader whose store is not the person's log

    func testNothingIsPublishedWhileTheReaderSaysItsStoreIsNotThePersonsLog() async {
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .ok
        let reader = RVettingReader(DuoLogSummary(totalsByDay: [today: 2000], goalML: 2000, earliestEntryDay: "2026-01-01"))
        reader.readsThePersonsLog = false
        h.engine.activate(logReader: reader)
        h.log([today: 1500])                    // the app's own summary, built from that same store
        await h.engine.refresh()
        await h.engine.flush()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.put), 0, "neither the reader's log nor the app's own is published")
        XCTAssertGreaterThan(h.sched.count(.fetch), 0, "reads go on")
        reader.readsThePersonsLog = true
        h.clock.advance(60)
        await h.engine.refresh()
        await h.engine.waitUntilIdle()
        XCTAssertEqual(h.sched.count(.put), 1, "the person's own log is published again")
    }

    // MARK: C25, the re-verification's killers for its surviving mutants

    func testACancelledBackgroundRunReadsNoFurtherDuo() async {
        // E07: the stop flag holds the reads too, not only the writes.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.addDuo(rDuoB)
        let run = Task { _ = await h.engine.backgroundRefresh() }
        await h.spin()
        XCTAssertEqual(h.sched.heldKinds, [.fetch], "the first read is out")
        run.cancel()
        await h.spin(50)
        h.sched.completeAll(.ok)
        await h.spin()
        h.sched.completeAll(.ok)
        await h.spin()
        XCTAssertEqual(h.sched.count(.fetch), 1, "nothing more is read once nobody waits for the run: \(h.sched.log)")
        await run.value
        await h.engine.waitUntilIdle()
    }

    func testAnOvertakenOwedWriteWhoseSleepIgnoredTheCancelDoesNotWrite() async {
        // E16: an owed write whose sleep finished just as a later write overtook it (the wake was
        // already on its way when the cancel came) must not write inside the thirty seconds.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .ok
        let gate = RGate()
        let first = RFlag()
        let sleeper = h.sleeper
        h.dependencies.sleep = { seconds in
            if await MainActor.run(body: { let was = first.value; first.value = true; return !was }) { await gate.pass() } else { try await sleeper.sleep(seconds) }
        }
        h.log([today: 600])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1)
        h.clock.advance(5)
        h.log([today: 1100])            // owed: waits at the gate, which ignores cancellation
        await h.spin()
        h.clock.advance(26)
        h.log([today: 1600])            // 31 s after the first: written now, overtaking the owed one
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 2)
        h.clock.advance(4)
        h.log([today: 2100])            // owed again, on the ordinary sleeper
        await h.spin()
        gate.open()                      // the overtaken owed write wakes
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 2, "an overtaken owed write wrote 4 s after the last write: \(h.sched.puts)")
        h.sleeper.releaseAll()
        await h.spin()
        await h.engine.waitUntilIdle()
    }

    func testAWipeEndsTheNudgeRetriesWaiting() async {
        // E35: a wipe takes the nudge retries that are waiting with it, not only their effect.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        let tap = Task { await h.engine.sendNudge(.waterBreak, in: DuoFixtures.duo(id: rDuoA)) }
        await h.spin()
        h.sched.completeFirst(.nudge, .offline)
        await tap.value
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 1, "waiting 30 s to retry")
        h.store.resetLocalState()
        h.engine.logChanged(DuoLogSummary(totalsByDay: [:], goalML: 2000, earliestEntryDay: nil))   // the next way into the engine
        await h.spin()
        XCTAssertEqual(h.sleeper.count, 0, "the retry waiting for the forgotten identity is cancelled")
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
    }

    func testAServerWaitIsOverWhenTheClockMovedBackByDays() async {
        // E37: a wait the server asked for, set before the clock was moved back by days, is over.
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .rateLimited(60)
        h.log([today: 600])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 1)
        h.sched.auto = .ok
        h.clock.force(h.clock.now.addingTimeInterval(-3 * 86_400))
        h.log([today: 1100])
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 2, "a hold three days long is a clock that moved back: written now")
        // A wrong engine is still waiting out the three days: let it, so it fails here, not hangs.
        h.sleeper.immediate = true
        h.sleeper.releaseAll()
        await h.engine.waitUntilIdle()
    }

    func testAFlushReadsTheLogAgain() async {
        // E42: C4 says a flush reads the log again too (a drink deleted on History, no hook call).
        let h = RH()
        h.knowMember()
        h.addDuo(rDuoA)
        h.sched.auto = .ok
        let reader = FakeLogReader(DuoLogSummary(totalsByDay: [today: 2000], goalML: 2000, earliestEntryDay: "2026-01-01"))
        h.engine.activate(logReader: reader)
        h.log([today: 2000])
        await h.spin()
        XCTAssertEqual(h.sched.puts.last?.put?.statuses.first?.progressBucket, 100)
        h.clock.advance(60)
        reader.summary = DuoLogSummary(totalsByDay: [:], goalML: 2000, earliestEntryDay: "2026-01-01")
        await h.engine.flush()
        await h.spin()
        XCTAssertEqual(h.sched.puts.count, 2, "the flush read the log again and wrote the deleted drink")
        XCTAssertEqual(h.sched.puts.last?.put?.statuses.first?.progressBucket, 0)
        await h.engine.waitUntilIdle()
    }

    func testHostileCursorsFromABrokenServerHealAtTheNextSaneAnswer() async {
        // Probe RV3: a negative, a zero and a huge cursor, then a server that answers sanely again.
        for bad: Int64 in [-5, 0, Int64.max] {
            let h = RH()
            h.knowMember()
            h.addDuo(rDuoA, cursor: 10)
            h.server.write(rDuoA.wire, role: .partner, day: today, bucket: 50)
            h.sched.auto = .ok
            await h.engine.refresh()
            let good = h.server.duos[rDuoA.wire]!.seq
            h.server.duos[rDuoA.wire]!.seq = bad == Int64.max ? Int64.max - 1 : bad
            if bad == Int64.max { h.server.write(rDuoA.wire, role: .partner, day: today, bucket: 75) }
            h.clock.advance(3600)
            await h.engine.refresh()
            h.server.duos[rDuoA.wire]!.seq = good + 5
            h.server.write(rDuoA.wire, role: .partner, day: today, bucket: 100)
            h.clock.advance(3600)
            await h.engine.refresh()
            await h.engine.waitUntilIdle()
            let duo = h.store.duo(rDuoA)!
            XCTAssertEqual(duo.cursor, h.server.duos[rDuoA.wire]!.seq, "cursor \(bad): the phone's cursor is the server's again")
            XCTAssertEqual(duo.status(of: .partner, on: today)?.progressBucket, 100, "cursor \(bad): the partner's newest row is read")
        }
    }
}

/// A log reader that can say its store is not the person's log (C24).
@MainActor
private final class RVettingReader: DuoLogReading, DuoLogSourceVetting {
    var readsThePersonsLog = true
    var summary: DuoLogSummary
    init(_ summary: DuoLogSummary) { self.summary = summary }
    func read(now: Date) -> DuoLogSummary { readsThePersonsLog ? summary : .empty }
}


// MARK: - The Worker model (the sync review's)

@MainActor
private final class WSleeper {
    final class Pending {
        let id: Int
        let wakeAt: Date
        var continuation: CheckedContinuation<Void, Error>?
        init(id: Int, wakeAt: Date) { self.id = id; self.wakeAt = wakeAt }
    }
    var pending: [Pending] = []
    var counter = 0
    var delays: [TimeInterval] = []
    let clock: RClock
    init(clock: RClock) { self.clock = clock }

    func sleep(_ seconds: TimeInterval) async throws {
        delays.append(seconds)
        counter += 1
        let entry = Pending(id: counter, wakeAt: clock.now.addingTimeInterval(seconds))
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()); return }
                entry.continuation = continuation
                pending.append(entry)
            }
        } onCancel: {
            Task { @MainActor in self.cancel(entry.id) }
        }
    }

    func cancel(_ id: Int) {
        guard let index = pending.firstIndex(where: { $0.id == id }) else { return }
        pending.remove(at: index).continuation?.resume(throwing: CancellationError())
    }

    /// Wakes one sleeper, moving the clock to its wake time if that is later.
    func wake(index: Int) {
        let entry = pending.remove(at: index)
        clock.reach(entry.wakeAt)
        entry.continuation?.resume()
    }
}

/// The Worker's per-duo state and the three routes the engine uses, as written from
/// src/routes/statuses.ts, src/duo/statuses.ts and src/duo/changes.ts at contract-v1.
@MainActor
private final class WServer {
    struct Row: Equatable { var goalMet: Bool; var bucket: Int; var ver: Int64; var updatedAt: Date; var writer: String; var seq: Int64 }
    struct Nudge { var id: String; var fromRole: DuoRole; var preset: String; var createdAt: Date; var seq: Int64 }

    let duoID: UUID
    let clock: RClock
    var seq: Int64 = 1
    var oldestSeq: Int64 = 0
    var rows: [String: Row] = [:]
    var deviceCreatedAt: [String: Date] = [:]
    var nudges: [Nudge] = []
    let myDevice = "dev-me", otherDevice = "dev-other", partnerDevice = "dev-partner"
    var puts = 0, downgradeRefused = 0, acceptedRows = 0
    var violations: [String] = []
    /// After a restore that left the phone's cursor (or an answer still on its way) ahead of `seq`:
    /// that cursor, until the phone takes a restored server's lower cursor (its cursor goes down,
    /// which only D72's adoption does: it saw the rollback) or `seq` climbs back to it first (it
    /// could not: an ordinary delta then skips what was written in between, which no client rule
    /// can notice without a server epoch, and the run is marked `unobservableRestore`).
    var restoreWatch: Int64?
    private(set) var unobservableRestore = false
    var phoneCursor: () -> Int64 = { 0 }
    private var lastPhoneCursor: Int64 = 0
    /// How many restores there have been, and which of them the last answer delivered to the
    /// phone was worked out after. A restore to a snapshot from before an earlier restore leaves an
    /// answer from in between describing a timeline that no longer exists, so the phone taking its
    /// lower cursor saw the first rollback, not the second.
    private(set) var generation = 0
    var deliveredGeneration = 0

    /// A restore the phone has no way to see from the start: it changed rows without taking `seq`
    /// below where the phone's cursor can reach, so every delta the phone asks for is ordinary.
    func markUnobservable() { unobservableRestore = true }

    func checkWatch() {
        let cursor = phoneCursor()
        defer { lastPhoneCursor = cursor }
        if cursor < lastPhoneCursor, restoreWatch != nil || deliveredGeneration != generation {
            // The phone took a restored server's lower cursor. From the timeline as it is now, it saw
            // the rollback. From one a later restore abandoned, it is only as safe as the next answer:
            // seq still below that cursor makes it a full one, and seq at or past it never will.
            if deliveredGeneration == generation {
                restoreWatch = nil
            } else if seq < cursor {
                restoreWatch = cursor
            } else {
                unobservableRestore = true
                restoreWatch = nil
            }
            return
        }
        guard let watch = restoreWatch else { return }
        if seq >= watch { unobservableRestore = true; restoreWatch = nil }
    }

    private func bump() {
        checkWatch()
        seq += 1
        checkWatch()
    }
    /// The server's clock is the phone's plus this (a phone whose clock is wrong).
    var nowOffset: TimeInterval = 0
    var now: Date { clock.now.addingTimeInterval(nowOffset) }

    init(duoID: UUID, clock: RClock) { self.duoID = duoID; self.clock = clock }

    static let utc: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(secondsFromGMT: 0)!; return c }()
    func dayAt(offsetHours: Int) -> String {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(secondsFromGMT: offsetHours * 3600)!
        return DayKey.key(for: now, calendar: c)
    }
    var dMin: String { Self.dayMinus(dayAt(offsetHours: -12), 8) }
    static func dayMinus(_ day: String, _ n: Int) -> String {
        DayKey.key(for: utc.date(byAdding: .day, value: -n, to: DayKey.date(from: day, calendar: utc)!)!, calendar: utc)
    }

    func header(role: DuoRole) -> DuoWireHeader {
        DuoWireHeader(id: duoID.uuidString.lowercased(), myRole: role, state: .active, createdAt: Date(timeIntervalSince1970: 1_789_000_000),
                      joinedAt: Date(timeIntervalSince1970: 1_789_100_000), ownerDisplayName: "Jo", ownerSkin: "classic", partnerDisplayName: "Sam",
                      partnerSkin: "forest", partnerIsDemo: false, invite: DuoWireHeaderInvite(hasOpenInvite: false, expiresAt: nil), seq: seq)
    }

    func wireRow(_ key: String, _ row: Row) -> DuoWireStatusRow {
        let parsed = DuoRecordName.parseDayStatus(key)!
        return DuoWireStatusRow(role: parsed.role, day: parsed.day, goalMet: row.goalMet, progressBucket: row.bucket, updatedAt: row.updatedAt, ver: row.ver)
    }

    func feed(since: Int64, role: DuoRole) -> DuoWireChanges {
        let full = since < oldestSeq || since > seq
        let statuses = rows.filter { full || $0.value.seq > since }.sorted { $0.key < $1.key }.map { wireRow($0.key, $0.value) }
        let ns = nudges.filter { full || $0.seq > since }.map { DuoWireNudge(id: $0.id, fromRole: $0.fromRole, presetId: $0.preset, createdAt: $0.createdAt) }
        return DuoWireChanges(duo: header(role: role), full: full, statuses: statuses, nudges: ns, handled: [], cursor: seq)
    }

    private func store(_ key: String, goalMet: Bool, bucket: Int, writer: String) {
        rows[key] = Row(goalMet: goalMet, bucket: bucket, ver: (rows[key]?.ver ?? 0) + 1, updatedAt: now, writer: writer, seq: seq)
    }

    /// Another writer: the partner, or this member's other device, through the same CAS.
    func otherWrite(role: DuoRole, day: String, bucket: Int, device: String) {
        let key = DuoRecordName.dayStatus(role: role, day: day)
        if let row = rows[key], row.bucket == bucket { return }
        bump()
        store(key, goalMet: bucket == 100, bucket: bucket, writer: device)
    }

    func partnerNudge(id: String) {
        bump()
        nudges.append(Nudge(id: id, fromRole: .partner, preset: "waterBreak", createdAt: now, seq: seq))
    }

    func put(_ request: DuoWirePutStatusesRequest, role: DuoRole, coverageAtSend: String, youngAtSend: Bool) throws -> DuoWireChangesWithResult {
        puts += 1
        guard request.myToday >= dayAt(offsetHours: -12), request.myToday <= dayAt(offsetHours: 14) else {
            throw DuoTransportError.dayOutOfRange(DuoErrorContext(httpStatus: 422, details: DuoWireErrorDetails(field: "my_today")))
        }
        var rejected: [DuoWireRejected] = [], accepted: [DuoWireStatusIn] = [], unchanged: [String] = []
        let yesterday = Self.dayMinus(request.myToday, 1)
        let fresh = (deviceCreatedAt[myDevice] ?? .distantPast) > now.addingTimeInterval(-48 * 3600) || !rows.values.contains { $0.writer == myDevice }
        for row in request.statuses {
            if row.day > request.myToday { rejected.append(DuoWireRejected(day: row.day, reason: .dayAfterToday)); continue }
            if row.day < dMin { rejected.append(DuoWireRejected(day: row.day, reason: .dayOutOfRange)); continue }
            if row.goalMet != (row.progressBucket == 100) { rejected.append(DuoWireRejected(day: row.day, reason: .statusInconsistent)); continue }
            let key = DuoRecordName.dayStatus(role: role, day: row.day)
            let current = rows[key]
            if let current, current.goalMet == row.goalMet, current.bucket == row.progressBucket {
                unchanged.append(row.day)
            } else if row.baseVer != (current?.ver ?? 0) {
                rejected.append(DuoWireRejected(day: row.day, reason: .verConflict, current: current.map { wireRow(key, $0) }))
            } else if let current, row.progressBucket < current.bucket, row.day < yesterday, fresh {
                downgradeRefused += 1
                rejected.append(DuoWireRejected(day: row.day, reason: .downgradeRefused, current: wireRow(key, current)))
            } else {
                accepted.append(row)
            }
        }
        if !accepted.isEmpty {
            bump()
            for row in accepted {
                let key = DuoRecordName.dayStatus(role: role, day: row.day)
                if let before = rows[key], row.progressBucket < before.bucket {
                    // The rules this review cares most about: a past day before coverage is never
                    // lowered, and a young install never lowers anything (D71).
                    if row.day != request.myToday, row.day < coverageAtSend { violations.append("DOWNGRADE BEFORE COVERAGE: \(key) \(before.bucket)->\(row.progressBucket)") }
                    if youngAtSend { violations.append("DOWNGRADE BY A YOUNG INSTALL: \(key) \(before.bucket)->\(row.progressBucket)") }
                }
                store(key, goalMet: row.goalMet, bucket: row.progressBucket, writer: myDevice)
            }
            acceptedRows += accepted.count
        }
        rejected = rejected.map { r in
            guard r.reason == .verConflict || r.reason == .downgradeRefused else { return r }
            let key = DuoRecordName.dayStatus(role: role, day: r.day)
            return DuoWireRejected(day: r.day, reason: r.reason, current: rows[key].map { wireRow(key, $0) })
        }
        return DuoWireChangesWithResult(changes: feed(since: request.since, role: role), accepted: accepted.map(\.day), unchanged: unchanged, rejected: rejected)
    }

    func nudge(_ request: DuoWireSendNudgeRequest, role: DuoRole) -> DuoWireSendNudgeResult {
        if let existing = nudges.first(where: { $0.id.lowercased() == request.id.lowercased() }) {
            return DuoWireSendNudgeResult(response: DuoWireSendNudgeResponse(nudge: DuoWireNudge(id: existing.id, fromRole: existing.fromRole, presetId: existing.preset,
                                                                                                 createdAt: existing.createdAt), remainingToday: 1), wasAlreadySent: true)
        }
        bump()
        let nudge = Nudge(id: request.id, fromRole: role, preset: request.presetId, createdAt: now, seq: seq)
        nudges.append(nudge)
        return DuoWireSendNudgeResult(response: DuoWireSendNudgeResponse(nudge: DuoWireNudge(id: nudge.id, fromRole: role, presetId: nudge.preset, createdAt: nudge.createdAt),
                                                                         remainingToday: 1), wasAlreadySent: false)
    }

    struct Snapshot { var seq: Int64; var oldestSeq: Int64; var rows: [String: Row]; var nudges: [Nudge] }
    func snapshot() -> Snapshot { Snapshot(seq: seq, oldestSeq: oldestSeq, rows: rows, nudges: nudges) }
    func restore(_ snapshot: Snapshot) {
        seq = snapshot.seq; oldestSeq = snapshot.oldestSeq; rows = snapshot.rows; nudges = snapshot.nudges
        generation += 1
    }
}

/// Requests wait for the driver: `process` is the server handling one (its state changes then),
/// `deliver` its answer reaching the phone (or, with `lose`, never doing so).
@MainActor
private final class WTransport: DuoTransport {
    enum Kind { case fetch, put, nudge, me }
    final class Pending {
        let kind: Kind
        var processed: Result<Any, Error>?
        var generation = 0
        let compute: () throws -> Any
        var continuation: CheckedContinuation<Any, Error>?
        init(kind: Kind, compute: @escaping () throws -> Any) { self.kind = kind; self.compute = compute }
    }
    let server: WServer
    var pending: [Pending] = []
    var log: [String] = []
    var putsSent = 0
    var putsBeforeRead = 0
    var fetchAnswersDelivered = 0
    var meResponse: DuoWireGetMeResponse?
    var coverageNow: () -> String = { DuoCoverage.coversNoPastDay }
    var youngNow: () -> Bool = { false }

    init(server: WServer) { self.server = server }

    private func wait<T>(_ kind: Kind, _ compute: @escaping () throws -> T) async throws -> T {
        let entry = Pending(kind: kind, compute: { try compute() })
        let value = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any, Error>) in
            entry.continuation = continuation
            pending.append(entry)
        }
        if kind == .fetch { fetchAnswersDelivered += 1 }
        return value as! T
    }

    func process(_ index: Int, failWith error: Error? = nil) {
        let entry = pending[index]
        guard entry.processed == nil else { return }
        entry.generation = server.generation
        if let error { entry.processed = .failure(error); return }
        do { entry.processed = .success(try entry.compute()) } catch { entry.processed = .failure(error) }
    }

    func deliver(_ index: Int, lose: Bool = false) {
        let entry = pending.remove(at: index)
        guard let result = entry.processed, !lose else { entry.continuation?.resume(throwing: DuoTransportError.offline); return }
        server.deliveredGeneration = entry.generation
        switch result {
        case .success(let value): entry.continuation?.resume(returning: value)
        case .failure(let error): entry.continuation?.resume(throwing: error)
        }
    }

    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges {
        log.append("fetch since \(since)")
        return try await wait(.fetch) { [server] in server.feed(since: since, role: .owner) }
    }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult {
        putsSent += 1
        if fetchAnswersDelivered == 0 { putsBeforeRead += 1 }
        log.append("put since \(request.since) rows \(request.statuses.map { "\($0.day):\($0.progressBucket)@\($0.baseVer)" })")
        let coverage = coverageNow(), young = youngNow()
        return try await wait(.put) { [server] in try server.put(request, role: .owner, coverageAtSend: coverage, youngAtSend: young) }
    }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult {
        log.append("nudge \(request.id)")
        return try await wait(.nudge) { [server] in server.nudge(request, role: .owner) }
    }
    func me() async throws -> DuoWireGetMeResponse {
        log.append("me")
        let response = meResponse
        return try await wait(.me) { guard let response else { throw DuoTransportError.offline }; return response }
    }
    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { throw DuoTransportError.offline }
    func attestChallenge() async throws -> DuoWireAttestChallenge { throw DuoTransportError.offline }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { throw DuoTransportError.offline }
    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember { throw DuoTransportError.offline }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { throw DuoTransportError.offline }
    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws { throw DuoTransportError.offline }
    func unregisterPush() async throws { throw DuoTransportError.offline }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { throw DuoTransportError.offline }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { throw DuoTransportError.offline }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { throw DuoTransportError.offline }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { throw DuoTransportError.offline }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { throw DuoTransportError.offline }
    func fetchDuo(id: String) async throws -> DuoWireHeader { throw DuoTransportError.offline }
    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse { throw DuoTransportError.offline }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { throw DuoTransportError.offline }
}

@MainActor
private final class WReader: DuoLogReading {
    unowned let world: RWorld
    init(_ world: RWorld) { self.world = world }
    func read(now: Date) -> DuoLogSummary { world.summary }
}

@MainActor
private final class RWorld {
    let duoID = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!
    let clock: RClock
    let server: WServer
    let transport: WTransport
    let store: DuoStore
    let identity: RIdentity
    let ops = RQueue()
    let push = FakePush()
    let announcer = RAnnouncer()
    let sleeper: WSleeper
    let dependencies: DuoDependencies
    var engine: DuoSyncEngine
    var entries: [(Date, Int)] = []
    let goal = 2000
    var tasks: [Task<Void, Never>] = []
    var cursorSeen: Int64 = 0
    var violations: [String] = []
    let unreadStart: Bool
    var allowCursorBack = false

    init(start: Date, zone: TimeZone = TimeZone(identifier: "UTC")!, installDaysAgo: Int = 60, syncedOnce: Bool = true, deviceAgeHours: Double = 500) {
        unreadStart = !syncedOnce
        clock = RClock(start, zone: zone)
        server = WServer(duoID: duoID, clock: clock)
        server.deviceCreatedAt[server.myDevice] = start.addingTimeInterval(-deviceAgeHours * 3600)
        transport = WTransport(server: server)
        store = DuoStore(cache: DuoCache(defaults: RMemoryDefaults()), usesServer: true, reloadWidget: {})
        let installDate = Calendar(identifier: .gregorian).date(byAdding: .day, value: -installDaysAgo, to: start)!
        identity = RIdentity(credential: DuoCredential(memberID: "m", deviceID: "d", deviceSecret: String(repeating: "s", count: 43)),
                             installDay: DayKey.key(for: installDate, calendar: clock.calendar))
        sleeper = WSleeper(clock: clock)
        dependencies = DuoDependencies(host: store, cache: store.cache, secrets: DuoSecrets(store: DuoMemorySecretStore()), clock: clock, random: RRandom(),
                                       client: DuoClientInfo(marketingVersion: "2.0", build: "1"), attester: FakeDuoAttester(), deviceCheck: FakeDuoDeviceCheck())
        dependencies.identity = identity
        dependencies.transport = transport
        dependencies.ops = ops
        dependencies.push = push
        dependencies.announcer = announcer
        let sleeper = self.sleeper
        dependencies.sleep = { seconds in try await sleeper.sleep(seconds) }
        engine = DuoSyncEngine(dependencies: dependencies)
        dependencies.sync = engine
        store.install(dependencies)
        store.upsert(DuoState(id: duoID, myRole: .owner, createdAt: start.addingTimeInterval(-86_400 * 30), ownerDisplayName: "Jo", partnerDisplayName: "Sam",
                              ownerSkin: "classic", partnerSkin: "forest", statuses: [], partnerHasJoined: true,
                              joinedAt: start.addingTimeInterval(-86_400 * 29), cursor: 0, syncedOnce: syncedOnce))
        store.memberInfo = DuoMemberInfo(memberID: "m", displayName: "Jo", skin: "classic", supportID: "S", tier: .attested, termsVersion: 1, nudgesPerDay: 3,
                                         maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: start)
        transport.meResponse = DuoWireGetMeResponse(
            member: DuoWireMember(id: "m", displayName: "Jo", skin: "classic", supportId: "S", tier: .attested, termsVersion: 1),
            limits: DuoWireLimits(nudgesPerDay: 3, maxActiveDuos: 5), devices: [DuoWireDevice(id: "d", platform: "ios", createdAt: start, thisDevice: true, superseded: false)],
            duos: [], minClient: DuoWireMinClient(ios: "2.0", android: "1.1"))
        transport.coverageNow = { [unowned self] in self.coverage }
        server.phoneCursor = { [unowned self] in self.store.duo(self.duoID)?.cursor ?? 0 }
        transport.youngNow = { [unowned self] in DuoCoverage.installAge(installDay: self.identity.installDay, now: self.clock.now, calendar: self.clock.calendar) < 48 * 3600 }
    }

    var summary: DuoLogSummary {
        let logged = entries.map { DuoLogEntry(timestamp: $0.0, hydratedML: $0.1, source: DuoLogEntry.hydroDropSource) }
        let floor = clock.now.addingTimeInterval(-9 * 86_400)
        return DuoLogSummary(totalsByDay: DuoLogTotals.totalsByDay(logged.filter { $0.timestamp >= floor }, calendar: clock.calendar), goalML: goal,
                             earliestEntryDay: entries.map(\.0).min().map { DayKey.key(for: $0, calendar: clock.calendar) })
    }
    /// Worked out here, independently of HydroCore's DuoCoverage, so a mutant of it is seen.
    var coverage: String {
        var days = [identity.installDay]
        if let first = entries.map(\.0).min() { days.append(DayKey.key(for: first, calendar: clock.calendar)) }
        return days.filter { $0.count == 10 && $0 >= "2000-01-01" }.min() ?? "9999-12-31"
    }
    var today: String { clock.today }
    var duo: DuoState { store.duo(duoID)! }
    func day(_ back: Int) -> String { WServer.dayMinus(today, back) }

    func logChanged() {
        let s = summary
        if store.latest != s { store.latest = s }
        engine.logChanged(s)
    }

    func spawn(_ work: @escaping @MainActor () async -> Void) { tasks.append(Task { @MainActor in await work() }) }
    func settle() async { for _ in 0..<40 { await Task.yield() } }

    /// Answers everything in order, wakes every sleeper, until nothing is left.
    func pump(wakeSleepers: Bool = true) async {
        for _ in 0..<50 {
            await settle()
            if transport.pending.isEmpty && (!wakeSleepers || sleeper.pending.isEmpty) { return }
            while !transport.pending.isEmpty { transport.process(0); transport.deliver(0); await settle() }
            if wakeSleepers { while !sleeper.pending.isEmpty { sleeper.wake(index: 0); await settle() } }
        }
    }

    func refresh() async { spawn { [engine] in await engine.refresh() }; await pump() }

    /// What the phone knows that differs from what the server holds.
    func mismatches() -> [String] {
        server.rows.sorted { $0.key < $1.key }.compactMap { key, row in
            let parsed = DuoRecordName.parseDayStatus(key)!
            let known = duo.status(of: parsed.role, on: parsed.day)
            guard known?.progressBucket != row.bucket || duo.vers[key] != row.ver else { return nil }
            return "\(key): server \(row.bucket)@\(row.ver), phone \(known.map { String($0.progressBucket) } ?? "none")@\(duo.vers[key].map(String.init) ?? "-")"
        }
    }

    /// Invariants that must hold at every quiet point.
    func checkInvariants(_ step: Int) {
        let d = duo
        if !allowCursorBack, d.cursor < cursorSeen { violations.append("step \(step): cursor moved back \(cursorSeen) -> \(d.cursor)") }
        cursorSeen = allowCursorBack ? d.cursor : max(cursorSeen, d.cursor)
        if !allowCursorBack {
            for status in d.statuses {
                let key = status.recordName
                guard let ver = d.vers[key], let row = server.rows[key] else { continue }
                if ver > row.ver { violations.append("step \(step): \(key) known ver \(ver) ahead of server \(row.ver)") }
                if ver == row.ver, row.goalMet != status.goalMet || row.bucket != status.progressBucket {
                    violations.append("step \(step): \(key) at ver \(ver) knows \(status.progressBucket) but server holds \(row.bucket)")
                }
            }
        }
        if unreadStart, transport.putsBeforeRead > 0 { violations.append("step \(step): \(transport.putsBeforeRead) PUT(s) before any read") }
    }
}

@MainActor
final class DuoSyncEngineServerModelTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21T14:13:20Z

    // MARK: C1 / D71, a reinstall with a partial import (probe P2)

    func testAReinstallWhoseImportBroughtBackOnlyAnOldDrinkLowersNothing() async {
        // The identity survived the reinstall (D64: no rotate), so the server sees an old device
        // that has written: its 48-hour backstop does not apply. Only D71 stands between the
        // partner's streak and a week of zeros.
        let w = RWorld(start: start, installDaysAgo: 0, syncedOnce: false, deviceAgeHours: 2000)
        for back in 1...6 { w.server.otherWrite(role: .owner, day: w.day(back), bucket: 100, device: w.server.myDevice) }
        for back in 0...6 { w.server.otherWrite(role: .partner, day: w.day(back), bucket: 100, device: w.server.partnerDevice) }
        w.entries = [(w.clock.now.addingTimeInterval(-40 * 86_400), 2000)]
        w.logChanged()
        await w.refresh()
        let mine = (1...6).map { w.server.rows["owner-\(w.day($0))"]!.bucket }
        XCTAssertEqual(mine, [100, 100, 100, 100, 100, 100], "nothing of the week is lowered: \(w.transport.log)")
        XCTAssertTrue(w.server.violations.isEmpty, "\(w.server.violations)")
        // The rest of the import lands: everything agrees again.
        for back in 1...6 { w.entries.append((w.clock.now.addingTimeInterval(-Double(back) * 86_400), 2000)) }
        w.clock.advance(31)
        w.logChanged()
        await w.pump()
        XCTAssertEqual((1...6).map { w.server.rows["owner-\(w.day($0))"]!.bucket }, [100, 100, 100, 100, 100, 100])
    }

    /// Probe RV1 (D78): a reinstall at 23:30 whose import is still partial. Counted from the start
    /// of the install day, the window was over at +25 h and four covered days went to 0; counted
    /// from its end, nothing is lowered until 48 hours after midnight, and then the window ends.
    func testAnEveningReinstallLowersNothingUntilFortyEightHoursAfterTheInstallDayEnds() async {
        let install = Date(timeIntervalSince1970: 1_790_033_400) // 2026-09-21T23:30:00Z
        func rowsOfMine(hoursLater: Double) async -> (rows: [Int], violations: [String]) {
            let w = RWorld(start: install, installDaysAgo: 0, syncedOnce: false, deviceAgeHours: 2000)
            let days = (1...6).map { w.day($0) }
            for day in days { w.server.otherWrite(role: .owner, day: day, bucket: 100, device: w.server.myDevice) }
            for back in 0...6 { w.server.otherWrite(role: .partner, day: w.day(back), bucket: 100, device: w.server.partnerDevice) }
            w.entries = [(install.addingTimeInterval(-40 * 86_400), 2000)]
            w.logChanged()
            await w.refresh()
            w.clock.advance(hoursLater * 3600)
            w.logChanged()
            await w.refresh()
            return (days.map { w.server.rows["owner-\($0)"]!.bucket }, w.server.violations)
        }
        for hoursLater in [23.0, 25.0, 47.0, 48.4] {
            let later = await rowsOfMine(hoursLater: hoursLater)
            XCTAssertEqual(later.rows, [100, 100, 100, 100, 100, 100], "+\(hoursLater) h after the install: nothing lowered")
            XCTAssertEqual(later.violations, [])
        }
        let past = await rowsOfMine(hoursLater: 48.6)
        XCTAssertEqual(past.rows, [0, 0, 0, 100, 100, 100], "past the window the ordinary diff applies to the week (D78's cost)")
    }

    // MARK: C2, a clock set far ahead (probe P3)

    func testAClockSetTwelveDaysAheadAndBackLosesNothing() async {
        let w = RWorld(start: start)
        for back in 0..<30 {
            w.server.otherWrite(role: .partner, day: w.day(back), bucket: 100, device: w.server.partnerDevice)
            w.server.otherWrite(role: .owner, day: w.day(back), bucket: 100, device: w.server.myDevice)
        }
        w.entries = (0..<30).map { (w.clock.now.addingTimeInterval(-Double($0) * 86_400 - 60), 2000) }
        w.logChanged()
        await w.refresh()
        let rowsBefore = w.duo.statuses.count
        let real = w.clock.now
        w.clock.force(real.addingTimeInterval(12 * 86_400))
        w.server.nowOffset = -12 * 86_400
        await w.refresh()
        w.clock.force(real.addingTimeInterval(120))
        w.server.nowOffset = 0
        for _ in 0..<3 { w.clock.advance(3600); await w.refresh() }
        XCTAssertEqual(w.duo.statuses.count, rowsBefore, "the copy was not pruned by the wrong clock")
        XCTAssertEqual(w.mismatches(), [])
        XCTAssertEqual(DuoStreak.current(statuses: w.duo.statuses, myRole: .owner, myToday: w.today, now: w.clock.now), 30)
    }

    // MARK: C3, a clock moved back (probe P7)

    func testAClockSetBackDoesNotStallPublishing() async {
        let w = RWorld(start: start)
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500)]
        w.logChanged()
        await w.refresh()
        let putsBefore = w.transport.putsSent
        w.clock.force(w.clock.now.addingTimeInterval(-2 * 3600))
        for i in 0..<6 {
            w.entries.append((w.clock.now, 400))
            w.logChanged()
            w.clock.advance(600)
            if i % 2 == 0 { w.spawn { [engine = w.engine] in await engine.refresh() } }
            await w.pump(wakeSleepers: true)
        }
        XCTAssertGreaterThan(w.transport.putsSent - putsBefore, 0)
        XCTAssertTrue(w.sleeper.delays.allSatisfy { $0 <= DuoWriteCoalescer.minimumInterval || $0 == 60 }, "no owed write waits for the old time: \(w.sleeper.delays)")
        XCTAssertEqual(w.server.rows["owner-\(w.today)"]?.bucket, DuoProgress.bucket(totalML: w.summary.totalsByDay[w.today] ?? 0, goalML: 2000))
    }

    func testTheFirstDrinkAfterTheClockWasSetBackIsSentAtOnce() async {
        // The 30-second clamp alone ends the stall. A last write ahead of now is also stale, so
        // the next drink goes at once instead of after an owed wait.
        let w = RWorld(start: start)
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500)]
        w.logChanged()
        await w.refresh()
        let putsBefore = w.transport.putsSent
        w.clock.force(w.clock.now.addingTimeInterval(-2 * 3600))
        w.entries.append((w.clock.now, 1000))
        w.logChanged()
        await w.settle()
        XCTAssertEqual(w.transport.pending.filter { $0.kind == .put }.count, 1, "sent at once")
        XCTAssertTrue(w.sleeper.pending.isEmpty, "with nothing owed")
        await w.pump()
        XCTAssertEqual(w.transport.putsSent, putsBefore + 1)
    }

    func testAClockToggledFiveTimesWithinSecondsSendsNoBurst() async {
        // Probe RV2: the date set a day ahead and back again, five times, a drink each way, with
        // nothing woken in between (all inside a few seconds of real time).
        let w = RWorld(start: start)
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500)]
        w.logChanged()
        await w.refresh()
        let t0 = w.clock.now
        let before = w.transport.putsSent
        for k in 0..<5 {
            w.clock.force(t0.addingTimeInterval(Double(k) * 2 + 86_400))
            w.entries.append((t0.addingTimeInterval(Double(k)), 100))
            w.logChanged()
            await w.pump(wakeSleepers: false)
            w.clock.force(t0.addingTimeInterval(Double(k) * 2 + 1))
            w.entries.append((t0.addingTimeInterval(Double(k) + 0.5), 100))
            w.logChanged()
            await w.pump(wakeSleepers: false)
        }
        XCTAssertLessThanOrEqual(w.transport.putsSent - before, 2, "one write each way at most; the rest is owed, not sent: \(w.sleeper.delays)")
        XCTAssertTrue(w.sleeper.delays.allSatisfy { $0 <= DuoWriteCoalescer.minimumInterval }, "no owed write waits for a day: \(w.sleeper.delays)")
        await w.pump()
        XCTAssertEqual(w.server.rows["owner-\(DayKey.key(for: t0, calendar: w.clock.calendar))"]?.bucket,
                       DuoProgress.bucket(totalML: w.summary.totalsByDay[DayKey.key(for: t0, calendar: w.clock.calendar)] ?? 0, goalML: 2000))
    }

    // MARK: C4 / D73, a refresh reads the log again (probe P8)

    func testADeletedDrinkReachesTheDuoAtTheNextRefresh() async {
        let w = RWorld(start: start)
        w.engine.activate(logReader: WReader(w))
        w.entries = [(w.clock.now.addingTimeInterval(-60), 2000)]
        w.logChanged()
        await w.refresh()
        XCTAssertEqual(w.server.rows["owner-\(w.today)"]?.bucket, 100)
        w.entries.removeAll()   // deleted on the History screen
        w.clock.advance(600)
        await w.refresh()
        XCTAssertEqual(w.server.rows["owner-\(w.today)"]?.bucket, 0, "the foreground read the log again and wrote the change")
    }

    // MARK: C5, a nudge survives a relaunch (probe P4)

    func testAnUnconfirmedNudgeSurvivesARelaunchAndIsSent() async {
        let w = RWorld(start: start)
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500)]
        w.logChanged()
        await w.refresh()
        w.spawn { [engine = w.engine, duo = w.duo] in await engine.sendNudge(.waterBreak, in: duo) }
        await w.settle()
        if let i = w.transport.pending.firstIndex(where: { $0.kind == .nudge }) { w.transport.process(i, failWith: DuoTransportError.offline); w.transport.deliver(i) }
        await w.settle()
        let copy = w.duo.allNudges.filter { $0.fromRole == .owner }.map(\.id)
        XCTAssertEqual(copy.count, 1)
        // Killed during the 30 s wait: a new engine over the same saved state.
        let relaunched = DuoSyncEngine(dependencies: w.dependencies)
        w.dependencies.sync = relaunched
        w.engine = relaunched
        w.clock.advance(600)
        await w.refresh()
        XCTAssertEqual(w.server.nudges.map(\.id), copy, "the same nudge, by its id")
        XCTAssertEqual(DuoNudgeRules.verdict(for: w.duo, partnerStatus: nil, now: w.clock.now, dailyLimit: 2, calendar: w.clock.calendar), .allowed(remaining: 1))
    }

    // MARK: C6 / D72, a restored server database (probes P1b, P1c)

    func testAnOlderFullAnswerDoesNotReplaceANewerOneAfterARestore() async {
        let w = RWorld(start: start)
        w.allowCursorBack = true
        for back in 0..<3 { w.server.otherWrite(role: .partner, day: w.day(back), bucket: 50, device: w.server.partnerDevice) }
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500)]
        w.logChanged()
        await w.refresh()
        let snapshot = w.server.snapshot()
        for i in 0..<8 { w.server.otherWrite(role: .partner, day: w.day(5), bucket: [25, 50, 75, 100][i % 4], device: w.server.partnerDevice) }
        w.clock.advance(31)
        await w.refresh()
        w.server.restore(snapshot)
        w.clock.advance(31)
        w.spawn { [engine = w.engine] in await engine.refresh() }
        await w.settle()
        guard let f1 = w.transport.pending.firstIndex(where: { $0.kind == .fetch }) else {
            return XCTFail("no fetch: pending \(w.transport.pending.map(\.kind)), log \(w.transport.log.suffix(4)), sleeps \(w.sleeper.pending.count)")
        }
        w.transport.process(f1)
        w.server.otherWrite(role: .partner, day: w.day(1), bucket: 100, device: w.server.partnerDevice)
        w.entries.append((w.clock.now, 1500))
        w.clock.advance(31)
        w.logChanged()
        await w.settle()
        guard let p = w.transport.pending.firstIndex(where: { $0.kind == .put }) else { return XCTFail("no put") }
        w.transport.process(p)
        w.transport.deliver(p)          // the newer full answer first
        await w.settle()
        let f1i = w.transport.pending.firstIndex(where: { $0.kind == .fetch })!
        w.transport.deliver(f1i)        // then the older one, to the same stale since
        await w.settle()
        XCTAssertEqual(w.duo.status(of: .partner, on: w.day(1))?.progressBucket, 100, "the older full answer did not put the older row back")
        await w.pump()
        for i in 0..<12 { w.server.otherWrite(role: .partner, day: w.day(3), bucket: [25, 50, 75, 100][i % 4], device: w.server.partnerDevice) }
        w.clock.advance(3600)
        await w.refresh()
        XCTAssertEqual(w.mismatches(), [])
    }

    func testARowWrittenAfterARestoreIsReadWhileTheServersSeqIsStillBelowTheCursor() async {
        let w = RWorld(start: start)
        w.allowCursorBack = true
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500)]
        w.logChanged()
        for i in 0..<10 { w.server.otherWrite(role: .partner, day: w.day(4), bucket: [25, 50, 75, 100][i % 4], device: w.server.partnerDevice) }
        let snapshot = w.server.snapshot()
        for i in 0..<5 { w.server.otherWrite(role: .partner, day: w.day(5), bucket: [25, 50, 75, 100, 0][i % 5], device: w.server.partnerDevice) }
        await w.refresh()
        w.server.restore(snapshot)
        w.clock.advance(3600)
        await w.refresh()
        XCTAssertEqual(w.duo.cursor, w.server.seq, "the phone took the restored server's cursor (D72)")
        w.server.otherWrite(role: .partner, day: w.day(1), bucket: 100, device: w.server.partnerDevice)
        for bucket in [25, 50, 75, 100, 25, 50, 75] {
            w.server.otherWrite(role: .partner, day: w.day(0), bucket: bucket, device: w.server.partnerDevice)
            w.spawn { [engine = w.engine, id = w.duoID, seq = w.server.seq] in await engine.pushArrived(DuoPushPayload(duoID: id, seq: seq, kind: .unknown("goal_met"))) }
            await w.pump()
        }
        XCTAssertEqual(w.duo.status(of: .partner, on: w.day(1))?.progressBucket, 100, "the row written after the restore is read")
        XCTAssertEqual(w.mismatches(), [])
    }

    // MARK: C17, a refused downgrade is held, not resent on every flush (probe P5)

    func testARefusedDowngradeIsNotSentAgainOnEveryForeground() async {
        let w = RWorld(start: start, deviceAgeHours: 1)
        for back in 2...5 { w.server.otherWrite(role: .owner, day: w.day(back), bucket: 100, device: w.server.otherDevice) }
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500), (w.clock.now.addingTimeInterval(-9 * 86_400), 100)]
        w.logChanged()
        await w.refresh()
        let putsAfterFirst = w.transport.putsSent
        for _ in 0..<10 { w.clock.advance(1800); await w.refresh() }
        XCTAssertEqual(w.transport.putsSent - putsAfterFirst, 0, "five hours of foregrounds with nothing changed send nothing")
        for _ in 0..<4 { w.clock.advance(1800); await w.refresh() }
        XCTAssertLessThanOrEqual(w.transport.putsSent - putsAfterFirst, 1, "after the hold, offered once more")
    }

    /// Found by the restore fuzz (seed 130349): the backstop's "never written this duo" lifts once
    /// a row of this device lands, but the answer that said so was lost, and the retry only heard
    /// `unchanged`. Releasing on an accepted row alone kept the refused rows back for six hours.
    func testAnUnchangedRowReleasesWhatAnEarlierAnswerHeldBack() async {
        let w = RWorld(start: start)
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500)]
        w.server.otherWrite(role: .owner, day: w.today, bucket: 25, device: w.server.otherDevice)
        for back in [1, 6] { w.server.otherWrite(role: .owner, day: w.day(back), bucket: 0, device: w.server.otherDevice) }
        for back in 2...5 { w.server.otherWrite(role: .owner, day: w.day(back), bucket: 100, device: w.server.otherDevice) }
        w.logChanged()
        await w.refresh()
        XCTAssertEqual(w.server.downgradeRefused, 4, "every lowered day refused: this device has not written the duo yet")
        XCTAssertEqual(w.server.rows[DuoRecordName.dayStatus(role: .owner, day: w.day(3))]?.bucket, 100)
        w.clock.advance(60)
        w.entries.append((w.clock.now, 500))
        w.logChanged()
        await w.settle()
        guard let p = w.transport.pending.firstIndex(where: { $0.kind == .put }) else { return XCTFail("no put for today's drink") }
        w.transport.process(p)
        w.transport.deliver(p, lose: true)
        await w.pump()
        XCTAssertEqual(w.server.rows[DuoRecordName.dayStatus(role: .owner, day: w.today)]?.bucket, 50)
        w.clock.advance(60)
        await w.refresh()
        for back in 2...5 {
            XCTAssertEqual(w.server.rows[DuoRecordName.dayStatus(role: .owner, day: w.day(back))]?.bucket, 0, "day -\(back) goes again once this device has written")
        }
        XCTAssertEqual(w.mismatches(), [])
    }

    /// Found by the young-device fuzz (seed 90042): a downgrade refused to a young device is held,
    /// then the member's other device lowers that day below it. The held row is now a raise, which
    /// the backstop lets through, and must not wait out the six hours.
    func testAHeldRowWhoseDayWasWrittenSinceGoesAgainAtOnce() async {
        let w = RWorld(start: start, deviceAgeHours: 1)
        let key = DuoRecordName.dayStatus(role: .owner, day: w.day(3))
        w.server.otherWrite(role: .owner, day: w.day(3), bucket: 100, device: w.server.otherDevice)
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500), (w.clock.now.addingTimeInterval(-3 * 86_400), 500)]
        w.logChanged()
        await w.refresh()
        w.clock.advance(60)
        await w.refresh()
        XCTAssertGreaterThanOrEqual(w.server.downgradeRefused, 1, "a young device may not lower day -3")
        XCTAssertEqual(w.server.rows[key]?.bucket, 100)
        let putsWhileHeld = w.transport.putsSent
        w.clock.advance(60)
        await w.refresh()
        XCTAssertEqual(w.transport.putsSent, putsWhileHeld, "held: nothing changed")
        w.server.otherWrite(role: .owner, day: w.day(3), bucket: 0, device: w.server.otherDevice)
        w.clock.advance(60)
        await w.refresh()
        XCTAssertEqual(w.server.rows[key]?.bucket, 25, "the row the other device lowered is raised to what this log says")
        XCTAssertEqual(w.mismatches(), [])
    }

    // MARK: C18, the my_today poison records what was sent (probe P6)

    func testTheMyTodayPoisonRecordsTheRowThatWasSent() async {
        let w = RWorld(start: start)
        w.entries = [(w.clock.now.addingTimeInterval(-60), 500)]
        w.logChanged()
        await w.refresh()
        let midnight = DayKey.date(from: WServer.dayMinus(w.today, -1), calendar: w.clock.calendar)!
        w.clock.force(midnight.addingTimeInterval(-5))
        w.entries.append((w.clock.now, 1500))
        let sentDay = w.today
        w.logChanged()
        await w.settle()
        guard let p = w.transport.pending.firstIndex(where: { $0.kind == .put }) else { return XCTFail("no put") }
        w.clock.force(midnight.addingTimeInterval(5))
        w.transport.process(p, failWith: DuoTransportError.dayOutOfRange(DuoErrorContext(httpStatus: 422, details: DuoWireErrorDetails(field: "my_today"))))
        w.transport.deliver(p)
        await w.settle()
        let refused = w.store.cache.loadRejectedDays()[w.duo.wireID]?.rows ?? [:]
        XCTAssertEqual(refused.keys.sorted(), [sentDay], "the request's own my_today, not the day the answer came in")
        XCTAssertEqual(refused[sentDay]?.progressBucket, 100)
    }
}

// MARK: - Randomized runs (trimmed from the reviews' 500 and 1,000 run harnesses)

@MainActor
final class DuoSyncEngineRandomizedTests: XCTestCase {
    private static var runs: Int { Int(ProcessInfo.processInfo.environment["DUO_C_RUNS"] ?? "") ?? 40 }

    // MARK: The sync review's fuzz, against the Worker model

    private struct FuzzConfig { var restoreServer = false; var youngDevice = false; var unread = true; var failures = true }

    private static let zones = ["UTC", "America/Los_Angeles", "Asia/Tokyo", "Pacific/Kiritimati", "Pacific/Pago_Pago", "Europe/London"]

    private func fuzzRun(seed: UInt64, config: FuzzConfig) async -> (violations: [String], unobservable: Bool) {
        var rng = RRNG(state: seed)
        let zone = TimeZone(identifier: Self.zones[Int(rng.next() % UInt64(Self.zones.count))])!
        let start = Date(timeIntervalSince1970: 1_790_000_000 + Double(rng.next() % 86_400))
        let w = RWorld(start: start, zone: zone, installDaysAgo: Int(rng.next() % 12), syncedOnce: !config.unread,
                       deviceAgeHours: config.youngDevice ? Double(rng.next() % 40) : 100)
        w.allowCursorBack = config.restoreServer
        for back in 0..<8 {
            let day = WServer.dayMinus(w.today, back)
            if rng.next() % 3 != 0 { w.server.otherWrite(role: .owner, day: day, bucket: [25, 50, 75, 100][Int(rng.next() % 4)], device: w.server.otherDevice) }
            if rng.next() % 3 != 0 { w.server.otherWrite(role: .partner, day: day, bucket: [0, 50, 100][Int(rng.next() % 3)], device: w.server.partnerDevice) }
        }
        for back in 0..<Int(rng.next() % 9) {
            w.entries.append((w.clock.now.addingTimeInterval(-Double(back) * 86_400 - 3600), [250, 500, 1000, 2000][Int(rng.next() % 4)]))
        }
        w.logChanged()
        var snapshots = [w.server.snapshot()]
        var nudgeCounter = 0
        for step in 0..<150 {
            switch Int(rng.next() % 100) {
            case 0..<10:
                w.entries.append((w.clock.now, [100, 250, 500, 800][Int(rng.next() % 4)]))
                w.logChanged()
            case 10..<14:
                let at = w.clock.now.addingTimeInterval(-Double(rng.next() % 7) * 86_400)
                let key = DayKey.key(for: at, calendar: w.clock.calendar)
                if rng.next() % 2 == 0, let index = w.entries.indices.first(where: { DayKey.key(for: w.entries[$0].0, calendar: w.clock.calendar) == key }) {
                    w.entries.remove(at: index)
                } else {
                    w.entries.append((at, 700))
                }
                w.logChanged()
            case 14..<16:
                w.entries.append((w.clock.now.addingTimeInterval(-Double(8 + rng.next() % 20) * 86_400), 400))
                w.logChanged()
            case 16..<24: w.spawn { [engine = w.engine] in await engine.refresh() }
            case 24..<30: w.spawn { [engine = w.engine] in await engine.flush() }
            case 30..<34:
                let seq = w.server.seq
                w.spawn { [engine = w.engine, id = w.duoID] in await engine.pushArrived(DuoPushPayload(duoID: id, seq: seq, kind: .unknown("x"))) }
            case 34..<38:
                w.server.otherWrite(role: .partner, day: WServer.dayMinus(w.today, Int(rng.next() % 3)), bucket: [0, 25, 50, 75, 100][Int(rng.next() % 5)], device: w.server.partnerDevice)
            case 38..<41:
                w.server.otherWrite(role: .owner, day: WServer.dayMinus(w.today, Int(rng.next() % 7)), bucket: [0, 25, 50, 75, 100][Int(rng.next() % 5)], device: w.server.otherDevice)
            case 41..<43:
                nudgeCounter += 1
                w.server.partnerNudge(id: String(format: "nudge-AAAAAAAA-0000-4000-8000-%012d", nudgeCounter))
            case 43..<45:
                w.spawn { [engine = w.engine, duo = w.duo] in await engine.sendNudge(.waterBreak, in: duo) }
            case 45..<55: w.clock.advance(Double(1 + rng.next() % 40))
            case 55..<57: w.clock.advance(Double(600 + rng.next() % 20_000))
            case 57..<58: w.clock.advance(Double(86_400 + rng.next() % 86_400))
            case 58..<78:
                if !w.transport.pending.isEmpty {
                    let i = Int(rng.next() % UInt64(w.transport.pending.count))
                    if config.failures, rng.next() % 6 == 0 {
                        let errors: [Error] = [DuoTransportError.maintenance(DuoErrorContext(httpStatus: 503)),
                                               DuoTransportError.rateLimited(DuoErrorContext(httpStatus: 429, retryAfter: 45)), DuoTransportError.offline]
                        w.transport.process(i, failWith: errors[Int(rng.next() % 3)])
                    } else {
                        w.transport.process(i)
                    }
                    snapshots.append(w.server.snapshot())
                }
            case 78..<92:
                let ready = w.transport.pending.indices.filter { w.transport.pending[$0].processed != nil }
                if !ready.isEmpty { w.transport.deliver(ready[Int(rng.next() % UInt64(ready.count))], lose: config.failures && rng.next() % 10 == 0) }
            case 92..<96:
                if !w.sleeper.pending.isEmpty { w.sleeper.wake(index: Int(rng.next() % UInt64(w.sleeper.pending.count))) }
            case 96..<97 where config.restoreServer:
                if snapshots.count > 2 {
                    let rowsBefore = w.server.rows, nudgesBefore = Set(w.server.nudges.map(\.id))
                    w.server.restore(snapshots[Int(rng.next() % UInt64(snapshots.count - 1))])
                    // How far the phone's cursor can get without asking again: its own, or an answer
                    // the server worked out before the rollback that is still on its way.
                    let onTheWay = w.transport.pending.compactMap { entry -> Int64? in
                        guard case .success(let value)? = entry.processed else { return nil }
                        return (value as? DuoWireChanges)?.cursor ?? (value as? DuoWireChangesWithResult)?.changes.cursor
                    }.max() ?? 0
                    let reach = max(w.duo.cursor, onTheWay)
                    if w.server.seq < reach {
                        w.server.restoreWatch = max(w.server.restoreWatch ?? 0, reach)
                    } else if w.server.rows != rowsBefore || Set(w.server.nudges.map(\.id)) != nudgesBefore {
                        w.server.markUnobservable()
                    }
                }
            default: break
            }
            await w.settle()
            w.server.checkWatch()
            w.checkInvariants(step)
        }
        // Drain: everything answered in order, no failures, until nothing is left.
        for round in 0..<60 {
            await w.settle()
            if w.transport.pending.isEmpty && w.sleeper.pending.isEmpty {
                if round > 12 { break }
                w.clock.advance(31)
                if round % 3 == 0 { w.spawn { [engine = w.engine] in await engine.refresh() } } else { w.spawn { [engine = w.engine] in await engine.flush() } }
                continue
            }
            while !w.transport.pending.isEmpty { w.transport.process(0); w.transport.deliver(0); await w.settle() }
            while !w.sleeper.pending.isEmpty { w.sleeper.wake(index: 0); await w.settle() }
            w.checkInvariants(10_000 + round)
        }
        w.clock.advance(31)
        w.spawn { [engine = w.engine] in await engine.refresh() }
        for _ in 0..<20 {
            await w.settle()
            while !w.transport.pending.isEmpty { w.transport.process(0); w.transport.deliver(0); await w.settle() }
            while !w.sleeper.pending.isEmpty { w.sleeper.wake(index: 0); await w.settle() }
        }
        var violations = w.violations + w.server.violations
        // Convergence: what the phone knows equals what the server holds.
        let d = w.duo
        if !d.syncedOnce { violations.append("never became syncedOnce") }
        let held = DuoStreak.pruned(w.server.rows.map { key, row in
            let p = DuoRecordName.parseDayStatus(key)!
            return DuoDayStatus(role: p.role, day: p.day, goalMet: row.goalMet, progressBucket: row.bucket, updatedAt: row.updatedAt)
        }, myToday: w.today, now: w.clock.now)
        for row in held {
            let server = w.server.rows[row.recordName]!
            guard let known = d.status(of: row.role, on: row.day) else { violations.append("converge: \(row.recordName) missing (server \(server.bucket)@\(server.ver))"); continue }
            if known.progressBucket != server.bucket { violations.append("converge: \(row.recordName) known \(known.progressBucket) server \(server.bucket)") }
            if d.vers[row.recordName] != server.ver { violations.append("converge: \(row.recordName) ver known \(d.vers[row.recordName].map(String.init) ?? "nil") server \(server.ver)") }
        }
        // What my log wants, against what the server holds for my role.
        let young = DuoCoverage.installAge(installDay: w.identity.installDay, now: w.clock.now, calendar: w.clock.calendar) < 48 * 3600
        let youngDevice = (w.server.deviceCreatedAt[w.server.myDevice] ?? .distantPast) > w.clock.now.addingTimeInterval(-48 * 3600)
        // §10.5's backstop also holds every past downgrade from a device that has never written
        // the duo, for as long as that lasts: seed 50045's writes were all refused or failed, and
        // the one that landed for its day was the member's other device's.
        let neverWrote = !w.server.rows.values.contains { $0.writer == w.server.myDevice }
        let refused = w.store.cache.loadRejectedDays()[d.wireID] ?? DuoRejectedDays()
        for want in DuoSyncPlan.wanted(role: .owner, summary: w.summary, myToday: w.today, now: w.clock.now, calendar: w.clock.calendar) {
            let server = w.server.rows[want.recordName]
            if refused.blocks(want) { continue }
            if want.day == w.today || want.day >= w.coverage {
                if server == nil, want.progressBucket == 0, want.day != w.today { continue }
                guard server?.bucket != want.progressBucket else { continue }
                let higher = (server?.bucket ?? 0) > want.progressBucket
                // D71: a young install leaves a higher row alone; the server's backstop holds a young device's.
                if higher, young || ((youngDevice || neverWrote) && want.day < WServer.dayMinus(w.today, 1)) { continue }
                violations.append("converge: my \(want.day) wants \(want.progressBucket) server \(server.map { String($0.bucket) } ?? "none")")
            } else if (server?.bucket ?? 0) < want.progressBucket {
                violations.append("converge: uncovered \(want.day) wants a raise to \(want.progressBucket), server \(server.map { String($0.bucket) } ?? "none")")
            }
        }
        let putsBefore = w.transport.putsSent
        w.clock.advance(31)
        w.spawn { [engine = w.engine] in await engine.flush() }
        await w.settle()
        while !w.transport.pending.isEmpty { w.transport.process(0); w.transport.deliver(0); await w.settle() }
        if w.transport.putsSent > putsBefore { violations.append("after convergence a flush still sent \(w.transport.putsSent - putsBefore) PUT(s)") }
        var seen: [String: Int] = [:]
        for key in w.announcer.delivered { seen[key, default: 0] += 1 }
        for (key, count) in seen where count > 1 { violations.append("announced \(key) \(count) times") }
        // A rollback of the server's database can lose a nudge it had already confirmed, which no
        // phone can know about: the check is for a server that keeps what it said it kept.
        // Of any age (C23): a copy the journal dropped after 23 hours used to stay for 48.
        let serverIDs = Set(w.server.nudges.map(\.id))
        for nudge in d.allNudges where !config.restoreServer && nudge.fromRole == .owner && !serverIDs.contains(nudge.id) {
            violations.append("optimistic nudge \(nudge.id) never confirmed, \(Int(w.clock.now.timeIntervalSince(nudge.createdAt) / 3600)) h old")
        }
        for task in w.tasks { task.cancel() }
        return (violations, w.server.unobservableRestore)
    }

    /// A run with a restore the phone had no way to see (`WServer.restoreWatch`) is counted and
    /// left out of the assertion: it is the residual D72 cannot reach. Every other run must hold.
    private func fuzz(_ name: String, config: FuzzConfig, seedBase: UInt64) async {
        var failing: [(UInt64, [String])] = []
        var unobservable = 0
        for i in 0..<Self.runs {
            let run = await fuzzRun(seed: seedBase &+ UInt64(i), config: config)
            if run.unobservable { unobservable += 1; continue }
            if !run.violations.isEmpty { failing.append((seedBase &+ UInt64(i), run.violations)) }
        }
        XCTAssertTrue(failing.isEmpty, "fuzz \(name): \(failing.count) of \(Self.runs - unobservable) runs failed; first: \(failing.prefix(3).map { "seed \($0.0): \($0.1.prefix(3))" })")
        XCTAssertLessThan(unobservable, Self.runs, "every run of \(name) was left out")
        if unobservable > 0 { print("DUO-C fuzz \(name): \(unobservable) of \(Self.runs) runs had a restore the phone could not see, left out") }
    }

    func testFuzzFromAnUnreadDuo() async { await fuzz("unread", config: FuzzConfig(), seedBase: 1_000) }
    func testFuzzFromAReadDuo() async { await fuzz("read", config: FuzzConfig(unread: false), seedBase: 50_000) }
    func testFuzzWithAYoungDevice() async { await fuzz("young", config: FuzzConfig(youngDevice: true), seedBase: 90_000) }
    func testFuzzWithNoFailures() async { await fuzz("nofail", config: FuzzConfig(failures: false), seedBase: 170_000) }
    func testFuzzWithRestoresOfTheServer() async { await fuzz("restore", config: FuzzConfig(restoreServer: true), seedBase: 130_000) }

    // MARK: The concurrency review's stress run, against held calls and a holding sleeper

    private enum StressMode { case normal, wipe, disconnect }

    private func stressRun(seed: UInt64, mode: StressMode) async -> [String] {
        var rng = RRNG(state: seed)
        let h = RH()
        let today = RH.today, yesterday = "2026-09-20"
        let ids = Array([rDuoA, rDuoB, rDuoC].prefix(Int.random(in: 1...3, using: &rng)))
        for id in ids {
            h.addDuo(id, cursor: 10, syncedOnce: Bool.random(using: &rng))
            h.server.write(id.wire, role: .partner, day: yesterday, bucket: 100)
        }
        if Bool.random(using: &rng) { h.knowMember() }
        var totals: [String: Int] = [today: 0, yesterday: Int.random(in: 0...2000, using: &rng)]
        var goal = 2000
        let reader = FakeLogReader(DuoLogSummary(totalsByDay: totals, goalML: goal, earliestEntryDay: "2026-01-01"))
        h.engine.activate(logReader: reader)
        var violations: [String] = []
        var nudgeBodies: [String: DuoWireSendNudgeRequest] = [:]
        var lastCursor: [UUID: Int64] = [:]
        var wiped = false
        var deliveredAtWipe: [Int] = []
        let store = h.store, identity = h.identity, ops = h.ops
        h.sched.onSend = { record in
            if identity.credential == nil { violations.append("bearer request with no credential: \(record)") }
            switch store.availability {
            case .disconnected, .banned, .needsRestoreChoice: violations.append("request while \(store.availability): \(record)")
            default: break
            }
            let duo = UUID(uuidString: record.wire).flatMap { store.duo($0) }
            switch record.kind {
            case .fetch:
                guard let duo else { violations.append("fetch for a duo the phone does not hold"); return }
                if duo.hasEnded || duo.pendingOp != nil { violations.append("fetch for an ended duo") }
                if record.since != (duo.syncedOnce ? duo.cursor : 0) { violations.append("fetch since \(record.since), cursor \(duo.cursor)") }
            case .put:
                guard let duo, let put = record.put else { violations.append("put for a duo the phone does not hold"); return }
                if !duo.syncedOnce { violations.append("put before the duo was read") }
                if duo.hasEnded || duo.pendingOp != nil { violations.append("put to an ended duo") }
                if ops.pending.contains(where: { $0.kind == .leave || $0.kind == .block }) { violations.append("put with an exit queued") }
                if put.since != duo.cursor { violations.append("put since \(put.since) but cursor \(duo.cursor)") }
                for s in put.statuses where s.baseVer != duo.ver(of: duo.myRole, on: s.day) { violations.append("put base_ver \(s.baseVer) for \(s.day)") }
            case .nudge:
                guard let duo, let body = record.nudge else { violations.append("nudge for a duo the phone does not hold"); return }
                if duo.hasEnded || duo.pendingOp != nil { violations.append("nudge to an ended duo") }
                if let first = nudgeBodies[body.id], first != body { violations.append("nudge \(body.id) resent with another body") } else { nudgeBodies[body.id] = body }
            case .me:
                if store.duos.isEmpty { violations.append("GET /me with no duo cached") }
            }
        }
        var tasks: [Task<Void, Never>] = []
        var backgrounds: [(Task<Void, Never>, RFlag)] = []
        var partnerNudgeCount: [UUID: Int] = [:]
        func outcome(for kind: RSched.Kind) -> ROutcome {
            switch Int.random(in: 0..<1000, using: &rng) {
            case 0..<560: return .ok
            case 560..<630: return .lost
            case 630..<720: return .offline
            case 720..<790: return .maintenance(Int.random(in: 30...120, using: &rng))
            case 790..<830: return .rateLimited(Int.random(in: 30...300, using: &rng))
            case 830..<880: return .cancelled
            case 880..<920: return .unreadable2xx
            case 920..<940 where kind == .nudge: return .error(.nudgeLimit(DuoErrorContext(httpStatus: 429)))
            case 940..<950 where kind == .nudge: return .error(.partnerAlreadyMet(DuoErrorContext(httpStatus: 409)))
            case 950..<956 where mode == .disconnect: return .error(.deviceRevoked(DuoErrorContext(httpStatus: 401)))
            case 956..<960 where mode == .disconnect: return .unauthenticated
            default: return .ok
            }
        }
        for _ in 0..<120 {
            switch Int.random(in: 0..<120, using: &rng) {
            case 0..<12:
                if Int.random(in: 0..<10, using: &rng) == 0 { totals[yesterday] = Int.random(in: 0...2500, using: &rng) }
                totals[today] = max(0, (totals[today] ?? 0) + Int.random(in: -200...700, using: &rng))
                if Int.random(in: 0..<25, using: &rng) == 0 { goal = [1500, 2000, 2500, 3000].randomElement(using: &rng)! }
                let summary = DuoLogSummary(totalsByDay: totals, goalML: goal, earliestEntryDay: "2026-01-01")
                reader.summary = summary
                h.store.latest = summary
                h.engine.logChanged(summary)
            case 12..<20: tasks.append(Task { await h.engine.refresh() })
            case 20..<24: tasks.append(Task { await h.engine.flush() })
            case 24..<30:
                let id = ids.randomElement(using: &rng)!
                let seq = h.server.duos[id.wire]?.seq ?? 0
                tasks.append(Task { await h.engine.pushArrived(DuoPushPayload(duoID: id, seq: seq, kind: .joined)) })
            case 30..<35:
                let id = ids.randomElement(using: &rng)!
                let preset = DuoNudgePreset.allCases.randomElement(using: &rng)!
                tasks.append(Task { await h.engine.sendNudge(preset, in: DuoFixtures.duo(id: id)) })
            case 35..<38:
                let flag = RFlag()
                backgrounds.append((Task { _ = await h.engine.backgroundRefresh(); flag.value = true }, flag))
            case 38..<68:
                if !h.sched.held.isEmpty {
                    let i = Int.random(in: 0..<h.sched.held.count, using: &rng)
                    h.sched.complete(i, outcome(for: h.sched.held[i].kind))
                }
            case 68..<78:
                if let id = h.sleeper.ids.randomElement(using: &rng) { h.sleeper.release(id, late: Double(Int.random(in: 0...20, using: &rng))) }
            case 78..<82:
                h.server.write(ids.randomElement(using: &rng)!.wire, role: .partner, day: today, bucket: [0, 25, 50, 75, 100].randomElement(using: &rng)!)
            case 82..<85:
                let id = ids.randomElement(using: &rng)!
                if (partnerNudgeCount[id] ?? 0) < 3, h.store.duo(id)?.syncedOnce == true {
                    partnerNudgeCount[id, default: 0] += 1
                    h.server.partnerNudge(id.wire, id: "nudge-" + UUID().uuidString.uppercased())
                }
            case 85..<87:
                h.server.write(ids.randomElement(using: &rng)!.wire, role: .owner, day: today, bucket: [0, 25, 50, 75, 100].randomElement(using: &rng)!)
            case 87..<92: h.clock.advance(Double(Int.random(in: 0...40, using: &rng)))
            case 92..<95: tasks.randomElement(using: &rng)?.cancel()
            case 95..<98:
                if let (task, flag) = backgrounds.last, !flag.value {
                    task.cancel()
                    await h.spin(30)
                    if !flag.value { violations.append("a cancelled background run still holds its caller") }
                }
            case 98..<99 where mode == .wipe:
                h.store.resetLocalState()
                h.identity.discard()
                lastCursor = [:]
                wiped = true
                deliveredAtWipe.append(h.announcer.delivered.count)
                await h.spin(10)
                h.identity.credential = DuoFixtures.credential()
                for id in ids { h.store.upsert(DuoFixtures.duo(id: id, cursor: 0, syncedOnce: false, now: h.clock.now)) }
            default: break
            }
            await h.spin(Int.random(in: 5...60, using: &rng))
            for duo in h.store.duos {
                if let last = lastCursor[duo.id], duo.cursor < last { violations.append("cursor moved back \(last) -> \(duo.cursor)") }
                lastCursor[duo.id] = duo.cursor
            }
        }
        // The network is healthy again: answer everything, wake every sleeper, until nothing moves.
        func quiesce() async -> Bool {
            var quiet = 0
            for _ in 0..<600 {
                if h.sched.held.isEmpty && h.sleeper.count == 0 { quiet += 1; if quiet > 4 { return true } } else { quiet = 0 }
                h.sched.completeAll(.ok)
                h.sleeper.releaseAll()
                await h.spin(30)
            }
            return false
        }
        if !(await quiesce()) { violations.append("never quiet with a healthy network") }
        for task in tasks { await task.value }
        for (task, _) in backgrounds { await task.value }
        let foreground = Task { await h.engine.refresh() }
        if !(await quiesce()) { violations.append("never quiet after the final refresh") }
        await foreground.value
        h.clock.advance(400)
        let flush = Task { await h.engine.flush() }
        if !(await quiesce()) { violations.append("never quiet after the final flush") }
        await flush.value
        h.sleeper.immediate = true
        h.sched.auto = .ok
        await h.engine.waitUntilIdle()
        let canWrite = h.identity.credential != nil && h.store.availability.allowsWrites
        if let latest = h.store.latest {
            for duo in h.store.duos where !duo.hasEnded && duo.pendingOp == nil {
                if canWrite && !duo.syncedOnce { violations.append("a live duo was never read") }
                guard canWrite, duo.syncedOnce else { continue }
                let owed = DuoSyncPlan.write(for: duo, summary: latest, coverageStart: DuoCoverage.start(installDay: "2026-01-01", earliestEntryDay: latest.earliestEntryDay),
                                             rejectedDays: h.cache.loadRejectedDays()[duo.wireID] ?? DuoRejectedDays(),
                                             myToday: h.clock.today, now: h.clock.now, calendar: h.clock.calendar).write
                if let owed { violations.append("a write is still owed after quiescence: \(owed.rows.map { "\($0.day):\($0.progressBucket)" })") }
                let mine = Set(h.server.myNudges(duo.wireID).map(\.id))
                for nudge in duo.allNudges where nudge.fromRole == duo.myRole && !mine.contains(nudge.id) { violations.append("my nudge \(nudge.id.prefix(12)) never confirmed") }
            }
        }
        if !wiped {
            for (wire, _) in h.server.duos {
                var perDay: [String: Int] = [:]
                for nudge in h.server.myNudges(wire) { perDay[DayKey.key(for: nudge.createdAt, calendar: h.clock.calendar), default: 0] += 1 }
                for (day, count) in perDay where count > 3 { violations.append("\(count) nudges sent on \(day), limit 3") }
            }
        }
        let cuts = [0] + deliveredAtWipe + [h.announcer.delivered.count]
        for i in 0..<(cuts.count - 1) {
            var segment: [String: Int] = [:]
            for key in h.announcer.delivered[cuts[i]..<cuts[i + 1]] { segment[key, default: 0] += 1 }
            for (key, count) in segment where count > 1 { violations.append("announced \(count) times: \(key.prefix(16))") }
        }
        var byDuo: [String: [RSched.Record]] = [:]
        for put in h.sched.puts { byDuo[put.wire, default: []].append(put) }
        for (_, puts) in byDuo {
            for i in 0..<puts.count where i + 2 < puts.count && puts[i + 2].at.timeIntervalSince(puts[i].at) < 30 {
                violations.append("three PUTs to one duo inside 30 s: \(puts[i].n),\(puts[i + 1].n),\(puts[i + 2].n)")
            }
        }
        for (kind, count) in h.sched.mostInFlight where (kind == .fetch || kind == .put || kind == .me) && count > 1 { violations.append("\(count) \(kind.rawValue) in flight at once") }
        return violations + h.sched.violations
    }

    private func stress(_ mode: StressMode, seedBase: UInt64) async {
        var failing: [(UInt64, [String])] = []
        for i in 0..<Self.runs {
            let violations = await stressRun(seed: seedBase &+ UInt64(i), mode: mode)
            if !violations.isEmpty { failing.append((seedBase &+ UInt64(i), violations)) }
        }
        XCTAssertTrue(failing.isEmpty, "stress \(mode): \(failing.count) of \(Self.runs) runs failed; first: \(failing.prefix(3).map { "seed \($0.0): \($0.1.prefix(3))" })")
    }

    func testStressInterleavings() async { await stress(.normal, seedBase: 1) }
    func testStressInterleavingsWithWipes() async { await stress(.wipe, seedBase: 20_001) }
    func testStressInterleavingsWithDisconnects() async { await stress(.disconnect, seedBase: 40_001) }
}

private struct RRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
#endif
