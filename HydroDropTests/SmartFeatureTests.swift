import XCTest
@testable import HydroDrop

final class WeeklyRecapTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    /// A fixed Wednesday, so "the last seven days" is the same seven days every run.
    private let now = Date(timeIntervalSince1970: 1_758_196_800)

    private func drink(dayOffset: Int, hour: Int, amountML: Int, type: DrinkType = .water) -> WaterEntry {
        let day = calendar.date(byAdding: .day, value: -dayOffset, to: calendar.startOfDay(for: now))!
        let timestamp = calendar.date(byAdding: .hour, value: hour, to: day)!
        return WaterEntry(amountML: amountML, timestamp: timestamp, drinkType: type)
    }

    private func recap(_ entries: [WaterEntry], goalML: Int = 2_000) -> WeeklyRecap {
        WeeklyRecap.make(
            entries: entries,
            goalML: goalML,
            windowStartMinutes: 8 * 60,
            windowEndMinutes: 22 * 60,
            now: now,
            calendar: calendar
        )
    }

    func testAlwaysCoversSevenDaysOldestFirst() {
        let result = recap([])
        XCTAssertEqual(result.days.count, 7)
        XCTAssertEqual(result.days.map(\.dayKey), result.days.map(\.dayKey).sorted())
        XCTAssertEqual(result.days.last?.dayKey, DayKey.key(for: now, calendar: calendar))
    }

    func testAnEmptyWeekSaysSo() {
        let result = recap([])
        XCTAssertFalse(result.hasAnyIntake)
        XCTAssertEqual(result.averageML, 0)
        XCTAssertNil(result.bestDay)
        XCTAssertEqual(result.daysGoalMet, 0)
        XCTAssertNil(result.slipHour)
    }

    /// Days with nothing logged are part of the average. A week with two good days is
    /// not a week averaging a good day.
    func testTheAverageIsOverAllSevenDays() {
        let result = recap([drink(dayOffset: 1, hour: 10, amountML: 2_100), drink(dayOffset: 2, hour: 10, amountML: 1_400)])
        XCTAssertEqual(result.averageML, 500)
    }

    func testBestDayAndGoalCount() {
        let result = recap([
            drink(dayOffset: 1, hour: 10, amountML: 2_100),
            drink(dayOffset: 2, hour: 10, amountML: 2_600),
            drink(dayOffset: 3, hour: 10, amountML: 900),
        ])
        XCTAssertEqual(result.bestDay?.totalML, 2_600)
        XCTAssertEqual(result.daysGoalMet, 2)
    }

    /// Totals here come from the same place the rest of the app's do.
    func testDrinkTypesCountAtTheirHydratedAmount() {
        let result = recap([drink(dayOffset: 1, hour: 10, amountML: 2_000, type: .juice)])
        XCTAssertEqual(result.bestDay?.totalML, 1_700)
        XCTAssertEqual(result.daysGoalMet, 0)
    }

    /// Someone who drinks nothing until the evening is behind all afternoon, and the
    /// worst gap is at the end of the window rather than the start.
    func testNamesTheHourTheDayFallsBehind() {
        var entries: [WaterEntry] = []
        for day in 1...5 {
            entries.append(drink(dayOffset: day, hour: 20, amountML: 2_000))
        }
        let result = recap(entries)
        XCTAssertNotNil(result.slipHour)
        XCTAssertGreaterThanOrEqual(result.slipHour ?? 0, 17)
    }

    /// Someone drinking steadily through the day is not behind anywhere, and naming an
    /// hour anyway would be inventing a pattern.
    func testSaysNothingWhenThePaceIsSteady() {
        var entries: [WaterEntry] = []
        for day in 1...5 {
            for hour in stride(from: 8, through: 20, by: 2) {
                entries.append(drink(dayOffset: day, hour: hour, amountML: 300))
            }
        }
        XCTAssertNil(recap(entries).slipHour)
    }

    func testSaysNothingAboutAWakingWindowThatHasNoLength() {
        let result = WeeklyRecap.make(
            entries: [drink(dayOffset: 1, hour: 20, amountML: 2_000)],
            goalML: 2_000,
            windowStartMinutes: 8 * 60,
            windowEndMinutes: 8 * 60,
            now: now,
            calendar: calendar
        )
        XCTAssertNil(result.slipHour)
    }
}

