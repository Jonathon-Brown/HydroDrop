import XCTest
@testable import HydroCore

/// The two pure steps of a duo's sync: a feed, with what it is worth announcing, and the write a
/// duo is owed (final design §6.4, §6.5, §9.5, §10.1 to §10.5; KV11, KV12, X14).
final class DuoSyncPlanTests: XCTestCase {
    private let id = UUID(uuidString: "6d2a0000-0000-4000-8000-000000000001")!
    /// 2026-09-21T15:00:00Z.
    private let now = Date(timeIntervalSince1970: 1_790_002_800)
    private let today = "2026-09-21"
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()
    private let nudgeID = "nudge-8F2A0000-0000-4000-8000-000000000002"

    private func header(_ id: UUID? = nil, state: DuoWireDuoState = .active, seq: Int64 = 9) -> DuoWireHeader {
        DuoWireHeader(id: (id ?? self.id).uuidString.lowercased(), myRole: .owner, state: state, createdAt: now.addingTimeInterval(-86_400 * 5),
                      joinedAt: now.addingTimeInterval(-86_400 * 4), endedAt: state == .ended ? now : nil, endedBy: state == .ended ? .partner : nil,
                      ownerDisplayName: "Jo", ownerSkin: "classic", partnerDisplayName: "Sam", partnerSkin: "forest", seq: seq)
    }

    private func feed(full: Bool = false, rows: [DuoWireStatusRow] = [], nudges: [DuoWireNudge] = [], handled: [DuoWireHandled] = [],
                      cursor: Int64 = 9, id: UUID? = nil) -> DuoWireChanges {
        DuoWireChanges(duo: header(id, seq: cursor), full: full, statuses: rows, nudges: nudges, handled: handled, cursor: cursor)
    }

    private func synced(statuses: [DuoDayStatus] = [], nudges: [DuoNudge] = [], syncedOnce: Bool = true) -> DuoState {
        DuoState(id: id, myRole: .owner, createdAt: now.addingTimeInterval(-86_400 * 5), ownerDisplayName: "Jo", partnerDisplayName: "Sam",
                 ownerSkin: "classic", partnerSkin: "forest", statuses: statuses, partnerHasJoined: true, nudges: nudges, cursor: 5,
                 syncedOnce: syncedOnce)
    }

    private func partnerNudge(_ id: String? = nil, age: TimeInterval = 3600) -> DuoWireNudge {
        DuoWireNudge(id: id ?? nudgeID, fromRole: .partner, presetId: "sipWithMe", createdAt: now.addingTimeInterval(-age))
    }

    private func partnerMet(_ day: String? = nil) -> DuoWireStatusRow {
        DuoWireStatusRow(role: .partner, day: day ?? today, goalMet: true, progressBucket: 100, updatedAt: now.addingTimeInterval(-60), ver: 3)
    }

    private func process(_ changes: DuoWireChanges, before: DuoState?, ledger: DuoLedger = DuoLedger(), delivered: Set<String> = [],
                         since: Int64? = nil) -> (duo: DuoState, announcements: [DuoAnnouncement], ledger: DuoLedger, isFirstRead: Bool)? {
        DuoSyncPlan.process(changes: changes, before: before, ledger: ledger, deliveredRemoteKeys: delivered, myToday: today, now: now,
                            calendar: utc, since: since)
    }

    // MARK: - A feed

    func testAPushTheServerAlreadySentIsMarkedSeenBeforeAnythingIsPlanned() throws {
        // KV12: `handled` lists the nudge, so the plan, which would announce it, finds it seen.
        let result = try XCTUnwrap(process(feed(nudges: [partnerNudge()], handled: [DuoWireHandled(kind: "nudge", id: nudgeID)]), before: synced()))
        XCTAssertTrue(result.announcements.isEmpty)
        XCTAssertTrue(result.ledger.hasSeen(nudgeID))
        XCTAssertEqual(result.duo.allNudges.map(\.id), [nudgeID], "handled says who was told, not what the duo holds")
    }

