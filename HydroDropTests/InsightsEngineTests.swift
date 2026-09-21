import XCTest
@testable import HydroDrop

/// Insights compares two averages and says so in one careful sentence. These pin the
/// parts that would be embarrassing to get wrong: which day's value is set against which
/// day's goal, when there is enough data to say anything, and what is never said.
final class InsightsEngineTests: XCTestCase {
    private var calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    private let today = "2026-09-21"

    private func day(_ offset: Int) -> String {
        let base = DayKey.date(from: today, calendar: calendar)!
        return DayKey.key(for: calendar.date(byAdding: .day, value: offset, to: base)!, calendar: calendar)
    }

    private func analyse(met: Set<String>, first: String?, health: DailyHealth) -> [InsightResult] {
        InsightsEngine.analyse(metDays: met, firstLoggedDay: first, health: health, today: today, calendar: calendar)
    }

    private func result(_ metric: InsightMetric, in results: [InsightResult]) -> InsightResult {
        results.first { $0.metric == metric }!
    }

    /// Thirty days of history: even offsets are goal days, odd are not.
    private var alternatingMet: Set<String> {
        Set((1...30).filter { $0 % 2 == 0 }.map { day(-$0) })
    }

    // MARK: - The window

    func testTheWindowIsTheSixtyDaysBeforeTodayAndNeverToday() {
        let window = InsightsEngine.window(today: today, firstLoggedDay: "2020-01-01", calendar: calendar)
        XCTAssertEqual(window.count, 60)
        XCTAssertEqual(window.first, day(-1))
        XCTAssertEqual(window.last, day(-60))
        XCTAssertFalse(window.contains(today))
    }

    func testDaysFromBeforeTheAppWasInUseAreNotDaysTheGoalWasMissed() {
        let window = InsightsEngine.window(today: today, firstLoggedDay: day(-10), calendar: calendar)
        XCTAssertEqual(window.count, 10)
        XCTAssertEqual(window.last, day(-10))
        XCTAssertTrue(InsightsEngine.window(today: today, firstLoggedDay: nil, calendar: calendar).isEmpty)
    }

    // MARK: - Lag alignment

    func testSleepIsTheNightThatFollowedTheDay() {
        // A goal day is followed by a long night, stored under the NEXT morning.
        var sleep: [String: Double] = [:]
        for offset in 1...30 {
            let wasGoalDay = offset % 2 == 0
            sleep[day(-offset + 1)] = wasGoalDay ? 480 : 420
        }
        let results = analyse(met: alternatingMet, first: day(-30), health: DailyHealth(sleepMinutesByWakeDay: sleep))
        guard case .finding(let finding) = result(.sleep, in: results) else { return XCTFail("expected a sleep finding") }
        XCTAssertEqual(finding.metMean, 480, accuracy: 0.001)
        XCTAssertEqual(finding.missedMean, 420, accuracy: 0.001)
        XCTAssertEqual(finding.sentence, "On days you hit your goal, you slept 60 minutes longer that night, on average.")
    }

    func testTheSameNumbersKeyedToTheSameDayWouldTellTheOppositeStory() {
        // Guards the lag itself: line the long nights up with the goal day's own morning
        // and the engine must NOT credit them to that day.
        var sleep: [String: Double] = [:]
        for offset in 1...30 { sleep[day(-offset)] = offset % 2 == 0 ? 480 : 420 }
        let results = analyse(met: alternatingMet, first: day(-30), health: DailyHealth(sleepMinutesByWakeDay: sleep))
        guard case .finding(let finding) = result(.sleep, in: results) else { return XCTFail("expected a sleep finding") }
        XCTAssertLessThan(finding.difference, 0, "the night AFTER a goal day is the odd day's value")
    }

    func testRestingHeartRateIsTheDayThatFollowed() {
        var heart: [String: Double] = [:]
        for offset in 1...30 { heart[day(-offset + 1)] = offset % 2 == 0 ? 56 : 59 }
        let results = analyse(met: alternatingMet, first: day(-30), health: DailyHealth(restingHeartRateByDay: heart))
        guard case .finding(let finding) = result(.restingHeartRate, in: results) else { return XCTFail("expected a finding") }
        XCTAssertEqual(finding.difference, -3, accuracy: 0.001)
        XCTAssertEqual(finding.sentence, "On the day after you hit your goal, your resting heart rate was 3.0 bpm lower, on average.")
    }

    func testActiveEnergyIsTheSameDay() {
        var energy: [String: Double] = [:]
        for offset in 1...30 { energy[day(-offset)] = offset % 2 == 0 ? 600 : 500 }
        let results = analyse(met: alternatingMet, first: day(-30), health: DailyHealth(activeEnergyByDay: energy))
        guard case .finding(let finding) = result(.activeEnergy, in: results) else { return XCTFail("expected a finding") }
        XCTAssertEqual(finding.metMean, 600, accuracy: 0.001)
        XCTAssertEqual(finding.sentence, "On days you hit your goal, your active energy was 20 percent higher, on average.")
    }

