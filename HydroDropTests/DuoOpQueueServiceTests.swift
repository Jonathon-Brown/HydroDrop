#if DUO_V2
import XCTest
@testable import HydroDrop

// MARK: - Test helpers (stage E)

/// Holds a request until the test lets it go, so a test can act while it is out.
fileprivate final class EQueueGate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var released = false
    private var entries = 0

    var entered: Int { lock.lock(); defer { lock.unlock() }; return entries }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            entries += 1
            if released {
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

/// `FakeDuoTransport` with a gate in front of a leave and a `PATCH /me`.
fileprivate final class EQueueGatedTransport: DuoTransport, @unchecked Sendable {
    let base: FakeDuoTransport
    var leaveGate: EQueueGate?
    var updateMeGate: EQueueGate?
    var registerPushGate: EQueueGate?

    init(_ base: FakeDuoTransport) { self.base = base }

    func registerPush(_ request: DuoWireRegisterPushRequest, firstUpload: Bool) async throws {
        if let registerPushGate { await registerPushGate.wait() }
        try await base.registerPush(request, firstUpload: firstUpload)
    }

    func leave(duoID: String, key: DuoIdempotencyKey) async throws -> DuoWireLeaveResponse {
        if let leaveGate { await leaveGate.wait() }
        return try await base.leave(duoID: duoID, key: key)
    }

    func updateMe(_ request: DuoWireUpdateMeRequest) async throws -> DuoWireMember {
        if let updateMeGate { await updateMeGate.wait() }
        return try await base.updateMe(request)
    }

    func createDevice(_ request: DuoWireCreateDeviceRequest) async throws -> DuoWireCreateDeviceResponse { try await base.createDevice(request) }
    func attestChallenge() async throws -> DuoWireAttestChallenge { try await base.attestChallenge() }
    func rotate(as credential: DuoCredential) async throws -> DuoWireRotateResponse { try await base.rotate(as: credential) }
    func me() async throws -> DuoWireGetMeResponse { try await base.me() }
    func deleteMe(_ request: DuoWireDeleteMeRequest, key: DuoIdempotencyKey) async throws { try await base.deleteMe(request, key: key) }
    func unregisterPush() async throws { try await base.unregisterPush() }
    func createDuo(_ request: DuoWireCreateDuoRequest, key: DuoIdempotencyKey) async throws -> DuoWireCreateDuoResponse { try await base.createDuo(request, key: key) }
    func createInvite(duoID: String, purpose: DuoWireInvitePurpose, key: DuoIdempotencyKey) async throws -> DuoWireInvite { try await base.createInvite(duoID: duoID, purpose: purpose, key: key) }
    func peekInvite(code: String) async throws -> DuoWirePeekResponse { try await base.peekInvite(code: code) }
    func redeemInvite(_ request: DuoWireRedeemRequest, key: DuoIdempotencyKey) async throws -> DuoWireChangesWithResult { try await base.redeemInvite(request, key: key) }
    func reconnect(_ request: DuoWireReconnectRequest, key: DuoIdempotencyKey) async throws -> DuoWireReconnectResponse { try await base.reconnect(request, key: key) }
    func fetchDuo(id: String) async throws -> DuoWireHeader { try await base.fetchDuo(id: id) }
    func fetchChanges(duoID: String, since: Int64) async throws -> DuoWireChanges { try await base.fetchChanges(duoID: duoID, since: since) }
    func pushDayStatuses(duoID: String, _ request: DuoWirePutStatusesRequest) async throws -> DuoWireChangesWithResult { try await base.pushDayStatuses(duoID: duoID, request) }
    func sendNudge(duoID: String, _ request: DuoWireSendNudgeRequest) async throws -> DuoWireSendNudgeResult { try await base.sendNudge(duoID: duoID, request) }
    func block(duoID: String, key: DuoIdempotencyKey) async throws { try await base.block(duoID: duoID, key: key) }
}

/// The network path, as the test says it is.
@MainActor
fileprivate final class EPathMonitor: DuoOpQueueService.PathMonitoring {
    private(set) var starts = 0
    private var onPathChange: (@MainActor (Bool) -> Void)?

    func start(_ onPathChange: @escaping @MainActor (Bool) -> Void) {
        starts += 1
        self.onPathChange = onPathChange
    }

    func reading(_ satisfied: Bool) { onPathChange?(satisfied) }
}

/// A sleep that pays no attention to being cancelled and ends one caller at a time, as the test
/// says: the case where a retry that was let go finds its delay over all the same.
fileprivate final class ESleepTurnstile: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var open = false
    private var entries = 0

    var entered: Int { lock.lock(); defer { lock.unlock() }; return entries }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            entries += 1
            if open {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    /// Ends the oldest sleep still going.
    func releaseOldest() {
        lock.lock()
        let first = waiters.isEmpty ? nil : waiters.removeFirst()
        lock.unlock()
        first?.resume()
    }

    /// Ends every sleep, now and from now on.
    func openForGood() {
        lock.lock()
        open = true
        let all = waiters
        waiters = []
        lock.unlock()
        all.forEach { $0.resume() }
    }
}

/// Counts callers that came back, from tasks on the main actor.
@MainActor
fileprivate final class EFinishCounter {
    var count = 0
}

/// Counts the monitors the service asked for.
@MainActor
fileprivate final class EMonitorFactory {
    let monitor = EPathMonitor()
    private(set) var made = 0
    func make() -> DuoOpQueueService.PathMonitoring { made += 1; return monitor }
}

// MARK: - The tests

/// The op queue of final design §10.1, through the real service over a `DuoTestKit`: order, the
/// replayed bytes, every disposition as the service acts on it, the network monitor, the single
/// drain, the queue outliving the service, and the identity's launch coming first.
@MainActor
final class DuoOpQueueServiceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let otherDuo = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000002")!
    private var folders: [URL] = []

    override func tearDown() {
        for folder in folders { try? FileManager.default.removeItem(at: folder) }
        folders = []
        super.tearDown()
    }

    /// A kit with a credential whose launch is settled, and the real queue service in it.
    private func makeKit(credential: DuoCredential? = DuoFixtures.credential()) -> (DuoTestKit, DuoOpQueueService) {
        let kit = DuoTestKit(credential: credential)
        kit.identity.launch = credential == nil ? .none : .ready
        let service = DuoOpQueueService(dependencies: kit.dependencies)
        kit.dependencies.ops = service
        return (kit, service)
    }

    private func leaveOp(_ duo: UUID = DuoFixtures.duoID, key: String = "leave-key") throws -> DuoQueuedOp {
        try DuoQueuedOp.leave(duoID: duo, key: key, now: now)
    }

    private func blockOp(_ duo: UUID = DuoFixtures.duoID, key: String = "block-key") throws -> DuoQueuedOp {
        try DuoQueuedOp.block(duoID: duo, key: key, now: now)
    }

    private func renameRequest(_ name: DuoWireField<String> = .value("Joanna")) -> DuoWireUpdateMeRequest {
        DuoWireUpdateMeRequest(displayName: name, skin: .value("forest"))
    }

    private func renameOp(_ name: DuoWireField<String> = .value("Joanna"), key: String = "rename-key") throws -> DuoQueuedOp {
        try DuoQueuedOp.updateMe(renameRequest(name), key: key, now: now)
    }

    private func pushRequest() -> DuoWireRegisterPushRequest {
        DuoWireRegisterPushRequest(token: "ab12cd", apnsEnv: "sandbox", tz: "Europe/London", wakeStartMin: 480, wakeEndMin: 1320,
                                   notificationsEnabled: true)
    }

    private func pushOp(firstUpload: Bool = true, key: String = "push-key") throws -> DuoQueuedOp {
        try DuoQueuedOp.registerPush(pushRequest(), firstUpload: firstUpload, key: key, now: now)
    }

    private func leaveResponse(_ endedBy: DuoEndedBy = .owner) -> DuoWireLeaveResponse {
        DuoWireLeaveResponse(state: "ended", endedBy: endedBy, endedAt: Date(timeIntervalSince1970: 1_790_000_500))
    }

    private func member(name: String? = "Joanna", skin: String? = "forest") -> DuoWireMember {
        DuoWireMember(id: DuoFixtures.credential().memberID, displayName: name, skin: skin, supportId: "ZZZZ9999ZZZZ", tier: .attested, termsVersion: 7)
    }

    private func memberInfo() -> DuoMemberInfo {
        DuoMemberInfo(memberID: DuoFixtures.credential().memberID, displayName: "Jo", skin: "classic", supportID: "ABCD1234EFGH", tier: .low,
                      termsVersion: 1, nudgesPerDay: 1, maxActiveDuos: 5, devices: [], minClientIOS: nil, updatedAt: now)
    }

    private func failure(_ code: DuoErrorCode, status: Int, retryAfter: Int? = nil) -> DuoTransportError {
        DuoTransportError(code: code, context: DuoErrorContext(httpStatus: status, requestID: "req-1", retryAfter: retryAfter))
    }

    private func leaves(_ transport: FakeDuoTransport) -> [DuoIdempotencyKey] {
        transport.calls.compactMap { if case .leave(_, let key) = $0 { return key }; return nil }
    }

    /// An ended card waiting for its leave, as the exit service leaves it.
    private func endedCardWaiting(_ kit: DuoTestKit, _ op: DuoPendingOp = .leave, id: UUID = DuoFixtures.duoID) {
        var duo = DuoFixtures.duo(id: id, now: now)
        duo.endedAt = now
        duo.endedBy = .owner
        duo.pendingOp = op
        kit.store.upsert(duo)
    }

    /// Lets the main actor run until `condition` holds, or fails after a bounded wait.
    private func yield(until condition: () -> Bool, _ message: String, file: StaticString = #filePath, line: UInt = #line) async {
        for _ in 0..<10_000 where !condition() { await Task.yield() }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }

    private func settle() async {
        for _ in 0..<500 { await Task.yield() }
    }

    /// A drain, and every retry it leaves behind, to the end. The kit's sleep returns at once, so a
    /// retry runs a few turns of the main actor later, and nothing of it may outlive the test.
    private func drained(_ service: DuoOpQueueService, file: StaticString = #filePath, line: UInt = #line) async {
        await service.drain()
        await yield(until: { service.isIdle }, "the drain's retries finish", file: file, line: line)
    }

    private func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("DuoOpQueueServiceTests-\(UUID().uuidString)", isDirectory: true)
        folders.append(folder)
        return folder
    }

    // MARK: - Order

    func testADrainSendsEveryKindInTheOrderItWasQueuedAndEmptiesTheQueue() async throws {
        let (kit, service) = makeKit()
        kit.transport.onUpdateMe = { _ in self.member() }
        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        kit.transport.onBlock = { _, _ in }
        kit.transport.onRegisterPush = { _, _ in }
        kit.transport.onUnregisterPush = {}
        service.enqueue(try renameOp())
        service.enqueue(try leaveOp())
        service.enqueue(try blockOp(otherDuo))
        service.enqueue(try pushOp(firstUpload: true))
        service.enqueue(DuoQueuedOp.unregisterPush(key: "unregister-key", now: now))

        await drained(service)

        XCTAssertEqual(kit.transport.calls, [
            .updateMe(renameRequest()),
            .leave(duoID: DuoFixtures.duoID.uuidString.lowercased(), DuoIdempotencyKey("leave-key")),
            .block(duoID: otherDuo.uuidString.lowercased(), DuoIdempotencyKey("block-key")),
            .registerPush(pushRequest(), firstUpload: true),
            .unregisterPush,
        ])
        XCTAssertTrue(service.pending.isEmpty)
        XCTAssertNil(kit.defaults.object(forKey: DuoCache.opsKey), "an empty queue leaves no key behind, so a wipe's on-disk set holds")
    }

    func testAnEntryThatMustWaitHoldsBackOnlyItsOwnGroup() async throws {
        // D74: first in, first out within the exits, the profile and the push token. A block that
        // must wait holds back the leave queued after it; it holds back no rename.
        let (kit, service) = makeKit()
        kit.transport.onBlock = { _, _ in throw DuoTransportError.offline }
        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        kit.transport.onUpdateMe = { _ in self.member() }
        service.enqueue(try blockOp())
        service.enqueue(try leaveOp(otherDuo))
        service.enqueue(try renameOp())

        await drained(service)

        XCTAssertTrue(leaves(kit.transport).isEmpty, "the leave waits behind the block it was queued after")
        XCTAssertEqual(kit.transport.calls.filter { if case .updateMe = $0 { return true }; return false }.count, 1,
                       "the rename is not held behind a group it is not in")
        XCTAssertEqual(service.pending.map(\.key), ["block-key", "leave-key"])
    }

    // MARK: - The same request every time

    func testALeaveAnUpdateAndAPushUploadAreReplayedAsTheSameBytesUnderTheSameKey() async throws {
        // Through the real API client and a recording session, so what is compared is what would
        // have gone over the wire: the body and the `Idempotency-Key` of every attempt.
        let (kit, service) = makeKit()
        let session = RecordingSession()
        kit.dependencies.transport = DuoAPIClient(baseURL: URL(string: "https://api.duo-stage-e.test/v1")!, client: kit.dependencies.client,
                                                  credentials: kit.identity, attester: kit.attester, session: session)
        let leave = try leaveOp()
        let rename = try renameOp(.null)
        let upload = try pushOp(firstUpload: false)
        service.enqueue(leave)
        service.enqueue(rename)
        service.enqueue(upload)

        await drained(service) // no connection: three tries of each group's head, then wait for the next trigger
        XCTAssertEqual(session.requests.count, 3 * DuoRetry.maximumAttempts, "the leave, the rename and the upload are in three groups (D74)")
        XCTAssertEqual(service.pending.count, 3)

        session.respond = { request in
            let url = request.url!
            func answer(_ status: Int, _ body: String) -> (Data, HTTPURLResponse) {
                (Data(body.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!)
            }
            switch url.path {
            case let path where path.hasSuffix("/leave"):
                return answer(200, #"{"ended_at":"2026-10-08T09:00:00Z","ended_by":"owner","state":"ended"}"#)
            case let path where path.hasSuffix("/me"):
                return answer(200, #"{"display_name":null,"id":"6d2a0000-0000-4000-8000-0000000000aa","skin":"forest","support_id":"ABCD1234EFGH","terms_version":1,"tier":"low"}"#)
            default:
                return answer(204, "")
            }
        }
        await drained(service)

        XCTAssertTrue(service.pending.isEmpty)
        let leaveAttempts = session.requests.filter { $0.url?.path.hasSuffix("/leave") == true }
        XCTAssertEqual(leaveAttempts.count, DuoRetry.maximumAttempts + 1)
        for attempt in leaveAttempts {
            XCTAssertEqual(attempt.httpBody, leave.body, "the recorded bytes, every time")
            XCTAssertEqual(attempt.value(forHTTPHeaderField: "Idempotency-Key"), leave.key, "under the recorded key, every time")
        }
        let renameAttempt = try XCTUnwrap(session.requests.first { $0.httpMethod == "PATCH" })
        XCTAssertEqual(renameAttempt.httpBody, rename.body, "a cleared name goes as the null it was saved as, not as an absent field")
        XCTAssertEqual(String(decoding: rename.body, as: UTF8.self), #"{"display_name":null,"skin":"forest"}"#)
        let uploadAttempt = try XCTUnwrap(session.requests.first { $0.httpMethod == "PUT" })
        XCTAssertEqual(uploadAttempt.httpBody, upload.body)
    }

    func testAnUpdateReplayedAfterAWaitIsTheSameTypedRequestAndTheSameLeaveKey() async throws {
        let (kit, service) = makeKit()
        var renameAnswers: [Result<DuoWireMember, DuoTransportError>] = [.failure(.offline), .success(member())]
        kit.transport.onUpdateMe = { _ in try renameAnswers.removeFirst().get() }
        var leaveAnswers: [Result<DuoWireLeaveResponse, DuoTransportError>] = [.failure(.maintenance(DuoErrorContext(httpStatus: 503))),
                                                                                .success(leaveResponse())]
        kit.transport.onLeave = { _, _ in try leaveAnswers.removeFirst().get() }
        let rename = try renameOp(.absent)
        service.enqueue(rename)
        service.enqueue(try leaveOp())

        await drained(service)

        let renames = kit.transport.calls.compactMap { call -> DuoWireUpdateMeRequest? in
            if case .updateMe(let request) = call { return request }
            return nil
        }
        XCTAssertEqual(renames.count, 2)
        XCTAssertEqual(renames[0], renames[1])
        for request in renames { XCTAssertEqual(try DuoWireCoding.encode(request), rename.body, "re-encodes to the very bytes recorded") }
        XCTAssertEqual(leaves(kit.transport), [DuoIdempotencyKey("leave-key"), DuoIdempotencyKey("leave-key")])
        XCTAssertEqual(kit.sleeper.delays, [60], "one retry, at the end of both groups' wait")
    }

    // MARK: - Dispositions

    func testARateLimitWaitsItsRetryAfterWithAFloorOf30SecondsAtMostThreeTriesThenStops() async throws {
        let (kit, service) = makeKit()
        kit.transport.onLeave = { _, _ in throw self.failure(.rateLimited, status: 429, retryAfter: 5) }
        kit.transport.onUpdateMe = { _ in self.member() }
        service.enqueue(try leaveOp())
        service.enqueue(try renameOp())

        await drained(service)

        XCTAssertEqual(leaves(kit.transport).count, 3, "three tries in a row (§6.7), then the next foreground")
        XCTAssertEqual(kit.sleeper.delays, [30, 30], "Retry-After 5 s is waited as the 30-second floor, between the tries")
        XCTAssertEqual(service.pending.map(\.key), ["leave-key"], "nothing is dropped, and the rename in another group went (D74)")

        kit.transport.onLeave = { _, _ in throw self.failure(.rateLimited, status: 429, retryAfter: 120) }
        await drained(service)
        // The trigger came inside the last 30-second window, so it sent nothing and left a retry for
        // the window's end: 90 s on this test's clock, which never moves. Then three more tries.
        XCTAssertEqual(kit.sleeper.delays, [30, 30, 90, 120, 120], "a longer Retry-After is honoured as given")
        XCTAssertEqual(leaves(kit.transport).count, 6, "each trigger gets its own three")

        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        await drained(service)
        XCTAssertTrue(service.pending.isEmpty)
    }

    func testADrainNeverHoldsItsCallerForTheDelayAndATriggerTriesANoConnectionHeadAtOnce() async throws {
        // The sync engine's refresh and a Leave tap await the drain, and must come back after the
        // request, not after the delay. The sleep waits until the test lets it go, so a drain that
        // slept inline would show up as a drain that never returned. (A server's own window is the
        // other case: a trigger inside it sends nothing, `DuoExitRobustnessTests` E4.)
        let (kit, service) = makeKit()
        let delays = EQueueGate()
        kit.dependencies.sleep = { _ in await delays.wait(); try Task.checkCancellation() }
        kit.transport.onLeave = { _, _ in throw DuoTransportError.offline }
        service.enqueue(try leaveOp())

        let finished = EFinishCounter()
        let first = Task { await service.drain(); finished.count += 1 }
        await yield(until: { finished.count == 1 }, "the drain returns without waiting out the delay")
        XCTAssertEqual(leaves(kit.transport).count, 1, "one try, then the drain returns")
        XCTAssertFalse(service.isIdle, "and a retry waits out the delay on its own")
        XCTAssertEqual(service.pending.map(\.key), ["leave-key"])

        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        let second = Task { await service.drain(); finished.count += 1 } // the connection is back, say
        await yield(until: { finished.count == 2 }, "a trigger is not held behind the waiting retry either")
        XCTAssertEqual(leaves(kit.transport).count, 2, "a trigger tries a no-connection head at once")
        XCTAssertTrue(service.pending.isEmpty)
        XCTAssertTrue(service.isIdle, "the waiting retry was let go")

        delays.release() // the delay is up
        await first.value
        await second.value
        await settle()
        XCTAssertEqual(leaves(kit.transport).count, 2, "a retry that was let go sends nothing when its delay ends")
    }

    func testARetryThatWasLetGoSendsNothingEvenIfItsSleepEndsAnyway() async throws {
        // A sleep that ignores the cancel (or a cancel that lands just as the delay ends): the retry
        // a trigger let go must not drain, nor clear the handle of the retry the trigger left on file.
        let (kit, service) = makeKit()
        let sleeps = ESleepTurnstile()
        kit.dependencies.sleep = { _ in await sleeps.wait() }
        kit.transport.onLeave = { _, _ in throw DuoTransportError.offline }
        service.enqueue(try leaveOp())

        await service.drain()
        await yield(until: { sleeps.entered == 1 }, "the first retry is waiting")
        await service.drain() // a trigger: tries at once, lets the first retry go, leaves its own
        XCTAssertEqual(leaves(kit.transport).count, 2)
        await settle()
        XCTAssertEqual(sleeps.entered, 1, "the trigger's retry starts its wait only once the one it replaced has ended")

        sleeps.releaseOldest() // the first retry's delay ends all the same
        await yield(until: { sleeps.entered == 2 }, "then the trigger's retry waits")
        await settle()

        XCTAssertEqual(leaves(kit.transport).count, 2, "the retry that was let go sends nothing")
        XCTAssertFalse(service.isIdle, "and the trigger's retry is still on file, to be let go or run")
        service.discardAll()
        sleeps.openForGood()
        await settle()
        XCTAssertEqual(leaves(kit.transport).count, 2)
    }

    func testADiscardLetsGoOfAWaitingRetry() async throws {
        let (kit, service) = makeKit()
        let delays = EQueueGate()
        kit.dependencies.sleep = { _ in await delays.wait(); try Task.checkCancellation() }
        kit.transport.onLeave = { _, _ in throw DuoTransportError.offline }
        service.enqueue(try leaveOp())
        let finished = EFinishCounter()
        let drain = Task { await service.drain(); finished.count += 1 }
        await yield(until: { finished.count == 1 }, "the drain returns")
        XCTAssertFalse(service.isIdle)

        service.discardAll()

        XCTAssertTrue(service.isIdle, "a new identity's requests are not held behind a retry of the old one's")
        service.enqueue(try renameOp())
        kit.transport.onUpdateMe = { _ in self.member() }
        let next = Task { await service.drain(); finished.count += 1 }
        await yield(until: { finished.count == 2 }, "the new entry goes at once")
        XCTAssertTrue(service.pending.isEmpty)
        delays.release()
        await drain.value
        await next.value
        await settle()
        XCTAssertEqual(leaves(kit.transport).count, 1, "the discarded leave is never sent again")
    }

    func testTheWaitCountIsPerEntryInARowNotPerDrain() async throws {
        let (kit, service) = makeKit()
        var answers: [Result<DuoWireLeaveResponse, DuoTransportError>] = [.failure(.offline), .failure(.offline), .success(leaveResponse())]
        kit.transport.onLeave = { _, _ in try answers.removeFirst().get() }
        var blockAnswers: [Result<Void, DuoTransportError>] = [.failure(.offline), .failure(.offline), .success(())]
        kit.transport.onBlock = { _, _ in try blockAnswers.removeFirst().get() }
        service.enqueue(try leaveOp())
        service.enqueue(try blockOp(otherDuo)) // the same group, behind it

        await drained(service)

        XCTAssertTrue(service.pending.isEmpty, "a settled entry starts the count again for the next one in its group")
        XCTAssertEqual(kit.sleeper.delays, [60, 60, 60, 60])
    }

    func testA401EmptiesTheQueueOnDiskAndForgetsTheIdentity() async throws {
        let (kit, service) = makeKit()
        kit.transport.onUpdateMe = { _ in throw self.failure(.unauthenticated, status: 401) }
        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        endedCardWaiting(kit)
        service.enqueue(try renameOp())
        service.enqueue(try leaveOp())

        await drained(service)

        XCTAssertTrue(service.pending.isEmpty)
        XCTAssertNil(kit.defaults.object(forKey: DuoCache.opsKey))
        XCTAssertTrue(DuoOpQueueService(dependencies: kit.dependencies).pending.isEmpty, "a relaunch finds nothing either")
        XCTAssertTrue(leaves(kit.transport).isEmpty, "a request made with a forgotten identity could only answer 401")
        XCTAssertEqual(kit.identity.discardCount, 1)
        XCTAssertNil(kit.store.duo(DuoFixtures.duoID)?.pendingOp, "nothing is waiting for that card any more")
        XCTAssertTrue(kit.sleeper.delays.isEmpty)
    }

    func testNoCredentialAtSendKeepsTheQueueAndSchedulesNothing() async throws {
        // Status 0: the client had no credential to send with (discarded a moment ago, or one it
        // would not send), so nothing reached a server and nothing was judged.
        let (kit, service) = makeKit()
        kit.transport.onLeave = { _, _ in throw DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0)) }
        kit.transport.onUpdateMe = { _ in self.member() }
        service.enqueue(try leaveOp())
        service.enqueue(try renameOp())

        await drained(service)

        XCTAssertEqual(service.pending.map(\.key), ["leave-key", "rename-key"], "kept, never dropped or discarded")
        XCTAssertEqual(leaves(kit.transport).count, 1, "tried once, then left for the next trigger")
        XCTAssertTrue(kit.sleeper.delays.isEmpty, "no retry is scheduled: waiting a minute changes nothing about a credential")
        XCTAssertEqual(kit.identity.discardCount, 0, "the identity is not forgotten for the client's own refusal")
        XCTAssertNotNil(kit.identity.credential)

        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        await drained(service)
        XCTAssertTrue(service.pending.isEmpty, "the next trigger sends it")
    }

    func testDeviceRevokedDropsTheEntryKeepsTheEndedCardAndGoesOn() async throws {
        let (kit, service) = makeKit()
        endedCardWaiting(kit)
        let before = try XCTUnwrap(kit.store.duo(DuoFixtures.duoID))
        kit.transport.onLeave = { _, _ in throw self.failure(.deviceRevoked, status: 401) }
        kit.transport.onRegisterPush = { _, _ in }
        service.enqueue(try leaveOp())
        let upload = try pushOp()
        service.enqueue(upload)

        await drained(service)

        XCTAssertTrue(service.pending.isEmpty)
        let after = try XCTUnwrap(kit.store.duo(DuoFixtures.duoID))
        XCTAssertEqual(after.endedAt, before.endedAt, "the local ended state is kept (§10.1)")
        XCTAssertEqual(after.endedBy, before.endedBy)
        XCTAssertNil(after.pendingOp, "and nothing claims a leave is still on its way")
        XCTAssertEqual(kit.store.availability, .disconnected)
        XCTAssertEqual(kit.push.finished.map { $0.0.key }, [upload.key], "one revoked answer says nothing about the next entry")
        XCTAssertEqual(kit.push.finished.map(\.1), [true])
    }

    func testALeaveThatAnswersDuoUnknownCountsAsDone() async throws {
        let (kit, service) = makeKit()
        endedCardWaiting(kit)
        kit.transport.onLeave = { _, _ in throw self.failure(.duoUnknown, status: 404) }
        service.enqueue(try leaveOp())

        await drained(service)

        XCTAssertTrue(service.pending.isEmpty)
        let duo = try XCTUnwrap(kit.store.duo(DuoFixtures.duoID))
        XCTAssertTrue(duo.hasEnded)
        XCTAssertNil(duo.pendingOp)
        XCTAssertTrue(kit.sleeper.delays.isEmpty)
        XCTAssertEqual(kit.store.diagnostics.recentErrors.first?.code, "duo_unknown", "noted like every failure")
    }

    func testEveryOther4xxDropsForGood() async throws {
        let cases: [(DuoQueuedOp, DuoTransportError)] = [
            (try leaveOp(), failure(.banned, status: 403)),
            (try blockOp(), failure(.schema, status: 400)),
            (try renameOp(), failure(.nameRejected, status: 422)),
            (try renameOp(), failure(.upgradeRequired, status: 426)),
            (try pushOp(), failure(.attestInvalid, status: 403)),
            (try leaveOp(), DuoTransportError.unreadable(httpStatus: 409, requestID: nil)),
        ]
        for (op, error) in cases {
            let (kit, service) = makeKit()
            kit.transport.onLeave = { _, _ in throw error }
            kit.transport.onBlock = { _, _ in throw error }
            kit.transport.onUpdateMe = { _ in throw error }
            kit.transport.onRegisterPush = { _, _ in throw error }
            service.enqueue(op)
            await drained(service)
            XCTAssertTrue(service.pending.isEmpty, "\(op.kind) with \(error) is dropped")
            XCTAssertTrue(kit.sleeper.delays.isEmpty, "and not retried")
            XCTAssertEqual(kit.transport.calls.count, 1)
        }
    }

    func testNoConnectionKeepsEverythingInOrder() async throws {
        let (kit, service) = makeKit()
        service.enqueue(try leaveOp())
        service.enqueue(try renameOp())
        service.enqueue(try pushOp())

        await drained(service) // every handler unset: offline

        XCTAssertEqual(service.pending.map(\.key), ["leave-key", "rename-key", "push-key"])
        XCTAssertEqual(kit.sleeper.delays, [60, 60], "one retry at a time serves every waiting group")
        XCTAssertEqual(kit.transport.calls.count, 9, "each group's head, three tries each (D74)")
        XCTAssertTrue(kit.push.finished.isEmpty, "a wait is not an answer: the push service is told nothing yet")
    }

    func testACancelledTaskKeepsTheEntryNotesNothingAndSchedulesNothing() async throws {
        let (kit, service) = makeKit()
        kit.transport.onLeave = { _, _ in throw CancellationError() }
        kit.transport.onUpdateMe = { _ in self.member() }
        service.enqueue(try leaveOp())
        service.enqueue(try renameOp())

        await drained(service)

        XCTAssertEqual(service.pending.map(\.key), ["leave-key", "rename-key"])
        XCTAssertTrue(kit.sleeper.delays.isEmpty, "no re-send is scheduled on .cancelled")
        XCTAssertTrue(kit.store.diagnostics.recentErrors.isEmpty, "a cancelled task is not a failure")
        XCTAssertEqual(kit.transport.calls.count, 1)
    }

    func testNoResponseAtAllKeepsTheEntryAndTheNextTriggerReplaysItsKey() async throws {
        let (kit, service) = makeKit()
        kit.transport.onLeave = { _, _ in throw DuoTransportError.unreadable(httpStatus: 0, requestID: nil) }
        service.enqueue(try leaveOp())

        await drained(service)
        XCTAssertEqual(service.pending.map(\.key), ["leave-key"], "it may have landed: kept, to be replayed under its key")
        XCTAssertTrue(kit.sleeper.delays.isEmpty)

        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        await drained(service)
        XCTAssertEqual(leaves(kit.transport), [DuoIdempotencyKey("leave-key"), DuoIdempotencyKey("leave-key")])
        XCTAssertTrue(service.pending.isEmpty)
    }

    func testAnEntryThatNoLongerDecodesIsDroppedRatherThanHoldingUpTheQueue() async throws {
        let (kit, service) = makeKit()
        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        var broken = try renameOp()
        broken.body = Data("not json".utf8)
        service.enqueue(broken)
        service.enqueue(try leaveOp())

        await drained(service)

        XCTAssertTrue(service.pending.isEmpty)
        XCTAssertEqual(leaves(kit.transport).count, 1)
        XCTAssertFalse(kit.transport.calls.contains { if case .updateMe = $0 { return true }; return false }, "nothing undecodable is sent")
    }

    // MARK: - What a success writes

    func testALeaveTakesTheServersEndAndTheCardStopsWaiting() async throws {
        let (kit, service) = makeKit()
        endedCardWaiting(kit)
        kit.transport.onLeave = { _, _ in self.leaveResponse(.partner) }
        service.enqueue(try leaveOp())

        await drained(service)

        let duo = try XCTUnwrap(kit.store.duo(DuoFixtures.duoID))
        XCTAssertEqual(duo.endedAt, Date(timeIntervalSince1970: 1_790_000_500))
        XCTAssertEqual(duo.endedBy, .partner, "the end the server has, which may be the partner's own leave")
        XCTAssertNil(duo.pendingOp)
    }

    func testABlockQueuedBehindALeaveKeepsTheCardWaitingUntilItGoes() async throws {
        let (kit, service) = makeKit()
        endedCardWaiting(kit, .block)
        let gate = EQueueGate()
        let gated = EQueueGatedTransport(kit.transport)
        kit.dependencies.transport = gated
        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        kit.transport.onBlock = { _, _ in }
        service.enqueue(try leaveOp())
        service.enqueue(try blockOp())
        gated.leaveGate = gate

        let drain = Task { await service.drain() }
        await yield(until: { gate.entered == 1 }, "the leave is out")
        gate.release()
        await drain.value

        XCTAssertNil(kit.store.duo(DuoFixtures.duoID)?.pendingOp)
        XCTAssertTrue(service.pending.isEmpty)

        // And with the block refused for now, the card still says a block is on its way.
        let (second, secondService) = makeKit()
        endedCardWaiting(second, .block)
        second.transport.onLeave = { _, _ in self.leaveResponse() }
        secondService.enqueue(try leaveOp())
        secondService.enqueue(try blockOp())
        await drained(secondService) // the block has no handler: offline
        XCTAssertEqual(second.store.duo(DuoFixtures.duoID)?.pendingOp, .block)
    }

    func testAnUpdateTakesTheNameAndSkinTheServerHoldsAndNothingElse() async throws {
        let (kit, service) = makeKit()
        kit.store.memberInfo = memberInfo()
        kit.transport.onUpdateMe = { _ in self.member(name: "Joanna", skin: "forest") }
        service.enqueue(try renameOp())

        await drained(service)

        let info = try XCTUnwrap(kit.store.memberInfo)
        XCTAssertEqual(info.displayName, "Joanna")
        XCTAssertEqual(info.skin, "forest")
        XCTAssertEqual(info.supportID, "ABCD1234EFGH", "the rest of the record is GET /me's to change")
        XCTAssertEqual(info.tier, .low)
        XCTAssertEqual(info.termsVersion, 1)
    }

    func testAnUpdateWithNoMemberRecordYetMakesNone() async throws {
        let (kit, service) = makeKit()
        kit.transport.onUpdateMe = { _ in self.member() }
        service.enqueue(try renameOp())
        await drained(service)
        XCTAssertNil(kit.store.memberInfo)
        XCTAssertTrue(service.pending.isEmpty)
    }

    func testThePushServiceIsToldOfEveryPushEntrySentOrDropped() async throws {
        let (kit, service) = makeKit()
        kit.transport.onRegisterPush = { _, _ in }
        kit.transport.onUnregisterPush = { throw self.failure(.schema, status: 400) }
        let upload = try pushOp()
        let removal = DuoQueuedOp.unregisterPush(key: "unregister-key", now: now)
        service.enqueue(upload)
        service.enqueue(removal)
        service.enqueue(try renameOp())
        kit.transport.onUpdateMe = { _ in self.member() }

        await drained(service)

        XCTAssertEqual(kit.push.finished.map { $0.0 }, [upload, removal], "the push kinds only")
        XCTAssertEqual(kit.push.finished.map(\.1), [true, false], "true when sent, false when dropped for good")
    }

    // MARK: - Only one drain, and the queue on disk

    func testDrainIsSingleFlightAndAJoiningCallerWaitsForTheOneUnderWay() async throws {
        let (kit, service) = makeKit()
        let gate = EQueueGate()
        let gated = EQueueGatedTransport(kit.transport)
        gated.leaveGate = gate
        kit.dependencies.transport = gated
        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        kit.transport.onUpdateMe = { _ in self.member() }
        service.enqueue(try leaveOp())

        let finished = EFinishCounter()
        let first = Task { await service.drain(); finished.count += 1 }
        await yield(until: { gate.entered == 1 }, "the first drain's leave is out")
        let second = Task { await service.drain(); finished.count += 1 }
        service.enqueue(try renameOp())
        await settle()
        XCTAssertEqual(finished.count, 0, "the second call waits for the drain under way rather than returning early")
        gate.release()
        await first.value
        await second.value

        XCTAssertEqual(gate.entered, 1, "one leave went out, not two")
        XCTAssertEqual(leaves(kit.transport).count, 1)
        XCTAssertEqual(kit.transport.calls.last, .updateMe(renameRequest()), "an entry queued while it ran is sent by the same drain")
        XCTAssertTrue(service.pending.isEmpty)
        XCTAssertEqual(finished.count, 2)
    }

    func testTheQueueOutlivesTheServiceThatMadeIt() async throws {
        let (kit, service) = makeKit()
        let leave = try leaveOp()
        let rename = try renameOp()
        service.enqueue(leave)
        service.enqueue(rename)

        let relaunched = DuoOpQueueService(dependencies: kit.dependencies)
        kit.dependencies.ops = relaunched
        XCTAssertEqual(relaunched.pending, [leave, rename], "written to disk at once, bytes and all")

        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        kit.transport.onUpdateMe = { _ in self.member() }
        await drained(relaunched)
        XCTAssertEqual(leaves(kit.transport), [DuoIdempotencyKey(leave.key)])
        XCTAssertTrue(relaunched.pending.isEmpty)
        XCTAssertTrue(service.pending.isEmpty, "both read the one queue on disk")
    }

    func testDiscardAllEmptiesMemoryAndDiskAndANewInstanceFindsNothing() throws {
        let (kit, service) = makeKit()
        endedCardWaiting(kit)
        service.enqueue(try leaveOp())
        service.enqueue(try renameOp())
        XCTAssertNotNil(kit.defaults.object(forKey: DuoCache.opsKey))

        service.discardAll()

        XCTAssertTrue(service.pending.isEmpty)
        XCTAssertNil(kit.defaults.object(forKey: DuoCache.opsKey))
        XCTAssertTrue(DuoOpQueueService(dependencies: kit.dependencies).pending.isEmpty)
        XCTAssertNil(kit.store.duo(DuoFixtures.duoID)?.pendingOp)
    }

    func testAWipeWhileAPushUploadIsOutDropsItsAnswer() async throws {
        // The store alone is reset here, not the queue, so it is the wipe epoch that has to stop
        // the late answer: told of it, the push service would record an upload for an identity the
        // phone has just forgotten, and write the push record back after the wipe.
        let (kit, service) = makeKit()
        let gate = EQueueGate()
        let gated = EQueueGatedTransport(kit.transport)
        gated.registerPushGate = gate
        kit.dependencies.transport = gated
        kit.transport.onRegisterPush = { _, _ in }
        kit.transport.onUpdateMe = { _ in self.member() }
        service.enqueue(try pushOp())
        service.enqueue(try renameOp())

        let drain = Task { await service.drain() }
        await yield(until: { gate.entered == 1 }, "the upload is out")
        kit.store.resetLocalState()
        gate.release()
        await drain.value

        XCTAssertTrue(kit.push.finished.isEmpty, "a late answer is not told to anyone")
        XCTAssertFalse(kit.transport.calls.contains { if case .updateMe = $0 { return true }; return false }, "and the drain stops")
        XCTAssertNil(kit.defaults.object(forKey: DuoCache.opsKey))
        XCTAssertEqual(kit.store.availability, .unknown, "not even a success is noted")
    }

    func testALate401AfterAWipeDoesNotForgetTheIdentityMadeSince() async throws {
        let (kit, service) = makeKit()
        let gate = EQueueGate()
        let gated = EQueueGatedTransport(kit.transport)
        gated.leaveGate = gate
        kit.dependencies.transport = gated
        kit.transport.onLeave = { _, _ in throw self.failure(.unauthenticated, status: 401) }
        service.enqueue(try leaveOp())

        let drain = Task { await service.drain() }
        await yield(until: { gate.entered == 1 }, "the leave is out")
        kit.store.resetLocalState()
        let fresh = DuoCredential(memberID: "6d2a0000-0000-4000-8000-0000000000dd", deviceID: "6d2a0000-0000-4000-8000-0000000000ee",
                                  deviceSecret: String(repeating: "f", count: 43))
        try kit.identity.store(fresh)
        gate.release()
        await drain.value

        XCTAssertEqual(kit.identity.discardCount, 0, "the 401 was about the identity the wipe already let go")
        XCTAssertEqual(kit.identity.credential, fresh)
        XCTAssertTrue(kit.store.diagnostics.recentErrors.isEmpty, "and nothing about it is written after the wipe")
    }

    func testAWipeWhileARenameIsOutWritesNoMemberBack() async throws {
        let (kit, service) = makeKit()
        kit.store.memberInfo = memberInfo()
        let gate = EQueueGate()
        let gated = EQueueGatedTransport(kit.transport)
        gated.updateMeGate = gate
        kit.dependencies.transport = gated
        kit.transport.onUpdateMe = { _ in self.member() }
        service.enqueue(try renameOp())

        let drain = Task { await service.drain() }
        await yield(until: { gate.entered == 1 }, "the rename is out")
        service.discardAll()
        kit.store.resetLocalState()
        kit.store.memberInfo = memberInfo() // a new identity's first GET /me, say
        gate.release()
        await drain.value

        XCTAssertEqual(kit.store.memberInfo?.displayName, "Jo", "the old rename's answer is not written over the new member")
    }

    func testADiscardWhileARequestIsOutStopsTheDrain() async throws {
        let (kit, service) = makeKit()
        let gate = EQueueGate()
        let gated = EQueueGatedTransport(kit.transport)
        gated.leaveGate = gate
        kit.dependencies.transport = gated
        kit.transport.onLeave = { _, _ in throw self.failure(.unauthenticated, status: 401) }
        kit.transport.onUpdateMe = { _ in self.member() }
        service.enqueue(try leaveOp())

        let drain = Task { await service.drain() }
        await yield(until: { gate.entered == 1 }, "the leave is out")
        // Another service met a 401 meanwhile, or the person started fresh, and a new identity has
        // queued a request of its own since.
        service.discardAll()
        service.enqueue(try renameOp())
        gate.release()
        await drain.value

        XCTAssertEqual(kit.identity.discardCount, 0, "the answer to a request from before the discard is not acted on")
        XCTAssertEqual(service.pending.map(\.key), ["rename-key"], "and the new entry is not thrown away with it")
    }

    // MARK: - The network monitor

    func testTheMonitorDrainsOncePerConnectionComingBack() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.identity.launch = .ready
        let factory = EMonitorFactory()
        let service = DuoOpQueueService(dependencies: kit.dependencies, makeMonitor: factory.make)
        kit.dependencies.ops = service
        // Held each time, so each drain sends it exactly once and keeps it.
        kit.transport.onLeave = { _, _ in throw DuoTransportError.unreadable(httpStatus: 0, requestID: nil) }
        service.enqueue(try leaveOp())

        service.startMonitoring()
        service.startMonitoring()
        XCTAssertEqual(factory.made, 1, "idempotent")
        XCTAssertEqual(factory.monitor.starts, 1)

        factory.monitor.reading(true)
        await settle()
        XCTAssertEqual(leaves(kit.transport).count, 0, "the first reading is the state at start, not a change")

        factory.monitor.reading(false)
        await settle()
        XCTAssertEqual(leaves(kit.transport).count, 0, "losing the path drains nothing")

        factory.monitor.reading(true)
        await yield(until: { self.leaves(kit.transport).count == 1 }, "a connection coming back drains")

        factory.monitor.reading(true)
        factory.monitor.reading(true)
        await settle()
        XCTAssertEqual(leaves(kit.transport).count, 1, "a satisfied path after a satisfied one is not a transition")

        factory.monitor.reading(false)
        factory.monitor.reading(true)
        await yield(until: { self.leaves(kit.transport).count == 2 }, "the next transition drains again")
        await settle()
        XCTAssertEqual(leaves(kit.transport).count, 2)
    }

    func testTheMonitorStartingOfflineDrainsWhenTheConnectionComes() async throws {
        let kit = DuoTestKit(credential: DuoFixtures.credential())
        kit.identity.launch = .ready
        let factory = EMonitorFactory()
        let service = DuoOpQueueService(dependencies: kit.dependencies, makeMonitor: factory.make)
        kit.dependencies.ops = service
        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        service.enqueue(try leaveOp())
        service.startMonitoring()

        factory.monitor.reading(false)
        factory.monitor.reading(true)
        await yield(until: { service.pending.isEmpty }, "sent once the path is satisfied")
    }

    // MARK: - The identity comes first

    func testAnEmptyQueueAsksTheIdentityNothing() async throws {
        // A credential and its marker on an install that never settled: its first `prepare()` sends
        // `GET /me` under whoever held the credential. A drain with nothing to send must not.
        let kit = DuoTestKit()
        let identity = DuoIdentity(dependencies: kit.dependencies, directory: temporaryFolder(), holdInBackground: { _ in {} })
        kit.dependencies.identity = identity
        try kit.dependencies.secrets.save(DuoFixtures.credential())
        try kit.dependencies.secrets.writeInstallMarker(random: kit.random)
        let service = DuoOpQueueService(dependencies: kit.dependencies)
        kit.dependencies.ops = service

        await drained(service)

        XCTAssertTrue(kit.transport.calls.isEmpty)
    }

    func testNothingIsSentWithoutACredentialAndOnlyTheIdentitysOwnEntriesGo() async throws {
        let (kit, service) = makeKit(credential: nil)
        kit.transport.onLeave = { _, _ in self.leaveResponse() }
        service.enqueue(try leaveOp())
        service.enqueue(try renameOp())
        service.enqueue(try pushOp())

        await drained(service)

        XCTAssertTrue(kit.transport.calls.isEmpty, "no request without a credential (§3.1)")
        XCTAssertEqual(service.pending.map(\.key), ["leave-key"],
                       "a rename and an upload were for the identity that is gone; a leave waits for a Reconnect into that member")
    }

    func testNothingIsSentWhileTheLaunchCannotTellOrTheRestoreQuestionIsUp() async throws {
        for launch in [DuoIdentityLaunch.unavailable, .needsRestoreChoice(DuoRestorePrompt(partnerName: "Sam", myName: "Jo"))] {
            let (kit, service) = makeKit()
            kit.identity.launch = launch
            kit.transport.onLeave = { _, _ in self.leaveResponse() }
            service.enqueue(try leaveOp())
            await drained(service)
            XCTAssertTrue(kit.transport.calls.isEmpty, "\(launch)")
            XCTAssertEqual(service.pending.map(\.key), ["leave-key"], "kept for the next trigger: \(launch)")
        }
    }

    func testARestoredPhoneRotatesBeforeAnyQueuedRequestGoes() async throws {
        // A credential and no install marker: a restore onto another phone. The monitor can drain
        // before the first refresh, and the queued request must not go under the secret the other
        // phone still holds: the rotate goes first, then `GET /me`, then the queue, with the new secret.
        let kit = DuoTestKit()
        let identity = DuoIdentity(dependencies: kit.dependencies, directory: temporaryFolder(), holdInBackground: { _ in {} })
        kit.dependencies.identity = identity
        try kit.dependencies.secrets.save(DuoFixtures.credential())
        let service = DuoOpQueueService(dependencies: kit.dependencies)
        kit.dependencies.ops = service
        let rotatedSecret = String(repeating: "r", count: 43)
        kit.transport.onRotate = { DuoWireRotateResponse(deviceSecret: rotatedSecret, secretVersion: 2) }
        kit.transport.onMe = { self.meAnswer(duos: []) }
        var sentWith: String?
        kit.transport.onUpdateMe = { _ in sentWith = identity.credential?.deviceSecret; return self.member() }
        service.enqueue(try renameOp())

        await drained(service)

        XCTAssertEqual(kit.transport.calls, [.rotate, .me, .updateMe(renameRequest())])
        XCTAssertEqual(sentWith, rotatedSecret, "sent with the rotated secret, never the one the other phone holds")
        XCTAssertTrue(service.pending.isEmpty)
    }

    func testNothingAtAllIsSentOrChangedWhileTheRestoreQuestionIsUp() async throws {
        let kit = DuoTestKit()
        let identity = DuoIdentity(dependencies: kit.dependencies, directory: temporaryFolder(), holdInBackground: { _ in {} })
        kit.dependencies.identity = identity
        try kit.dependencies.secrets.save(DuoFixtures.credential())
        let service = DuoOpQueueService(dependencies: kit.dependencies)
        kit.dependencies.ops = service
        kit.transport.onRotate = { DuoWireRotateResponse(deviceSecret: String(repeating: "r", count: 43), secretVersion: 2) }
        kit.transport.onMe = { self.meAnswer(duos: [DuoFixtures.wireHeader()]) }
        kit.transport.onUpdateMe = { _ in self.member() }
        kit.transport.onRegisterPush = { _, _ in }
        let rename = try renameOp()
        service.enqueue(rename)
        service.enqueue(try pushOp())

        await drained(service)
        await drained(service)

        XCTAssertEqual(kit.transport.calls, [.rotate, .me], "the launch's own two, then nothing until the person answers")
        if case .needsRestoreChoice = kit.store.availability {} else { XCTFail("the question is up: \(kit.store.availability)") }
        XCTAssertEqual(service.pending.map(\.key), ["rename-key", "push-key"], "nothing dropped, nothing sent")
        XCTAssertTrue(kit.push.finished.isEmpty)
    }

    private func meAnswer(duos: [DuoWireHeader]) -> DuoWireGetMeResponse {
        let credential = DuoFixtures.credential()
        return DuoWireGetMeResponse(
            member: DuoWireMember(id: credential.memberID, displayName: "Jo", skin: "classic", supportId: "ABCD1234EFGH", tier: .low, termsVersion: 1),
            limits: DuoWireLimits(nudgesPerDay: 1, maxActiveDuos: 1),
            devices: [DuoWireDevice(id: credential.deviceID, platform: "ios", createdAt: Date(timeIntervalSince1970: 1_789_000_000),
                                    thisDevice: true, superseded: false)],
            duos: duos, minClient: DuoWireMinClient(ios: "2.0", android: "2.0"))
    }
}
#endif