    func testAHandledGoalIsNotAnnouncedEither() throws {
        let result = try XCTUnwrap(process(feed(rows: [partnerMet()], handled: [DuoWireHandled(kind: "goal_met", day: today)]), before: synced()))
        XCTAssertTrue(result.announcements.isEmpty)
        XCTAssertTrue(result.ledger.hasSeen(DuoLedger.goalKey(duoID: id, day: today)))
    }

    func testWhatThePushesDidNotSayIsAnnouncedOnceAndOnlyOnce() throws {
        let first = try XCTUnwrap(process(feed(rows: [partnerMet()], nudges: [partnerNudge()]), before: synced()))
        XCTAssertEqual(Set(first.announcements.map(\.key)), [nudgeID, DuoLedger.goalKey(duoID: id, day: today)])
        XCTAssertFalse(first.isFirstRead)
        // The same feed again, as a push and a refresh that both fetch would see it: from the old
        // duo with the new ledger, and from the new duo.
        XCTAssertTrue(try XCTUnwrap(process(feed(rows: [partnerMet()], nudges: [partnerNudge()]), before: synced(), ledger: first.ledger)).announcements.isEmpty)
        XCTAssertTrue(try XCTUnwrap(process(feed(rows: [partnerMet()], nudges: [partnerNudge()]), before: first.duo, ledger: first.ledger)).announcements.isEmpty)
    }

    func testAnEventWhoseRemoteNotificationIsOnThisPhoneIsDroppedButStaysSeen() throws {
        // X14: a nudge seven hours old, whose push row expired so `handled` leaves it out. In the
        // delivered list the push said it; not in it, it is announced.
        let old = partnerNudge(age: 7 * 3600)
        let shown = try XCTUnwrap(process(feed(nudges: [old]), before: synced(), delivered: [nudgeID]))
        XCTAssertTrue(shown.announcements.isEmpty)
        XCTAssertTrue(shown.ledger.hasSeen(nudgeID), "never offered again")
        let missing = try XCTUnwrap(process(feed(nudges: [old]), before: synced()))
        XCTAssertEqual(missing.announcements.map(\.key), [nudgeID])
    }

    func testAFirstReadIsCatchingUpSoAGoalFoundMetIsNotNews() throws {
        let full = try XCTUnwrap(process(feed(full: true, rows: [partnerMet()]), before: synced()))
        XCTAssertTrue(full.isFirstRead)
        XCTAssertTrue(full.announcements.isEmpty)
        XCTAssertFalse(full.ledger.hasSeen(DuoLedger.goalKey(duoID: id, day: today)))
        // A duo this phone has not read since a reinstall, reconnect or link is a first read even
        // when the server answers with a delta.
        let unread = try XCTUnwrap(process(feed(rows: [partnerMet()]), before: synced(syncedOnce: false)))
        XCTAssertTrue(unread.isFirstRead)
        XCTAssertTrue(unread.announcements.isEmpty)
        // And a read of a duo already read is news.
        XCTAssertEqual(try XCTUnwrap(process(feed(rows: [partnerMet()]), before: synced())).announcements.count, 1)
    }

    func testAFirstReadStillAnnouncesARecentNudgeButNotAnOldOne() throws {
        let result = try XCTUnwrap(process(feed(full: true, nudges: [partnerNudge(), partnerNudge("nudge-8F2A0000-0000-4000-8000-000000000003", age: 13 * 3600)]),
                                           before: nil))
        XCTAssertEqual(result.announcements.map(\.key), [nudgeID])
        XCTAssertTrue(result.ledger.hasSeen("nudge-8F2A0000-0000-4000-8000-000000000003"), "too old to announce, marked seen anyway")
    }

    func testAForgottenKeyIsAnnouncedAgainTheNextTimeItComesUp() throws {
        // What the engine does with a key iOS refused: it is taken back out of the ledger.
        let first = try XCTUnwrap(process(feed(nudges: [partnerNudge()]), before: synced()))
        var ledger = first.ledger
        ledger.forget(nudgeID)
        XCTAssertEqual(try XCTUnwrap(process(feed(nudges: [partnerNudge()]), before: synced(), ledger: ledger)).announcements.map(\.key), [nudgeID])
    }

