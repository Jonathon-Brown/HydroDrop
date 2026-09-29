import XCTest
@testable import HydroCore

/// The rules Duo v2's server design added to the ones the iCloud version already had: a
/// kept window of 100 days, a coverage start for a reinstalled phone, quiet hours by the
/// clock, and one way of cleaning a name. The cases include the final design's vectors
/// X1, X3, X5, X9a-e, X12, KV6 and KV7, plus neighbouring cases. X9b and the name rule's
/// step order used to differ from the design, which the Phase 1 errata corrected (see
/// below and `DuoState.cleanedName`). They reach the Android app and the server once they
/// are exported to the shared vectors file.
final class DuoV2RuleTests: XCTestCase {
    private var utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func instant(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func status(_ role: DuoRole, _ day: String, met: Bool, bucket: Int? = nil) -> DuoDayStatus {
        DuoDayStatus(role: role, day: day, goalMet: met, progressBucket: bucket ?? (met ? 100 : 0), updatedAt: .distantPast)
    }

    /// `count` day keys, newest first, ending on `last`.
    private func days(endingOn last: String, count: Int) -> [String] {
        let end = DayKey.date(from: last, calendar: utc)!
        return (0..<count).map { DayKey.key(for: utc.date(byAdding: .day, value: -$0, to: end)!, calendar: utc) }
    }

    private func bothMet(_ days: [String]) -> [DuoDayStatus] {
        days.flatMap { day in DuoRole.allCases.map { status($0, day, met: true) } }
    }

    // MARK: - The kept window

    func testNobodyKeepsMoreThanAHundredDaysAndALongerStreakIsAHundredPlus() {
        let today = "2026-09-25"
        let now = instant("2026-09-25T18:00:00Z")
        let all = bothMet(days(endingOn: today, count: 130))

        let kept = DuoStreak.pruned(all, myToday: today, now: now)
        XCTAssertEqual(Set(kept.map(\.day)).count, 100)
        XCTAssertEqual(kept.map(\.day).min(), "2026-06-18")

        for role in DuoRole.allCases {
            XCTAssertEqual(DuoStreak.current(statuses: kept, myRole: role, myToday: today, now: now), 100)
            XCTAssertTrue(DuoStreak.reachedRetentionEdge(statuses: kept, myRole: role, myToday: today, now: now))
            XCTAssertTrue(DuoStreak.reachedRetentionEdge(statuses: all, myRole: role, myToday: today, now: now), "and before pruning")
        }
        XCTAssertEqual(DuoStreak.current(statuses: all, myRole: .owner, myToday: today, now: now), 130, "counting itself is unchanged")
    }

    /// V14's 120-day case (final design §14): the same answers as 130 days.
    func testAHundredAndTwentyDayStreakIsKeptAsAHundred() {
        let today = "2026-09-25"
        let now = instant("2026-09-25T18:00:00Z")
        let kept = DuoStreak.pruned(bothMet(days(endingOn: today, count: 120)), myToday: today, now: now)
        XCTAssertEqual(Set(kept.map(\.day)).count, 100)
        XCTAssertEqual(DuoStreak.current(statuses: kept, myRole: .partner, myToday: today, now: now), 100)
        XCTAssertTrue(DuoStreak.reachedRetentionEdge(statuses: kept, myRole: .partner, myToday: today, now: now))
    }

    func testAShorterStreakIsANumberNotAHundredPlus() {
        let today = "2026-09-25"
        let now = instant("2026-09-25T18:00:00Z")
        let statuses = bothMet(days(endingOn: today, count: 20))
        XCTAssertEqual(DuoStreak.current(statuses: statuses, myRole: .owner, myToday: today, now: now), 20)
        XCTAssertFalse(DuoStreak.reachedRetentionEdge(statuses: statuses, myRole: .owner, myToday: today, now: now))
    }

    func testABreakInsideTheWindowIsNotAHundredPlus() {
        let today = "2026-09-25"
        let now = instant("2026-09-25T18:00:00Z")
        let statuses = bothMet(days(endingOn: today, count: 130)).filter { !($0.day == "2026-08-01" && $0.role == .owner) }
            + [status(.owner, "2026-08-01", met: false, bucket: 50)]
        XCTAssertFalse(DuoStreak.reachedRetentionEdge(statuses: statuses, myRole: .owner, myToday: today, now: now))
        let kept = DuoStreak.pruned(statuses, myToday: today, now: now)
        XCTAssertEqual(kept.map(\.day).min(), "2026-08-01", "everything before the break goes")
        XCTAssertFalse(DuoStreak.reachedRetentionEdge(statuses: kept, myRole: .owner, myToday: today, now: now))
    }

    /// X3: the server prunes once a day with the date in the last time zone on Earth.
    func testTheServersDailyPruneUsesTheSameCutoffs() {
        let now = instant("2026-09-25T12:05:00Z")
        var lastPlace = Calendar(identifier: .gregorian)
        lastPlace.timeZone = TimeZone(secondsFromGMT: -12 * 3600)!
        let myToday = DayKey.key(for: now, calendar: lastPlace)
        XCTAssertEqual(myToday, "2026-09-25")
        XCTAssertEqual(DuoStreak.retentionStart(myToday: myToday), "2026-06-18")

        let run = days(endingOn: myToday, count: 117)
        let brokenOnTheCutoff = bothMet(run).filter { !($0.day == "2026-09-16" && $0.role == .partner) }
        XCTAssertEqual(DuoStreak.pruned(brokenOnTheCutoff, myToday: myToday, now: now).map(\.day).min(), "2026-09-16",
                       "a break on the cutoff day ends the old run for good")

        let brokenAfterTheCutoff = bothMet(run).filter { !($0.day == "2026-09-17" && $0.role == .partner) }
        XCTAssertEqual(DuoStreak.pruned(brokenAfterTheCutoff, myToday: myToday, now: now).map(\.day).min(), "2026-06-18",
                       "a break that could still be corrected is kept, and only the 100-day cap applies")
    }

    /// A phone prunes its cache when it applies a fetch, so a cache last pruned yesterday
    /// can start a day before today's window. A break on that extra day is before the
    /// window and doesn't stop "100+" (final design §8.5; vector HC.edge.staleCache).
    func testACacheLastPrunedYesterdayStillReachesTheEdge() {
        let yesterday = DuoStreak.pruned(bothMet(days(endingOn: "2026-09-24", count: 130)), myToday: "2026-09-24",
                                         now: instant("2026-09-24T18:00:00Z"))
        let cache = (yesterday + bothMet(["2026-09-25"])).filter { !($0.day == "2026-06-17" && $0.role == .partner) }
        XCTAssertEqual(cache.map(\.day).min(), "2026-06-17", "a day before today's window, which starts on 06-18")
        let now = instant("2026-09-25T18:00:00Z")
        XCTAssertTrue(DuoStreak.reachedRetentionEdge(statuses: cache, myRole: .owner, myToday: "2026-09-25", now: now))
        XCTAssertEqual(DuoStreak.current(statuses: cache, myRole: .owner, myToday: "2026-09-25", now: now), 100)
    }

    // MARK: - What a phone publishes

    /// X5: the last week is judged against the goal as it stands now.
    func testRaisingTheGoalRejudgesTheLastWeek() {
        let known = [status(.owner, "2026-09-18", met: true)]
        let now = instant("2026-09-21T12:00:00Z")
        func published(goal: Int) -> [DuoDayStatus] {
            DuoOutbox.unsent(role: .owner, totalsByDay: ["2026-09-18": 2100], goalML: goal, known: known,
                             myToday: "2026-09-21", now: now, calendar: utc).filter { $0.day == "2026-09-18" }
        }
        let raised = published(goal: 2500)
        XCTAssertEqual(raised.count, 1)
        XCTAssertEqual(raised.first?.goalMet, false)
        XCTAssertEqual(raised.first?.progressBucket, 75)
        XCTAssertTrue(published(goal: 2000).isEmpty)
    }

    /// X12: a reinstalled phone opened before its log is back can't empty its own past.
    func testAReinstalledPhoneCannotEmptyItsPastDays() {
        let today = "2026-09-21"
        let now = instant("2026-09-21T12:00:00Z")
        let known = (15...20).map { status(.owner, "2026-09-\($0)", met: true) }

        let covered = DuoOutbox.unsent(role: .owner, totalsByDay: [:], goalML: 2000, known: known,
                                       myToday: today, now: now, coverageStart: today, calendar: utc)
        XCTAssertEqual(covered.map(\.day), [today])
        XCTAssertEqual(covered.first?.goalMet, false)
        XCTAssertEqual(covered.first?.progressBucket, 0)

        let uncovered = DuoOutbox.unsent(role: .owner, totalsByDay: [:], goalML: 2000, known: known,
                                         myToday: today, now: now, calendar: utc)
        XCTAssertEqual(uncovered.count, 7, "without a coverage start the empty log is taken at its word")
    }

    /// X12's companion: with today already known, and with the log covering the week.
    func testTodayIsAlwaysWrittenAndACoveredWeekIsTakenAtItsWord() {
        let today = "2026-09-21"
        let now = instant("2026-09-21T12:00:00Z")
        let known = (15...20).map { status(.owner, "2026-09-\($0)", met: true) } + [status(.owner, today, met: false, bucket: 25)]

        let covered = DuoOutbox.unsent(role: .owner, totalsByDay: [:], goalML: 2000, known: known,
                                       myToday: today, now: now, coverageStart: today, calendar: utc)
        XCTAssertEqual(covered.map(\.day), [today])
        XCTAssertEqual(covered.first?.progressBucket, 0)

        let wholeWeek = DuoOutbox.unsent(role: .owner, totalsByDay: [:], goalML: 2000, known: known,
                                         myToday: today, now: now, coverageStart: "2026-09-15", calendar: utc)
        XCTAssertEqual(wholeWeek.count, 7)
        XCTAssertTrue(wholeWeek.allSatisfy { !$0.goalMet && $0.progressBucket == 0 })
    }

    /// The install day can be recorded after today's date, for instance by a phone that
    /// then flew west across the date line. Today is still written.
    func testTodayIsWrittenEvenBeforeTheCoverageStart() {
        let today = "2026-09-21"
        let known = [status(.owner, today, met: false, bucket: 50)]
        let published = DuoOutbox.unsent(role: .owner, totalsByDay: [:], goalML: 2000, known: known,
                                         myToday: today, now: instant("2026-09-21T12:00:00Z"),
                                         coverageStart: "2026-09-22", calendar: utc)
        XCTAssertEqual(published.first { $0.day == today }?.progressBucket, 0)
    }

    func testBeforeCoverageADayCanStillGoUp() {
        let today = "2026-09-21"
        let known = [status(.owner, "2026-09-19", met: false, bucket: 25)]
        let published = DuoOutbox.unsent(role: .owner, totalsByDay: ["2026-09-19": 1000], goalML: 2000, known: known,
                                         myToday: today, now: instant("2026-09-21T12:00:00Z"),
                                         coverageStart: today, calendar: utc)
        XCTAssertEqual(published.first { $0.day == "2026-09-19" }?.progressBucket, 50)
    }

    // MARK: - Quiet hours by the clock

    func testTheWindowOpensAtItsTimeOnTheDayTheClocksGoForward() {
        let eight = 8 * 60, ten = 22 * 60
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2027-03-14T06:30:00Z"), startMinutes: eight, endMinutes: ten, calendar: calendar("America/New_York")),
                       instant("2027-03-14T12:00:00Z"), "08:00 EDT, not an hour late at 09:00")
        let la = calendar("America/Los_Angeles")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-03-08T09:30:00Z"), startMinutes: eight, endMinutes: ten, calendar: la),
                       instant("2026-03-08T15:00:00Z"), "held from 01:30 PST")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-03-08T10:30:00Z"), startMinutes: eight, endMinutes: ten, calendar: la),
                       instant("2026-03-08T15:00:00Z"), "held from 03:30 PDT")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-03-29T00:30:00Z"), startMinutes: eight, endMinutes: ten, calendar: calendar("Europe/London")),
                       instant("2026-03-29T07:00:00Z"), "08:00 BST, held from 00:30 GMT")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-03-29T01:30:00Z"), startMinutes: eight, endMinutes: ten, calendar: calendar("Europe/London")),
                       instant("2026-03-29T07:00:00Z"), "and from 02:30 BST")
    }

    /// A start that the clocks skip opens when the gap ends. The design's vector X9b used
    /// to give 07:30Z for the first case, against its own rule (final design §8.4) and the
    /// Android vectors (KV7); Phase 1 erratum 1 corrected it to the end of the gap, 07:00Z.
    func testAStartInsideTheGapOpensWhenTheGapEnds() {
        let twoThirty = 150, ten = 22 * 60
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2027-03-14T06:30:00Z"), startMinutes: twoThirty, endMinutes: ten, calendar: calendar("America/New_York")),
                       instant("2027-03-14T07:00:00Z"), "03:00 EDT")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-03-08T09:00:00Z"), startMinutes: twoThirty, endMinutes: ten, calendar: calendar("America/Los_Angeles")),
                       instant("2026-03-08T10:00:00Z"), "03:00 PDT")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-03-29T00:30:00Z"), startMinutes: 90, endMinutes: ten, calendar: calendar("Europe/London")),
                       instant("2026-03-29T01:00:00Z"), "02:00 BST, since 01:30 never happens")
    }

    /// X9d and X9e: a window of 02:30-03:00 that the gap swallows whole. The opening is
    /// always strictly after the arrival, so arriving on the jump itself waits for the next
    /// day, and arriving the second before it opens at the jump, when the window has in
    /// fact already closed (the server's fire-time check then defers once more).
    func testAWindowTheGapSwallowsOpensAtTheJumpOrTheNextDay() {
        let newYork = calendar("America/New_York")
        for arrival in ["2027-03-14T07:00:00Z", "2027-03-14T06:59:59Z"] {
            XCTAssertFalse(DuoQuietHours.isAwake(instant(arrival), startMinutes: 150, endMinutes: 180, calendar: newYork), arrival)
        }
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2027-03-14T07:00:00Z"), startMinutes: 150, endMinutes: 180, calendar: newYork),
                       instant("2027-03-15T06:30:00Z"), "02:30 EDT the next day, not the jump it arrived on")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2027-03-14T06:59:59Z"), startMinutes: 150, endMinutes: 180, calendar: newYork),
                       instant("2027-03-14T07:00:00Z"), "the jump, a second later")
    }

    /// Not every clock change is an hour on the hour. The expected instants were worked
    /// out independently with Python's zoneinfo.
    func testUnusualClockChangesStillOpenTheSameDay() {
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-10-03T12:30:00Z"), startMinutes: 130, endMinutes: 1320, calendar: calendar("Australia/Lord_Howe")),
                       instant("2026-10-03T15:30:00Z"), "Lord Howe goes from 02:00 to 02:30, so 02:10 opens at 02:30")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-03-28T23:30:00Z"), startMinutes: 60, endMinutes: 1320, calendar: calendar("Antarctica/Troll")),
                       instant("2026-03-29T01:00:00Z"), "Troll goes from 01:00 to 03:00, two hours")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-03-28T20:00:00Z"), startMinutes: 1390, endMinutes: 420, calendar: calendar("America/Nuuk")),
                       instant("2026-03-29T01:00:00Z"), "Nuuk goes from 23:00 to midnight, so 23:10 opens at midnight")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-09-26T12:00:00Z"), startMinutes: 180, endMinutes: 1320, calendar: calendar("Pacific/Chatham")),
                       instant("2026-09-26T14:00:00Z"), "the Chatham Islands go from 02:45 to 03:45")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-04-04T12:00:00Z"), startMinutes: 230, endMinutes: 1320, calendar: calendar("Pacific/Chatham")),
                       instant("2026-04-04T15:05:00Z"), "on the day they go back, 03:50 happens once, after the repeated hour")
    }

    func testAStartThatHappensTwiceOpensTheFirstTime() {
        let oneThirty = 90, ten = 22 * 60
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-11-01T04:30:00Z"), startMinutes: oneThirty, endMinutes: ten, calendar: calendar("America/New_York")),
                       instant("2026-11-01T05:30:00Z"), "01:30 EDT, before the clocks go back")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-11-01T07:30:00Z"), startMinutes: oneThirty, endMinutes: ten, calendar: calendar("America/Los_Angeles")),
                       instant("2026-11-01T08:30:00Z"), "01:30 PDT")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-10-24T23:30:00Z"), startMinutes: oneThirty, endMinutes: ten, calendar: calendar("Europe/London")),
                       instant("2026-10-25T00:30:00Z"), "01:30 BST")
    }

    /// Something that arrives in the repeated hour, after the first reading of the start
    /// has passed, opens at the second one, not a day later. The expected instants were
    /// worked out with Python's zoneinfo.
    func testArrivingBetweenTheTwoReadingsOpensAtTheSecond() {
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-11-01T06:10:00Z"), startMinutes: 90, endMinutes: 1320, calendar: calendar("America/New_York")),
                       instant("2026-11-01T06:30:00Z"), "01:10 EST opens at 01:30 EST")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-10-25T01:10:00Z"), startMinutes: 90, endMinutes: 1320, calendar: calendar("Europe/London")),
                       instant("2026-10-25T01:30:00Z"), "01:10 GMT opens at 01:30 GMT")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-04-04T15:10:00Z"), startMinutes: 110, endMinutes: 1320, calendar: calendar("Australia/Lord_Howe")),
                       instant("2026-04-04T15:20:00Z"), "Lord Howe repeats half an hour")
        XCTAssertEqual(DuoQuietHours.holdUntil(instant("2026-04-05T03:13:53Z"), startMinutes: 1439, endMinutes: 420, calendar: calendar("America/Santiago")),
                       instant("2026-04-05T03:59:00Z"), "Santiago repeats 23:00-23:59")
    }

    func testAwakeIsJudgedByTheClock() {
        let la = calendar("America/Los_Angeles")
        XCTAssertTrue(DuoQuietHours.isAwake(instant("2026-03-08T10:30:00Z"), startMinutes: 150, endMinutes: 1320, calendar: la), "03:30 PDT is inside 02:30-22:00")
        XCTAssertFalse(DuoQuietHours.isAwake(instant("2026-03-08T09:30:00Z"), startMinutes: 150, endMinutes: 1320, calendar: la), "01:30 PST is not")
    }

    // MARK: - Names

    /// KV6: one way of cleaning a name, on the server and both phones.
    func testANameIsCleanedTheSameWayEverywhere() {
        XCTAssertEqual(DuoState.cleanedName("  Sam \n"), "Sam")
        XCTAssertEqual(DuoState.cleanedName("Sam\nJones"), "Sam Jones")
        XCTAssertEqual(DuoState.cleanedName("a\r\nb"), "a b", "a pasted Windows line break is one space, not two")
        XCTAssertEqual(DuoState.cleanedName("a\tb"), "a b")
        XCTAssertEqual(DuoState.cleanedName("Sam\u{00A0}\u{00A0}Jones"), "Sam Jones", "non-breaking spaces count as spaces")
        XCTAssertEqual(DuoState.cleanedName(String(repeating: "a", count: 80)), String(repeating: "a", count: 24))
        XCTAssertEqual(DuoState.cleanedName("   "), "")

        XCTAssertEqual(DuoState.cleanedName("\u{202E}abc"), "abc", "no right-to-left override")
        XCTAssertEqual(DuoState.cleanedName("a\u{200B}b"), "ab", "no zero-width space")
        XCTAssertEqual(DuoState.cleanedName("\u{E000}Sam"), "Sam", "no private-use characters")
        XCTAssertEqual(DuoState.cleanedName("\u{0378}Sam"), "Sam", "no unassigned code points")
        XCTAssertEqual(DuoState.cleanedName("\u{FB01}sh"), "\u{FB01}sh", "NFC, not NFKC: a ligature in a real name stays")

        let decomposed = String(repeating: "e\u{0301}", count: 30)
        XCTAssertEqual(DuoState.cleanedName(decomposed), String(repeating: "\u{00E9}", count: 24), "composed, and 24 letters as a person counts them")

        let family = "👨\u{200D}👩\u{200D}👧\u{200D}👦"
        let families = DuoState.cleanedName(String(repeating: family, count: 30))
        XCTAssertEqual(families.count, 24, "24 characters as a person counts them")
        XCTAssertFalse(families.unicodeScalars.contains("\u{200D}"), "a joiner between two emoji spells nothing, and the server rejects emoji anyway")
        XCTAssertEqual(DuoState.cleanedName("🏴\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}"), "\u{1F3F4}",
                       "tag characters are format characters and go, leaving the black flag")
        XCTAssertEqual(DuoState.cleanedName(String(repeating: "🇬🇧🇬🇧", count: 15)).count, 24)

        XCTAssertEqual(DuoState.cleanedName("\u{200B} Sam"), "Sam", "an invisible character beside a space leaves no stray space")
        XCTAssertEqual(DuoState.cleanedName("Sam \u{200B}"), "Sam")
        XCTAssertEqual(DuoState.cleanedName("a \u{202E} b"), "a b")
        XCTAssertEqual(DuoState.cleanedName("e\u{200B}\u{0301}"), "\u{00E9}", "a letter and its accent are rejoined")

        XCTAssertEqual(DuoState.cleanedName("\u{AC00}\u{11A8}"), "\u{AC01}", "가 and a trailing ㄱ compose to 각, which Foundation's NFC misses")
        XCTAssertEqual(DuoState.cleanedName("\u{AC00}\u{200B}\u{11A8}"), "\u{AC01}")
        XCTAssertEqual(DuoState.cleanedName("\u{0C95}\u{0CCA}\u{0CD5}"), "\u{0C95}\u{0CCB}", "a Kannada vowel sign composes")
        XCTAssertEqual(DuoState.cleanedName("\u{1100}\u{1176}"), "\u{1100}\u{1176}", "an Old Hangul pair stays as written, as ICU leaves it")

        let sinhala = "\u{0DC1}\u{0DCA}\u{200D}\u{0DBB}\u{0DD3}"
        XCTAssertEqual(DuoState.cleanedName(sinhala), sinhala, "the joiner is part of how ශ්‍රී is spelled")

        XCTAssertEqual(DuoState.cleanedName(" \u{200D} "), "", "a joiner on its own is an invisible name, so it goes")
        XCTAssertEqual(DuoState.cleanedName("Sam\u{200D}"), "Sam", "and at an edge")
        XCTAssertEqual(DuoState.cleanedName("\u{200C}\u{200C}Sam"), "Sam")
        XCTAssertEqual(DuoState.cleanedName("a\u{200C}\u{200C}b"), "a\u{200C}b", "only the joiner with a letter on both sides stays")
        XCTAssertEqual(DuoState.cleanedName("e\u{0301}\u{1100}\u{1176}"), "\u{00E9}\u{1100}\u{1176}",
                       "one character Foundation can't compose doesn't stop the rest")

        let persian = "می\u{200C}خواهم"
        XCTAssertEqual(DuoState.cleanedName(persian), persian, "the non-joiner is part of the spelling")

        XCTAssertEqual(DuoState.cleanedName(" \u{0301}Sam"), "\u{0301}Sam",
                       "trimming is by code point, so a mark with no letter before it stays; the server's check refuses it")
    }

    /// A joiner belongs to the character before it as a person sees it, so a cut at 24
    /// can end on one whose next letter fell past the cut. The joiner used to stay there,
    /// last in the name, and the server's check refuses a name that ends on one.
    func testACutThatEndsOnAJoinerDropsIt() {
        let a23 = String(repeating: "a", count: 23)
        XCTAssertEqual(DuoState.cleanedName(a23 + "b\u{200D}c"), a23 + "b")
        XCTAssertEqual(DuoState.cleanedName(a23 + "b\u{200C}c"), a23 + "b")
        XCTAssertEqual(DuoState.cleanedName(a23 + "\u{0D4E}\u{200D}c"), a23 + "\u{0D4E}", "and after a prepended character")
        XCTAssertEqual(DuoState.cleanedName(String(repeating: "a", count: 22) + "b\u{200D}c"),
                       String(repeating: "a", count: 22) + "b\u{200D}c", "a joiner that fits with its letter stays")
    }

    /// Cleaning a cleaned name changes nothing (final design §8.8), so the server, which
    /// cleans what a phone already cleaned, stores what the phone showed. It used to fail
    /// for a name cut just after a joiner, the case above: the first cleaning kept the
    /// joiner at the end and the second dropped it.
    ///
    /// Every short tail of a set of awkward characters is tried after 21 to 24 letters, so
    /// the cut falls on each of them. The results are compared code point by code point,
    /// because Swift's `==` treats strings that only differ in composition as equal.
    func testCleaningACleanedNameChangesNothing() {
        let pieces = ["b", " ", "\u{200D}", "\u{200C}", "\u{200B}", "\u{0301}", "\u{0D4E}", "\u{1F468}", "\n"]
        var names = ["  Sam \n", "a\r\nb", "\u{200B} Sam", "a \u{202E} b", "e\u{200B}\u{0301}", " \u{200D} ", "a\u{200C}\u{200C}b",
                     "\u{0DC1}\u{0DCA}\u{200D}\u{0DBB}\u{0DD3}", "\u{AC00}\u{11A8}", "\u{0C95}\u{0CCA}\u{0CD5}", "e\u{0301}\u{1100}\u{1176}",
                     "\u{0F40}\u{0301}\u{0F73}", " \u{0301}Sam", String(repeating: "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}", count: 12)]
        for letters in 21...24 {
            for first in pieces {
                for second in pieces {
                    for third in pieces {
                        names.append(String(repeating: "a", count: letters) + first + second + third + "c")
                    }
                }
            }
        }
        for name in names {
            let once = DuoState.cleanedName(name)
            let twice = DuoState.cleanedName(once)
            XCTAssertEqual(Array(twice.unicodeScalars), Array(once.unicodeScalars),
                           "cleaning \(name.unicodeScalars.map { String($0.value, radix: 16) }) a second time changed it")
        }
    }
}
