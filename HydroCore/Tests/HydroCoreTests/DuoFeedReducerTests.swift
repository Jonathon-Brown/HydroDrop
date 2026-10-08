import XCTest
@testable import HydroCore

/// The change feed applied to a duo, the way every fetch, write and join applies it.
final class DuoFeedReducerTests: XCTestCase {
    private let id = "6d2a0000-0000-4000-8000-000000000001"
    private let now = Date(timeIntervalSince1970: 1_790_000_000)
    private var today: String { DayKey.key(for: now, calendar: utc) }
    private var yesterday: String { DayKey.key(for: now.addingTimeInterval(-86_400), calendar: utc) }
    private let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private func header(state: DuoWireDuoState = .active, full: Bool = true, seq: Int64 = 5) -> DuoWireHeader {
        DuoWireHeader(id: id, myRole: .owner, state: state, createdAt: full ? now.addingTimeInterval(-86_400 * 5) : nil,
                      joinedAt: full ? now.addingTimeInterval(-86_400 * 4) : nil, endedAt: state == .ended ? now : nil,
                      endedBy: state == .ended ? .owner : nil, ownerDisplayName: full ? "Jo" : nil, ownerSkin: full ? "classic" : nil,
                      partnerDisplayName: full ? "Sam" : nil, partnerSkin: full ? "forest" : nil, partnerLastWriteDay: nil,
                      partnerIsDemo: nil, invite: nil, seq: seq)
    }

    private func row(_ role: DuoRole, _ day: String, _ bucket: Int, ver: Int64) -> DuoWireStatusRow {
        DuoWireStatusRow(role: role, day: day, goalMet: bucket == 100, progressBucket: bucket, updatedAt: now, ver: ver)
    }

    private func feed(_ header: DuoWireHeader, full: Bool = false, rows: [DuoWireStatusRow] = [], nudges: [DuoWireNudge] = [],
                      handled: [DuoWireHandled] = [], cursor: Int64 = 5) -> DuoWireChanges {
        DuoWireChanges(duo: header, full: full, statuses: rows, nudges: nudges, handled: handled, cursor: cursor)
    }

    func testAFullFeedReplacesEverythingAndRecordsEachRowsVer() throws {
        var old = try XCTUnwrap(DuoMapping.duo(from: header(), previous: nil, now: now))
        old.statuses = [DuoDayStatus(role: .owner, day: yesterday, goalMet: true, progressBucket: 100, updatedAt: now)]
        old.vers = ["owner-\(yesterday)": 9]
        old.nudges = [DuoNudge(id: "nudge-8F2A0000-0000-4000-8000-000000000002", fromRole: .partner, presetID: "sipWithMe", createdAt: now)]
        let result = try XCTUnwrap(DuoFeedReducer.apply(feed(header(), full: true, rows: [row(.owner, today, 50, ver: 2), row(.partner, today, 100, ver: 7)], cursor: 12),
                                                         to: old, myToday: today, now: now))
        XCTAssertTrue(result.isFirstRead)
        XCTAssertEqual(result.duo.statuses.map(\.day), [today, today])
        XCTAssertEqual(result.duo.vers, ["owner-\(today)": 2, "partner-\(today)": 7])
        XCTAssertTrue(result.duo.allNudges.isEmpty, "a full feed replaces the nudges too")
        XCTAssertEqual(result.duo.cursor, 12)
        XCTAssertTrue(result.duo.syncedOnce)
    }

    func testADeltaUpsertsAndLeavesTheRestAlone() throws {
        var old = try XCTUnwrap(DuoMapping.duo(from: header(), previous: nil, now: now))
        old.statuses = [DuoDayStatus(role: .owner, day: yesterday, goalMet: true, progressBucket: 100, updatedAt: now)]
        old.vers = ["owner-\(yesterday)": 3]
        old.cursor = 5
        let result = try XCTUnwrap(DuoFeedReducer.apply(feed(header(seq: 9), rows: [row(.partner, today, 25, ver: 1)], cursor: 9), to: old, myToday: today, now: now))
        XCTAssertFalse(result.isFirstRead)
        XCTAssertEqual(result.duo.statuses.count, 2)
        XCTAssertEqual(result.duo.vers["owner-\(yesterday)"], 3)
        XCTAssertEqual(result.duo.vers["partner-\(today)"], 1)
        XCTAssertEqual(result.duo.cursor, 9)
    }

    func testTheCursorNeverMovesBack() throws {
        var old = try XCTUnwrap(DuoMapping.duo(from: header(), previous: nil, now: now))
        old.cursor = 40
        let result = try XCTUnwrap(DuoFeedReducer.apply(feed(header(full: false), cursor: 0), to: old, myToday: today, now: now))
        XCTAssertEqual(result.duo.cursor, 40, "a header-only answer carries the client's own since")
    }

    func testRowsThisBuildCannotHoldAreDroppedAndADaySentTwiceTakesTheLast() throws {
        let rows = [row(.owner, "2026-02-30", 25, ver: 1), row(.owner, today, 25, ver: 1), row(.owner, today, 75, ver: 2)]
        let result = try XCTUnwrap(DuoFeedReducer.apply(feed(header(), rows: rows), to: nil, myToday: today, now: now))
        XCTAssertEqual(result.duo.statuses.map(\.progressBucket), [75])
        XCTAssertEqual(result.duo.vers, ["owner-\(today)": 2])
    }

