import XCTest
@testable import HydroDrop

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// A fixed Friday. `at(21, 30)` is half past nine that evening; `dayOffset` moves days.
private func at(_ hour: Int, _ minute: Int = 0, dayOffset: Int = 0) -> Date {
    let base = utc.date(from: DateComponents(year: 2026, month: 9, day: 18))!
    let day = utc.date(byAdding: .day, value: dayOffset, to: base)!
    return utc.date(byAdding: .minute, value: hour * 60 + minute, to: day)!
}

final class DrinkTypePhaseThreeTests: XCTestCase {
    /// Every tea already in anyone's log is stored as "tea", and has to stay black tea.
    func testTeaAlreadyInTheLogReadsBackAsBlackTea() {
        XCTAssertEqual(DrinkType(rawValue: "tea"), .blackTea)
        XCTAssertEqual(DrinkType.blackTea.rawValue, "tea")
        let entry = WaterEntry(amountML: 250)
        entry.drinkTypeRawValue = "tea"
        XCTAssertEqual(entry.drinkType, .blackTea)
        XCTAssertEqual(entry.hydratedML, 238)
    }

    func testShortcutsStillMeanTheSameTea() {
        XCTAssertEqual(DrinkTypeChoice.tea.drinkType, .blackTea)
        XCTAssertEqual(DrinkTypeChoice.greenTea.drinkType, .greenTea)
        XCTAssertEqual(DrinkTypeChoice.espresso.drinkType, .espresso)
        XCTAssertEqual(DrinkTypeChoice.cola.drinkType, .cola)
        XCTAssertEqual(DrinkTypeChoice.energyDrink.drinkType, .energyDrink)
    }

    func testNewDrinksCountForWhatWasAgreed() {
        XCTAssertEqual(DrinkType.greenTea.hydrationMultiplier, 0.95)
        XCTAssertEqual(DrinkType.espresso.hydrationMultiplier, 0.9)
        XCTAssertEqual(DrinkType.cola.hydrationMultiplier, 0.9)
        XCTAssertEqual(DrinkType.energyDrink.hydrationMultiplier, 0.85)
    }

    /// In the log, and nothing towards the goal.
    func testAlcoholicDrinksAddNothingToHydration() {
        for type in [DrinkType.beer, .wine, .cocktail, .spirits] {
            XCTAssertTrue(type.isAlcoholic)
            XCTAssertEqual(type.hydratedML(from: 500), 0, type.rawValue)
            XCTAssertEqual(WaterEntry(amountML: 330, drinkType: type).hydratedML, 0)
        }
        XCTAssertFalse(DrinkType.water.isAlcoholic)
        XCTAssertFalse(DrinkType.other.isAlcoholic)
    }

    /// Health refuses a zero-quantity water sample, so an alcoholic drink must never be
    /// offered to it as water.
    func testAnAlcoholicDrinkIsNeverWrittenToHealthAsWater() async {
        let entry = WaterEntry(amountML: 330, timestamp: at(21), drinkType: .beer)
        let eligible = await HealthKitManager.isEligible(entry, since: .distantPast)
        XCTAssertFalse(eligible)
    }
}

final class CaffeineTests: XCTestCase {
    func testCaffeinePerTypicalServing() {
        XCTAssertEqual(DrinkType.coffee.caffeineMg(in: 250), 95, accuracy: 0.001)
        XCTAssertEqual(DrinkType.blackTea.caffeineMg(in: 250), 47, accuracy: 0.001)
        XCTAssertEqual(DrinkType.greenTea.caffeineMg(in: 250), 28, accuracy: 0.001)
        XCTAssertEqual(DrinkType.cola.caffeineMg(in: 250), 22, accuracy: 0.001)
        XCTAssertEqual(DrinkType.energyDrink.caffeineMg(in: 250), 80, accuracy: 0.001)
    }

    /// Espresso is per 30 mL shot, not scaled up to a quarter of a litre.
    func testEspressoIsCountedByTheShot() {
        XCTAssertEqual(DrinkType.espresso.caffeineMg(in: 30), 63, accuracy: 0.001)
        XCTAssertEqual(DrinkType.espresso.caffeineMg(in: 60), 126, accuracy: 0.001)
        XCTAssertLessThan(DrinkType.espresso.caffeineMg(in: 30), DrinkType.coffee.caffeineMg(in: 250))
    }

    func testCaffeineScalesWithTheAmount() {
        XCTAssertEqual(DrinkType.coffee.caffeineMg(in: 500), 190, accuracy: 0.001)
        XCTAssertEqual(DrinkType.coffee.caffeineMg(in: 125), 47.5, accuracy: 0.001)
        XCTAssertEqual(DrinkType.coffee.caffeineMg(in: 0), 0)
        XCTAssertEqual(DrinkType.coffee.caffeineMg(in: -50), 0)
    }

    func testDrinksWithoutCaffeineHaveNone() {
        for type in [DrinkType.water, .sparkling, .juice, .other, .beer, .wine, .cocktail, .spirits] {
            XCTAssertFalse(type.hasCaffeine, type.rawValue)
            XCTAssertEqual(type.caffeineMg(in: 500), 0)
        }
    }