    func testAGoalForADayOverEverywhereIsNotAnnounced() throws {
        // X11's client side: the 20th is over everywhere at the 21st, 12:00Z, which is before now.
        let result = try XCTUnwrap(process(feed(rows: [partnerMet("2026-09-20")]), before: synced()))
        XCTAssertTrue(result.announcements.isEmpty)
    }

    func testAnEndedDuoAnnouncesNothing() throws {
        let changes = DuoWireChanges(duo: header(state: .ended), full: false, statuses: [partnerMet()], nudges: [partnerNudge()], handled: [], cursor: 9)
        let result = try XCTUnwrap(process(changes, before: synced()))
        XCTAssertTrue(result.duo.hasEnded)
        XCTAssertTrue(result.announcements.isEmpty)
    }

    func testAFeedForAnotherDuoIsNeverWrittenIntoThisOne() {
        XCTAssertNil(process(feed(rows: [partnerMet()], id: UUID(uuidString: "6d2a0000-0000-4000-8000-000000000099")!), before: synced()))
        var broken = feed()
        broken.duo.id = "not-a-uuid"
        XCTAssertNil(process(broken, before: nil))
    }

    // MARK: - Whether an answer still fits

    private func reply(cursor: Int64, full: Bool = false) -> DuoWireChanges {
        DuoWireChanges(duo: header(seq: cursor), full: full, statuses: [], nudges: [], handled: [], cursor: cursor)
    }

    func testAnAnswerAtOrAheadOfTheCursorFits() {
        var duo = synced()
        duo.cursor = 10
        XCTAssertTrue(DuoSyncPlan.answerFits(reply(cursor: 12), since: 10, before: duo))
        XCTAssertTrue(DuoSyncPlan.answerFits(reply(cursor: 10), since: 10, before: duo), "a header-only answer carries the since it was asked with")
        XCTAssertTrue(DuoSyncPlan.answerFits(reply(cursor: 15), since: 7, before: duo), "an answer to an older since is a superset")
    }

    func testAnAnswerBehindOneAlreadyAppliedDoesNotFit() {
        var duo = synced()
        duo.cursor = 14
        XCTAssertFalse(DuoSyncPlan.answerFits(reply(cursor: 11), since: 10, before: duo), "its rows are older than the ones held")
        XCTAssertFalse(DuoSyncPlan.answerFits(reply(cursor: 11, full: true), since: 10, before: duo), "a full answer to a since behind it is just old")
    }

    func testAFullAnswerToAPhoneAheadOfTheServerFitsHoweverOldItLooks() {
        // §6.4: `since > duo.seq` (a phone that outlived a restore of the server's database) is
        // answered in full, at the server's own lower cursor.
        var duo = synced()
        duo.cursor = 500
        XCTAssertTrue(DuoSyncPlan.answerFits(reply(cursor: 120, full: true), since: 500, before: duo))
        XCTAssertFalse(DuoSyncPlan.answerFits(reply(cursor: 120), since: 500, before: duo), "but not a delta")
    }

    func testARestoredServersAnswerFitsOnlyWhileTheCursorIsTheSinceItAnswers() {
        // D72: the restored server's full answer is taken once; a second full answer to the same
        // stale since, after the cursor has moved, is just behind.
        var duo = synced()
        duo.cursor = 600
        XCTAssertFalse(DuoSyncPlan.answerFits(reply(cursor: 120, full: true), since: 500, before: duo))
        duo.cursor = 500
        XCTAssertTrue(DuoSyncPlan.answerFits(reply(cursor: 120, full: true), since: 500, before: duo))
    }

    func testARestoredServersAnswerMovesTheCursorBackToTheServers() throws {
        var duo = synced()
        duo.cursor = 500
        let restored = DuoWireChanges(duo: header(seq: 120), full: true, statuses: [partnerMet()], nudges: [], handled: [], cursor: 120)
        let adopted = try XCTUnwrap(process(restored, before: duo, since: 500))
        XCTAssertEqual(adopted.duo.cursor, 120, "kept at 500, every row the restored server writes up to seq 500 would be skipped")
        let ordinary = try XCTUnwrap(process(DuoWireChanges(duo: header(seq: 530), full: false, statuses: [], nudges: [], handled: [], cursor: 530),
                                             before: duo, since: 500))
        XCTAssertEqual(ordinary.duo.cursor, 530)
        XCTAssertEqual(try XCTUnwrap(process(restored, before: duo)).duo.cursor, 500, "without the since nothing moves back")
    }

