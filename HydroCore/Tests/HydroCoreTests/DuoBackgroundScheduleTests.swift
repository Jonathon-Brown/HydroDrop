import XCTest
@testable import HydroCore

/// When the next background refresh is asked for (final design §10.6, vector X4): the one-shot
/// just after local midnight in the six hours before it, the half-hourly net the rest of the day.
final class DuoBackgroundScheduleTests: XCTestCase {
    private typealias Schedule = DuoBackgroundSchedule

    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    func testInTheSixHoursBeforeMidnightItIsTheOneShotJustAfterIt() {
        let toronto = calendar("America/Toronto")
        // 21:00 in Toronto (EDT, UTC-4) is 01:00Z; midnight there is 04:00Z.
        let begin = Schedule.nextEarliestBegin(now: instant("2026-10-08T01:00:00Z"), calendar: toronto, jitterSeconds: 600)
        XCTAssertEqual(begin, instant("2026-10-08T04:10:00Z"))
        // Exactly six hours before midnight is still inside.
        XCTAssertEqual(Schedule.nextEarliestBegin(now: instant("2026-10-07T22:00:00Z"), calendar: toronto, jitterSeconds: 300),
                       instant("2026-10-08T04:05:00Z"))
        // One second before midnight.
        XCTAssertEqual(Schedule.nextEarliestBegin(now: instant("2026-10-08T03:59:59Z"), calendar: toronto, jitterSeconds: 2100),
                       instant("2026-10-08T04:35:00Z"))
    }

    func testFurtherFromMidnightItIsTheRegularNetHalfAnHourOn() {
        let toronto = calendar("America/Toronto")
        // Six hours and one second before midnight.
        let early = instant("2026-10-07T21:59:59Z")
        XCTAssertEqual(Schedule.nextEarliestBegin(now: early, calendar: toronto, jitterSeconds: 600), early.addingTimeInterval(30 * 60))
        // Just after midnight, the next one is a day away.
        let justAfter = instant("2026-10-08T04:00:00Z")
        XCTAssertEqual(Schedule.nextEarliestBegin(now: justAfter, calendar: toronto, jitterSeconds: 600), justAfter.addingTimeInterval(30 * 60))
        // Mid-afternoon.
        let afternoon = instant("2026-10-08T19:00:00Z")
        XCTAssertEqual(Schedule.nextEarliestBegin(now: afternoon, calendar: toronto, jitterSeconds: 600), afternoon.addingTimeInterval(30 * 60))
    }

    /// Midnight is the phone's own, so the same instant is evening in one zone and morning in another.
    func testMidnightIsLocal() {
        let now = instant("2026-10-08T20:00:00Z")
        XCTAssertEqual(Schedule.nextEarliestBegin(now: now, calendar: calendar("Europe/London"), jitterSeconds: 300),
                       instant("2026-10-08T23:05:00Z"), "21:00 BST, midnight at 23:00Z")
        XCTAssertEqual(Schedule.nextEarliestBegin(now: now, calendar: calendar("Asia/Tokyo"), jitterSeconds: 300),
                       now.addingTimeInterval(30 * 60), "05:00 in Tokyo, midnight 19 hours away")
    }

    func testTheJitterIsKeptToFiveToThirtyFiveMinutes() {
        let toronto = calendar("America/Toronto")
        let now = instant("2026-10-08T01:00:00Z")
        let midnight = instant("2026-10-08T04:00:00Z")
        XCTAssertEqual(Schedule.nextEarliestBegin(now: now, calendar: toronto, jitterSeconds: 0), midnight.addingTimeInterval(300))
        XCTAssertEqual(Schedule.nextEarliestBegin(now: now, calendar: toronto, jitterSeconds: -40), midnight.addingTimeInterval(300))
        XCTAssertEqual(Schedule.nextEarliestBegin(now: now, calendar: toronto, jitterSeconds: 99_999), midnight.addingTimeInterval(2100))
        XCTAssertEqual(Schedule.nextEarliestBegin(now: now, calendar: toronto, jitterSeconds: 1234), midnight.addingTimeInterval(1234))
    }