    func testTodaysTotalLeavesYesterdayOut() {
        let entries = [
            WaterEntry(amountML: 250, timestamp: at(8), drinkType: .coffee),
            WaterEntry(amountML: 30, timestamp: at(13), drinkType: .espresso),
            WaterEntry(amountML: 500, timestamp: at(15), drinkType: .water),
            WaterEntry(amountML: 250, timestamp: at(9, dayOffset: -1), drinkType: .coffee),
        ]
        XCTAssertEqual(CaffeineCutoff.totalMg(of: entries, on: at(16), calendar: utc), 158, accuracy: 0.001)
    }

    func testCaffeineIsOnlyOfferedToHealthOnce() async {
        let coffee = WaterEntry(amountML: 250, timestamp: at(8), drinkType: .coffee)
        var eligible = await HealthKitManager.isCaffeineEligible(coffee, since: .distantPast)
        XCTAssertTrue(eligible)
        coffee.caffeineSampleUUID = UUID().uuidString
        eligible = await HealthKitManager.isCaffeineEligible(coffee, since: .distantPast)
        XCTAssertFalse(eligible)

        let water = WaterEntry(amountML: 250, timestamp: at(8))
        eligible = await HealthKitManager.isCaffeineEligible(water, since: .distantPast)
        XCTAssertFalse(eligible, "nothing to write for a drink with no caffeine")
    }

    // MARK: - Cutoff

    private let twoPM = 14 * 60
    private let eightAM = 8 * 60

    private func isLate(_ date: Date) -> Bool {
        CaffeineCutoff.isLate(date, cutoffMinutes: twoPM, wakingStartMinutes: eightAM, calendar: utc)
    }

    func testTheCutoffDefaultsToTwoInTheAfternoon() {
        XCTAssertEqual(CaffeineCutoff.defaultMinutes, 840)
    }

    func testBeforeTheCutoffIsFine() {
        XCTAssertFalse(isLate(at(8)))
        XCTAssertFalse(isLate(at(13, 59)))
    }

    func testFromTheCutoffOnIsLate() {
        XCTAssertTrue(isLate(at(14)))
        XCTAssertTrue(isLate(at(21, 30)))
    }

    /// One in the morning is later than nine at night, not the start of a new day.
    func testTheSmallHoursAreStillLate() {
        XCTAssertTrue(isLate(at(1, dayOffset: 1)))
        XCTAssertTrue(isLate(at(7, 59, dayOffset: 1)))
        XCTAssertFalse(isLate(at(8, dayOffset: 1)))
    }

    func testOnlyTheLatestCaffeinatedDrinkDecidesTheNote() {
        let morningCoffee = WaterEntry(amountML: 250, timestamp: at(9), drinkType: .coffee)
        let lateTea = WaterEntry(amountML: 250, timestamp: at(16), drinkType: .greenTea)
        let lateWater = WaterEntry(amountML: 250, timestamp: at(18))

        func late(_ entries: [WaterEntry]) -> WaterEntry? {
            CaffeineCutoff.lateDrink(in: entries, on: at(19), cutoffMinutes: twoPM, wakingStartMinutes: eightAM, calendar: utc)
        }
        XCTAssertNil(late([morningCoffee, lateWater]), "water after the cutoff is not caffeine")
        XCTAssertTrue(late([morningCoffee, lateTea, lateWater]) === lateTea)
        XCTAssertNil(late([]))
    }
}

final class NightOutTests: XCTestCase {
    private let tenPM = 22 * 60
    private let eightAM = 8 * 60

    // MARK: - How long it lasts

    func testItLastsSixHours() {
        let start = at(20)
        func active(_ now: Date) -> Bool {
            NightOut.isActive(startedAt: start, now: now, wakingEndMinutes: tenPM, calendar: utc)
        }
        XCTAssertTrue(active(start))
        XCTAssertTrue(active(at(23, 30)))
        XCTAssertTrue(active(at(1, 59, dayOffset: 1)))
        XCTAssertFalse(active(at(2, dayOffset: 1)), "six hours is the limit")
        XCTAssertFalse(active(at(19, 59)), "it cannot be running before it started")
    }

    /// Whatever the duration is ever changed to, it never outlives the end of the next
    /// day's waking window.
    func testItNeverSurvivesPastTheEndOfTheNextDaysWakingWindow() {
        let start = at(20)
        XCTAssertEqual(
            NightOut.hardStop(startedAt: start, wakingEndMinutes: tenPM, calendar: utc),
            at(22, dayOffset: 1)
        )
        XCTAssertLessThan(
            start.addingTimeInterval(NightOut.duration),
            NightOut.hardStop(startedAt: start, wakingEndMinutes: tenPM, calendar: utc)
        )
    }

    // MARK: - The morning after

    func testAnEveningOutIsFollowedUpTomorrowMorning() {
        XCTAssertEqual(
            NightOut.nextWakingStart(after: at(21, 30), wakingStartMinutes: eightAM, calendar: utc),
            at(8, dayOffset: 1)
        )
    }

