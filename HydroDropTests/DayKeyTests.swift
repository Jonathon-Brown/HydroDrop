import XCTest
@testable import HydroDrop

final class DayKeyTests: XCTestCase {
    private func calendar(_ identifier: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier)!
        return calendar
    }

    private func date(_ iso: String) -> Date {
        ISO8601DateFormatter().date(from: iso)!
    }

    /// The regression this type exists for: the same moment, on the same local day,
    /// has to produce the same key in every timezone that agrees it's that day.
    func testSameLocalDayMatchesAcrossTimezones() {
        let moment = date("2026-08-20T15:00:00Z")
        XCTAssertEqual(DayKey.key(for: moment, calendar: calendar("America/New_York")), "2026-08-20")
        XCTAssertEqual(DayKey.key(for: moment, calendar: calendar("Europe/London")), "2026-08-20")
        XCTAssertEqual(DayKey.key(for: moment, calendar: calendar("Asia/Tokyo")), "2026-08-21")
    }

    /// The key used to come from `String(format: "%04d-%02d-%02d")`. It is built by hand
    /// now, and has to read exactly as the formatter wrote it for every year the vectors
    /// and the rules can meet, including the padding on a short year and no cutting on a
    /// long one.
    func testTheKeyReadsExactlyAsTheFormatterWroteIt() {
        let utc = calendar("UTC")
        for year in [1, 999, 2000, 2026, 9999, 10_000, 275_760] {
            for (month, day) in [(1, 1), (9, 30), (12, 31)] {
                guard let date = utc.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
                    continue
                }
                XCTAssertEqual(
                    DayKey.key(for: date, calendar: utc),
                    String(format: "%04d-%02d-%02d", year, month, day),
                    "year \(year)"
                )
            }
        }
    }

    func testMonthAccounting() {
        XCTAssertEqual(DayKey.month(ofDayKey: "2026-09-01"), "2026-09")
        XCTAssertEqual(
            DayKey.monthKey(for: date("2026-09-02T20:00:00Z"), calendar: calendar("America/Los_Angeles")),
            "2026-09"
        )
    }

    func testPreviousDayCrossesMonthBoundary() {
        XCTAssertEqual(DayKey.previousDayKey(before: "2026-09-01"), "2026-08-31")
        XCTAssertEqual(DayKey.previousDayKey(before: "2026-03-01"), "2026-02-28")
    }

    /// 1 November 2026 is a 25-hour day in New York. Stepping back a day has to land on
    /// it, not on 23:00 the day before.
    func testPreviousDayAcrossDaylightSavingChange() {
        let ny = calendar("America/New_York")
        let afterTransition = date("2026-11-02T17:00:00Z")
        XCTAssertEqual(DayKey.previousDayKey(before: afterTransition, calendar: ny), "2026-11-01")
        XCTAssertEqual(DayKey.previousDayKey(before: "2026-11-02", calendar: ny), "2026-11-01")
    }

    func testRoundTripsThroughDate() {
        let ny = calendar("America/New_York")
        let parsed = DayKey.date(from: "2026-08-20", calendar: ny)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(DayKey.key(for: parsed!, calendar: ny), "2026-08-20")
    }

    func testRejectsMalformedKey() {
        XCTAssertNil(DayKey.date(from: "not-a-day"))
        XCTAssertNil(DayKey.date(from: "2026-08"))
    }
}
