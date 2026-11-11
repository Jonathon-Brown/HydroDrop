import XCTest
@testable import HydroDrop

/// The cache Today and History read their totals from. It has to answer exactly what
/// `StreakCalculator.totalsByDay` answers, and work it out again only when the log, or the
/// calendar that decides which day a drink falls on, has changed.
final class LogCacheTests: XCTestCase {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func entries() -> [WaterEntry] {
        [
            WaterEntry(amountML: 500, timestamp: Date(timeIntervalSince1970: 1_790_000_000)),
            WaterEntry(amountML: 300, timestamp: Date(timeIntervalSince1970: 1_790_000_000 + 3_600), drinkType: .coffee),
            WaterEntry(amountML: 250, timestamp: Date(timeIntervalSince1970: 1_790_000_000 - 86_400)),
        ]
    }

    func testTheCacheAnswersWhatTheCalculatorAnswers() {
        let log = entries()
        let calendar = calendar("Europe/London")
        XCTAssertEqual(LogCache().totalsByDay(of: log, calendar: calendar), StreakCalculator.totalsByDay(log, calendar: calendar))
    }

    func testAnUnchangedLogIsNotWalkedAgain() {
        let cache = LogCache()
        let log = entries()
        _ = cache.totalsByDay(of: log)
        _ = cache.totalsByDay(of: log)
        _ = cache.totalsByDay(of: Array(log))
        XCTAssertEqual(cache.recomputeCount, 1)
    }

    /// An edit changes a drink in place: same objects, same count, different totals.
    func testAChangedAmountIsSeen() {
        let cache = LogCache()
        let log = entries()
        _ = cache.totalsByDay(of: log)
        log[0].amountML = 700
        let totals = cache.totalsByDay(of: log)
        XCTAssertEqual(cache.recomputeCount, 2)
        XCTAssertEqual(totals, StreakCalculator.totalsByDay(log))
    }

    func testAMovedDrinkAndAChangedTypeAreSeen() {
        let cache = LogCache()
        let log = entries()
        _ = cache.totalsByDay(of: log)
        log[2].timestamp = log[2].timestamp.addingTimeInterval(-86_400)
        _ = cache.totalsByDay(of: log)
        log[1].drinkType = .water
        _ = cache.totalsByDay(of: log)
        XCTAssertEqual(cache.recomputeCount, 3)
    }

    func testADrinkAddedOrRemovedIsSeen() {
        let cache = LogCache()
        var log = entries()
        _ = cache.totalsByDay(of: log)
        log.append(WaterEntry(amountML: 100))
        _ = cache.totalsByDay(of: log)
        log.removeFirst()
        _ = cache.totalsByDay(of: log)
        XCTAssertEqual(cache.recomputeCount, 3)
    }

    /// The same instants fall on different days in different zones, so a change of zone
    /// is a change of totals.
    func testAChangeOfTimeZoneIsSeen() {
        let cache = LogCache()
        let log = entries()
        _ = cache.totalsByDay(of: log, calendar: calendar("America/Los_Angeles"))
        let tokyo = cache.totalsByDay(of: log, calendar: calendar("Asia/Tokyo"))
        XCTAssertEqual(cache.recomputeCount, 2)
        XCTAssertEqual(tokyo, StreakCalculator.totalsByDay(log, calendar: calendar("Asia/Tokyo")))
    }
}
