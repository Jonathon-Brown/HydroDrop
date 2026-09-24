import XCTest
import CloudKit
@testable import HydroDrop

/// A duo is two people, often in two time zones, talking through a server that is
/// sometimes busy. None of the rules that make that work need the server to be tested:
/// which days count, what a record is called, when to write, and who is allowed in.
final class DuoTests: XCTestCase {
    private var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// An instant, given as UTC.
    private func instant(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func status(_ role: DuoRole, _ day: String, met: Bool, bucket: Int? = nil, at updatedAt: Date = .distantPast) -> DuoDayStatus {
        DuoDayStatus(role: role, day: day, goalMet: met, progressBucket: bucket ?? (met ? 100 : 0), updatedAt: updatedAt)
    }

    private func bothMet(_ days: String...) -> [DuoDayStatus] {
        days.flatMap { day in DuoRole.allCases.map { status($0, day, met: true) } }
    }

    // MARK: - The shared streak

    func testEveryDayBothPeopleMetTheirGoalCounts() {
        let statuses = bothMet("2026-09-18", "2026-09-19", "2026-09-20")
        let streak = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-20", now: instant(2026, 9, 20, 22))
        XCTAssertEqual(streak, 3)
    }

    func testNobodyHasAStreakAlone() {
        let statuses = ["2026-09-18", "2026-09-19", "2026-09-20"].map { status(.owner, $0, met: true) }
        let streak = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 23))
        XCTAssertEqual(streak, 0)
    }

    func testMyDayInProgressDoesNotBreakTheStreak() {
        let statuses = bothMet("2026-09-19", "2026-09-20") + [
            status(.owner, "2026-09-21", met: false, bucket: 50),
            status(.partner, "2026-09-21", met: true),
        ]
        let streak = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21, 15))
        XCTAssertEqual(streak, 2)
    }

    func testMyPartnersDayInProgressDoesNotBreakItEither() {
        let statuses = bothMet("2026-09-19", "2026-09-20") + [status(.owner, "2026-09-21", met: true)]
        let streak = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21, 15))
        XCTAssertEqual(streak, 2, "today is not counted until both have met it, and not held against anyone until it is over")
    }

    func testADayOneOfUsMissedEndsIt() {
        let statuses = bothMet("2026-09-17", "2026-09-18") + [
            status(.owner, "2026-09-19", met: true),
            status(.partner, "2026-09-19", met: false, bucket: 75),
        ] + bothMet("2026-09-20")
        let streak = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21, 15))
        XCTAssertEqual(streak, 1, "only the day after the miss survives")
    }

    func testADayNobodyWroteAnythingAboutEndsItOnceItIsOver() {
        let statuses = bothMet("2026-09-17", "2026-09-18") + bothMet("2026-09-20")
        let streak = DuoStreak.current(statuses: statuses, myRole: .partner, myToday: "2026-09-21", now: instant(2026, 9, 21, 15))
        XCTAssertEqual(streak, 1)
    }

    func testMyOwnMissedYesterdayEndsItAtMidnightMyTime() {
        let statuses = bothMet("2026-09-19") + [status(.partner, "2026-09-20", met: true)]
        // Early on the 21st, UTC: the 20th is not over everywhere, but it is over for me.
        let streak = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21, 1))
        XCTAssertEqual(streak, 0)
    }

    func testAPartnersYesterdayIsNotHeldAgainstThemWhileItCouldStillBeTheirToday() {
        let statuses = bothMet("2026-09-19") + [status(.owner, "2026-09-20", met: true)]
        // 01:00 UTC on the 21st. Somewhere west of here it is still the 20th.
        let early = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21, 1))
        XCTAssertEqual(early, 1)
        // 12:00 UTC on the 21st is midnight in the last place on Earth. The 20th is over.
        let late = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21, 12))
        XCTAssertEqual(late, 0)
    }

    func testAPartnerWhoHasMovedOnToANewDayHasFinishedTheOldOne() {
        let statuses = bothMet("2026-09-19") + [
            status(.owner, "2026-09-20", met: true),
            status(.partner, "2026-09-21", met: false, bucket: 0),
        ]
        let streak = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21, 1))
        XCTAssertEqual(streak, 0, "they wrote the 21st, so their 20th ended without the goal")
    }

    // MARK: - Across time zones

    /// The owner is in Tokyo and the partner in Los Angeles. At 02:00 UTC on the 21st it
    /// is 11:00 on the 21st in Tokyo and 19:00 on the 20th in Los Angeles.
    func testTokyoAndLosAngelesSeeTheSameStreakFromBothSides() {
        let now = instant(2026, 9, 21, 2)
        let statuses = bothMet("2026-09-18", "2026-09-19") + [
            status(.owner, "2026-09-20", met: true),
            status(.owner, "2026-09-21", met: false, bucket: 25),
            status(.partner, "2026-09-20", met: false, bucket: 75),
        ]
        let fromTokyo = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: now)
        let fromLosAngeles = DuoStreak.current(statuses: statuses, myRole: .partner, myToday: "2026-09-20", now: now)
        XCTAssertEqual(fromTokyo, 2)
        XCTAssertEqual(fromLosAngeles, 2)
    }

    func testTheDayCountsOnceTheLaterTimeZoneFinishesIt() {
        let now = instant(2026, 9, 21, 5)
        let statuses = bothMet("2026-09-18", "2026-09-19", "2026-09-20") + [
            status(.owner, "2026-09-21", met: false, bucket: 50),
        ]
        XCTAssertEqual(DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: now), 3)
        XCTAssertEqual(DuoStreak.current(statuses: statuses, myRole: .partner, myToday: "2026-09-20", now: now), 3)
    }

    func testDaysAreComparedAsWrittenNotAsInstants() {
        // Both met "2026-09-20", thirty-one hours apart in real time. Same day of the streak.
        let statuses = [
            status(.owner, "2026-09-20", met: true, at: instant(2026, 9, 19, 16)),
            status(.partner, "2026-09-20", met: true, at: instant(2026, 9, 20, 23)),
        ]
        XCTAssertEqual(DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21, 0)), 1)
    }

    func testADayImpossiblyFarAheadIsNotWalkedBackFrom() {
        let statuses = bothMet("2026-09-20") + [status(.partner, "9999-12-31", met: true)]
        let streak = DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-20", now: instant(2026, 9, 20, 20))
        XCTAssertEqual(streak, 1)
        XCTAssertNil(
            DuoStreak.currentStatus(of: .partner, statuses: [status(.partner, "9999-12-31", met: true)], myRole: .owner, myToday: "2026-09-20", now: instant(2026, 9, 20, 20)),
            "and it is not shown as anybody's today"
        )
    }

    func testTheLastPlaceOnEarthDecidesWhenADayIsOver() {
        XCTAssertFalse(DuoStreak.isOverEverywhere("2026-09-20", now: instant(2026, 9, 21, 11, 59)))
        XCTAssertTrue(DuoStreak.isOverEverywhere("2026-09-20", now: instant(2026, 9, 21, 12, 0)))
    }

    // MARK: - Whose today is showing

    func testMyOwnStatusIsTodays() {
        let statuses = [status(.owner, "2026-09-20", met: true), status(.owner, "2026-09-21", met: false, bucket: 25)]
        let shown = DuoStreak.currentStatus(of: .owner, statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21))
        XCTAssertEqual(shown?.progressBucket, 25)
    }

    func testAPartnerBehindMeInTimeShowsTheirOwnTodayWhileItIsFresh() {
        let now = instant(2026, 9, 21, 2)
        let fresh = [status(.partner, "2026-09-20", met: false, bucket: 75, at: now.addingTimeInterval(-3600))]
        XCTAssertEqual(
            DuoStreak.currentStatus(of: .partner, statuses: fresh, myRole: .owner, myToday: "2026-09-21", now: now)?.progressBucket,
            75
        )
        let stale = [status(.partner, "2026-09-20", met: true, at: now.addingTimeInterval(-7 * 3600))]
        XCTAssertNil(
            DuoStreak.currentStatus(of: .partner, statuses: stale, myRole: .owner, myToday: "2026-09-21", now: now),
            "last night's goal is not shown as this morning's"
        )
    }

    func testAPartnerAheadOfMeShowsTheirNewDay() {
        let statuses = [status(.partner, "2026-09-21", met: true), status(.partner, "2026-09-22", met: false, bucket: 0)]
        let shown = DuoStreak.currentStatus(of: .partner, statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: instant(2026, 9, 21, 20))
        XCTAssertEqual(shown?.day, "2026-09-22")
    }

    // MARK: - Record naming

    func testTheSameDayIsAlwaysTheSameRecord() {
        let morning = status(.partner, "2026-09-21", met: false, bucket: 25, at: instant(2026, 9, 21, 8))
        let evening = status(.partner, "2026-09-21", met: true, at: instant(2026, 9, 21, 20))
        XCTAssertEqual(morning.recordName, "partner-2026-09-21")
        XCTAssertEqual(morning.recordName, evening.recordName, "a later write replaces the earlier one, never sits beside it")
        XCTAssertNotEqual(morning.recordName, status(.owner, "2026-09-21", met: true).recordName)
        XCTAssertNotEqual(morning.recordName, status(.partner, "2026-09-22", met: true).recordName)
    }

    func testARecordNameReadsBackToWhoseDayItIs() throws {
        let parsed = try XCTUnwrap(DuoRecordName.parseDayStatus("owner-2026-09-21"))
        XCTAssertEqual(parsed.role, .owner)
        XCTAssertEqual(parsed.day, "2026-09-21")
    }

    func testAnythingElseInTheZoneIsNotAStatus() {
        for name in ["duo", "nudge-2026-09-21", "owner-", "owner-yesterday", "owner-2026-13-45", "owner-2026-9-1", CKRecordNameZoneWideShare] {
            XCTAssertNil(DuoRecordName.parseDayStatus(name), name)
        }
    }

    func testOnlyADuosZoneIsEverRecognised() {
        let id = UUID()
        XCTAssertEqual(DuoRecordName.zoneName(for: id), "Duo-\(id.uuidString)")
        XCTAssertEqual(DuoRecordName.duoID(fromZoneName: DuoRecordName.zoneName(for: id)), id)
        // The zone SwiftData mirrors the drink log into, the default zone, and a near miss.
        for zone in ["com.apple.coredata.cloudkit.zone", "_defaultZone", "Duo-", "Duo-not-a-uuid", "duo-\(id.uuidString)"] {
            XCTAssertNil(DuoRecordName.duoID(fromZoneName: zone), zone)
        }
    }

    // MARK: - What is shared

    func testProgressIsRoundedDownToAQuarter() {
        let goal = 2000
        XCTAssertEqual(DuoProgress.bucket(totalML: 0, goalML: goal), 0)
        XCTAssertEqual(DuoProgress.bucket(totalML: 499, goalML: goal), 0)
        XCTAssertEqual(DuoProgress.bucket(totalML: 500, goalML: goal), 25)
        XCTAssertEqual(DuoProgress.bucket(totalML: 1000, goalML: goal), 50)
        XCTAssertEqual(DuoProgress.bucket(totalML: 1999, goalML: goal), 75)
        XCTAssertEqual(DuoProgress.bucket(totalML: 2000, goalML: goal), 100)
        XCTAssertEqual(DuoProgress.bucket(totalML: 9000, goalML: goal), 100)
        XCTAssertEqual(DuoProgress.bucket(totalML: 500, goalML: 0), 0)
    }

    func testAFullBucketAndGoalMetAreTheSameMoment() {
        for total in stride(from: 0, through: 3000, by: 50) {
            let made = DuoProgress.status(role: .owner, day: "2026-09-21", totalML: total, goalML: 2000, now: Date())
            XCTAssertEqual(made.goalMet, made.progressBucket == 100, "\(total) mL")
            XCTAssertTrue(DuoProgress.buckets.contains(made.progressBucket))
        }
    }

    /// A pin. A status carries these five things and no others. Anyone adding a sixth
    /// has to come here and change this, and think about what a partner would learn.
    func testADayStatusSharesExactlyFiveThings() throws {
        let data = try JSONEncoder().encode(status(.owner, "2026-09-21", met: true))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["role", "day", "goalMet", "progressBucket", "updatedAt"])
    }

    func testAFirstNameIsTrimmedKeptToOneLineAndKeptShort() {
        XCTAssertEqual(DuoState.cleanedName("  Sam \n"), "Sam")
        XCTAssertEqual(DuoState.cleanedName("Sam\nJones"), "Sam Jones")
        XCTAssertEqual(DuoState.cleanedName(String(repeating: "a", count: 80)).count, DuoState.maximumNameLength)
        XCTAssertEqual(DuoState.cleanedName("   "), "")
    }

    // MARK: - Spacing writes out

    func testTheFirstWriteGoesStraightAway() {
        var coalescer = DuoWriteCoalescer()
        XCTAssertEqual(coalescer.request(now: instant(2026, 9, 21)), .writeNow)
    }

    func testABurstOfChangesIsOneWriteNowAndOneOwed() {
        var coalescer = DuoWriteCoalescer()
        let start = instant(2026, 9, 21)
        var decisions: [DuoWriteCoalescer.Decision] = []
        for second in 0..<30 {
            decisions.append(coalescer.request(now: start.addingTimeInterval(Double(second))))
        }
        XCTAssertEqual(decisions.filter { $0 == .writeNow }.count, 1)
        XCTAssertEqual(decisions.filter { $0 == .wait(until: start.addingTimeInterval(30)) }.count, 1)
        XCTAssertEqual(decisions.filter { $0 == .alreadyWaiting }.count, 28)
    }

    func testTheOwedWriteStartsTheThirtySecondsAgain() {
        var coalescer = DuoWriteCoalescer()
        let start = instant(2026, 9, 21)
        _ = coalescer.request(now: start)
        _ = coalescer.request(now: start.addingTimeInterval(5))
        coalescer.waitEnded(now: start.addingTimeInterval(30))
        XCTAssertEqual(coalescer.request(now: start.addingTimeInterval(40)), .wait(until: start.addingTimeInterval(60)))
        coalescer.waitEnded(now: start.addingTimeInterval(60))
        XCTAssertEqual(coalescer.request(now: start.addingTimeInterval(95)), .writeNow)
    }

    func testWritesAreNeverCloserThanThirtySeconds() {
        var coalescer = DuoWriteCoalescer()
        let start = instant(2026, 9, 21)
        var writes: [Date] = []
        var owed: Date?
        // Someone logging a drink every seven seconds for ten minutes.
        for tick in stride(from: 0.0, through: 600, by: 7) {
            let now = start.addingTimeInterval(tick)
            if let due = owed, now >= due {
                coalescer.waitEnded(now: due)
                writes.append(due)
                owed = nil
            }
            switch coalescer.request(now: now) {
            case .writeNow: writes.append(now)
            case .wait(let until): owed = until
            case .alreadyWaiting: break
            }
        }
        XCTAssertGreaterThan(writes.count, 2)
        for (earlier, later) in zip(writes, writes.dropFirst()) {
            XCTAssertGreaterThanOrEqual(later.timeIntervalSince(earlier), DuoWriteCoalescer.minimumInterval)
        }
    }

    // MARK: - What is still to be sent

    private func unsent(_ totals: [String: Int], known: [DuoDayStatus] = [], role: DuoRole = .owner) -> [DuoDayStatus] {
        DuoOutbox.unsent(
            role: role,
            totalsByDay: totals,
            goalML: 2000,
            known: known,
            myToday: "2026-09-21",
            now: instant(2026, 9, 21),
            calendar: utc
        )
    }

    func testTodayIsSentEvenWhenEmptyAndEmptyPastDaysAreNot() {
        let sent = unsent([:])
        XCTAssertEqual(sent.map(\.day), ["2026-09-21"])
        XCTAssertEqual(sent.first?.progressBucket, 0)
    }

    func testNothingIsSentWhenICloudAlreadyKnows() {
        let known = [status(.owner, "2026-09-21", met: false, bucket: 50)]
        XCTAssertTrue(unsent(["2026-09-21": 1100], known: known).isEmpty)
        // More water, same quarter: still nothing to say.
        XCTAssertTrue(unsent(["2026-09-21": 1400], known: known).isEmpty)
        // The next quarter is news.
        XCTAssertEqual(unsent(["2026-09-21": 1500], known: known).first?.progressBucket, 75)
    }

    func testAWriteThatNeverHappenedIsStillOwedTheNextDay() {
        // Met the goal last night with no signal. iCloud still thinks it was 75.
        let known = [status(.owner, "2026-09-20", met: false, bucket: 75)]
        let sent = unsent(["2026-09-20": 2100], known: known)
        XCTAssertTrue(sent.contains { $0.day == "2026-09-20" && $0.goalMet })
        XCTAssertTrue(sent.contains { $0.day == "2026-09-21" })
    }

    func testAnEditedDrinkCorrectsTheDayItMovedFrom() {
        let known = [status(.owner, "2026-09-18", met: true), status(.owner, "2026-09-21", met: false, bucket: 0)]
        let sent = unsent(["2026-09-18": 900], known: known)
        XCTAssertEqual(sent.map(\.day), ["2026-09-18"])
        XCTAssertEqual(sent.first?.goalMet, false)
    }

    func testNothingOlderThanAWeekIsEverRewritten() {
        let known = [status(.owner, "2026-09-10", met: true), status(.owner, "2026-09-21", met: false, bucket: 0)]
        XCTAssertTrue(unsent(["2026-09-10": 0], known: known).isEmpty)
    }

    func testOnlyMyOwnSideIsEverWritten() {
        let known = [status(.owner, "2026-09-21", met: true)]
        let sent = unsent(["2026-09-21": 2500], known: known, role: .partner)
        XCTAssertEqual(sent.map(\.role), [.partner], "the owner's record is the owner's to write")
    }

    // MARK: - Limits

    private func duo(ended: Bool = false) -> DuoState {
        let id = UUID()
        return DuoState(
            id: id,
            zoneName: DuoRecordName.zoneName(for: id),
            zoneOwnerName: "owner",
            myRole: .owner,
            createdAt: instant(2026, 9, 1),
            ownerDisplayName: "Jo",
            partnerDisplayName: "Sam",
            ownerSkin: "classic",
            partnerSkin: "forest",
            statuses: [],
            shareURL: nil,
            partnerHasJoined: true,
            endedAt: ended ? instant(2026, 9, 2) : nil
        )
    }

    func testOneDuoIsFree() {
        XCTAssertTrue(DuoLimit.canAddDuo(existing: [], isSubscribed: false))
        XCTAssertFalse(DuoLimit.canAddDuo(existing: [duo()], isSubscribed: false))
    }

    func testFiveWithHydroDropPlus() {
        XCTAssertTrue(DuoLimit.canAddDuo(existing: Array(repeating: (), count: 4).map { duo() }, isSubscribed: true))
        XCTAssertFalse(DuoLimit.canAddDuo(existing: Array(repeating: (), count: 5).map { duo() }, isSubscribed: true))
    }

    func testADuoThatEndedDoesNotTakeUpAPlace() {
        XCTAssertTrue(DuoLimit.canAddDuo(existing: [duo(ended: true)], isSubscribed: false))
    }

    func testALapsedSubscriberKeepsTheirDuosButCannotAddMore() {
        let three = [duo(), duo(), duo()]
        XCTAssertFalse(DuoLimit.canAddDuo(existing: three, isSubscribed: false))
    }

    // MARK: - A duo is two people

    private typealias Seat = DuoParticipants.Participant

    func testNobodyIsRemovedWhileTheInviteIsStillOpen() {
        let seats = [Seat(id: "0", isOwner: true, hasAccepted: true), Seat(id: "1", isOwner: false, hasAccepted: false), Seat(id: "2", isOwner: false, hasAccepted: false)]
        XCTAssertTrue(DuoParticipants.toRemove(from: seats, keeping: nil).isEmpty)
    }

    func testOnceSomeoneAcceptsEveryoneElseIsRemoved() {
        let seats = [Seat(id: "0", isOwner: true, hasAccepted: true), Seat(id: "1", isOwner: false, hasAccepted: false), Seat(id: "2", isOwner: false, hasAccepted: true), Seat(id: "3", isOwner: false, hasAccepted: true)]
        XCTAssertEqual(DuoParticipants.toRemove(from: seats, keeping: nil), ["1", "3"], "the first to accept stays")
    }

    func testTheOwnerIsNeverRemoved() {
        let seats = [Seat(id: "0", isOwner: true, hasAccepted: true), Seat(id: "1", isOwner: false, hasAccepted: true)]
        XCTAssertTrue(DuoParticipants.toRemove(from: seats, keeping: nil).isEmpty)
    }

    // MARK: - When iCloud says no

    private func cloudError(_ code: CKError.Code, retryAfter: Double? = nil, partial: [CKRecord.ID: NSError]? = nil) -> Error {
        var userInfo: [String: Any] = [:]
        if let retryAfter { userInfo[CKErrorRetryAfterKey] = retryAfter }
        if let partial { userInfo[CKPartialErrorsByItemIDKey] = partial as NSDictionary }
        return NSError(domain: CKErrorDomain, code: code.rawValue, userInfo: userInfo)
    }

    func testABusyServerIsRetriedWhenItSaysTo() {
        XCTAssertEqual(DuoRetry.verdict(for: cloudError(.zoneBusy, retryAfter: 7)), .retry(after: 7))
        XCTAssertEqual(DuoRetry.verdict(for: cloudError(.requestRateLimited, retryAfter: 42)), .retry(after: 42))
    }

    func testAServerThatDoesNotSayWhenGetsTheFallback() {
        XCTAssertEqual(DuoRetry.verdict(for: cloudError(.zoneBusy)), .retry(after: DuoRetry.fallbackDelay))
        XCTAssertEqual(DuoRetry.verdict(for: cloudError(.networkUnavailable)), .retry(after: DuoRetry.fallbackDelay))
    }

    func testAChangedRecordIsSentAgain() {
        XCTAssertEqual(DuoRetry.verdict(for: cloudError(.serverRecordChanged)), .retry(after: 0))
    }

    func testAMissingZoneMeansTheDuoEnded() {
        XCTAssertEqual(DuoRetry.verdict(for: cloudError(.zoneNotFound)), .ended)
        XCTAssertEqual(DuoRetry.verdict(for: cloudError(.userDeletedZone)), .ended)
    }

    func testAPartialFailureIsJudgedByWhatIsInsideIt() {
        let zone = CKRecordZone.ID(zoneName: "Duo-test", ownerName: CKCurrentUserDefaultName)
        let first = CKRecord.ID(recordName: "owner-2026-09-20", zoneID: zone)
        let second = CKRecord.ID(recordName: "owner-2026-09-21", zoneID: zone)
        let busy = cloudError(.partialFailure, partial: [
            first: cloudError(.zoneBusy, retryAfter: 3) as NSError,
            second: cloudError(.requestRateLimited, retryAfter: 9) as NSError,
        ])
        XCTAssertEqual(DuoRetry.verdict(for: busy), .retry(after: 9), "the longest wait anyone asked for")
        let gone = cloudError(.partialFailure, partial: [first: cloudError(.zoneNotFound) as NSError])
        XCTAssertEqual(DuoRetry.verdict(for: gone), .ended)
    }

    func testAnythingElseIsNotRetried() {
        XCTAssertEqual(DuoRetry.verdict(for: cloudError(.permissionFailure)), .fail)
        XCTAssertEqual(DuoRetry.verdict(for: cloudError(.quotaExceeded)), .fail)
        XCTAssertEqual(DuoRetry.verdict(for: DuoError.notADuoZone), .fail)
        XCTAssertEqual(DuoRetry.verdict(for: DuoError.ended), .ended)
    }

    // MARK: - The cache

    func testTheCacheKeepsOnlyWhatStillMatters() {
        let now = instant(2026, 9, 21)
        // A break on the 5th, long past correcting, and an unbroken run ever since.
        let run = (6...20).map { String(format: "2026-09-%02d", $0) }
        let statuses = bothMet("2026-09-03", "2026-09-04") + [status(.owner, "2026-09-05", met: true)]
            + run.flatMap { day in DuoRole.allCases.map { status($0, day, met: true) } }
        let kept = DuoStreak.pruned(statuses, myToday: "2026-09-21", now: now)
        XCTAssertFalse(kept.contains { $0.day < "2026-09-05" })
        XCTAssertTrue(kept.contains { $0.day == "2026-09-06" })
        XCTAssertEqual(DuoStreak.current(statuses: kept, myRole: .owner, myToday: "2026-09-21", now: now), 15)
        XCTAssertEqual(DuoStreak.current(statuses: statuses, myRole: .owner, myToday: "2026-09-21", now: now), 15)
    }

    func testARunThatDiedLongAgoIsDroppedWithTheBreakThatKilledIt() {
        let now = instant(2026, 9, 21)
        let statuses = bothMet("2026-09-06", "2026-09-07", "2026-09-20")
        let kept = DuoStreak.pruned(statuses, myToday: "2026-09-21", now: now)
        XCTAssertEqual(Set(kept.map(\.day)), ["2026-09-20"], "the week of nothing in between ended the old run for good")
        XCTAssertEqual(DuoStreak.current(statuses: kept, myRole: .owner, myToday: "2026-09-21", now: now), 1)
    }

    func testAnUnbrokenStreakIsNeverPruned() {
        let days = (1...20).map { String(format: "2026-09-%02d", $0) }
        let statuses = days.flatMap { day in DuoRole.allCases.map { status($0, day, met: true) } }
        XCTAssertEqual(DuoStreak.pruned(statuses, myToday: "2026-09-21", now: instant(2026, 9, 21)).count, statuses.count)
    }

    func testTheCacheSurvivesARoundTrip() throws {
        let suite = "DuoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertTrue(DuoCache.load(from: defaults).isEmpty)
        var saved = duo()
        saved.statuses = bothMet("2026-09-20")
        saved.changeToken = Data([1, 2, 3])
        DuoCache.save([saved], to: defaults)
        XCTAssertEqual(DuoCache.load(from: defaults), [saved])
    }

    func testAnUnreadableCacheIsAnEmptyOneNotACrash() throws {
        let suite = "DuoTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(Data("not json".utf8), forKey: "duo.states.v1")
        XCTAssertTrue(DuoCache.load(from: defaults).isEmpty)
    }
}