    func testAClockSetFarAheadDoesNotPruneTheCopy() throws {
        // Thirty days of both meeting the goal, read on a phone whose clock says twelve days on.
        var held: [DuoDayStatus] = []
        var day = "2026-08-23"
        for _ in 0..<30 {
            held += [DuoDayStatus(role: .owner, day: day, goalMet: true, progressBucket: 100, updatedAt: now),
                     DuoDayStatus(role: .partner, day: day, goalMet: true, progressBucket: 100, updatedAt: now)]
            day = DayKey.nextDayKey(after: day, calendar: utc)!
        }
        let duo = synced(statuses: held)
        let ahead = now.addingTimeInterval(12 * 86_400)
        let delta = DuoWireChanges(duo: header(seq: 12), full: false, statuses: [], nudges: [], handled: [], cursor: 12)
        let result = try XCTUnwrap(DuoSyncPlan.process(changes: delta, before: duo, ledger: DuoLedger(), deliveredRemoteKeys: [],
                                                       myToday: DayKey.key(for: ahead, calendar: utc), now: ahead, calendar: utc))
        XCTAssertEqual(result.duo.statuses.count, 60, "pruned as of two days past the newest row, not as of the clock")
        XCTAssertEqual(DuoSyncPlan.pruneDay(myToday: "2026-10-03", held: held), "2026-09-23")
        XCTAssertEqual(DuoSyncPlan.pruneDay(myToday: "2026-09-21", held: held), "2026-09-21", "an ordinary clock prunes as of today")
        XCTAssertEqual(DuoSyncPlan.pruneDay(myToday: "2026-09-21", held: []), "2026-09-21")
    }

    func testAnAnswerToADuoReseatedWhileItWasOutDoesNotFit() {
        // A reconnect or a restore made it unread (cursor 0, `syncedOnce` false): only a read of
        // the whole duo counts now.
        let reseated = DuoMapping.reseated({ var duo = synced(); duo.cursor = 10; return duo }())
        XCTAssertFalse(DuoSyncPlan.answerFits(reply(cursor: 12), since: 10, before: reseated))
        XCTAssertTrue(DuoSyncPlan.answerFits(reply(cursor: 12, full: true), since: 0, before: reseated))
    }

    // MARK: - A write

    private func summary(_ totals: [String: Int], goal: Int = 2000) -> DuoLogSummary {
        DuoLogSummary(totalsByDay: totals, goalML: goal, earliestEntryDay: "2026-01-01")
    }

    private func write(_ duo: DuoState, _ summary: DuoLogSummary?, coverage: String = "2026-01-01", refused: DuoRejectedDays = DuoRejectedDays(),
                       holding: [DuoDayStatus] = [], installAge: TimeInterval = .infinity) -> (write: DuoSyncPlan.Write?, rejectedDays: DuoRejectedDays) {
        DuoSyncPlan.write(for: duo, summary: summary, coverageStart: coverage, rejectedDays: refused, holding: holding, installAge: installAge,
                          myToday: today, now: now, calendar: utc)
    }

    private func mine(_ day: String, _ bucket: Int) -> DuoDayStatus {
        DuoDayStatus(role: .owner, day: day, goalMet: bucket == 100, progressBucket: bucket, updatedAt: now)
    }

    func testAWriteCarriesTheVerLastSeenAsBaseVerAndTheCursorAsSince() throws {
        var duo = synced(statuses: [mine(today, 25)])
        duo.vers = ["owner-\(today)": 37, "partner-\(today)": 99]
        duo.cursor = 410
        let owed = try XCTUnwrap(write(duo, summary([today: 1000, "2026-09-20": 2000])).write)
        XCTAssertEqual(owed.request, DuoWirePutStatusesRequest(myToday: today, since: 410, statuses: [
            DuoWireStatusIn(day: today, goalMet: false, progressBucket: 50, baseVer: 37),
            DuoWireStatusIn(day: "2026-09-20", goalMet: true, progressBucket: 100, baseVer: 0),
        ]))
        XCTAssertEqual(owed.rows.map(\.role), [.owner, .owner], "only ever this phone's own side")
    }