    func testTodaysValueIsStillBeingGatheredAndIsNotCompared() {
        // Yesterday was a goal day. Its "following day" is today, which is not over.
        var heart: [String: Double] = [today: 40]
        for offset in 2...30 { heart[day(-offset + 1)] = 60 }
        let met = Set((1...30).map { day(-$0) })
        let results = analyse(met: met, first: day(-30), health: DailyHealth(restingHeartRateByDay: heart))
        guard case .needsMoreData(_, let goalDays, let otherDays) = result(.restingHeartRate, in: results) else {
            return XCTFail("every day was a goal day, so there is nothing to compare with")
        }
        XCTAssertEqual(goalDays, 0)
        XCTAssertEqual(otherDays, 7)
    }

    // MARK: - Buckets and thresholds

    func testAFindingNeedsSevenDaysInEachBucket() {
        // Six goal days with data, plenty of others.
        var energy: [String: Double] = [:]
        for offset in 1...30 { energy[day(-offset)] = 500 }
        let met = Set((1...6).map { day(-$0) })
        let six = analyse(met: met, first: day(-30), health: DailyHealth(activeEnergyByDay: energy))
        XCTAssertEqual(result(.activeEnergy, in: six), .needsMoreData(metric: .activeEnergy, goalDaysNeeded: 1, otherDaysNeeded: 0))

        let seven = analyse(met: met.union([day(-7)]), first: day(-30), health: DailyHealth(activeEnergyByDay: energy))
        XCTAssertEqual(result(.activeEnergy, in: seven), .noClearPattern(metric: .activeEnergy), "enough days now, and identical averages")
    }

    func testADayOnlyCountsIfHealthHasAValueForIt() {
        // Thirty days logged, and Health only knows about four of them.
        var energy: [String: Double] = [:]
        for offset in [2, 3, 4, 5] { energy[day(-offset)] = 500 }
        let results = analyse(met: alternatingMet, first: day(-30), health: DailyHealth(activeEnergyByDay: energy))
        XCTAssertEqual(result(.activeEnergy, in: results), .needsMoreData(metric: .activeEnergy, goalDaysNeeded: 5, otherDaysNeeded: 5))
    }

    func testTheThresholds() {
        func finding(_ metric: InsightMetric, _ met: Double, _ missed: Double) -> InsightFinding {
            InsightFinding(metric: metric, metMean: met, missedMean: missed, metDays: 10, missedDays: 10)
        }
        XCTAssertFalse(InsightsEngine.clearsThreshold(finding(.sleep, 429.9, 420)))
        XCTAssertTrue(InsightsEngine.clearsThreshold(finding(.sleep, 430, 420)))
        XCTAssertTrue(InsightsEngine.clearsThreshold(finding(.sleep, 410, 420)), "shorter counts too")

        XCTAssertFalse(InsightsEngine.clearsThreshold(finding(.restingHeartRate, 58.6, 60)))
        XCTAssertTrue(InsightsEngine.clearsThreshold(finding(.restingHeartRate, 58.5, 60)))

        XCTAssertFalse(InsightsEngine.clearsThreshold(finding(.activeEnergy, 539, 500)))
        XCTAssertTrue(InsightsEngine.clearsThreshold(finding(.activeEnergy, 540, 500)))
        XCTAssertFalse(InsightsEngine.clearsThreshold(finding(.activeEnergy, 100, 0)), "nothing to be a percentage of")
    }

    /// No watch, no sleep tracking, or access not given. Logging more water will never
    /// fix that, so the answer must not be "keep logging".
    func testAMetricHealthHasNothingForSaysSoRatherThanKeepLogging() {
        let results = analyse(met: alternatingMet, first: day(-30), health: DailyHealth())
        XCTAssertEqual(results, InsightMetric.allCases.map { .noHealthData(metric: $0) })
        let message = InsightResult.noHealthData(metric: .sleep).waitingMessage ?? ""
        XCTAssertTrue(message.hasPrefix("Apple Health has no sleep data for these days."), message)
        XCTAssertFalse(message.contains("Keep logging"))
    }

    func testOneMissingMetricDoesNotHideTheOthers() {
        var energy: [String: Double] = [:]
        for offset in 1...30 { energy[day(-offset)] = offset % 2 == 0 ? 600 : 500 }
        let results = analyse(met: alternatingMet, first: day(-30), health: DailyHealth(activeEnergyByDay: energy))
        XCTAssertEqual(result(.sleep, in: results), .noHealthData(metric: .sleep))
        if case .finding = result(.activeEnergy, in: results) {} else { XCTFail("energy has data and a clear difference") }
    }

