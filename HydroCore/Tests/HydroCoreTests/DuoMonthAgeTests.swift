import Foundation
import XCTest
@testable import HydroCore

final class DuoMonthAgeTests: XCTestCase {
    private var calendar: Calendar {
        var result = Calendar(identifier: .gregorian)
        result.timeZone = TimeZone(secondsFromGMT: 0)!
        return result
    }
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }
    func testWholeThirteenthBirthdayMonthMustHaveEnded() {
        for day in [1, 20, 31] {
            XCTAssertEqual(DuoAgeGate.decide(birthYear: 2013, birthMonth: 11, now: date(2026, 10, day), calendar: calendar), .refused)
        }
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2013, birthMonth: 10, now: date(2026, 11, 1), calendar: calendar), .allowed)
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2013, birthMonth: 12, now: date(2027, 1, 1), calendar: calendar), .allowed)
    }

    /// Decision b (2026-11-12): born in this very month thirteen years ago is "not yet". It records
    /// nothing (`decide` says unknown), it can still be confirmed on the screen, and only that one
    /// month is treated so: the month before is still a refusal and the month after is allowed.
    func testTheThirteenthBirthdayMonthIsNotYetAndRecordsNothing() {
        for day in [1, 20, 31] {
            let now = date(2026, 10, day)
            XCTAssertEqual(DuoAgeGate.decide(birthYear: 2013, birthMonth: 10, now: now, calendar: calendar), .unknown)
            XCTAssertTrue(DuoAgeGate.isNotYet(birthYear: 2013, birthMonth: 10, now: now, calendar: calendar))
        }
        XCTAssertFalse(DuoAgeGate.isNotYet(birthYear: 2013, birthMonth: 11, now: date(2026, 10, 20), calendar: calendar))
        XCTAssertFalse(DuoAgeGate.isNotYet(birthYear: 2013, birthMonth: 9, now: date(2026, 10, 20), calendar: calendar))
        XCTAssertFalse(DuoAgeGate.isNotYet(birthYear: 2026, birthMonth: 13, now: date(2026, 10, 20), calendar: calendar))
        // Across the year change: born January 2014, asked in January 2027.
        XCTAssertTrue(DuoAgeGate.isNotYet(birthYear: 2014, birthMonth: 1, now: date(2027, 1, 15), calendar: calendar))
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2013, birthMonth: 12, now: date(2026, 12, 15), calendar: calendar), .unknown)

        var entry = DuoConsentFlow.BirthEntry()
        entry.typeMonth("10")
        entry.typeYear("2013")
        XCTAssertTrue(entry.confirm(now: date(2026, 10, 20), calendar: calendar), "the answer can be confirmed, so the screen can say not yet")
        XCTAssertEqual(entry.pending?.confirmation, "Born in October 2013?")
    }
    func testInvalidClockAndFutureOrInvalidMonthNeverRefuse() {
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 1990, birthMonth: 1, now: date(2001, 1, 1), calendar: calendar), .unknown)
        for month in [0, 13, 11] {
            XCTAssertEqual(DuoAgeGate.decide(birthYear: 2026, birthMonth: month, now: date(2026, 10, 20), calendar: calendar), .unknown)
        }
    }
    func testGregorianRuleUsesLocalMonthBoundary() {
        let moment = ISO8601DateFormatter().date(from: "2026-11-01T00:30:00Z")!
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = TimeZone(secondsFromGMT: -3600)!
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2013, birthMonth: 11, now: moment, calendar: buddhist), .refused)
        XCTAssertTrue(DuoAgeGate.isNotYet(birthYear: 2013, birthMonth: 10, now: moment, calendar: buddhist))
        buddhist.timeZone = TimeZone(secondsFromGMT: 3600)!
        XCTAssertEqual(DuoAgeGate.decide(birthYear: 2013, birthMonth: 10, now: moment, calendar: buddhist), .allowed)
    }
    func testInputIsBlankNeutralAndEveryEditInvalidatesConfirmation() {
        var entry = DuoConsentFlow.BirthEntry()
        let now = date(2026, 10, 20)
        XCTAssertFalse(entry.canContinue(now: now, calendar: calendar))
        entry.typeYear("1990")
        XCTAssertFalse(entry.canContinue(now: now, calendar: calendar))
        for invalid in ["1 ", "001", "1x", "-1", "13", "", "¹"] {
            entry.typeMonth(invalid)
            XCTAssertFalse(entry.confirm(now: now, calendar: calendar), invalid)
            XCTAssertEqual(entry.monthText, invalid)
        }
        entry.typeMonth("١٠")
        XCTAssertTrue(entry.confirm(now: now, calendar: calendar))
        XCTAssertEqual(entry.pending?.confirmation, "Born in October 1990?")
        entry.typeYear("2019")
        XCTAssertNil(entry.pending)
        XCTAssertTrue(entry.confirm(now: now, calendar: calendar))
        XCTAssertEqual(entry.pending?.confirmation, "Born in October 2019?")
        XCTAssertEqual(entry.take()?.year, 2019)
        XCTAssertNil(entry.take())
        XCTAssertEqual(entry.yearText, "")
        XCTAssertEqual(entry.monthText, "")
    }
}