/// What someone sees when joining fails. Every failure used to read "That did not work",
/// which nobody could act on and which hid the cause from whoever was helping.
@MainActor
final class DuoJoinMessageTests: XCTestCase {
    private let noLongerOpen = "That invite is no longer open. Ask for a new one."
    private let notOpenToYou = "This invite is not open to you anymore. Someone else may have joined first. "
        + "Ask for a new one."

    /// How CKAcceptSharesOperation can report one invite's failure: inside a partial failure.
    private func partial(_ code: CKError.Code) -> CKError {
        let perItem: [AnyHashable: Error] = [CKRecord.ID(recordName: "share"): CKError(code)]
        return CKError(.partialFailure, userInfo: [CKPartialErrorsByItemIDKey: perItem])
    }

    func testAnEndedDuoSaysTheInviteIsNoLongerOpen() {
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.zoneNotFound)), noLongerOpen)
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.userDeletedZone)), noLongerOpen)
    }

    func testAMissingShareSaysTheInviteIsNoLongerOpen() {
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.unknownItem)), noLongerOpen)
        XCTAssertEqual(DuoStore.joinFailureMessage(for: partial(.unknownItem)), noLongerOpen)
    }

    /// Past the Join sheet, a permission error means this person was taken off the
    /// invite, most often because someone else joined first.
    func testAnInviteNoLongerOpenToThisPersonSaysSo() {
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.participantMayNeedVerification)), notOpenToYou)
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.permissionFailure)), notOpenToYou)
        XCTAssertEqual(DuoStore.joinFailureMessage(for: partial(.participantMayNeedVerification)), notOpenToYou)
    }

    /// Cases where "try again" can't work until something else is done first.
    func testAccountProblemsSayWhatToDo() {
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.accountTemporarilyUnavailable)),
                       "Finish signing in to iCloud in Settings, then try again.")
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.managedAccountRestricted)),
                       "Duo streaks cannot be used with this Apple Account.")
    }

    /// Joining writes into the inviter's iCloud, so full storage is theirs to fix.
    func testFullStorageIsPutOnTheInviter() {
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.quotaExceeded)),
                       "The person who invited you is out of iCloud storage, so you cannot join yet. Let them know.")
    }

    func testFailuresThatAlreadyHadWordsKeepThem() {
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.notAuthenticated)),
                       "Sign in to iCloud in Settings, then try again.")
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.networkUnavailable)),
                       "No connection right now. Try again in a bit.")
    }

    /// Anything unexplained carries its code, so a screenshot tells which failure it was.
    func testAnUnexplainedFailureCarriesItsCode() {
        XCTAssertEqual(DuoStore.joinFailureMessage(for: CKError(.internalError)),
                       "That did not work. Please try again. (iCloud error \(CKError.Code.internalError.rawValue))")
        XCTAssertEqual(DuoStore.joinFailureMessage(for: NSError(domain: "Test", code: 7)),
                       "That did not work. Please try again. (error 7)")
    }

    /// The join wording must not leak into the write retries, where "not found" is not
    /// the end of a duo.
    func testWriteRetriesStillDoNotTreatAMissingRecordAsAnEndedDuo() {
        XCTAssertEqual(DuoRetry.verdict(for: CKError(.unknownItem)), .fail)
        XCTAssertEqual(DuoRetry.verdict(for: CKError(.permissionFailure)), .fail)
    }
}
