import XCTest
@testable import HydroCore

/// The per-row verdicts of a status write, applied to what this phone knows (final design §6.5,
/// §10.2, §10.3, §10.5; KV11, X7).
final class DuoRebaseTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private let server = Date(timeIntervalSince1970: 1_790_000_500)
    private let today = "2026-09-21"
    private let yesterday = "2026-09-20"

    private func mine(_ day: String, _ bucket: Int, at: Date? = nil) -> DuoDayStatus {
        DuoDayStatus(role: .owner, day: day, goalMet: bucket == 100, progressBucket: bucket, updatedAt: at ?? now)
    }

    private func row(_ day: String, _ bucket: Int, ver: Int64, role: DuoRole = .owner) -> DuoWireStatusRow {
        DuoWireStatusRow(role: role, day: day, goalMet: bucket == 100, progressBucket: bucket, updatedAt: server, ver: ver)
    }

    private func apply(sent: [DuoDayStatus], accepted: [String] = [], unchanged: [String] = [], rejected: [DuoWireRejected] = [],
                       known: [DuoDayStatus] = [], vers: [String: Int64] = [:], refused: DuoRejectedDays = DuoRejectedDays()) -> DuoRebase.Outcome {
        DuoRebase.apply(sent: sent, accepted: accepted, unchanged: unchanged, rejected: rejected, role: .owner, statuses: known,
                        vers: vers, rejectedDays: refused)
    }

    func testAnAcceptedRowNeedsNothingSinceTheFeedBroughtIt() {
        // The feed's row (with the server's time and ver) is already in what is known.
        let fromFeed = DuoDayStatus(role: .owner, day: today, goalMet: false, progressBucket: 50, updatedAt: server)
        let outcome = apply(sent: [mine(today, 50)], accepted: [today], known: [fromFeed], vers: ["owner-\(today)": 4])
        XCTAssertEqual(outcome.statuses, [fromFeed], "the sent row (this phone's clock) never replaces the server's (X8)")
        XCTAssertEqual(outcome.vers, ["owner-\(today)": 4])
        XCTAssertFalse(outcome.needsRetry)
        XCTAssertTrue(outcome.rejectedDays.isEmpty)
        XCTAssertTrue(outcome.heldRows.isEmpty)
    }

    func testAnAcceptedRowTheFeedLeftOutIsNotTakenOnTrust() {
        // `known` advances only from server-stamped rows (§10.1): the next diff sends it again
        // and the CAS answers `unchanged` or a conflict that re-bases it.
        let outcome = apply(sent: [mine(today, 50)], accepted: [today])
        XCTAssertTrue(outcome.statuses.isEmpty)
        XCTAssertTrue(outcome.vers.isEmpty)
    }

    func testAnUnchangedRowBecomesWhatIsKnownAndKeepsTheServersTime() {
        let older = DuoDayStatus(role: .owner, day: today, goalMet: false, progressBucket: 25, updatedAt: server)
        let outcome = apply(sent: [mine(today, 50), mine(yesterday, 75)], unchanged: [today, yesterday], known: [older], vers: ["owner-\(today)": 2])
        XCTAssertEqual(outcome.statuses.count, 2)
        XCTAssertEqual(outcome.statuses.first { $0.day == today }, DuoDayStatus(role: .owner, day: today, goalMet: false, progressBucket: 50, updatedAt: server))
        XCTAssertEqual(outcome.statuses.first { $0.day == yesterday }, mine(yesterday, 75))
        XCTAssertEqual(outcome.vers, ["owner-\(today)": 2], "the stored ver is not told, so it is left as it was")
        XCTAssertFalse(outcome.needsRetry)
        XCTAssertTrue(outcome.rejectedDays.isEmpty)
    }

    func testAConflictWithCurrentTakesTheServersRowAndItsVer() {
        // KV11: sent with base_ver 37, the server holds ver 40.
        let outcome = apply(sent: [mine(today, 50)], rejected: [DuoWireRejected(day: today, reason: .verConflict, current: row(today, 75, ver: 40))],
                            known: [mine(today, 25)], vers: ["owner-\(today)": 37])
        XCTAssertEqual(outcome.statuses, [DuoDayStatus(role: .owner, day: today, goalMet: false, progressBucket: 75, updatedAt: server)])
        XCTAssertEqual(outcome.vers, ["owner-\(today)": 40])
        XCTAssertTrue(outcome.needsRetry)
        XCTAssertTrue(outcome.rejectedDays.isEmpty, "a conflict is settled by re-basing, never by poisoning the day (§10.2)")
        XCTAssertTrue(outcome.heldRows.isEmpty)
    }

    func testAConflictWithoutCurrentMeansTheServerHoldsNoRowSoTheDaysVerGoes() {
        // §10.3: no `current` is ver 0. Keeping ver 37 would send it, and be refused, on every flush.
        let outcome = apply(sent: [mine(today, 50)], rejected: [DuoWireRejected(day: today, reason: .verConflict)],
                            known: [mine(today, 25), mine(yesterday, 100)], vers: ["owner-\(today)": 37, "owner-\(yesterday)": 3])
        XCTAssertEqual(outcome.statuses, [mine(yesterday, 100)])
        XCTAssertEqual(outcome.vers, ["owner-\(yesterday)": 3])
        XCTAssertTrue(outcome.needsRetry)
        XCTAssertTrue(outcome.rejectedDays.isEmpty)
    }

    func testARefusedDowngradeIsAdoptedNeverRetriedInTheSlotAndNeverPoisoned() {
        let outcome = apply(sent: [mine(yesterday, 0)], rejected: [DuoWireRejected(day: yesterday, reason: .downgradeRefused, current: row(yesterday, 100, ver: 6))],
                            known: [], vers: [:])
        XCTAssertEqual(outcome.statuses, [DuoDayStatus(role: .owner, day: yesterday, goalMet: true, progressBucket: 100, updatedAt: server)])
        XCTAssertEqual(outcome.vers, ["owner-\(yesterday)": 6])
        XCTAssertFalse(outcome.needsRetry, "a refused downgrade alone asks for no second write")
        XCTAssertEqual(outcome.heldRows, [mine(yesterday, 0)], "held back by the caller, the row that was sent")
        XCTAssertTrue(outcome.rejectedDays.isEmpty, "never poisoned (§10.2)")
    }

    func testARefusedDowngradeIsHeldOutOfTheRetryThatAConflictBesideItAsksFor() {
        let outcome = apply(sent: [mine(today, 50), mine(yesterday, 0)],
                            rejected: [DuoWireRejected(day: today, reason: .verConflict, current: row(today, 25, ver: 9)),
                                       DuoWireRejected(day: yesterday, reason: .downgradeRefused, current: row(yesterday, 100, ver: 6))])
        XCTAssertTrue(outcome.needsRetry)
        XCTAssertEqual(outcome.heldRows, [mine(yesterday, 0)])
    }

    func testTheRowRulesRecordTheSentRowSoItIsSkippedUntilItChanges() {
        let sent = [mine("2026-09-01", 25), mine("2026-09-30", 50), mine(today, 75)]
        let outcome = apply(sent: sent, rejected: [
            DuoWireRejected(day: "2026-09-01", reason: .dayOutOfRange),
            DuoWireRejected(day: "2026-09-30", reason: .dayAfterToday),
            DuoWireRejected(day: today, reason: .statusInconsistent),
        ])
        for row in sent { XCTAssertTrue(outcome.rejectedDays.blocks(row), row.day) }
        XCTAssertTrue(outcome.heldRows.isEmpty)
        XCTAssertFalse(outcome.rejectedDays.blocks(mine(today, 100)), "what is wanted changed, so it may be sent")
        XCTAssertFalse(outcome.needsRetry)
        XCTAssertTrue(outcome.statuses.isEmpty, "nothing refused becomes known")
    }

    func testAReasonThisBuildDoesNotKnowIsHeldInMemoryNotPoisonedOnDisk() {
        let outcome = apply(sent: [mine(yesterday, 25)], rejected: [DuoWireRejected(day: yesterday, reason: .unknown)])
        XCTAssertTrue(outcome.rejectedDays.isEmpty, "a newer server's reason may mean anything: nothing kept for nine days")
        XCTAssertEqual(outcome.heldRows, [mine(yesterday, 25)])
        XCTAssertFalse(outcome.needsRetry)
    }

    func testARefusalForADayThatWasNotSentPoisonsNothing() {
        let outcome = apply(sent: [mine(today, 50)], rejected: [DuoWireRejected(day: yesterday, reason: .dayOutOfRange)])
        XCTAssertTrue(outcome.rejectedDays.isEmpty)
    }

    func testACurrentInThePartnersRoleOrThatCannotBeHeldIsIgnored() {
        let partners = apply(sent: [mine(today, 50)], rejected: [DuoWireRejected(day: today, reason: .verConflict, current: row(today, 75, ver: 4, role: .partner))],
                             known: [mine(today, 25)], vers: ["owner-\(today)": 3])
        XCTAssertEqual(partners.statuses, [mine(today, 25)])
        XCTAssertEqual(partners.vers, ["owner-\(today)": 3])
        XCTAssertFalse(partners.needsRetry)
        let broken = apply(sent: [mine(today, 50)], rejected: [DuoWireRejected(day: today, reason: .verConflict, current: row(today, 60, ver: 4))],
                           known: [mine(today, 25)], vers: ["owner-\(today)": 3])
        XCTAssertEqual(broken.vers, ["owner-\(today)": 3])
        XCTAssertFalse(broken.needsRetry)
    }

    func testAReplayedAcceptedWriteReBasesToWhatIsAlreadyKnownAndLeavesNothingToSend() throws {
        // X7: the first write was accepted (ver 4) but its answer was lost; the replay of the same
        // bytes (base_ver 3) is refused with a `current` equal to what was sent.
        let calendar: Calendar = {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            return calendar
        }()
        let summary = DuoLogSummary(totalsByDay: [today: 1000], goalML: 2000, earliestEntryDay: "2026-01-01")
        var duo = DuoState(id: UUID(), myRole: .owner, createdAt: now, ownerDisplayName: "Jo", partnerDisplayName: "Sam", ownerSkin: "classic",
                           partnerSkin: "forest", statuses: [mine(today, 25)], partnerHasJoined: true, cursor: 10, vers: ["owner-\(today)": 3],
                           syncedOnce: true)
        let first = try XCTUnwrap(DuoSyncPlan.write(for: duo, summary: summary, coverageStart: "2026-01-01", rejectedDays: DuoRejectedDays(),
                                                    myToday: today, now: now, calendar: calendar).write)
        XCTAssertEqual(first.request.statuses, [DuoWireStatusIn(day: today, goalMet: false, progressBucket: 50, baseVer: 3)])
        let replay = DuoWireChangesWithResult(changes: DuoWireChanges(duo: DuoWireHeader(id: duo.wireID, myRole: .owner, state: .active, seq: 11),
                                                                      full: false, statuses: [], nudges: [], handled: [], cursor: 11),
                                              accepted: [], unchanged: [], rejected: [DuoWireRejected(day: today, reason: .verConflict, current: row(today, 50, ver: 4))])
        let (rebased, outcome) = DuoRebase.apply(replay, sent: first.rows, to: duo, rejectedDays: DuoRejectedDays())
        XCTAssertTrue(outcome.needsRetry)
        duo = rebased
        XCTAssertNil(DuoSyncPlan.write(for: duo, summary: summary, coverageStart: "2026-01-01", rejectedDays: outcome.rejectedDays,
                                       holding: outcome.heldRows, myToday: today, now: now, calendar: calendar).write,
                     "the re-diff is empty, so there is no third request")
    }
}