    func testOneThatRanPastMidnightIsFollowedUpThatSameMorning() {
        XCTAssertEqual(
            NightOut.nextWakingStart(after: at(1, 15, dayOffset: 1), wakingStartMinutes: eightAM, calendar: utc),
            at(8, dayOffset: 1)
        )
    }

    func testTheReminderComesTwentyMinutesAfterADrink() {
        XCTAssertEqual(NightOut.waterRoundDelay, 20 * 60)
    }

    // MARK: - Tally

    private func tally(_ entries: [WaterEntry], since start: Date) -> NightOut.Tally {
        NightOut.tally(of: entries, since: start)
    }

    func testTheTallyCountsDrinksAndWatersSinceItBegan() {
        let start = at(20)
        let entries = [
            WaterEntry(amountML: 500, timestamp: at(15)),                          // before
            WaterEntry(amountML: 330, timestamp: at(20, 10), drinkType: .beer),
            WaterEntry(amountML: 250, timestamp: at(20, 40)),
            WaterEntry(amountML: 150, timestamp: at(21, 15), drinkType: .wine),
            WaterEntry(amountML: 250, timestamp: at(21, 20), drinkType: .coffee),  // neither
            WaterEntry(amountML: 250, timestamp: at(21, 50), drinkType: .sparkling),
        ]
        XCTAssertEqual(tally(entries, since: start), NightOut.Tally(drinks: 2, waters: 2))
    }

    func testTheExampleInTheBrief() {
        XCTAssertEqual(
            NightOut.line(for: NightOut.Tally(drinks: 2, waters: 1)),
            "2 drinks, 1 water. One water to go."
        )
    }

    func testTheLineIsAlwaysAboutWater() {
        XCTAssertEqual(NightOut.line(for: .init(drinks: 0, waters: 0)), "Night Out is on. I will nudge you about water.")
        XCTAssertEqual(NightOut.line(for: .init(drinks: 1, waters: 0)), "1 drink, 0 waters. One water to go.")
        XCTAssertEqual(NightOut.line(for: .init(drinks: 3, waters: 1)), "3 drinks, 1 water. Two waters to go.")
        XCTAssertEqual(NightOut.line(for: .init(drinks: 2, waters: 2)), "2 drinks, 2 waters. All caught up on water.")
        XCTAssertEqual(NightOut.line(for: .init(drinks: 1, waters: 4)), "1 drink, 4 waters. All caught up on water.")
    }

    /// Extra water is never a debt in the other direction.
    func testWatersToGoIsNeverNegative() {
        XCTAssertEqual(NightOut.Tally(drinks: 1, waters: 5).watersToGo, 0)
    }

    /// No line may praise a drink count, set one as a target, or estimate anything.
    func testNoLineEncouragesDrinking() {
        let banned = ["great", "nice", "keep going", "more drinks", "cheers", "bac", "alcohol level", "record", "streak", "badge"]
        for drinks in 0...12 {
            for waters in 0...12 {
                let line = NightOut.line(for: .init(drinks: drinks, waters: waters)).lowercased()
                for word in banned {
                    XCTAssertFalse(line.contains(word), "\"\(line)\" contains \"\(word)\"")
                }
                XCTAssertFalse(line.contains("—"))
            }
        }
    }
}

final class TodayBumpTests: XCTestCase {
    func testTheMorningAfterSuggestsHalfALitre() {
        XCTAssertEqual(TodayBump.nightOutML, 500)
        XCTAssertEqual(
            TodayBump.suggestion(from: [.nightOut: TodayBump.nightOutML], alreadyAcceptedML: 0),
            TodayBump.Suggestion(addML: 500, sources: [.nightOut])
        )
    }

    /// A hot morning after a Night Out is one question, not two.
    func testHeatAndNightOutBecomeOneSuggestion() {
        let suggestion = TodayBump.suggestion(from: [.heat: 250, .nightOut: 500], alreadyAcceptedML: 0)
        XCTAssertEqual(suggestion, TodayBump.Suggestion(addML: 750, sources: [.heat, .nightOut]))
    }

    func testTheCombinedSuggestionIsCappedAtOneLitre() {
        let suggestion = TodayBump.suggestion(from: [.heat: 750, .nightOut: 500], alreadyAcceptedML: 0)
        XCTAssertEqual(suggestion?.addML, 1_000)
    }

    /// The cap is on the day, not on the offer.
    func testWhatWasAlreadyAcceptedTodayCountsTowardsTheCap() {
        XCTAssertEqual(TodayBump.suggestion(from: [.nightOut: 500], alreadyAcceptedML: 750)?.addML, 250)
        XCTAssertNil(TodayBump.suggestion(from: [.nightOut: 500], alreadyAcceptedML: 1_000))
        XCTAssertEqual(TodayBump.total(alreadyAcceptedML: 750, adding: 500), 1_000)
        XCTAssertEqual(TodayBump.total(alreadyAcceptedML: 0, adding: 500), 500)
    }

    func testNoReasonMeansNoSuggestion() {
        XCTAssertNil(TodayBump.suggestion(from: [:], alreadyAcceptedML: 0))
        XCTAssertNil(TodayBump.suggestion(from: [.heat: 0], alreadyAcceptedML: 0))
    }
}