final class WeatherGoalAdviceTests: XCTestCase {
    func testSaysNothingAboutAMildDay() {
        XCTAssertNil(WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: 18, baseGoalML: 2_000))
        XCTAssertNil(WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: 26.9, baseGoalML: 2_000))
    }

    func testTheBumpGrowsWithTheHeat() {
        XCTAssertEqual(WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: 27, baseGoalML: 2_000), 250)
        XCTAssertEqual(WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: 31, baseGoalML: 2_000), 500)
        XCTAssertEqual(WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: 38, baseGoalML: 2_000), 750)
    }

    /// Never suggests a target the goal stepper itself would refuse.
    func testTheSuggestionIsCappedByTheGoalRange() {
        let ceiling = MeasurementSystem.storedGoalRangeML.upperBound
        XCTAssertEqual(WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: 38, baseGoalML: ceiling - 100), 100)
        XCTAssertNil(WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: 38, baseGoalML: ceiling))
    }

    func testAnUnreadableTemperatureSuggestsNothing() {
        XCTAssertNil(WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: .nan, baseGoalML: 2_000))
        XCTAssertNil(WeatherGoalAdvice.suggestedBumpML(apparentTemperatureC: .infinity, baseGoalML: 2_000))
    }
}

final class WeatherBumpSettingsTests: XCTestCase {
    private var settings: AppSettings { AppSettings.shared }
    private var originalGoal = 2_000

    override func setUp() {
        super.setUp()
        originalGoal = settings.dailyGoalML
        settings.dailyGoalML = 2_000
        settings.weatherGoalEnabled = false
    }

    override func tearDown() {
        settings.weatherGoalEnabled = false
        settings.dailyGoalML = originalGoal
        super.tearDown()
    }

    func testTodayMatchesTheSavedGoalUntilABumpIsAccepted() {
        XCTAssertEqual(settings.todayGoalML(), settings.dailyGoalML)
    }

    func testAnAcceptedBumpRaisesTodayOnly() {
        settings.acceptWeatherBump(500)
        XCTAssertEqual(settings.todayGoalML(), 2_500)
        // The saved goal is the user's, and a suggestion never touches it.
        XCTAssertEqual(settings.dailyGoalML, 2_000)

        let tomorrow = Date().addingTimeInterval(86_400)
        XCTAssertEqual(settings.todayGoalML(now: tomorrow), 2_000)
    }

    func testABumpCannotPushTodayPastTheGoalCeiling() {
        settings.dailyGoalML = MeasurementSystem.storedGoalRangeML.upperBound
        settings.acceptWeatherBump(750)
        XCTAssertEqual(settings.todayGoalML(), MeasurementSystem.storedGoalRangeML.upperBound)
    }

    func testDismissingIsRememberedForTheDayOnly() {
        settings.dismissWeatherBump()
        XCTAssertTrue(settings.hasDismissedWeatherBump())
        XCTAssertFalse(settings.hasDismissedWeatherBump(now: Date().addingTimeInterval(86_400)))
    }

    /// Turning the feature off should not leave a raised target behind.
    func testTurningTheFeatureOffClearsAnAcceptedBump() {
        settings.weatherGoalEnabled = true
        settings.acceptWeatherBump(500)
        XCTAssertEqual(settings.todayGoalML(), 2_500)
        settings.weatherGoalEnabled = false
        XCTAssertEqual(settings.todayGoalML(), 2_000)
    }
}

final class LiveActivityStateTests: XCTestCase {
    private func state(total: Int, goal: Int) -> HydrationActivityAttributes.ContentState {
        HydrationActivityAttributes.ContentState(
            todayTotalML: total,
            goalML: goal,
            measurementSystemRawValue: MeasurementSystem.metric.rawValue,
            mascotSkinRawValue: MascotSkin.classic.rawValue,
            streak: 3
        )
    }

    func testProgressAndRemaining() {
        let half = state(total: 1_000, goal: 2_000)
        XCTAssertEqual(half.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(half.remainingML, 1_000)
    }

    func testProgressIsClampedForTheGauge() {
        XCTAssertEqual(state(total: 4_000, goal: 2_000).clampedProgress, 1)
        XCTAssertEqual(state(total: 0, goal: 2_000).clampedProgress, 0)
    }

    func testNothingLeftToDrinkOnceTheGoalIsMet() {
        XCTAssertEqual(state(total: 2_400, goal: 2_000).remainingML, 0)
    }

    func testAZeroGoalDoesNotDivideByZero() {
        XCTAssertEqual(state(total: 500, goal: 0).progress, 0)
    }

    func testUnknownStoredValuesFallBack() {
        var unknown = state(total: 100, goal: 2_000)
        unknown.measurementSystemRawValue = "cubits"
        unknown.mascotSkinRawValue = "puce"
        XCTAssertEqual(unknown.measurementSystem, .deviceDefault)
        XCTAssertEqual(unknown.mascotSkin, .classic)
    }
}