    func testNudgesAreMergedByIdAndTheOldOnesGo() throws {
        let fresh = DuoWireNudge(id: "nudge-8F2A0000-0000-4000-8000-000000000002", fromRole: .partner, presetId: "sipWithMe", createdAt: now.addingTimeInterval(-60))
        let stale = DuoWireNudge(id: "nudge-8F2A0000-0000-4000-8000-000000000003", fromRole: .partner, presetId: "cheers", createdAt: now.addingTimeInterval(-3 * 86_400))
        let broken = DuoWireNudge(id: "nudge-nope", fromRole: .partner, presetId: "cheers", createdAt: now)
        let first = try XCTUnwrap(DuoFeedReducer.apply(feed(header(), nudges: [fresh, stale, broken]), to: nil, myToday: today, now: now))
        XCTAssertEqual(first.duo.allNudges.map(\.id), [fresh.id])
        let again = try XCTUnwrap(DuoFeedReducer.apply(feed(header(), nudges: [fresh]), to: first.duo, myToday: today, now: now))
        XCTAssertEqual(again.duo.allNudges.count, 1, "the same nudge twice is one")
    }

    func testWhatThePushesAlreadySaidBecomesLedgerKeys() throws {
        let handled = [DuoWireHandled(kind: "goal_met", day: today, id: nil),
                       DuoWireHandled(kind: "nudge", day: nil, id: "nudge-8F2A0000-0000-4000-8000-000000000002"),
                       DuoWireHandled(kind: "from_the_future", day: nil, id: nil),
                       DuoWireHandled(kind: "nudge", day: nil, id: "nudge-bad")]
        let result = try XCTUnwrap(DuoFeedReducer.apply(feed(header(), handled: handled), to: nil, myToday: today, now: now))
        XCTAssertEqual(result.handledKeys, ["met|\(id)|\(today)", "nudge-8F2A0000-0000-4000-8000-000000000002"])
    }

    func testAHeaderOnlyFeedChangesOnlyTheHeader() throws {
        var old = try XCTUnwrap(DuoMapping.duo(from: header(), previous: nil, now: now))
        old.statuses = [DuoDayStatus(role: .owner, day: today, goalMet: false, progressBucket: 25, updatedAt: now)]
        old.vers = ["owner-\(today)": 4]
        let ended = try XCTUnwrap(DuoFeedReducer.apply(feed(header(state: .ended, full: false)), to: old, myToday: today, now: now))
        XCTAssertTrue(ended.duo.hasEnded)
        XCTAssertEqual(ended.duo.statuses.count, 1)
        XCTAssertEqual(ended.duo.vers["owner-\(today)"], 4)
        XCTAssertEqual(ended.duo.partnerDisplayName, "Sam")
    }

    func testADayThatIsPrunedLosesItsVer() throws {
        let old = DayKey.key(for: now.addingTimeInterval(-86_400 * 120), calendar: utc)
        let result = try XCTUnwrap(DuoFeedReducer.apply(feed(header(), rows: [row(.owner, old, 100, ver: 5), row(.owner, today, 50, ver: 1)]), to: nil, myToday: today, now: now))
        XCTAssertEqual(result.duo.statuses.map(\.day), [today])
        XCTAssertEqual(result.duo.vers, ["owner-\(today)": 1])
    }

    func testAnUpdateMeRequestComesBackOutOfItsBytes() throws {
        for request in [DuoWireUpdateMeRequest(), DuoWireUpdateMeRequest(displayName: .null), DuoWireUpdateMeRequest(displayName: .value("Sam"), skin: .value("forest"), termsVersion: .value(1))] {
            let bytes = try DuoWireCoding.encode(request)
            let again = try DuoWireCoding.decode(DuoWireUpdateMeRequest.self, from: bytes)
            XCTAssertEqual(again, request)
            XCTAssertEqual(try DuoWireCoding.encode(again), bytes, "a replay writes the very same bytes")
        }
        let push = DuoWireRegisterPushRequest(token: "ab", apnsEnv: "sandbox", tz: "Europe/London", wakeStartMin: 480, wakeEndMin: 1320, notificationsEnabled: true)
        let pushBytes = try DuoWireCoding.encode(push)
        XCTAssertEqual(try DuoWireCoding.encode(try DuoWireCoding.decode(DuoWireRegisterPushRequest.self, from: pushBytes)), pushBytes)
    }

    func testTheApprovedWordsAreTheDesignsWords() {
        XCTAssertEqual(DuoCopy.leaveMessage(partner: "Sam", alsoEndsAnotherDuo: false).components(separatedBy: "\n\n").count, 1)
        XCTAssertTrue(DuoCopy.leaveMessage(partner: "Sam", alsoEndsAnotherDuo: true).hasSuffix("\n\nYour other duo with Sam ends too."))
        XCTAssertTrue(DuoCopy.leaveMessage(partner: "Sam", alsoEndsAnotherDuo: false).hasPrefix("This ends the duo for both of you and the shared streak is gone."))
        XCTAssertTrue(DuoCopy.blockMessage(partner: "Sam", onEndedCard: false, sharesAnotherDuo: false).hasPrefix("This ends your duo with Sam, and any other you share. For a year,"))
        XCTAssertTrue(DuoCopy.blockMessage(partner: "Sam", onEndedCard: true, sharesAnotherDuo: true).hasPrefix("This ends any other duo you share with Sam. For a year,"))
        XCTAssertTrue(DuoCopy.blockMessage(partner: "Sam", onEndedCard: true, sharesAnotherDuo: false).hasPrefix("For a year,"))
        XCTAssertEqual(DuoCopy.blockTitle(partner: "Sam"), "Block Sam?")
        XCTAssertEqual(DuoCopy.restorePrompt(partner: "Alex", name: "Jo"), "This phone was connected to a duo with Alex. Continue as Jo?")
        XCTAssertEqual(DuoCopy.streakText(days: 130, reachedEdge: true), "100+ days")
        XCTAssertEqual(DuoCopy.streakText(days: 12, reachedEdge: false), "12")
        XCTAssertEqual(DuoCopy.explainerLines.count, 6)
    }
}