    func testSomeoneWhoHasNeverLoggedGetsTheWaitingStateNotACrash() {
        let results = analyse(met: [], first: nil, health: DailyHealth(activeEnergyByDay: [day(-1): 400]))
        XCTAssertEqual(result(.activeEnergy, in: results), .needsMoreData(metric: .activeEnergy, goalDaysNeeded: 7, otherDaysNeeded: 7))
        XCTAssertEqual(result(.sleep, in: results), .noHealthData(metric: .sleep))
    }

    func testTheWaitingMessageSaysHowManyMoreDays() {
        let both = InsightResult.needsMoreData(metric: .sleep, goalDaysNeeded: 3, otherDaysNeeded: 1)
        XCTAssertEqual(both.waitingMessage, "Keep logging. Insights unlock after a bit more data: 3 more days when you hit your goal, and 1 more day when you did not.")
        let one = InsightResult.needsMoreData(metric: .sleep, goalDaysNeeded: 0, otherDaysNeeded: 4)
        XCTAssertEqual(one.waitingMessage, "Keep logging. Insights unlock after a bit more data: 4 more days when you did not.")
    }

    // MARK: - What is never said

    /// Every sentence the engine can produce, in both directions, checked for the words
    /// that would turn a pattern into a claim. Insights describes. It never explains.
    func testNoSentenceEverClaimsACauseOrSoundsMedical() {
        let banned = [
            "cause", "because", "thanks to", "due to", "lead", "led to", "result", "improve", "boost", "help",
            "treat", "prevent", "cure", "heal", "diagnos", "risk", "healthy", "healthier", "should", "better", "worse",
            "water made", "hydration made", "—",
            // Words that smuggle a claim in without saying "caused".
            "hydrat", "benefit", "linked", "associated", "correlat", "effect", "impact", "quality", "recovery",
            "performance", "optimal", "normal", "elevated", "reduce", "increase", "support", "restore", "symptom",
            "clinical", "doctor",
        ]
        // Everything fixed that Insights shows, not just what the engine writes: the
        // primer, the cards and the workout title carry as much risk as a finding does.
        var sentences: [String] = InsightsCopy.all
        for metric in InsightMetric.allCases {
            sentences.append(metric.alignmentNote)
            for (met, missed) in [(480.0, 420.0), (420.0, 480.0), (61.0, 60.0)] {
                sentences.append(InsightFinding(metric: metric, metMean: met, missedMean: missed, metDays: 9, missedDays: 12).sentence)
            }
            sentences.append(InsightResult.noClearPattern(metric: metric).waitingMessage ?? "")
            sentences.append(InsightResult.needsMoreData(metric: metric, goalDaysNeeded: 2, otherDaysNeeded: 5).waitingMessage ?? "")
            sentences.append(InsightResult.noHealthData(metric: metric).waitingMessage ?? "")
        }
        XCTAssertGreaterThan(sentences.count, 30)
        for sentence in sentences {
            // The product's own name for the Health app is allowed to contain "heal".
            let lowered = sentence.lowercased()
                .replacingOccurrences(of: "apple health", with: "")
                .replacingOccurrences(of: "health app", with: "")
            for word in banned {
                XCTAssertFalse(lowered.contains(word), "\"\(sentence)\" contains \"\(word)\"")
            }
        }
        XCTAssertEqual(InsightsEngine.footer, "Patterns in your own data, not medical advice.")
    }

    func testEveryFindingIsAboutTheUsersOwnDaysAndAnAverage() {
        for metric in InsightMetric.allCases {
            let sentence = InsightFinding(metric: metric, metMean: 500, missedMean: 400, metDays: 9, missedDays: 9).sentence
            XCTAssertTrue(sentence.contains("you hit your goal"), sentence)
            XCTAssertTrue(sentence.hasSuffix("on average."), sentence)
        }
    }

    // MARK: - Sleep nights