    func testARandomJitterIsAlwaysInRange() {
        struct Fixed: DuoRandom {
            let value: [UInt8]
            func bytes(_ count: Int) -> [UInt8] { Array(value.prefix(count)) }
            func uuid() -> UUID { UUID() }
        }
        for bytes in [[0, 0], [0, 1], [0xFF, 0xFF], [0x07, 0x08], [0x80, 0x00]] as [[UInt8]] {
            let jitter = Schedule.jitterSeconds(random: Fixed(value: bytes))
            XCTAssertTrue(Schedule.jitterRange.contains(jitter), "\(bytes) gave \(jitter)")
        }
        XCTAssertEqual(Schedule.jitterSeconds(random: Fixed(value: [0, 0])), 300)
        XCTAssertEqual(Schedule.jitterSeconds(random: Fixed(value: [0x07, 0x08])), 300 + 0x0708 % 1801)
    }

    /// Chile moves its clocks forward at midnight: on 2026-09-06 there is no 00:00 in Santiago, and
    /// the day begins at 01:00 (-03:00), 04:00Z. The one-shot follows the day's first instant.
    func testOnADayWithNoMidnightTheOneShotFollowsTheDaysFirstInstant() {
        let santiago = calendar("America/Santiago")
        let now = instant("2026-09-06T01:00:00Z") // 21:00 on the 5th, -04:00
        XCTAssertEqual(Schedule.nextMidnight(after: now, calendar: santiago), instant("2026-09-06T04:00:00Z"))
        XCTAssertEqual(Schedule.nextEarliestBegin(now: now, calendar: santiago, jitterSeconds: 300), instant("2026-09-06T04:05:00Z"))
        // And the day after it has its midnight back, at -03:00.
        XCTAssertEqual(Schedule.nextMidnight(after: instant("2026-09-06T23:00:00Z"), calendar: santiago), instant("2026-09-07T03:00:00Z"))
    }

    /// On 2026-04-04 Santiago's clocks go back from 24:00 to 23:00, so the 4th is 25 hours long and
    /// its one midnight comes at -04:00, 04:00Z on the 5th.
    func testOnADayTheClocksGoBackAtMidnightItIsTheMidnightStillAhead() {
        let santiago = calendar("America/Santiago")
        XCTAssertEqual(Schedule.nextMidnight(after: instant("2026-04-05T01:00:00Z"), calendar: santiago), instant("2026-04-05T04:00:00Z"))
        // In the repeated hour (23:30 -04:00, after 23:59:59 -03:00 has already passed once).
        XCTAssertEqual(Schedule.nextMidnight(after: instant("2026-04-05T03:30:00Z"), calendar: santiago), instant("2026-04-05T04:00:00Z"))
        XCTAssertEqual(Schedule.nextEarliestBegin(now: instant("2026-04-05T03:30:00Z"), calendar: santiago, jitterSeconds: 300),
                       instant("2026-04-05T04:05:00Z"))
    }

    /// New York's spring change is at 02:00, so midnight is unaffected but the day is 23 hours long.
    func testAShortDayStillEndsAtItsMidnight() {
        let newYork = calendar("America/New_York")
        XCTAssertEqual(Schedule.nextMidnight(after: instant("2027-03-14T07:00:00Z"), calendar: newYork), instant("2027-03-15T04:00:00Z"))
    }

    func testTheAnswerIsNeverAtOrBeforeNow() {
        let zones = ["UTC", "America/Toronto", "America/Santiago", "Asia/Beirut", "Pacific/Kiritimati", "Pacific/Pago_Pago", "Australia/Lord_Howe", "Asia/Kathmandu"]
        var now = instant("2026-03-27T00:00:00Z")
        let end = instant("2026-04-07T00:00:00Z")
        while now < end {
            for zone in zones {
                let cal = calendar(zone)
                let begin = Schedule.nextEarliestBegin(now: now, calendar: cal, jitterSeconds: 300)
                XCTAssertGreaterThan(begin, now, "\(zone) at \(now)")
                XCTAssertLessThanOrEqual(begin.timeIntervalSince(now), Schedule.midnightHorizon + 2100, "\(zone) at \(now)")
                if let midnight = Schedule.nextMidnight(after: now, calendar: cal) {
                    XCTAssertGreaterThan(midnight, now, "\(zone) at \(now)")
                    XCTAssertEqual(cal.startOfDay(for: midnight), midnight, "\(zone): the answer is a day's first instant")
                    XCTAssertFalse(cal.isDate(midnight, inSameDayAs: now), "\(zone) at \(now): the next day, not this one")
                }
            }
            now = now.addingTimeInterval(17 * 60)
        }
    }
}
