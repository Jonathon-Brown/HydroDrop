import XCTest
@testable import HydroCore

/// What a duo is told about the log: per-day totals of HydroDrop's own entries, in the phone's
/// own calendar, and the first day the log can speak for (final design §8.7, §10.5; KV14, X10).
final class DuoLogTotalsTests: XCTestCase {
    private func calendar(_ zone: String) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func instant(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }

    private func entry(_ iso: String, _ ml: Int, _ source: String = DuoLogEntry.hydroDropSource) -> DuoLogEntry {
        DuoLogEntry(timestamp: instant(iso), hydratedML: ml, source: source)
    }

    func testADrinkIsCountedOnTheDayItFellOnWhereThePhoneIsNow() {
        // X10: one drink at 03:00Z on the 29th is the 28th's evening in Los Angeles and the
        // 29th's lunchtime in Tokyo. Moving zones moves it, as it does the solo streak (§8.4).
        let drink = [entry("2026-09-29T03:00:00Z", 2000)]
        XCTAssertEqual(DuoLogTotals.totalsByDay(drink, calendar: calendar("America/Los_Angeles")), ["2026-09-28": 2000])
        XCTAssertEqual(DuoLogTotals.totalsByDay(drink, calendar: calendar("Asia/Tokyo")), ["2026-09-29": 2000])
    }

    func testAnEveningDrinkInLosAngelesIsTheNextDayInTokyo() {
        // KV14's first half: 23:30 on the 20th at UTC−7 is 06:30Z on the 21st, 15:30 in Tokyo.
        let drink = [DuoLogEntry(timestamp: ISO8601DateFormatter().date(from: "2026-09-20T23:30:00-07:00")!, hydratedML: 500,
                                 source: DuoLogEntry.hydroDropSource)]
        XCTAssertEqual(DuoLogTotals.totalsByDay(drink, calendar: calendar("Asia/Tokyo")), ["2026-09-21": 500])
        XCTAssertEqual(DuoLogTotals.totalsByDay(drink, calendar: calendar("America/Los_Angeles")), ["2026-09-20": 500])
    }

    func testAnImportFromHealthConnectNeverCounts() {
        // KV14's second half: 1500 logged in HydroDrop and 600 imported, against a goal of 2000,
        // is three quarters and not met. Counting the import would have made it met.
        let entries = [entry("2026-09-21T09:00:00Z", 1500), entry("2026-09-21T10:00:00Z", 600, "health_connect")]
        let totals = DuoLogTotals.totalsByDay(entries, calendar: calendar("UTC"))
        XCTAssertEqual(totals, ["2026-09-21": 1500])
        XCTAssertEqual(DuoProgress.bucket(totalML: totals["2026-09-21"] ?? 0, goalML: 2000), 75)
        XCTAssertFalse(DuoProgress.goalMet(totalML: totals["2026-09-21"] ?? 0, goalML: 2000))
    }

    func testAnySourceButHydroDropsOwnIsLeftOutNotJustHealthConnect() {
        let entries = [entry("2026-09-21T09:00:00Z", 300, "healthkit"), entry("2026-09-21T09:00:00Z", 300, "HydroDrop"),
                       entry("2026-09-21T09:00:00Z", 300, "")]
        XCTAssertEqual(DuoLogTotals.totalsByDay(entries, calendar: calendar("UTC")), [:], "the source is matched exactly")
    }

    func testForHydroDropsOwnEntriesItIsTheSameGroupingTheSoloStreakUses() {
        // `StreakCalculator.totalsByDay` (in the app) groups `hydratedML` by `DayKey` and sums it;
        // the app's reader test compares the two on real `WaterEntry` rows. Here the rule is held
        // to that formula across zones, days, a negative contribution and an empty log.
        let entries = [entry("2026-09-20T22:59:59Z", 250), entry("2026-09-20T23:00:00Z", 400), entry("2026-09-21T12:00:00Z", -120),
                       entry("2026-09-22T00:30:00Z", 1000), entry("2026-09-22T23:59:59Z", 1)]
        for zone in ["UTC", "Europe/London", "America/New_York", "Asia/Kolkata", "Pacific/Kiritimati", "Pacific/Pago_Pago"] {
            let calendar = calendar(zone)
            let reference = Dictionary(grouping: entries) { DayKey.key(for: $0.timestamp, calendar: calendar) }
                .mapValues { $0.reduce(0) { $0 + $1.hydratedML } }
            XCTAssertEqual(DuoLogTotals.totalsByDay(entries, calendar: calendar), reference, zone)
        }
        XCTAssertEqual(DuoLogTotals.totalsByDay([], calendar: calendar("UTC")), [:])
    }

    // MARK: - Coverage

    func testCoverageStartsAtTheEarlierOfTheInstallAndTheOldestDrink() {
        XCTAssertEqual(DuoCoverage.start(installDay: "2026-09-20", earliestEntryDay: "2025-01-03"), "2025-01-03")
        XCTAssertEqual(DuoCoverage.start(installDay: "2026-09-20", earliestEntryDay: "2026-09-25"), "2026-09-20")
        XCTAssertEqual(DuoCoverage.start(installDay: "2026-09-20", earliestEntryDay: nil), "2026-09-20",
                       "a reinstall whose log has not come back yet covers only from today (§3.4 step 4)")
    }

    func testADayThatIsNotADayCoversNothing() {
        // `Date.distantPast` as a day key is year 1, which as a string sorts before every real day
        // and would have let the outbox lower any day of the week.
        XCTAssertEqual(DuoCoverage.start(installDay: "2026-09-20", earliestEntryDay: "0001-01-01"), "2026-09-20")
        XCTAssertEqual(DuoCoverage.start(installDay: "", earliestEntryDay: "2026-09-25"), "2026-09-25")
        XCTAssertEqual(DuoCoverage.start(installDay: "garbage", earliestEntryDay: nil), DuoCoverage.coversNoPastDay)
        // And what that means for the outbox: no past day can be lowered, today is still written.
        let known = [DuoDayStatus(role: .owner, day: "2026-09-29", goalMet: true, progressBucket: 100, updatedAt: Date(timeIntervalSince1970: 0))]
        let rows = DuoOutbox.unsent(role: .owner, totalsByDay: [:], goalML: 2000, known: known, myToday: "2026-09-30",
                                    now: instant("2026-09-30T12:00:00Z"), coverageStart: DuoCoverage.coversNoPastDay, calendar: calendar("UTC"))
        XCTAssertEqual(rows.map(\.day), ["2026-09-30"])
    }
}
