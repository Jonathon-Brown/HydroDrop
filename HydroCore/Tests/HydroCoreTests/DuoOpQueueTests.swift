import XCTest
@testable import HydroCore

/// The op queue's model (final design §10.1): its order, its removals, how it is kept, and the
/// disposition table row by row, every one of the contract's 34 codes included, so a code added
/// later fails to compile here until someone decides what it does to a queued request.
final class DuoOpQueueTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let duoA = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!
    private let duoB = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000002")!

    private func leave(_ duo: UUID? = nil, key: String = "k-leave") throws -> DuoQueuedOp {
        try DuoQueuedOp.leave(duoID: duo ?? duoA, key: key, now: now)
    }

    private func block(_ duo: UUID? = nil, key: String = "k-block") throws -> DuoQueuedOp {
        try DuoQueuedOp.block(duoID: duo ?? duoA, key: key, now: now)
    }

    private func rename(_ name: String, key: String) throws -> DuoQueuedOp {
        try DuoQueuedOp.updateMe(DuoWireUpdateMeRequest(displayName: .value(name)), key: key, now: now)
    }

    private func push(key: String = "k-push") throws -> DuoQueuedOp {
        try DuoQueuedOp.registerPush(DuoWireRegisterPushRequest(token: "ab", apnsEnv: "sandbox", tz: "UTC", wakeStartMin: nil, wakeEndMin: nil,
                                                                notificationsEnabled: false), firstUpload: true, key: key, now: now)
    }

    private func error(_ code: DuoErrorCode, status: Int, retryAfter: Int? = nil) -> DuoTransportError {
        DuoTransportError(code: code, context: DuoErrorContext(httpStatus: status, requestID: "r", retryAfter: retryAfter))
    }

    // MARK: - Order and removal

    func testTheQueueIsFirstInFirstOutAndNeverCoalesces() throws {
        var queue = DuoOpQueue()
        XCTAssertTrue(queue.isEmpty)
        XCTAssertNil(queue.next)
        let first = try rename("Jo", key: "1")
        let second = try leave(key: "2")
        let third = try rename("Joanna", key: "3")
        queue.enqueue(first)
        queue.enqueue(second)
        queue.enqueue(third)
        XCTAssertEqual(queue.ops.map(\.key), ["1", "2", "3"], "two renames stay two entries, in the order they were made")
        XCTAssertEqual(queue.next, first)
        queue.remove(key: "1")
        XCTAssertEqual(queue.next, second)
        queue.remove(key: "2")
        XCTAssertEqual(queue.next, third)
    }

    func testTheSameEntryHandedOverTwiceIsKeptOnce() throws {
        var queue = DuoOpQueue()
        let op = try leave()
        XCTAssertEqual(queue.enqueue(op), .added)
        XCTAssertEqual(queue.enqueue(op), .alreadyQueued)
        XCTAssertEqual(queue.ops, [op], "one key is one request; two copies would be sent twice")
    }

    func testAnotherEntryUnderAQueuedKeyIsRefusedAndTheFirstKept() throws {
        // Probe P11 of the stage E queue review: the second upload under one key used to vanish
        // without a word. It is still refused (its bytes may already be on the server under that
        // key), but now it says so, and the app treats it as a programming error in Debug.
        var queue = DuoOpQueue()
        let first = try DuoQueuedOp.registerPush(DuoWireRegisterPushRequest(token: "old", apnsEnv: nil, tz: nil, wakeStartMin: nil, wakeEndMin: nil,
                                                                            notificationsEnabled: true), firstUpload: false, key: "push", now: now)
        let second = try DuoQueuedOp.registerPush(DuoWireRegisterPushRequest(token: "new", apnsEnv: nil, tz: nil, wakeStartMin: nil, wakeEndMin: nil,
                                                                             notificationsEnabled: false), firstUpload: false, key: "push", now: now)
        XCTAssertEqual(queue.enqueue(first), .added)
        XCTAssertEqual(queue.enqueue(second), .conflicting)
        XCTAssertEqual(queue.ops, [first])
    }

    // MARK: - The groups (D74)

    func testEveryKindBelongsToItsGroup() {
        XCTAssertEqual(DuoOpQueue.group(of: .leave), .exits)
        XCTAssertEqual(DuoOpQueue.group(of: .block), .exits)
        XCTAssertEqual(DuoOpQueue.group(of: .updateMe), .profile)
        XCTAssertEqual(DuoOpQueue.group(of: .registerPush), .push)
        XCTAssertEqual(DuoOpQueue.group(of: .unregisterPush), .push)
    }

    func testAWaitingGroupHoldsBackOnlyItsOwnEntries() throws {
        let queue = DuoOpQueue([try rename("Jo", key: "r1"), try rename("Joanna", key: "r2"), try block(key: "b"), try push(key: "p"),
                                try leave(duoB, key: "l")])
        XCTAssertEqual(queue.next(skipping: [])?.key, "r1", "the oldest of all when nothing waits")
        XCTAssertEqual(queue.next(skipping: [.profile])?.key, "b", "a rate-limited rename does not hold a block back")
        XCTAssertEqual(queue.next(skipping: [.profile, .exits])?.key, "p")
        XCTAssertNil(queue.next(skipping: [.profile, .exits, .push]))
    }

    func testWithinAGroupTheOrderIsStrict() throws {
        let queue = DuoOpQueue([try block(key: "b"), try rename("Jo", key: "r"), try leave(duoB, key: "l")])
        XCTAssertEqual(queue.next(skipping: [.profile])?.key, "b", "the head of the exits")
        XCTAssertNil(queue.next(skipping: [.exits, .profile]), "the leave behind a waiting block is not sent before it")
        let pushes = DuoOpQueue([try push(key: "up"), DuoQueuedOp.unregisterPush(key: "down", now: now)])
        XCTAssertEqual(pushes.next(skipping: [])?.key, "up")
        XCTAssertNil(pushes.next(skipping: [.push]), "a removal never overtakes the upload it follows")
    }

    func testADrainSendsOnlyTheEntriesItFoundWhenItBegan() throws {
        let queue = DuoOpQueue([try block(key: "old"), try push(key: "new")])
        XCTAssertEqual(queue.next(skipping: [.exits], among: ["old"])?.key, nil, "an entry queued since waits for the next drain")
        XCTAssertEqual(queue.next(skipping: [], among: ["old"])?.key, "old")
        let behind = DuoOpQueue([try rename("Jo", key: "late"), try block(key: "found")])
        XCTAssertEqual(behind.next(skipping: [], among: ["found"])?.key, "found")
        // A group's later entry is never picked over its head, whichever keys are offered.
        let group = DuoOpQueue([try block(key: "head"), try leave(duoB, key: "behind")])
        XCTAssertNil(group.next(skipping: [], among: ["behind"]), "the leave is not sent before the block it was queued after")
    }

    func testANewIdentityTakesTheRenamesAndPushEntriesButKeepsTheExits() throws {
        var queue = DuoOpQueue([try rename("Jo", key: "r"), try leave(key: "l"), try push(key: "p"), DuoQueuedOp.unregisterPush(key: "u", now: now),
                                try block(duoB, key: "b")])
        queue.removeIdentityBound()
        XCTAssertEqual(queue.ops.map(\.key), ["l", "b"])
    }

    func testOnlyNoConnectionIsNotTheServersOwnWait() throws {
        XCTAssertFalse(DuoOpQueue.isServerWait(DuoTransportError.offline))
        XCTAssertTrue(DuoOpQueue.isServerWait(error(.rateLimited, status: 429, retryAfter: 60)))
        XCTAssertTrue(DuoOpQueue.isServerWait(error(.maintenance, status: 503)))
        XCTAssertTrue(DuoOpQueue.isServerWait(DuoTransportError.unreadable(httpStatus: 502, requestID: nil)))
        XCTAssertFalse(DuoOpQueue.isServerWait(nil))
        XCTAssertFalse(DuoOpQueue.isServerWait(CancellationError()))
    }

    func testRemovalIsByKeyNotByPosition() throws {
        var queue = DuoOpQueue([try rename("Jo", key: "1"), try leave(key: "2"), try rename("Sam", key: "3")])
        queue.remove(key: "2")
        XCTAssertEqual(queue.ops.map(\.key), ["1", "3"])
        queue.remove(key: "absent")
        XCTAssertEqual(queue.ops.map(\.key), ["1", "3"], "a key that is not there removes nothing")
    }

    func testRemoveAllForADuoTakesItsLeaveAndBlockAndNothingElse() throws {
        var queue = DuoOpQueue([try leave(duoA, key: "a-leave"), try rename("Jo", key: "rename"), try block(duoB, key: "b-block"),
                                try block(duoA, key: "a-block"), try push()])
        queue.removeAll(forDuo: duoA)
        XCTAssertEqual(queue.ops.map(\.key), ["rename", "b-block", "k-push"])
    }

    func testRemoveAllForADuoMatchesAnIdInAnyCase() throws {
        var shouty = try leave(duoA, key: "upper")
        shouty.duoID = duoA.uuidString.uppercased()
        var queue = DuoOpQueue([shouty])
        queue.removeAll(forDuo: duoA)
        XCTAssertTrue(queue.isEmpty)
    }

    func testRemoveAllEmptiesTheQueue() throws {
        var queue = DuoOpQueue([try leave(), try push()])
        queue.removeAll()
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: - Kept

    func testTheQueueRoundTripsAndIsSavedAsTheBareArrayTheCacheKeeps() throws {
        let ops = [try leave(), try rename("Jo", key: "r"), try push(), DuoQueuedOp.unregisterPush(key: "u", now: now)]
        let queue = DuoOpQueue(ops)
        let encoded = try JSONEncoder().encode(queue)
        XCTAssertEqual(try JSONDecoder().decode(DuoOpQueue.self, from: encoded), queue)
        // A plain encoder does not promise one key order from one call to the next, so the two
        // shapes are compared with the keys sorted.
        let sorted = JSONEncoder()
        sorted.outputFormatting = .sortedKeys
        XCTAssertEqual(try sorted.encode(queue), try sorted.encode(ops), "the shape `DuoCache.saveOps` writes, so either reads the other")
        XCTAssertEqual(try JSONDecoder().decode(DuoOpQueue.self, from: try JSONEncoder().encode(ops)).ops, ops)
        let decoded = try JSONDecoder().decode(DuoOpQueue.self, from: encoded)
        XCTAssertEqual(decoded.ops.map(\.body), ops.map(\.body), "the exact bytes to replay survive being kept")
        XCTAssertEqual(decoded.ops[2].attestsFirstUpload, true)
    }

    // MARK: - The disposition table

    /// Every code at the status contract-v1 sends it with, on a leave and on a rename. The switch
    /// has no default, so a new code is a compile error here.
    func testEveryCodeAtItsOwnStatusDoesWhatSection10Point1Says() throws {
        let leaveOp = try leave()
        let blockOp = try block()
        let renameOp = try rename("Jo", key: "r")
        for code in DuoErrorCode.allCases {
            let status: Int
            let onLeave: DuoOpQueue.Disposition
            var onRename: DuoOpQueue.Disposition?
            switch code {
            case .schema: status = 400; onLeave = .drop
            case .idempotencyMismatch: status = 422; onLeave = .drop
            case .unauthenticated: status = 401; onLeave = .discardAll
            case .deviceRevoked: status = 401; onLeave = .drop
            case .banned: status = 403; onLeave = .drop
            case .blocked, .notPartner, .attestRequired, .attestInvalid: status = 403; onLeave = .drop
            case .duoUnknown: status = 404; onLeave = .done; onRename = .drop
            case .inviteUnknown: status = 404; onLeave = .drop
            case .inviteTaken, .inviteOwn, .wrongPurpose, .alreadyInDuo, .duoLimit, .deviceLimit, .pendingExists, .memberNotFresh,
                 .targetActive, .duoPending, .partnerAlreadyMet, .conflict:
                status = 409; onLeave = .drop
            case .duoEnded: status = 409; onLeave = .done; onRename = .drop
            case .payloadTooLarge: status = 413; onLeave = .drop
            case .nameRejected, .presetUnknown, .dayOutOfRange, .senderDayOutOfRange: status = 422; onLeave = .drop
            case .upgradeRequired: status = 426; onLeave = .drop
            case .termsRequired: status = 428; onLeave = .drop
            case .nudgeLimit, .rateLimited: status = 429; onLeave = .wait(after: DuoRetry.fallbackDelay)
            case .maintenance: status = 503; onLeave = .wait(after: DuoRetry.fallbackDelay)
            }
            let failure = error(code, status: status)
            XCTAssertEqual(DuoOpQueue.disposition(for: leaveOp, error: failure), onLeave, "\(code.rawValue) at \(status) on a leave")
            XCTAssertEqual(DuoOpQueue.disposition(for: blockOp, error: failure), onLeave, "\(code.rawValue) at \(status) on a block")
            XCTAssertEqual(DuoOpQueue.disposition(for: renameOp, error: failure), onRename ?? onLeave, "\(code.rawValue) at \(status) on a rename")
        }
    }

    func testASuccessIsDone() throws {
        for op in [try leave(), try block(), try rename("Jo", key: "r"), try push(), DuoQueuedOp.unregisterPush(key: "u", now: now)] {
            XCTAssertEqual(DuoOpQueue.disposition(for: op, error: nil), .done, "\(op.kind)")
        }
    }

    func testTheClientsOwnNoCredentialIsHeldNeverDiscardedOrDropped() throws {
        let noCredential = DuoTransportError.unauthenticated(DuoErrorContext(httpStatus: 0))
        for op in [try leave(), try rename("Jo", key: "r"), try push()] {
            XCTAssertEqual(DuoOpQueue.disposition(for: op, error: noCredential), .hold,
                           "nothing left the phone, so nothing was judged: the next trigger tries again")
        }
        XCTAssertEqual(DuoOpQueue.disposition(for: try leave(), error: error(.unauthenticated, status: 401)), .discardAll,
                       "only the server's own 401 means the identity is gone")
    }

    func testACancelledTaskHoldsTheEntryAndSchedulesNothing() throws {
        XCTAssertEqual(DuoOpQueue.disposition(for: try leave(), error: CancellationError()), .hold)
        XCTAssertEqual(DuoOpQueue.disposition(for: try rename("Jo", key: "r"), error: CancellationError()), .hold)
    }

    func testAnAnswerThatCannotBeReadIsJudgedByItsStatus() throws {
        let op = try leave()
        func unreadable(_ status: Int) -> DuoOpQueue.Disposition {
            DuoOpQueue.disposition(for: op, error: DuoTransportError.unreadable(httpStatus: status, requestID: nil))
        }
        XCTAssertEqual(unreadable(200), .done, "a leave's own success status: it landed, whatever its body says")
        XCTAssertEqual(unreadable(204), .wait(after: 60), "not a leave's status: not the server's answer")
        XCTAssertEqual(unreadable(0), .hold, "no HTTP response at all says nothing")
        XCTAssertEqual(unreadable(401), .wait(after: 60), "a 401 with a code this build does not know is neither the server forgetting us nor a refusal")
        XCTAssertEqual(unreadable(404), .drop, "a 4xx is a refusal whatever its code")
        XCTAssertEqual(unreadable(409), .drop)
        XCTAssertEqual(unreadable(429), .wait(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(unreadable(500), .wait(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(unreadable(599), .wait(after: DuoRetry.fallbackDelay))
    }

    func testAnUnreadable2xxIsDoneOnlyAtTheKindsOwnSuccessStatus() throws {
        // A filtering proxy answers a block's URL with a 200 page; the block's own status is 204,
        // so the client reads the page as `unreadable(200)` and the server never saw the request.
        XCTAssertEqual(DuoOpQueue.successStatus(of: .leave), 200)
        XCTAssertEqual(DuoOpQueue.successStatus(of: .updateMe), 200)
        XCTAssertEqual(DuoOpQueue.successStatus(of: .block), 204)
        XCTAssertEqual(DuoOpQueue.successStatus(of: .registerPush), 204)
        XCTAssertEqual(DuoOpQueue.successStatus(of: .unregisterPush), 204)
        let page = DuoTransportError.unreadable(httpStatus: 200, requestID: nil)
        XCTAssertEqual(DuoOpQueue.disposition(for: try block(), error: page), .wait(after: 60))
        XCTAssertEqual(DuoOpQueue.disposition(for: try push(), error: page), .wait(after: 60))
        XCTAssertEqual(DuoOpQueue.disposition(for: DuoQueuedOp.unregisterPush(key: "u", now: now), error: page), .wait(after: 60))
        XCTAssertEqual(DuoOpQueue.disposition(for: try rename("Jo", key: "r"), error: page), .done, "a PATCH /me answers 200")
        XCTAssertEqual(DuoOpQueue.disposition(for: try leave(), error: DuoTransportError.unreadable(httpStatus: 202, requestID: nil)), .wait(after: 60))
    }

    func testNoConnectionWaitsAMinute() throws {
        XCTAssertEqual(DuoOpQueue.disposition(for: try leave(), error: DuoTransportError.offline), .wait(after: 60))
        XCTAssertEqual(DuoOpQueue.disposition(for: try push(), error: DuoTransportError.offline), .wait(after: 60))
    }

    func testARateLimitWaitsItsRetryAfterWithTheFloorAndTheCeiling() throws {
        let op = try leave()
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.rateLimited, status: 429, retryAfter: 5)), .wait(after: 30),
                       "§6.7: Retry-After is honoured with a floor of 30 s")
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.rateLimited, status: 429, retryAfter: 30)), .wait(after: 30))
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.rateLimited, status: 429, retryAfter: 120)), .wait(after: 120))
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.rateLimited, status: 429, retryAfter: 2_147_483_647)),
                       .wait(after: DuoRetry.maximumDelay), "a proxy's absurd number does not park the queue for decades")
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.rateLimited, status: 429)), .wait(after: 60))
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.maintenance, status: 503, retryAfter: 90)), .wait(after: 90))
    }

    func testMaintenanceWaitsWhateverStatusItCameWith() throws {
        // The classifier makes a WAF's 403, a captive portal's bare 401 (D63) and a refused redirect
        // `maintenance`; none is the server's refusal, so none may drop or discard anything.
        let op = try leave()
        for status in [401, 403, 302, 503, 502] {
            XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.maintenance, status: status)), .wait(after: 60), "\(status)")
        }
    }

    func testACodedAnswerAtA5xxOrA429WaitsAndAt401Waits() throws {
        let op = try rename("Jo", key: "r")
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.schema, status: 500)), .wait(after: 60),
                       "§10.1 removes only on a 2xx or a 4xx: a 5xx is not a refusal whatever it says")
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.conflict, status: 503, retryAfter: 45)), .wait(after: 45))
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.schema, status: 429)), .wait(after: 60))
        XCTAssertEqual(DuoOpQueue.disposition(for: op, error: error(.schema, status: 401)), .wait(after: 60),
                       "a 401 is never removed (§10.1), and only the client's own status 0 holds")
    }

    func testTheClientRefusingToBuildARequestDropsIt() throws {
        // The app's real transport throws `schema` at status 0 for a duo id that is not a lowercase UUID, or a
        // body it cannot encode: such an entry can never leave the phone, and kept it would hold up
        // everything behind it for good.
        XCTAssertEqual(DuoOpQueue.disposition(for: try leave(), error: error(.schema, status: 0)), .drop)
    }

    func testAnErrorThatIsNotTheTransportsDropsTheEntry() throws {
        struct Undecodable: Error {}
        XCTAssertEqual(DuoOpQueue.disposition(for: try rename("Jo", key: "r"), error: Undecodable()), .drop)
        XCTAssertEqual(DuoOpQueue.disposition(for: try rename("Jo", key: "r"),
                                              error: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "x"))), .drop)
    }

    func testTheEndedCodesAreDoneOnlyForALeaveOrABlock() throws {
        for code in [DuoErrorCode.duoUnknown, .duoEnded] {
            let status = code == .duoUnknown ? 404 : 409
            XCTAssertEqual(DuoOpQueue.disposition(for: try leave(), error: error(code, status: status)), .done)
            XCTAssertEqual(DuoOpQueue.disposition(for: try block(), error: error(code, status: status)), .done)
            XCTAssertEqual(DuoOpQueue.disposition(for: try push(), error: error(code, status: status)), .drop)
            XCTAssertEqual(DuoOpQueue.disposition(for: DuoQueuedOp.unregisterPush(key: "u", now: now), error: error(code, status: status)), .drop)
        }
    }
}
