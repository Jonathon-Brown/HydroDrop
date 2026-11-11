import XCTest
@testable import HydroDrop

/// `MinuteOfDay.instant` is what every scheduled time of day goes through: the pace-aware
/// reminder slots, the Night Out morning offer and the Live Activity's end. Adding
/// minutes to midnight used to put all of them an hour off on the two days a year the
/// clocks change, so the clock time is what these pin.
final class MinuteOfDayTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func startOfDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.startOfDay(for: calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!)
    }

    private func clock(_ date: Date?) -> (hour: Int, minute: Int, day: Int) {
        let parts = calendar.dateComponents([.hour, .minute, .day], from: date!)
        return (parts.hour!, parts.minute!, parts.day!)
    }

    func testAnOrdinaryDayReadsAsTheClockTime() {
        let morning = MinuteOfDay.instant(8 * 60 + 30, on: startOfDay(2026, 6, 10), calendar: calendar)
        XCTAssertEqual(clock(morning).hour, 8)
        XCTAssertEqual(clock(morning).minute, 30)
        XCTAssertEqual(clock(morning).day, 10)
    }

    /// 8 March 2026 has 23 hours in New York. Eight hours after midnight is 9am there,
    /// and an 8am slot has to be at 8am.
    func testTheDayTheClocksGoForwardKeepsTheClockTime() {
        let day = startOfDay(2026, 3, 8)
        let added = calendar.date(byAdding: .minute, value: 8 * 60, to: day)
        XCTAssertEqual(clock(added).hour, 9, "the fixture is a day the clocks change")
        XCTAssertEqual(clock(MinuteOfDay.instant(8 * 60, on: day, calendar: calendar)).hour, 8)
    }

    /// 1 November 2026 has 25 hours in New York, and an 8am slot is still 8am.
    func testTheDayTheClocksGoBackKeepsTheClockTime() {
        let day = startOfDay(2026, 11, 1)
        let added = calendar.date(byAdding: .minute, value: 8 * 60, to: day)
        XCTAssertEqual(clock(added).hour, 7, "the fixture is a day the clocks change")
        XCTAssertEqual(clock(MinuteOfDay.instant(8 * 60, on: day, calendar: calendar)).hour, 8)
    }

    /// An overnight window's slots are minutes past the end of the day they belong to.
    func testMinutesPastMidnightLandOnTheNextDay() {
        let late = MinuteOfDay.instant(26 * 60 + 15, on: startOfDay(2026, 6, 10), calendar: calendar)
        XCTAssertEqual(clock(late).day, 11)
        XCTAssertEqual(clock(late).hour, 2)
        XCTAssertEqual(clock(late).minute, 15)
    }

    /// 2:30am does not exist on 8 March 2026 in New York. The next time that does is
    /// still an instant, not a dropped slot.
    func testATimeThatDoesNotExistStillGivesAnInstant() {
        XCTAssertNotNil(MinuteOfDay.instant(2 * 60 + 30, on: startOfDay(2026, 3, 8), calendar: calendar))
    }

    func testANegativeMinuteIsNotATime() {
        XCTAssertNil(MinuteOfDay.instant(-1, on: startOfDay(2026, 6, 10), calendar: calendar))
    }
}
