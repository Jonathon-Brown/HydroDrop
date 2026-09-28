import XCTest
@testable import HydroDrop

/// A nudge is small, and the rules around it are what keep it kind: only so many, never
/// twice, never at night, and never words a stranger typed.
final class DuoNudgeTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func at(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour, minute: minute))!
    }

    private func duo(
        myRole: DuoRole = .owner,
        nudges: [DuoNudge] = [],
        statuses: [DuoDayStatus] = [],
        joined: Bool = true,
        ended: Bool = false
    ) -> DuoState {
        let id = UUID(uuidString: "11111111-2222-4333-8444-555555555555")!
        return DuoState(
            id: id,
            zoneName: DuoRecordName.zoneName(for: id),
            zoneOwnerName: "owner",
            myRole: myRole,
            createdAt: at(1, 9),
            ownerDisplayName: "Jo",
            partnerDisplayName: "Sam",
            ownerSkin: "classic",
            partnerSkin: "forest",
            statuses: statuses,
            shareURL: nil,
            partnerHasJoined: joined,
            endedAt: ended ? at(2, 9) : nil,
            changeToken: nil,
            nudges: nudges
        )
    }

    private func nudge(_ name: String, from role: DuoRole, _ date: Date, preset: DuoNudgePreset = .waterBreak) -> DuoNudge {
        DuoNudge(id: "nudge-\(name)", fromRole: role, presetID: preset.rawValue, createdAt: date)
    }

    private func status(_ role: DuoRole, _ day: String, met: Bool, at updatedAt: Date) -> DuoDayStatus {
        DuoDayStatus(role: role, day: day, goalMet: met, progressBucket: met ? 100 : 50, updatedAt: updatedAt)
    }

    // MARK: - Presets

    func testThereAreSixToEightPresetsAndNoneIsEmptyOrHasADash() {
        XCTAssertTrue((6...8).contains(DuoNudgePreset.allCases.count))
        for preset in DuoNudgePreset.allCases {
            XCTAssertFalse(preset.text.isEmpty)
            XCTAssertFalse(preset.text.contains("—"), preset.rawValue)
            XCTAssertLessThanOrEqual(preset.text.count, 60, "\(preset.rawValue) is too long for a notification line")
        }
        XCTAssertEqual(Set(DuoNudgePreset.allCases.map(\.text)).count, DuoNudgePreset.allCases.count)
    }

    func testAPresetThisVersionHasNeverHeardOfStillSaysSomethingOfOurs() {
        XCTAssertEqual(DuoNudgePreset.text(forID: "fromTheFuture"), DuoNudgePreset.fallbackText)
        // Whatever is in the record, the words come from this phone's table.
        XCTAssertEqual(DuoNudgePreset.text(forID: "Buy cheap watches at example.com"), DuoNudgePreset.fallbackText)
    }

    func testANudgeCarriesNoWordsOfItsOwn() throws {
        let data = try JSONEncoder().encode(DuoNudge.make(from: .owner, preset: .cheers, now: at(21, 10)))
        let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]).keys
        XCTAssertEqual(Set(keys), ["id", "fromRole", "presetID", "createdAt"])
    }

    func testNudgeRecordNamesAreRecognisedAndNothingElseIs() {
        XCTAssertTrue(DuoNudge.isNudgeRecordName(DuoNudge.make(from: .owner, preset: .cheers, now: at(21, 10)).id))
        for name in ["nudge-", "nudge-not-a-uuid", "owner-2026-09-21", "duo"] {
            XCTAssertFalse(DuoNudge.isNudgeRecordName(name), name)
        }
        // And the day-status parser from Phase 4 still wants nothing to do with one.
        XCTAssertNil(DuoRecordName.parseDayStatus("nudge-\(UUID().uuidString)"))
    }

    // MARK: - Rate limit

    func testThreeNudgesADayAndThenNoMore() {
        let now = at(21, 15)
        var sent: [DuoNudge] = []
        for index in 0..<3 {
            XCTAssertEqual(
                DuoNudgeRules.verdict(for: duo(nudges: sent), partnerStatus: nil, now: now, calendar: calendar),
                .allowed(remaining: 3 - index)
            )
            sent.append(nudge("a\(index)", from: .owner, at(21, 9 + index)))
        }
        XCTAssertEqual(DuoNudgeRules.verdict(for: duo(nudges: sent), partnerStatus: nil, now: now, calendar: calendar), .limitReached)
    }

    func testTheLimitIsPerPersonAndStartsAgainEachDay() {
        let theirs = (0..<3).map { nudge("p\($0)", from: .partner, at(21, 8 + $0)) }
        let yesterdays = (0..<3).map { nudge("y\($0)", from: .owner, at(20, 8 + $0)) }
        XCTAssertEqual(
            DuoNudgeRules.verdict(for: duo(nudges: theirs + yesterdays), partnerStatus: nil, now: at(21, 15), calendar: calendar),
            .allowed(remaining: 3),
            "my partner's nudges and my own from yesterday are not mine from today"
        )
    }

    func testNoNudgingSomeoneWhoHasAlreadyMetTheirGoal() {
        let met = status(.partner, "2026-09-21", met: true, at: at(21, 14))
        XCTAssertEqual(DuoNudgeRules.verdict(for: duo(), partnerStatus: met, now: at(21, 15), calendar: calendar), .partnerAlreadyMet)
    }

    func testNobodyToNudgeBeforeAnyoneJoinsOrAfterItEnds() {
        XCTAssertEqual(DuoNudgeRules.verdict(for: duo(joined: false), partnerStatus: nil, now: at(21, 15), calendar: calendar), .nobodyToNudge)
        XCTAssertEqual(DuoNudgeRules.verdict(for: duo(ended: true), partnerStatus: nil, now: at(21, 15), calendar: calendar), .nobodyToNudge)
    }

    func testOnlyMyOwnOldNudgesAreMineToClearAway() {
        let nudges = [
            nudge("old-mine", from: .owner, at(18, 9)),
            nudge("old-theirs", from: .partner, at(18, 9)),
            nudge("new-mine", from: .owner, at(21, 9)),
        ]
        XCTAssertEqual(DuoNudgeRules.expired(sentBy: .owner, nudges: nudges, now: at(21, 15)).map(\.id), ["nudge-old-mine"])
        XCTAssertEqual(DuoNudgeRules.current(nudges, now: at(21, 15)).map(\.id), ["nudge-new-mine"])
    }

    // MARK: - Never twice

    func testTheLedgerSaysYesOnceAndNoEveryTimeAfter() {
        var ledger = DuoLedger()
        XCTAssertTrue(ledger.markSeen("nudge-a"))
        XCTAssertFalse(ledger.markSeen("nudge-a"))
        XCTAssertTrue(ledger.hasSeen("nudge-a"))
        XCTAssertTrue(ledger.markSeen("nudge-b"))
    }

    func testSomethingThatWasNeverShownCanBeForgottenAndTriedAgain() {
        var ledger = DuoLedger()
        _ = ledger.markSeen("nudge-a")
        ledger.forget("nudge-a")
        XCTAssertTrue(ledger.markSeen("nudge-a"))
    }

    func testTheLedgerForgetsTheOldestFirstAndNeverGrowsPastItsCapacity() {
        var ledger = DuoLedger()
        for index in 0..<(DuoLedger.capacity + 25) { _ = ledger.markSeen("k\(index)") }
        XCTAssertEqual(ledger.seen.count, DuoLedger.capacity)
        XCTAssertFalse(ledger.hasSeen("k0"))
        XCTAssertTrue(ledger.hasSeen("k\(DuoLedger.capacity + 24)"))
    }

    func testTheLedgerSurvivesBeingSaved() throws {
        let suite = "DuoNudgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var ledger = DuoCache.loadLedger(from: defaults)
        _ = ledger.markSeen("nudge-a")
        DuoCache.save(ledger, to: defaults)
        XCTAssertTrue(DuoCache.loadLedger(from: defaults).hasSeen("nudge-a"))
    }

    private func plan(before: DuoState, after: DuoState, firstRead: Bool = false, ledger: inout DuoLedger, now: Date) -> [DuoAnnouncement] {
        DuoAnnouncements.plan(
            before: before,
            after: after,
            isFirstRead: firstRead,
            ledger: &ledger,
            myToday: DayKey.key(for: now, calendar: calendar),
            now: now,
            calendar: calendar
        )
    }

    func testANewNudgeIsAnnouncedOnceHoweverManyTimesItIsFetched() {
        let now = at(21, 15)
        let arrived = duo(nudges: [nudge("a", from: .partner, at(21, 14), preset: .sipWithMe)])
        var ledger = DuoLedger()

        let first = plan(before: duo(), after: arrived, ledger: &ledger, now: now)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.title, "Sam nudged you")
        XCTAssertEqual(first.first?.body, DuoNudgePreset.sipWithMe.text)
        XCTAssertEqual(first.first?.isActionable, true)

        // The push, then the background refresh, then opening the app. Same nudge.
        XCTAssertTrue(plan(before: arrived, after: arrived, ledger: &ledger, now: now).isEmpty)
        // Even if the cache was lost and it looks new again, the ledger remembers.
        XCTAssertTrue(plan(before: duo(), after: arrived, ledger: &ledger, now: now).isEmpty)
    }

    func testMyOwnNudgesAreNeverAnnouncedToMe() {
        var ledger = DuoLedger()
        let mine = duo(nudges: [nudge("mine", from: .owner, at(21, 14))])
        XCTAssertTrue(plan(before: duo(), after: mine, ledger: &ledger, now: at(21, 15)).isEmpty)
    }

    func testANudgeThatTurnsUpADayLateIsNotAnnouncedAndDoesNotComeBack() {
        var ledger = DuoLedger()
        let late = duo(nudges: [nudge("late", from: .partner, at(20, 9))])
        XCTAssertTrue(plan(before: duo(), after: late, ledger: &ledger, now: at(21, 15)).isEmpty)
        XCTAssertTrue(ledger.hasSeen("nudge-late"))
    }

    func testNoMoreThanThreeAreAnnouncedInADayWhateverTheOtherPhoneSends() {
        var ledger = DuoLedger()
        let flood = duo(nudges: (0..<10).map { nudge("f\($0)", from: .partner, at(21, 10, $0)) })
        XCTAssertEqual(plan(before: duo(), after: flood, ledger: &ledger, now: at(21, 11)).count, DuoNudgeRules.dailyLimit)
    }

    func testMyPartnerMeetingTheirGoalIsAnnouncedOnce() {
        let now = at(21, 15)
        let before = duo(statuses: [status(.partner, "2026-09-21", met: false, at: at(21, 12))])
        let after = duo(statuses: [status(.partner, "2026-09-21", met: true, at: at(21, 15))])
        var ledger = DuoLedger()

        let first = plan(before: before, after: after, ledger: &ledger, now: now)
        XCTAssertEqual(first.map(\.title), ["Sam hit their goal"])
        XCTAssertEqual(first.first?.body, "Your turn. Keep the flame going.")
        XCTAssertEqual(first.first?.isActionable, false)
        XCTAssertTrue(plan(before: before, after: after, ledger: &ledger, now: now).isEmpty)
    }

    func testTheWordingKnowsWhenWeHaveBothMadeIt() {
        let before = duo(statuses: [status(.owner, "2026-09-21", met: true, at: at(21, 10))])
        let after = duo(statuses: before.statuses + [status(.partner, "2026-09-21", met: true, at: at(21, 15))])
        var ledger = DuoLedger()
        XCTAssertEqual(plan(before: before, after: after, ledger: &ledger, now: at(21, 15)).first?.body, "You both made it today.")
    }

    func testAGoalFoundAlreadyMetOnAFirstReadIsNotNews() {
        var ledger = DuoLedger()
        let after = duo(statuses: [status(.partner, "2026-09-21", met: true, at: at(21, 9))])
        XCTAssertTrue(plan(before: duo(), after: after, firstRead: true, ledger: &ledger, now: at(21, 15)).isEmpty)
    }

    func testNothingIsAnnouncedAboutADuoThatHasEnded() {
        var ledger = DuoLedger()
        let after = duo(nudges: [nudge("a", from: .partner, at(21, 14))], ended: true)
        XCTAssertTrue(plan(before: duo(), after: after, ledger: &ledger, now: at(21, 15)).isEmpty)
    }

    // MARK: - Never at night

    func testInsideTheWakingWindowIsNow() {
        XCTAssertNil(DuoQuietHours.holdUntil(at(21, 9), startMinutes: 8 * 60, endMinutes: 22 * 60, calendar: calendar))
        XCTAssertNil(DuoQuietHours.holdUntil(at(21, 8), startMinutes: 8 * 60, endMinutes: 22 * 60, calendar: calendar), "the window opens on the minute")
    }

    func testLateAtNightWaitsForTomorrowMorning() {
        XCTAssertEqual(
            DuoQuietHours.holdUntil(at(21, 23, 30), startMinutes: 8 * 60, endMinutes: 22 * 60, calendar: calendar),
            at(22, 8)
        )
        XCTAssertEqual(
            DuoQuietHours.holdUntil(at(21, 22), startMinutes: 8 * 60, endMinutes: 22 * 60, calendar: calendar),
            at(22, 8),
            "the window closes on the minute"
        )
    }

    func testTheSmallHoursWaitForThisMorning() {
        XCTAssertEqual(
            DuoQuietHours.holdUntil(at(21, 3), startMinutes: 8 * 60, endMinutes: 22 * 60, calendar: calendar),
            at(21, 8)
        )
    }

    func testAWindowThatWrapsPastMidnightIsRespectedToo() {
        // A night shift: awake from ten at night until six in the morning.
        let start = 22 * 60, end = 6 * 60
        XCTAssertNil(DuoQuietHours.holdUntil(at(21, 23), startMinutes: start, endMinutes: end, calendar: calendar))
        XCTAssertNil(DuoQuietHours.holdUntil(at(21, 2), startMinutes: start, endMinutes: end, calendar: calendar))
        XCTAssertEqual(DuoQuietHours.holdUntil(at(21, 12), startMinutes: start, endMinutes: end, calendar: calendar), at(21, 22))
    }

    func testNoWindowAtAllHoldsNothing() {
        XCTAssertNil(DuoQuietHours.holdUntil(at(21, 3), startMinutes: 480, endMinutes: 480, calendar: calendar))
    }

    // MARK: - The invite moment

    func testTheSuggestionAppearsAfterThreeDaysAndOnlyToSomeoneWithNoDuo() {
        XCTAssertFalse(DuoInviteMoment.shouldShow(soloStreak: 2, hasAnyDuo: false, wasDismissed: false))
        XCTAssertTrue(DuoInviteMoment.shouldShow(soloStreak: 3, hasAnyDuo: false, wasDismissed: false))
        XCTAssertTrue(DuoInviteMoment.shouldShow(soloStreak: 40, hasAnyDuo: false, wasDismissed: false))
        XCTAssertFalse(DuoInviteMoment.shouldShow(soloStreak: 3, hasAnyDuo: true, wasDismissed: false))
    }

    func testOnceDismissedItNeverComesBack() {
        XCTAssertFalse(DuoInviteMoment.shouldShow(soloStreak: 300, hasAnyDuo: false, wasDismissed: true))
    }

    // MARK: - An older cache

    /// What Phase 4 wrote, before nudges existed. It has to keep reading, or an update
    /// would quietly empty the Duo screen of anyone who already had one.
    func testACacheWrittenBeforeNudgesExistedStillReads() throws {
        let json = """
        [{"id":"11111111-2222-4333-8444-555555555555","zoneName":"Duo-11111111-2222-4333-8444-555555555555",
          "zoneOwnerName":"__defaultOwner__","myRole":"owner","createdAt":780000000,
          "ownerDisplayName":"Jo","partnerDisplayName":"Sam","ownerSkin":"classic","partnerSkin":"forest",
          "statuses":[{"role":"owner","day":"2026-09-20","goalMet":true,"progressBucket":100,"updatedAt":780000000}],
          "partnerHasJoined":true}]
        """
        let duos = try JSONDecoder().decode([DuoState].self, from: Data(json.utf8))
        XCTAssertEqual(duos.count, 1)
        XCTAssertTrue(duos[0].allNudges.isEmpty)
        XCTAssertEqual(duos[0].statuses.count, 1)
    }

    func testNotificationsAreOnUntilTurnedOff() throws {
        let suite = "DuoNudgeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(DuoCache.notificationsEnabled(in: defaults))
        DuoCache.setNotificationsEnabled(false, in: defaults)
        XCTAssertFalse(DuoCache.notificationsEnabled(in: defaults))
    }
}
