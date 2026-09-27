import SwiftUI
import XCTest
@testable import HydroDrop

/// The world is a picture of the log. These pin what the picture is allowed to say:
/// growth only ever goes up, a bad week changes how the world looks and never what is in
/// it, and someone with a year of history opens this version to a year's worth of world.
final class WorldEngineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let goal = 2000

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 12) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    private func key(_ year: Int, _ month: Int, _ day: Int) -> String {
        DayKey.key(for: date(year, month, day), calendar: calendar)
    }

    /// Totals for a run of days ending on `end`: true is a goal day, false a day with a
    /// little logged, nil a day with nothing logged at all.
    private func history(endingOn end: Date, _ days: [Bool?]) -> [String: Int] {
        var totals: [String: Int] = [:]
        for (index, met) in days.enumerated() {
            guard let met else { continue }
            let offset = -(days.count - 1 - index)
            let day = calendar.date(byAdding: .day, value: offset, to: end)!
            totals[DayKey.key(for: day, calendar: calendar)] = met ? goal + 100 : 400
        }
        return totals
    }

    private func state(_ totals: [String: Int], frozen: [String] = [], recorded: Int = 0, now: Date) -> WorldState {
        WorldEngine.state(totalsByDay: totals, goalML: goal, frozenDayKeys: frozen, recordedGoalDays: recorded, now: now, calendar: calendar)
    }

    // MARK: - Growth

    func testGrowthIsTheNumberOfDaysTheGoalWasMet() {
        let now = date(2026, 9, 21)
        let totals = history(endingOn: now, [true, false, true, nil, true, true, false])
        XCTAssertEqual(state(totals, now: now).goalDays, 4)
    }

    func testGrowthCountsDaysNotStreaks() {
        let now = date(2026, 9, 21)
        // Never two in a row, and it all still counts.
        let totals = history(endingOn: now, [true, false, true, false, true, false, true])
        XCTAssertEqual(state(totals, now: now).goalDays, 4)
    }

    func testGrowthNeverDecreasesWhenTheGoalIsRaisedOrDrinksAreDeleted() {
        let now = date(2026, 9, 21)
        let totals = history(endingOn: now, [true, true, true])
        XCTAssertEqual(state(totals, now: now).goalDays, 3)
        // The same log judged against a goal nobody met, with the record remembered.
        let raised = WorldEngine.state(totalsByDay: totals, goalML: 5000, recordedGoalDays: 3, now: now, calendar: calendar)
        XCTAssertEqual(raised.goalDays, 3)
        XCTAssertEqual(raised.stage, .sprout)
        // And with the whole log gone.
        XCTAssertEqual(state([:], recorded: 3, now: now).goalDays, 3)
    }

    func testNoGoalMeansNoGrowthButNothingIsTakenAway() {
        let now = date(2026, 9, 21)
        let none = WorldEngine.state(totalsByDay: history(endingOn: now, [true]), goalML: 0, recordedGoalDays: 12, now: now, calendar: calendar)
        XCTAssertEqual(none.goalDays, 12)
    }

    // MARK: - Stages

    func testStagesUnlockExactlyAtTheirThresholds() {
        let thresholds: [(Int, WorldStage)] = [
            (0, .pond), (2, .pond), (3, .sprout), (6, .sprout), (7, .reeds), (13, .reeds), (14, .lilyPads),
            (29, .lilyPads), (30, .flowers), (59, .flowers), (60, .tree), (99, .tree), (100, .fireflies),
            (199, .fireflies), (200, .koi), (364, .koi), (365, .blossom), (5000, .blossom),
        ]
        for (days, stage) in thresholds {
            XCTAssertEqual(WorldStage.reached(by: days), stage, "\(days) goal days")
        }
    }

    func testTheThresholdsAreTheOnesInTheSpec() {
        XCTAssertEqual(WorldStage.allCases.map(\.goalDays), [0, 3, 7, 14, 30, 60, 100, 200, 365])
    }

    func testProgressTowardsTheNextStage() {
        let halfway = WorldState(goalDays: 22, vitality: 1)
        XCTAssertEqual(halfway.stage, .lilyPads)
        XCTAssertEqual(halfway.stage.next, .flowers)
        XCTAssertEqual(halfway.daysToNext, 8)
        XCTAssertEqual(halfway.progressToNext, 0.5, accuracy: 0.0001)

        let done = WorldState(goalDays: 400, vitality: 1)
        XCTAssertNil(done.stage.next)
        XCTAssertNil(done.daysToNext)
        XCTAssertEqual(done.progressToNext, 1)
    }

    func testOnlyTheFurthestNewStageIsMarkedAndTheBarePondNever() {
        XCTAssertNil(WorldStage.newlyReached(goalDays: 0, alreadyCelebrated: []))
        XCTAssertNil(WorldStage.newlyReached(goalDays: 2, alreadyCelebrated: []))
        XCTAssertEqual(WorldStage.newlyReached(goalDays: 3, alreadyCelebrated: []), .sprout)
        // A long history crossing several at once is one moment.
        XCTAssertEqual(WorldStage.newlyReached(goalDays: 75, alreadyCelebrated: []), .tree)
        XCTAssertNil(WorldStage.newlyReached(goalDays: 75, alreadyCelebrated: [60]))
        XCTAssertNil(WorldStage.newlyReached(goalDays: 8, alreadyCelebrated: [3, 7]))
    }

    // MARK: - Vitality

    func testAWorldWithNoHistoryStartsWell() {
        XCTAssertEqual(state([:], now: date(2026, 9, 21)).vitality, WorldEngine.startingVitality)
    }

    func testAGoalDayRaisesItByAThirdAndAMissedDayLowersItByAFifth() {
        let now = date(2026, 9, 21)
        let start = WorldEngine.startingVitality
        // One goal day, yesterday.
        XCTAssertEqual(state(history(endingOn: now, [true, nil]), now: now).vitality, min(1, start + 0.34), accuracy: 0.0001)
        // A goal day, then a missed one, then today not yet met.
        XCTAssertEqual(state(history(endingOn: now, [true, false, nil]), now: now).vitality, min(1, start + 0.34) - 0.2, accuracy: 0.0001)
    }

    func testVitalityIsClampedAtBothEnds() {
        let now = date(2026, 9, 21)
        XCTAssertEqual(state(history(endingOn: now, Array(repeating: true, count: 12)), now: now).vitality, 1)
        let drought: [Bool?] = [true] + Array(repeating: nil, count: 20)
        XCTAssertEqual(state(history(endingOn: now, drought), now: now).vitality, 0)
    }

    func testADayWithNothingLoggedIsAMissedDayToo() {
        let now = date(2026, 9, 21)
        let logged = state(history(endingOn: now, [true, false, false, nil]), now: now).vitality
        let silent = state(history(endingOn: now, [true, nil, nil, nil]), now: now).vitality
        XCTAssertEqual(logged, silent, accuracy: 0.0001)
    }

    func testTodayInProgressNeverLowersIt() {
        let now = date(2026, 9, 21, hour: 9)
        let beforeToday = state(history(endingOn: now, [true, true, nil]), now: now).vitality
        let sippedToday = state(history(endingOn: now, [true, true, false]), now: now).vitality
        XCTAssertEqual(beforeToday, sippedToday, accuracy: 0.0001)
        // The same morning seen from tomorrow: now it is a missed day.
        let tomorrow = date(2026, 9, 22, hour: 9)
        XCTAssertEqual(state(history(endingOn: now, [true, true, false]), now: tomorrow).vitality, sippedToday - 0.2, accuracy: 0.0001)
    }

    func testTodayMetRaisesItStraightAway() {
        let now = date(2026, 9, 21)
        let before = state(history(endingOn: now, [true, false, false, nil]), now: now).vitality
        let after = state(history(endingOn: now, [true, false, false, true]), now: now).vitality
        XCTAssertEqual(after, before + 0.34, accuracy: 0.0001)
    }

    func testADayCoveredByAStreakFreezeIsNotAMissedDay() {
        let now = date(2026, 9, 21)
        // Two goal days, a miss yesterday, and today not started.
        let totals = history(endingOn: now, [true, true, false, nil])
        let unprotected = state(totals, now: now).vitality
        let protected = state(totals, frozen: [key(2026, 9, 20)], now: now).vitality
        XCTAssertEqual(unprotected, 0.8, accuracy: 0.0001, "full after two goal days, then down a fifth")
        XCTAssertEqual(protected, 1, accuracy: 0.0001, "the freeze covered yesterday, so nothing was lost")
    }

    func testAFreezeNeitherLowersNorRaises() {
        let now = date(2026, 9, 21)
        // One goal day, then a frozen day, then today.
        let totals = history(endingOn: now, [true, nil, nil])
        let value = state(totals, frozen: [key(2026, 9, 20)], now: now).vitality
        XCTAssertEqual(value, min(1, WorldEngine.startingVitality + 0.34), accuracy: 0.0001)
    }

    func testLowVitalityNeverRemovesWhatHasGrown() {
        let now = date(2026, 9, 21)
        // Sixty goal days, then a month of nothing.
        let days: [Bool?] = Array(repeating: true, count: 60) + Array(repeating: nil, count: 30)
        let world = state(history(endingOn: now, days), now: now)
        XCTAssertEqual(world.vitality, 0)
        XCTAssertEqual(world.mood, .wilting)
        XCTAssertEqual(world.goalDays, 60)
        XCTAssertEqual(world.stage, .tree)
    }

    func testTheWordsForVitality() {
        XCTAssertEqual(WorldVitality(1), .thriving)
        XCTAssertEqual(WorldVitality(0.8), .thriving)
        XCTAssertEqual(WorldVitality(0.6), .healthy)
        XCTAssertEqual(WorldVitality(0.4), .thirsty)
        XCTAssertEqual(WorldVitality(0.1), .wilting)
        for mood in WorldVitality.allCases { XCTAssertFalse(mood.words.contains("—")) }
    }

    // MARK: - An existing user's first look

    /// Five months of someone's real-looking history: a strong start, a holiday in the
    /// middle where nothing was logged, a freeze, and a good last week.
    func testTheWorldIsDerivedFromHistoryThatPredatesIt() {
        let now = date(2026, 9, 21)
        var days: [Bool?] = []
        days += Array(repeating: true, count: 40)          // a strong start
        days += [false, true, true, false, true]           // a wobble
        days += Array(repeating: nil, count: 12)           // a holiday, nothing logged
        days += Array(repeating: true, count: 25)          // back at it
        days += [false]                                    // a miss, which a freeze covered
        days += Array(repeating: true, count: 6)           // a good week
        days += [nil]                                      // today, nothing yet
        let totals = history(endingOn: now, days)
        let frozenDay = calendar.date(byAdding: .day, value: -7, to: now)!
        let world = state(totals, frozen: [DayKey.key(for: frozenDay, calendar: calendar)], now: now)

        XCTAssertEqual(world.goalDays, 40 + 3 + 25 + 6)
        XCTAssertEqual(world.stage, .tree, "74 goal days is past the tree and short of the fireflies")
        XCTAssertEqual(world.daysToNext, 26)
        XCTAssertEqual(world.vitality, 1, accuracy: 0.0001)
        XCTAssertEqual(world.mood, .thriving)
        XCTAssertTrue(world.spokenDescription.contains("A young tree"))
        XCTAssertTrue(world.spokenDescription.contains("74 goal days"))
        XCTAssertTrue(world.spokenDescription.contains("Fireflies in 26 more days"))
    }

    func testTheSameHistoryGivesTheSameWorldWhateverOrderItArrivesIn() {
        let now = date(2026, 9, 21)
        let totals = history(endingOn: now, [true, false, true, true, nil, true, false, true])
        let shuffled = Dictionary(uniqueKeysWithValues: totals.shuffled().map { ($0.key, $0.value) })
        XCTAssertEqual(state(totals, now: now), state(shuffled, now: now))
    }

    // MARK: - Light and sky

    func testTimeOfDay() {
        let expected: [(Int, WorldTimeOfDay)] = [(0, .night), (4, .night), (5, .dawn), (7, .dawn), (8, .day), (16, .day), (17, .dusk), (19, .dusk), (20, .night), (23, .night)]
        for (hour, light) in expected {
            XCTAssertEqual(WorldTimeOfDay(hour: hour), light, "\(hour):00")
        }
    }

    func testTheSkyIsOnlyDrawnWhenTheWeatherFeatureIsOnAndTheDataIsFresh() throws {
        let suite = "WorldEngineTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fetched = date(2026, 9, 21, hour: 9)

        XCTAssertNil(WorldWeather.current(isFeatureActive: true, now: fetched, in: defaults), "nothing fetched yet")
        WorldWeather.remember(.rain, at: fetched, in: defaults)
        XCTAssertEqual(WorldWeather.current(isFeatureActive: true, now: fetched.addingTimeInterval(3600), in: defaults), .rain)
        XCTAssertNil(WorldWeather.current(isFeatureActive: false, now: fetched.addingTimeInterval(3600), in: defaults), "feature off")
        XCTAssertNil(WorldWeather.current(isFeatureActive: true, now: fetched.addingTimeInterval(4 * 3600), in: defaults), "this morning's rain is not this afternoon's")
    }

    /// The painter's veil and heavy cloud and the World's Apple Weather mark all follow
    /// `isOvercast`. A clear reading paints the same sky as none, so it must not claim to
    /// show Apple Weather; the other three change the sky, so they must.
    func testOnlyOvercastSkiesShowTheWeather() {
        XCTAssertFalse(WorldWeather.clear.isOvercast)
        for weather in [WorldWeather.cloudy, .rain, .snow] {
            XCTAssertTrue(weather.isOvercast, "\(weather)")
        }
    }

    /// Why a clear reading carries no Apple Weather mark: it paints exactly the sky that
    /// no reading paints, by day and by night, so nothing on screen came from WeatherKit.
    /// Every sky that does carry the mark has to paint something different.
    @MainActor
    func testAClearSkyPaintsTheSameAsNoWeather() throws {
        func picture(_ weather: WorldWeather?, _ time: WorldTimeOfDay) throws -> Data {
            let scene = WorldSceneView(
                state: WorldState(goalDays: 40, vitality: 0.8),
                timeOfDay: time,
                weather: weather,
                isAnimated: false
            )
            .frame(width: 320, height: 240)
            let renderer = ImageRenderer(content: scene)
            renderer.scale = 1
            return try XCTUnwrap(renderer.uiImage?.pngData())
        }
        for time in [WorldTimeOfDay.day, .night] {
            let none = try picture(nil, time)
            XCTAssertEqual(try picture(.clear, time), none, "\(time)")
            for weather in WorldWeather.allCases where weather.isOvercast {
                XCTAssertNotEqual(try picture(weather, time), none, "\(weather) \(time)")
            }
        }
    }

    // MARK: - The share card

    /// The world card is drawn by `ImageRenderer`, away from any screen. This makes sure
    /// a `Canvas` scene actually survives that, and leaves the picture behind when asked
    /// to (`TEST_RUNNER_WORLD_CARD_OUTPUT=<folder>`), so it can be looked at.
    @MainActor
    func testTheWorldShareCardRenders() throws {
        let card = StreakShareCard(
            streak: 12,
            skin: .classic,
            milestone: nil,
            todayTotalML: 1500,
            goalML: 2000,
            system: .metric,
            world: WorldCardContent(
                state: WorldState(goalDays: 120, vitality: 0.9),
                decorations: [.lantern, .paperBoat, .bunting],
                timeOfDay: .dusk
            )
        )
        let renderer = ImageRenderer(content: card)
        renderer.scale = 2
        renderer.proposedSize = ProposedViewSize(StreakShareCard.size)
        let image = try XCTUnwrap(renderer.uiImage)
        XCTAssertEqual(image.size.width, StreakShareCard.size.width, accuracy: 1)
        XCTAssertEqual(image.size.height, StreakShareCard.size.height, accuracy: 1)

        if let folder = ProcessInfo.processInfo.environment["WORLD_CARD_OUTPUT"], let data = image.pngData() {
            try data.write(to: URL(fileURLWithPath: folder).appendingPathComponent("world-card.png"))
        }
    }

    // MARK: - Decorations

    func testThereAreAtLeastEightDecorationsAndExactlyTwoAreFree() {
        XCTAssertGreaterThanOrEqual(WorldDecoration.allCases.count, 8)
        XCTAssertEqual(WorldDecoration.allCases.filter { !$0.requiresPlus }.count, 2)
    }

    func testPaidDecorationsAreHiddenWithoutPlusAndComeBackWithIt() {
        let chosen = [WorldDecoration.lantern, .bridge, .rubberDuck].map(\.rawValue)
        XCTAssertEqual(WorldDecoration.active(from: chosen, isPlusActive: false), [.lantern])
        XCTAssertEqual(Set(WorldDecoration.active(from: chosen, isPlusActive: true)), [.lantern, .bridge, .rubberDuck])
    }

    func testAnUnknownDecorationFromANewerVersionIsIgnored() {
        XCTAssertEqual(WorldDecoration.active(from: ["hotAirBalloon", "lantern"], isPlusActive: true), [.lantern])
    }
}
