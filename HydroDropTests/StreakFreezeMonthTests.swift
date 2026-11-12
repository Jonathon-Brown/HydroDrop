import XCTest
import SwiftData
@testable import HydroDrop

/// Fixed-clock regressions for the month a streak freeze is charged to. The allowance
/// belongs to the missed day, so the first day of a month can't spend a second freeze
/// for the month before.
final class StreakFreezeMonthTests: XCTestCase {
    private var container: ModelContainer!
    private var directory: URL!

    override func setUpWithError() throws {
        let temporary = try TemporaryStore.make(for: Schema([WaterEntry.self]))
        container = temporary.container
        directory = temporary.directory
    }

    override func tearDown() {
        container = nil
        TemporaryStore.remove(directory)
        directory = nil
        super.tearDown()
    }

    private func calendar(_ zone: String = "UTC") -> Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: zone)!
        return value
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
    }

    private func entries(_ days: [String], amount: Int = 2_000) -> [WaterEntry] {
        days.map { WaterEntry(amountML: amount, timestamp: date("\($0)T15:00:00Z")) }
    }

    /// Both public paths, because Today's LogCache passes grouped totals while other
    /// callers still pass entries.
    private func assertProtection(
        _ expected: String?, entries: [WaterEntry], frozen: [String], now: String,
        subscribed: Bool = true, zone: String = "UTC", file: StaticString = #filePath, line: UInt = #line
    ) {
        let cal = calendar(zone)
        let instant = date(now)
        XCTAssertEqual(StreakFreeze.dayToProtect(entries: entries, goalML: 2_000,
            frozenDayKeys: frozen, isSubscribed: subscribed, now: instant, calendar: cal), expected, file: file, line: line)
        XCTAssertEqual(StreakFreeze.dayToProtect(totals: StreakCalculator.totalsByDay(entries, calendar: cal),
            goalML: 2_000, frozenDayKeys: frozen, isSubscribed: subscribed,
            now: instant, calendar: cal), expected, file: file, line: line)
    }

    func testMonthRolloverCannotSpendAnotherFreezeFromTheProtectedMonth() {
        assertProtection(nil, entries: entries(["2026-08-30"]), frozen: ["2026-08-05"], now: "2026-09-01T18:00:00Z")
    }

    func testTheNextMonthsLedgerDoesNotBlockAnUnusedProtectedMonth() {
        // A restored ledger or a clock or time-zone change can make the next month's key
        // present. Its allowance is independent of the August day being protected.
        assertProtection("2026-08-31", entries: entries(["2026-08-30"]), frozen: ["2026-09-02"], now: "2026-09-01T18:00:00Z")
    }

    func testYearAndLeapMonthBoundariesUseTheMissedDaysAllowance() {
        let december = entries(["2026-12-30"])
        assertProtection(nil, entries: december, frozen: ["2026-12-05"], now: "2027-01-01T18:00:00Z")
        assertProtection("2026-12-31", entries: december, frozen: [], now: "2027-01-01T18:00:00Z")
        let february = entries(["2028-02-28"])
        assertProtection(nil, entries: february, frozen: ["2028-02-05"], now: "2028-03-01T18:00:00Z")
        assertProtection("2028-02-29", entries: february, frozen: [], now: "2028-03-01T18:00:00Z")
    }

    func testRepeatedReconciliationRetainsOneFreezeWithoutAddingAGoalDay() throws {
        let log = entries(["2026-08-29", "2026-08-30"])
        let now = date("2026-09-01T18:00:00Z")
        let protected = try XCTUnwrap(StreakFreeze.dayToProtect(entries: log, goalML: 2_000,
            frozenDayKeys: [], isSubscribed: true, now: now, calendar: calendar()))
        XCTAssertEqual(protected, "2026-08-31")
        assertProtection(nil, entries: log, frozen: [protected], now: "2026-09-01T18:00:00Z")
        XCTAssertEqual(StreakCalculator.currentStreak(entries: log, goalML: 2_000,
            frozenDayKeys: [protected], now: now, calendar: calendar()), 2)
        XCTAssertEqual(StreakFreeze.freezesRemaining(frozenDayKeys: [protected], now: now, calendar: calendar()), 1)
        assertProtection("2026-09-02", entries: entries(["2026-09-01"]), frozen: [protected], now: "2026-09-03T18:00:00Z")
    }

    func testTravelRetainsTheProtectedDayAndItsMonth() {
        let log = entries(["2026-08-29", "2026-08-30"])
        let frozen = ["2026-08-31"]
        for zone in ["America/New_York", "Europe/London"] {
            assertProtection(nil, entries: log, frozen: frozen, now: "2026-09-01T18:00:00Z", zone: zone)
            XCTAssertEqual(StreakCalculator.currentStreak(entries: log, goalML: 2_000,
                frozenDayKeys: frozen, now: date("2026-09-01T18:00:00Z"), calendar: calendar(zone)), 2)
            XCTAssertEqual(StreakFreeze.freezesRemaining(frozenDayKeys: frozen,
                now: date("2026-08-31T18:00:00Z"), calendar: calendar(zone)), 0)
        }
    }

    func testLapsePreventsNewSpendingButKeepsAnExistingBridge() {
        let log = entries(["2026-08-29", "2026-08-30"])
        assertProtection(nil, entries: log, frozen: [], now: "2026-09-01T18:00:00Z", subscribed: false)
        XCTAssertEqual(StreakCalculator.currentStreak(entries: log, goalML: 2_000,
            frozenDayKeys: ["2026-08-31"], now: date("2026-09-01T18:00:00Z"), calendar: calendar()), 2)
    }
}