    func testNothingIsWrittenToADuoBeforeItHasBeenRead() {
        // KV11's third case: the first PUT before any fetch is refused by the plan.
        XCTAssertNil(write(synced(syncedOnce: false), summary([today: 2000])).write)
    }

    func testNothingIsOwedToAnEndedDuoOrOneWithALeaveWaiting() {
        var ended = synced()
        ended.endedAt = now
        XCTAssertNil(write(ended, summary([today: 2000])).write)
        var leaving = synced()
        leaving.pendingOp = .leave
        XCTAssertNil(write(leaving, summary([today: 2000])).write)
    }

    func testALogWithNoGoalOrNoLogAtAllOwesNothing() {
        // Judged against a goal of 0 every day of the week reads as missed.
        XCTAssertNil(write(synced(statuses: [mine(today, 100)]), summary([:], goal: 0)).write)
        XCTAssertNil(write(synced(), nil).write)
    }

    func testAWriteSaysNothingTheServerAlreadyHolds() {
        XCTAssertNil(write(synced(statuses: [mine(today, 50)]), summary([today: 1000])).write)
    }

    func testTodayIsWrittenEvenEmptyAndAnEmptyPastDayIsNot() throws {
        let owed = try XCTUnwrap(write(synced(), summary([:])).write)
        XCTAssertEqual(owed.request.statuses, [DuoWireStatusIn(day: today, goalMet: false, progressBucket: 0, baseVer: 0)])
    }

    func testAPastDayBeforeCoverageIsNeverLowered() {
        let duo = synced(statuses: [mine(today, 0), mine("2026-09-19", 100)])
        XCTAssertNil(write(duo, summary([:]), coverage: today).write, "the log may not be back yet (§10.5)")
        XCTAssertEqual(write(duo, summary([:]), coverage: "2026-01-01").write?.request.statuses.map(\.day), ["2026-09-19"])
    }

    func testARefusedRowIsSkippedUntilWhatIsWantedChangesAndSettledDaysComeBack() throws {
        var refused = DuoRejectedDays()
        refused.record(mine(today, 50))
        refused.record(mine("2026-09-01", 25))
        let skipped = write(synced(), summary([today: 1000]), refused: refused)
        XCTAssertNil(skipped.write)
        XCTAssertTrue(skipped.rejectedDays.blocks(mine(today, 50)))
        XCTAssertFalse(skipped.rejectedDays.blocks(mine("2026-09-01", 25)), "older than nine days is forgotten")
        let changed = write(synced(), summary([today: 1500]), refused: refused)
        XCTAssertEqual(changed.write?.request.statuses.map(\.progressBucket), [75])
        XCTAssertFalse(changed.rejectedDays.blocks(mine(today, 50)), "a change in what is wanted clears the refusal")
    }

    func testAHeldRowIsLeftOutWhileItIsStillWhatIsWanted() {
        let duo = synced()
        let owed = write(duo, summary([today: 1000, "2026-09-20": 500]), holding: [mine("2026-09-20", 25)]).write
        XCTAssertEqual(owed?.request.statuses.map(\.day), [today])
        XCTAssertNil(write(duo, summary([today: 0, "2026-09-20": 500]), holding: [mine(today, 0), mine("2026-09-20", 25)]).write)
        XCTAssertEqual(write(duo, summary([today: 0, "2026-09-20": 1000]), holding: [mine(today, 0), mine("2026-09-20", 25)]).write?
                        .request.statuses.map(\.day), ["2026-09-20"], "once the log wants something else, it is sent")
    }

    // MARK: - D71, a young install only raises