    private func interval(_ fromDay: Int, _ fromHour: Int, _ toDay: Int, _ toHour: Int) -> DateInterval {
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: fromDay, hour: fromHour))!
        let end = calendar.date(from: DateComponents(year: 2026, month: 9, day: toDay, hour: toHour))!
        return DateInterval(start: start, end: end)
    }

    func testANightBelongsToTheMorningItEndedOn() {
        let nights = SleepNights.minutesByWakeDay([interval(19, 23, 20, 7)], calendar: calendar)
        XCTAssertEqual(nights, ["2026-09-20": 480])
    }

    func testANightThatStartedAfterMidnightIsStillThatMorning() {
        let nights = SleepNights.minutesByWakeDay([interval(20, 1, 20, 8)], calendar: calendar)
        XCTAssertEqual(nights, ["2026-09-20": 420])
    }

    func testTheSameNightFromAWatchAndAPhoneIsCountedOnce() {
        let nights = SleepNights.minutesByWakeDay([interval(19, 23, 20, 7), interval(19, 23, 20, 6), interval(20, 2, 20, 7)], calendar: calendar)
        XCTAssertEqual(nights["2026-09-20"] ?? 0, 480, accuracy: 0.001)
    }

    func testStagesOfOneNightAddUp() {
        // Core, deep, REM, with a short wake between two of them.
        let nights = SleepNights.minutesByWakeDay([interval(19, 23, 20, 2), interval(20, 2, 20, 4), interval(20, 5, 20, 7)], calendar: calendar)
        XCTAssertEqual(nights["2026-09-20"] ?? 0, 420, accuracy: 0.001)
    }

    func testNoSleepDataIsNoNights() {
        XCTAssertTrue(SleepNights.minutesByWakeDay([], calendar: calendar).isEmpty)
    }

    // MARK: - The workout bump

    func testThreeHundredAndFiftyForEveryHalfHour() {
        XCTAssertEqual(WorkoutBump.suggestedML(workoutMinutes: [30]), 350)
        XCTAssertEqual(WorkoutBump.suggestedML(workoutMinutes: [60]), 700)
        XCTAssertEqual(WorkoutBump.suggestedML(workoutMinutes: [20]), 250, "233 mL, to the nearest 50")
        XCTAssertEqual(WorkoutBump.suggestedML(workoutMinutes: [45]), 550, "525 mL, to the nearest 50")
    }

    func testAWorkoutUnderTwentyMinutesIsNotCounted() {
        XCTAssertNil(WorkoutBump.suggestedML(workoutMinutes: []))
        XCTAssertNil(WorkoutBump.suggestedML(workoutMinutes: [19.9]))
        XCTAssertNil(WorkoutBump.suggestedML(workoutMinutes: [10, 12, 15]), "three short ones do not add up to a long one")
        XCTAssertEqual(WorkoutBump.suggestedML(workoutMinutes: [10, 30]), 350, "only the long one counts")
    }

    private func workout(_ fromHour: Int, _ fromMinute: Int, minutes: Double) -> DateInterval {
        let start = calendar.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: fromHour, minute: fromMinute))!
        return DateInterval(start: start, duration: minutes * 60)
    }

    func testTheSameWorkoutFromAWatchAndAnotherAppIsCountedOnce() {
        // One half hour run, written to Health twice.
        let minutes = WorkoutBump.minutes(of: [workout(7, 0, minutes: 30), workout(7, 0, minutes: 30)])
        XCTAssertEqual(minutes, [30])
        XCTAssertEqual(WorkoutBump.suggestedML(workoutMinutes: minutes), 350, "not 700")

        // The second record starts a little late and ends a little late. Still one run.
        let ragged = WorkoutBump.minutes(of: [workout(7, 0, minutes: 30), workout(7, 2, minutes: 30)])
        XCTAssertEqual(ragged, [32])
    }

    func testTwoSeparateWorkoutsStayTwoEvenBackToBack() {
        let minutes = WorkoutBump.minutes(of: [workout(7, 0, minutes: 30), workout(7, 30, minutes: 15), workout(18, 0, minutes: 25)])
        XCTAssertEqual(minutes, [30, 15, 25])
        XCTAssertEqual(WorkoutBump.suggestedML(workoutMinutes: minutes), 650, "the 15 minute one is too short to count: 55 minutes")
    }

    func testTwoWorkoutsInADayAreOneSuggestion() {
        XCTAssertEqual(WorkoutBump.suggestedML(workoutMinutes: [30, 30]), 700)
    }

    func testTheDailyCapCoversEveryReasonTogether() {
        // A two hour workout asks for 1400 and is offered the cap.
        let long = TodayBump.suggestion(from: [.workout: WorkoutBump.suggestedML(workoutMinutes: [120]) ?? 0], alreadyAcceptedML: 0)
        XCTAssertEqual(long?.addML, 1000)
        XCTAssertEqual(long?.sources, [.workout])

        // With 500 already accepted for the heat, only the room that is left is offered.
        let afterHeat = TodayBump.suggestion(from: [.workout: 700], alreadyAcceptedML: 500)
        XCTAssertEqual(afterHeat?.addML, 500)

        // Hot, the morning after, and a workout: one question, capped once.
        let everything = TodayBump.suggestion(from: [.heat: 500, .nightOut: 500, .workout: 350], alreadyAcceptedML: 0)
        XCTAssertEqual(everything?.addML, 1000)
        XCTAssertEqual(everything?.sources, [.heat, .nightOut, .workout])

        // Nothing left to offer once the cap has been reached.
        XCTAssertNil(TodayBump.suggestion(from: [.workout: 350], alreadyAcceptedML: 1000))
    }
}
