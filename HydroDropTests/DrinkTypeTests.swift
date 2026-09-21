import XCTest
import SwiftData
@testable import HydroDrop

final class DrinkTypeTests: XCTestCase {
    func testWaterCountsInFull() {
        XCTAssertEqual(DrinkType.water.hydrationMultiplier, 1.0)
        XCTAssertEqual(DrinkType.water.hydratedML(from: 500), 500)
        XCTAssertFalse(DrinkType.water.countsForLess)
    }

    func testSparklingCountsInFull() {
        XCTAssertEqual(DrinkType.sparkling.hydratedML(from: 330), 330)
    }

    func testOtherTypesCountForLess() {
        XCTAssertEqual(DrinkType.coffee.hydratedML(from: 200), 180)
        XCTAssertEqual(DrinkType.juice.hydratedML(from: 200), 170)
        XCTAssertEqual(DrinkType.blackTea.hydratedML(from: 200), 190)
        for type in DrinkType.allCases where type != .water && type != .sparkling {
            XCTAssertTrue(type.countsForLess, "\(type.label) should count for less")
        }
    }

    func testEveryTypeHasADistinctRawValueAndLabel() {
        XCTAssertEqual(Set(DrinkType.allCases.map(\.rawValue)).count, DrinkType.allCases.count)
        XCTAssertEqual(Set(DrinkType.allCases.map(\.label)).count, DrinkType.allCases.count)
    }

    /// Multipliers are a rule of thumb, but a negative or above-water one would let a
    /// drink subtract from the day or count more than it was.
    func testMultipliersAreBetweenZeroAndOne() {
        for type in DrinkType.allCases {
            // Alcoholic drinks are the one exception to "everything hydrates a little":
            // they are in the log and count for exactly nothing, never less than that.
            if type.isAlcoholic {
                XCTAssertEqual(type.hydrationMultiplier, 0)
            } else {
                XCTAssertGreaterThan(type.hydrationMultiplier, 0)
            }
            XCTAssertLessThanOrEqual(type.hydrationMultiplier, 1.0)
        }
    }
}

final class WaterEntryDrinkTypeTests: XCTestCase {
    /// The default has to stay water, because that is what every entry logged before
    /// drink types existed actually was.
    func testDefaultsToWater() {
        let entry = WaterEntry(amountML: 250)
        XCTAssertEqual(entry.drinkType, .water)
        XCTAssertEqual(entry.hydratedML, 250)
    }

    /// A record synced from a version that never wrote the field comes back with nil.
    func testAMissingRawValueReadsAsWater() {
        let entry = WaterEntry(amountML: 250)
        entry.drinkTypeRawValue = nil
        XCTAssertEqual(entry.drinkType, .water)
        XCTAssertEqual(entry.hydratedML, 250)
    }

    /// A record written by a future version must not be lost or crash an older build.
    func testAnUnknownRawValueReadsAsWater() {
        let entry = WaterEntry(amountML: 250)
        entry.drinkTypeRawValue = "kombucha"
        XCTAssertEqual(entry.drinkType, .water)
    }

    func testSettingTheTypeUpdatesTheStoredRawValue() {
        let entry = WaterEntry(amountML: 200)
        entry.drinkType = .coffee
        XCTAssertEqual(entry.drinkTypeRawValue, "coffee")
        XCTAssertEqual(entry.hydratedML, 180)
    }
}

final class HydratedTotalsTests: XCTestCase {
    private let calendar = Calendar.current

    func testDailyTotalsUseTheHydratedAmount() {
        let day = Date()
        let entries = [
            WaterEntry(amountML: 500, timestamp: day, drinkType: .water),
            WaterEntry(amountML: 200, timestamp: day, drinkType: .coffee),
        ]
        let totals = StreakCalculator.totalsByDay(entries, calendar: calendar)
        XCTAssertEqual(totals[DayKey.key(for: day, calendar: calendar)], 680)
    }

    /// A day of nothing but coffee can fall short of a goal the poured volume met,
    /// which is the whole point of the multiplier.
    func testAStreakFollowsTheHydratedTotal() {
        let now = Date()
        let entries = (0..<3).compactMap { offset -> WaterEntry? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: now) else { return nil }
            return WaterEntry(amountML: 2000, timestamp: day, drinkType: .juice)
        }
        XCTAssertEqual(
            StreakCalculator.currentStreak(entries: entries, goalML: 2000, now: now, calendar: calendar),
            0,
            "1700 mL of juice should not meet a 2000 mL goal"
        )
        XCTAssertEqual(
            StreakCalculator.currentStreak(entries: entries, goalML: 1700, now: now, calendar: calendar),
            3
        )
    }
}

final class DrinkTimeTests: XCTestCase {
    func testTheWindowReachesBackAWeekAndNeverForward() {
        let now = Date()
        let range = DrinkTime.range(now: now)
        XCTAssertEqual(range.upperBound, now)
        XCTAssertEqual(
            Calendar.current.dateComponents([.day], from: range.lowerBound, to: now).day,
            DrinkTime.backfillDays
        )
    }

    func testAFutureTimeIsPulledBackToNow() {
        let now = Date()
        let tomorrow = now.addingTimeInterval(86_400)
        XCTAssertEqual(DrinkTime.clamped(tomorrow, now: now), now)
    }

    func testATooOldTimeIsPulledForwardToTheWindow() {
        let now = Date()
        let lastMonth = now.addingTimeInterval(-30 * 86_400)
        XCTAssertEqual(DrinkTime.clamped(lastMonth, now: now), DrinkTime.earliest(now: now))
    }

    func testATimeInsideTheWindowIsUntouched() {
        let now = Date()
        let yesterday = now.addingTimeInterval(-86_400)
        XCTAssertEqual(DrinkTime.clamped(yesterday, now: now), yesterday)
    }

    /// Editing an entry older than the backfill window has to stay possible.
    func testTheEditingWindowStretchesToReachAnOlderEntry() {
        let now = Date()
        let old = now.addingTimeInterval(-60 * 86_400)
        let range = DrinkTime.editingRange(existing: old, now: now)
        XCTAssertTrue(range.contains(old))
        XCTAssertTrue(range.contains(now))
    }
}