    func testAYoungInstallNeverLowersARowPastOrToday() {
        // A reinstall whose iCloud mirror has brought back one old drink and nothing of the week:
        // coverage reaches back before the week, so without D71 every met day would be lowered.
        let duo = synced(statuses: [mine(today, 100), mine("2026-09-20", 100), mine("2026-09-19", 75)])
        let partial = DuoLogSummary(totalsByDay: [today: 500], goalML: 2000, earliestEntryDay: "2026-08-01")
        let young = write(duo, partial, coverage: "2026-08-01", installAge: 47 * 3600 + 59 * 60).write
        XCTAssertNil(young, "47 h 59 after the install day ended: nothing is lowered, today included")
        let grown = write(duo, partial, coverage: "2026-08-01", installAge: DuoSyncPlan.youngInstallWindow).write
        XCTAssertEqual(grown?.request.statuses.map(\.day), [today, "2026-09-20", "2026-09-19"], "at 48 h the ordinary diff applies")
    }

    func testAYoungInstallStillRaisesAndWritesDaysItHasNoRowFor() {
        let duo = synced(statuses: [mine(today, 25), mine("2026-09-20", 100)])
        let owed = write(duo, summary([today: 1500, "2026-09-19": 2000]), installAge: 3600).write
        XCTAssertEqual(owed?.request.statuses.map(\.day), [today, "2026-09-19"], "a raise and a new day go; the met 20th is not lowered")
        let empty = write(synced(), summary([:]), installAge: 3600).write
        XCTAssertEqual(empty?.request.statuses, [DuoWireStatusIn(day: today, goalMet: false, progressBucket: 0, baseVer: 0)],
                       "today at 0 with no row held lowers nothing")
    }

    // MARK: - D78, the young window counts from the end of the install day

