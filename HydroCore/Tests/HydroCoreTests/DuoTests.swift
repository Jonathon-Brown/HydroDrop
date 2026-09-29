import XCTest
@testable import HydroCore

/// A duo is two people, often in two time zones, talking through a server that is
/// sometimes busy. None of the rules that make that work need the server to be tested:
/// which days count, what a record is called, when to write, and how many duos anyone
/// can have.
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

    func testAnythingElseIsNotAStatus() {
        // "cloudkit.zoneshare" is the value of CloudKit's CKRecordNameZoneWideShare, spelled
        // out so that HydroCore's tests do not import CloudKit.
        for name in ["duo", "nudge-2026-09-21", "owner-", "owner-yesterday", "owner-2026-13-45", "owner-2026-9-1", "cloudkit.zoneshare"] {
            XCTAssertNil(DuoRecordName.parseDayStatus(name), name)
        }
    }

    /// The server stores no day before 2000 (final design §6.0), so neither does a phone.
    /// Any year the calendar could write used to pass, 0001-01-01 included.
    func testADayBeforeTheYear2000IsNotADay() {
        for text in ["1999-12-31", "0001-01-01", "0000-01-01"] {
            XCTAssertFalse(DuoStreak.isDayKey(text), text)
            XCTAssertNil(DuoRecordName.parseDayStatus("owner-\(text)"), text)
        }
        XCTAssertTrue(DuoStreak.isDayKey("2000-01-01"))
        XCTAssertEqual(DuoRecordName.parseDayStatus("partner-2000-01-01")?.day, "2000-01-01")
    }

    // The zone-name test went with `DuoRecordName`'s zone helpers: Duo v2 has no zones.

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
            zoneName: "Duo-\(id.uuidString)",
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

    // The three `DuoParticipants` tests (nobody removed while the invite is open, the first
    // to accept stays, the owner is never removed) went with it: the server enforces the
    // same "exactly two, first to join wins" rule when an invite is redeemed.

    // The CloudKit retry tests that used to sit here (`DuoRetry`) went with the iCloud
    // transport. Duo v2 replaces them with verdict tests for its own transport errors.

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

    // The two `DuoCache` storage tests (a round trip, and an unreadable cache reading as
    // empty) come back with it in Phase 2.
}
