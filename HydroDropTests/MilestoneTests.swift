import XCTest
@testable import HydroDrop

final class StreakMilestoneTests: XCTestCase {
    func testMilestonesAreTheAdvertisedDays() {
        XCTAssertEqual(StreakMilestone.allCases.map(\.days), [3, 7, 14, 30, 60, 100, 365])
    }

    func testReachedIncludesEveryMilestonePassed() {
        XCTAssertEqual(StreakMilestone.reached(by: 0).map(\.days), [])
        XCTAssertEqual(StreakMilestone.reached(by: 2).map(\.days), [])
        XCTAssertEqual(StreakMilestone.reached(by: 3).map(\.days), [3])
        XCTAssertEqual(StreakMilestone.reached(by: 31).map(\.days), [3, 7, 14, 30])
        XCTAssertEqual(StreakMilestone.reached(by: 500).map(\.days), [3, 7, 14, 30, 60, 100, 365])
    }

    func testNothingToCelebrateBelowTheFirstMilestone() {
        XCTAssertNil(StreakMilestone.newlyReached(streak: 2, alreadyCelebrated: []))
    }

    func testCelebratesTheMilestoneJustReached() {
        XCTAssertEqual(StreakMilestone.newlyReached(streak: 7, alreadyCelebrated: [3]), .oneWeek)
    }

    /// A streak restored from another device can cross several at once, and a queue of
    /// celebrations to dismiss is not a moment.
    func testOnlyTheHighestNewMilestoneIsCelebrated() {
        XCTAssertEqual(StreakMilestone.newlyReached(streak: 40, alreadyCelebrated: []), .oneMonth)
    }

    func testAnAlreadyCelebratedMilestoneIsNotRepeated() {
        XCTAssertNil(StreakMilestone.newlyReached(streak: 8, alreadyCelebrated: [3, 7]))
    }

    func testEveryMilestoneHasItsOwnIconAndWords() {
        XCTAssertEqual(Set(StreakMilestone.allCases.map(\.icon)).count, StreakMilestone.allCases.count)
        XCTAssertEqual(Set(StreakMilestone.allCases.map(\.title)).count, StreakMilestone.allCases.count)
        for milestone in StreakMilestone.allCases {
            XCTAssertFalse(milestone.blurb.isEmpty)
            // Rule for all user-facing copy in this app.
            XCTAssertFalse(milestone.blurb.contains("\u{2014}"), "\(milestone.title) uses an em dash")
        }
    }
}

final class LongestStreakTests: XCTestCase {
    private let calendar = Calendar.current

    /// Builds entries `daysAgo` back, one per listed offset, each meeting the goal.
    private func entries(metOn offsets: [Int], amountML: Int = 2_000) -> [WaterEntry] {
        offsets.compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return WaterEntry(amountML: amountML, timestamp: day)
        }
    }

    func testNoHistoryIsNoStreak() {
        XCTAssertEqual(StreakCalculator.longestStreak(entries: [], goalML: 2_000, calendar: calendar), 0)
    }

    func testASingleDayIsAStreakOfOne() {
        XCTAssertEqual(
            StreakCalculator.longestStreak(entries: entries(metOn: [3]), goalML: 2_000, calendar: calendar),
            1
        )
    }

    /// The point of this calculation: a long run finished in the past still counts,
    /// even though the current streak is shorter.
    func testFindsTheBestRunEvenWhenItIsNotTheCurrentOne() {
        // A five-day run a while back, a gap, then two days recently.
        let history = entries(metOn: [20, 19, 18, 17, 16, 1, 0])
        XCTAssertEqual(
            StreakCalculator.longestStreak(entries: history, goalML: 2_000, calendar: calendar),
            5
        )
    }

    func testDaysBelowTheGoalBreakTheRun() {
        let history = entries(metOn: [5, 4, 3]) + entries(metOn: [2], amountML: 100) + entries(metOn: [1, 0])
        XCTAssertEqual(
            StreakCalculator.longestStreak(entries: history, goalML: 2_000, calendar: calendar),
            3
        )
    }

    /// Same rule as `currentStreak`: a freeze bridges the gap without counting itself.
    func testAFrozenDayBridgesWithoutCounting() {
        let history = entries(metOn: [4, 3, 1, 0])
        guard let missed = calendar.date(byAdding: .day, value: -2, to: Date()) else {
            return XCTFail("could not build the missed day")
        }
        let frozen = [DayKey.key(for: missed, calendar: calendar)]
        XCTAssertEqual(
            StreakCalculator.longestStreak(entries: history, goalML: 2_000, frozenDayKeys: frozen, calendar: calendar),
            4
        )
        XCTAssertEqual(
            StreakCalculator.longestStreak(entries: history, goalML: 2_000, calendar: calendar),
            2,
            "without the freeze the same history is two separate runs"
        )
    }

    func testNoGoalIsNoStreak() {
        XCTAssertEqual(
            StreakCalculator.longestStreak(entries: entries(metOn: [2, 1, 0]), goalML: 0, calendar: calendar),
            0
        )
    }

    /// Drink types apply here too, because this is built on the same daily totals.
    func testTheHydratedTotalDecidesWhetherADayCounted() {
        let history = (0...2).compactMap { offset -> WaterEntry? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: Date()) else { return nil }
            return WaterEntry(amountML: 2_000, timestamp: day, drinkType: .juice)
        }
        XCTAssertEqual(StreakCalculator.longestStreak(entries: history, goalML: 2_000, calendar: calendar), 0)
        XCTAssertEqual(StreakCalculator.longestStreak(entries: history, goalML: 1_700, calendar: calendar), 3)
    }
}

final class DayKeyNextDayTests: XCTestCase {
    func testNextDayCrossesAMonthBoundary() {
        XCTAssertEqual(DayKey.nextDayKey(after: "2026-01-31"), "2026-02-01")
    }

    func testNextDayCrossesAYearBoundary() {
        XCTAssertEqual(DayKey.nextDayKey(after: "2026-12-31"), "2027-01-01")
    }

    func testNextDayHandlesALeapDay() {
        XCTAssertEqual(DayKey.nextDayKey(after: "2028-02-28"), "2028-02-29")
        XCTAssertEqual(DayKey.nextDayKey(after: "2028-02-29"), "2028-03-01")
    }

    func testNextDayRejectsAMalformedKey() {
        XCTAssertNil(DayKey.nextDayKey(after: "not-a-day"))
    }

    func testPreviousAndNextAreInverses() {
        for key in ["2026-03-01", "2026-12-31", "2028-02-29", "2026-07-15"] {
            guard let next = DayKey.nextDayKey(after: key) else {
                return XCTFail("no next day for \(key)")
            }
            XCTAssertEqual(DayKey.previousDayKey(before: next), key)
        }
    }
}