    private func zone(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func isYoung(installedAt install: Date, hoursLater: Double, calendar: Calendar) -> Bool {
        let installDay = DayKey.key(for: install, calendar: calendar)
        let age = DuoCoverage.installAge(installDay: installDay, now: install.addingTimeInterval(hoursLater * 3600), calendar: calendar)
        return age < DuoSyncPlan.youngInstallWindow
    }

    func testTheInstallAgeCountsFromTheEndOfTheInstallDay() {
        XCTAssertEqual(DuoCoverage.installAge(installDay: today, now: now, calendar: utc), -9 * 3600, "the install day is not over: 9 hours to go")
        XCTAssertEqual(DuoCoverage.installAge(installDay: "2026-09-19", now: now, calendar: utc), 39 * 3600)
        XCTAssertEqual(DuoCoverage.installAge(installDay: "garbage", now: now, calendar: utc), 0, "an unreadable day is a new install")
    }

    func testTheWindowEndsFortyEightHoursAfterTheInstallDayEnds() {
        // 2026-09-21T00:00:00Z, the start of the install day; its end is 24 hours later.
        let dayStart = Date(timeIntervalSince1970: 1_789_948_800)
        XCTAssertTrue(isYoung(installedAt: dayStart, hoursLater: 71 + 59.0 / 60, calendar: utc), "47 h 59 after the day ended")
        XCTAssertFalse(isYoung(installedAt: dayStart, hoursLater: 72, calendar: utc), "48 h after the day ended")
        // An install a minute before midnight is protected for 48 hours and a minute, one a minute
        // after for 71 hours and 59 minutes: never less than 48 hours, never more than 72.
        let lateInstall = dayStart.addingTimeInterval(23 * 3600 + 59 * 60)
        XCTAssertTrue(isYoung(installedAt: lateInstall, hoursLater: 48, calendar: utc))
        XCTAssertFalse(isYoung(installedAt: lateInstall, hoursLater: 48 + 1.0 / 60, calendar: utc))
        let earlyInstall = dayStart.addingTimeInterval(60)
        XCTAssertTrue(isYoung(installedAt: earlyInstall, hoursLater: 71 + 58.0 / 60, calendar: utc))
        XCTAssertFalse(isYoung(installedAt: earlyInstall, hoursLater: 71 + 59.0 / 60, calendar: utc))
    }

    func testAYoungInstallLowersNothingUntilSeventyTwoHoursAfterTheInstallDayBegan() {
        let duo = synced(statuses: [mine(today, 100), mine("2026-09-20", 100)])
        let partial = DuoLogSummary(totalsByDay: [today: 500], goalML: 2000, earliestEntryDay: "2026-08-01")
        let dayStart = Date(timeIntervalSince1970: 1_789_948_800)
        let before = DuoCoverage.installAge(installDay: "2026-09-21", now: dayStart.addingTimeInterval(71 * 3600 + 59 * 60), calendar: utc)
        XCTAssertNil(write(duo, partial, coverage: "2026-08-01", installAge: before).write)
        let after = DuoCoverage.installAge(installDay: "2026-09-21", now: dayStart.addingTimeInterval(72 * 3600), calendar: utc)
        XCTAssertEqual(write(duo, partial, coverage: "2026-08-01", installAge: after).write?.request.statuses.map(\.day), [today, "2026-09-20"])
    }

    func testAChangeOfTimeZoneMovesTheEndOfTheInstallDayByTheChange() {
        // The install day is read in the phone's calendar now. Flying 26 hours west moves the end of
        // that day 26 hours later, which lengthens the window; flying east shortens it as much.
        let east = zone("Pacific/Kiritimati")   // UTC+14
        let west = zone("Etc/GMT+12")            // UTC-12
        let ageEast = DuoCoverage.installAge(installDay: today, now: now, calendar: east)
        let ageWest = DuoCoverage.installAge(installDay: today, now: now, calendar: west)
        XCTAssertEqual(ageEast - ageWest, 26 * 3600, "an install day ends 26 hours later in UTC-12 than in UTC+14")
        // Installed at 23:59 in UTC+14, then read in UTC-12: protected for 74 hours and a minute.
        let installEast = Date(timeIntervalSince1970: 1_789_948_800 - 14 * 3600 + 23 * 3600 + 59 * 60)
        XCTAssertEqual(DayKey.key(for: installEast, calendar: east), today)
        XCTAssertLessThan(DuoCoverage.installAge(installDay: today, now: installEast.addingTimeInterval(74 * 3600), calendar: west), DuoSyncPlan.youngInstallWindow)
        XCTAssertGreaterThanOrEqual(DuoCoverage.installAge(installDay: today, now: installEast.addingTimeInterval(74 * 3600 + 60), calendar: west),
                                    DuoSyncPlan.youngInstallWindow)
        // Installed at 00:01 in UTC-12, then read in UTC+14: protected for 45 hours and 59 minutes.
        let installWest = Date(timeIntervalSince1970: 1_789_948_800 + 12 * 3600 + 60)
        XCTAssertEqual(DayKey.key(for: installWest, calendar: west), today)
        XCTAssertLessThan(DuoCoverage.installAge(installDay: today, now: installWest.addingTimeInterval(45 * 3600 + 58 * 60), calendar: east),
                          DuoSyncPlan.youngInstallWindow)
        XCTAssertGreaterThanOrEqual(DuoCoverage.installAge(installDay: today, now: installWest.addingTimeInterval(45 * 3600 + 59 * 60), calendar: east),
                                    DuoSyncPlan.youngInstallWindow)
    }

    func testAWriteNeverHoldsMoreThanTheWeek() throws {
        var totals: [String: Int] = [:]
        for offset in 0..<20 { totals[DayKey.key(for: now.addingTimeInterval(-Double(offset) * 86_400), calendar: utc)] = 2000 }
        let owed = try XCTUnwrap(write(synced(), summary(totals)).write)
        XCTAssertEqual(owed.request.statuses.count, DuoStreak.correctionWindowDays)
    }

    func testWantedIsTheLastSevenDaysTodayFirst() {
        let wanted = DuoSyncPlan.wanted(role: .partner, summary: summary([today: 2000, "2026-09-15": 500]), myToday: today, now: now, calendar: utc)
        XCTAssertEqual(wanted.map(\.day), ["2026-09-21", "2026-09-20", "2026-09-19", "2026-09-18", "2026-09-17", "2026-09-16", "2026-09-15"])
        XCTAssertEqual(wanted.map(\.progressBucket), [100, 0, 0, 0, 0, 0, 25])
        XCTAssertEqual(Set(wanted.map(\.role)), [.partner])
    }
}
