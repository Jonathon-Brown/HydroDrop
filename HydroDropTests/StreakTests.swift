import XCTest
import SwiftData
@testable import HydroDrop

/// Streak and freeze rules. These are pure functions over entries, a goal and a set of
/// frozen days, so they are tested against explicit calendars and an explicit `now`
/// rather than against whatever timezone the test machine happens to be in.
final class StreakTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    private let goal = 2000

    override func setUpWithError() throws {
        container = try ModelContainer(
            for: WaterEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() {
        context = nil
        container = nil
        super.tearDown()
    }

    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// Midday UTC, which is the same calendar day in New York and London alike.
    private func entries(_ days: [(String, Int)]) -> [WaterEntry] {
        days.map { WaterEntry(amountML: $0.1, timestamp: date("\($0.0)T15:00:00Z")) }
    }

    // MARK: - Streak

    func testCountsConsecutiveDaysMeetingTheGoal() {
        let streak = StreakCalculator.currentStreak(
            entries: entries([("2026-08-21", 2000), ("2026-08-20", 2000), ("2026-08-19", 2000)]),
            goalML: goal,
            now: date("2026-08-21T18:00:00Z"),
            calendar: calendar("America/New_York")
        )
        XCTAssertEqual(streak, 3)
    }

    func testTodayInProgressDoesNotZeroAnExistingStreak() {
        let streak = StreakCalculator.currentStreak(
            entries: entries([("2026-08-21", 500), ("2026-08-20", 2000), ("2026-08-19", 2000)]),
            goalML: goal,
            now: date("2026-08-21T18:00:00Z"),
            calendar: calendar("America/New_York")
        )
        XCTAssertEqual(streak, 2)
    }

    func testAMissedDayEndsTheStreak() {
        let streak = StreakCalculator.currentStreak(
            entries: entries([("2026-08-21", 2000), ("2026-08-20", 100), ("2026-08-19", 2000)]),
            goalML: goal,
            now: date("2026-08-21T18:00:00Z"),
            calendar: calendar("America/New_York")
        )
        XCTAssertEqual(streak, 1)
    }

    func testAFrozenDayBridgesTheGapWithoutCountingItself() {
        let streak = StreakCalculator.currentStreak(
            entries: entries([("2026-08-21", 2000), ("2026-08-19", 2000), ("2026-08-18", 2000)]),
            goalML: goal,
            frozenDayKeys: ["2026-08-20"],
            now: date("2026-08-21T18:00:00Z"),
            calendar: calendar("America/New_York")
        )
        XCTAssertEqual(streak, 3, "the frozen day bridges but does not add to the streak")
    }

    /// Regression: freezes were stored as `startOfDay` instants, so flying east or west
    /// made them stop matching and the protected streak collapsed.
    func testAFrozenDaySurvivesATimezoneChange() {
        let frozenInNewYork = DayKey.key(
            for: date("2026-08-20T15:00:00Z"),
            calendar: calendar("America/New_York")
        )
        let streakInLondon = StreakCalculator.currentStreak(
            entries: entries([("2026-08-21", 2000), ("2026-08-19", 2000)]),
            goalML: goal,
            frozenDayKeys: [frozenInNewYork],
            now: date("2026-08-21T18:00:00Z"),
            calendar: calendar("Europe/London")
        )
        XCTAssertEqual(streakInLondon, 2)
    }

    func testNoStreakWithoutAGoal() {
        XCTAssertEqual(
            StreakCalculator.currentStreak(entries: entries([("2026-08-21", 2000)]), goalML: 0),
            0
        )
    }

    func testEmptyHistoryIsNotAStreak() {
        XCTAssertEqual(StreakCalculator.currentStreak(entries: [], goalML: goal), 0)
    }

    // MARK: - Freeze

    private func dayToProtect(
        _ days: [(String, Int)],
        frozen: [String] = [],
        subscribed: Bool = true,
        now: String = "2026-08-21T18:00:00Z",
        timezone: String = "America/New_York"
    ) -> String? {
        StreakFreeze.dayToProtect(
            entries: entries(days),
            goalML: goal,
            frozenDayKeys: frozen,
            isSubscribed: subscribed,
            now: date(now),
            calendar: calendar(timezone)
        )
    }

    func testSpendsAFreezeOnAMissedYesterdayWithAStreakBehindIt() {
        XCTAssertEqual(dayToProtect([("2026-08-19", 2000), ("2026-08-18", 2000)]), "2026-08-20")
    }

    func testDoesNotSpendAFreezeWithoutASubscription() {
        XCTAssertNil(dayToProtect([("2026-08-19", 2000)], subscribed: false))
    }

    func testDoesNotSpendAFreezeWithNoStreakToSave() {
        XCTAssertNil(dayToProtect([("2026-08-18", 2000)]), "the day before yesterday was also missed")
    }

    func testDoesNotSpendAFreezeOnAMetGoal() {
        XCTAssertNil(dayToProtect([("2026-08-20", 2000), ("2026-08-19", 2000)]))
    }

    /// Re-evaluating on the same day — which happens on every appearance and every
    /// foreground — must not spend a second freeze.
    func testRepeatedEvaluationDoesNotDoubleSpend() {
        let first = dayToProtect([("2026-08-19", 2000), ("2026-08-18", 2000)])
        XCTAssertEqual(first, "2026-08-20")
        XCTAssertNil(dayToProtect([("2026-08-19", 2000), ("2026-08-18", 2000)], frozen: [first!]))
    }

    func testAllowanceIsOnePerCalendarMonth() {
        XCTAssertEqual(StreakFreeze.freezesRemaining(frozenDayKeys: [], now: date("2026-08-21T18:00:00Z")), 1)
        XCTAssertEqual(
            StreakFreeze.freezesRemaining(
                frozenDayKeys: ["2026-08-04"],
                now: date("2026-08-21T18:00:00Z"),
                calendar: calendar("America/New_York")
            ),
            0
        )
    }

    func testLastMonthsFreezeDoesNotCountAgainstThisMonth() {
        XCTAssertEqual(
            StreakFreeze.freezesRemaining(
                frozenDayKeys: ["2026-07-04"],
                now: date("2026-08-21T18:00:00Z"),
                calendar: calendar("America/New_York")
            ),
            1
        )
    }

    /// Regression: a freeze taken on the 1st in Tokyo was stored as an instant that fell
    /// in the previous month once read in Los Angeles, which handed out a second freeze
    /// in the same month.
    func testAMonthBoundaryFreezeStillCountsAfterTravellingWest() {
        let frozenInTokyo = DayKey.key(
            for: date("2026-09-01T06:00:00Z"),
            calendar: calendar("Asia/Tokyo")
        )
        XCTAssertEqual(frozenInTokyo, "2026-09-01")
        XCTAssertEqual(
            StreakFreeze.freezesRemaining(
                frozenDayKeys: [frozenInTokyo],
                now: date("2026-09-02T20:00:00Z"),
                calendar: calendar("America/Los_Angeles")
            ),
            0,
            "the September freeze is still a September freeze in California"
        )
    }
}
