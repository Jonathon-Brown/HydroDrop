import XCTest
@testable import HydroDrop

final class OnboardingGoalTests: XCTestCase {
    /// 70 kg at 33 mL/kg is 2310; low activity adds nothing; nearest 100 is 2300.
    func testSuggestionRoundsToTheNearestHundred() {
        XCTAssertEqual(OnboardingGoal.suggestedGoalML(weightKG: 70, activity: .low), 2300)
    }

    func testActivityAddsTheDocumentedBonus() {
        let low = OnboardingGoal.suggestedGoalML(weightKG: 80, activity: .low)
        let moderate = OnboardingGoal.suggestedGoalML(weightKG: 80, activity: .moderate)
        let high = OnboardingGoal.suggestedGoalML(weightKG: 80, activity: .high)
        // 2640 -> 2600, 2990 -> 3000, 3340 -> 3300
        XCTAssertEqual(low, 2600)
        XCTAssertEqual(moderate, 3000)
        XCTAssertEqual(high, 3300)
    }

    func testSuggestionIsClampedToTheGoalRange() {
        XCTAssertEqual(
            OnboardingGoal.suggestedGoalML(weightKG: 5, activity: .low),
            HydrationGoalCalculator.validGoalRange.lowerBound
        )
        XCTAssertEqual(
            OnboardingGoal.suggestedGoalML(weightKG: 400, activity: .high),
            HydrationGoalCalculator.validGoalRange.upperBound
        )
    }

    /// The three onboarding levels price exactly like the calculator's own, so a user
    /// who reopens "Calculate for me" with the same inputs sees the same number.
    func testLevelsMapOntoTheCalculator() {
        for activity in OnboardingActivity.allCases {
            let viaOnboarding = OnboardingGoal.suggestedGoalML(weightKG: 64, activity: activity)
            let viaCalculator = HydrationGoalCalculator.recommendedGoalML(
                weightKG: 64,
                sex: .notSpecified,
                activity: activity.activityLevel,
                roundedTo: 100
            )
            XCTAssertEqual(viaOnboarding, viaCalculator)
        }
    }
}

final class VolumeUnitTests: XCTestCase {
    func testImperialPresetsAreWholeOunces() {
        let presets = MeasurementSystem.imperial.defaultQuickAddPresetsML
        XCTAssertEqual(presets.map { MeasurementSystem.imperial.formattedNumber(mL: $0) }, ["8", "12", "16"])
    }

    func testMetricPresetsAreUnchanged() {
        XCTAssertEqual(MeasurementSystem.metric.defaultQuickAddPresetsML, [200, 330, 500])
    }

    func testDisplayVolumeRoundTrips() {
        for ounces in [1, 8, 12, 16, 24, 68] {
            let mL = MeasurementSystem.imperial.mL(fromDisplayVolume: Double(ounces))
            XCTAssertEqual(MeasurementSystem.imperial.wholeUnits(fromML: mL), ounces)
        }
        XCTAssertEqual(MeasurementSystem.metric.mL(fromDisplayVolume: 250), 250)
    }

    func testImperialDropsAMeaninglessDecimal() {
        XCTAssertEqual(MeasurementSystem.imperial.format(mL: 237), "8 fl oz")
        XCTAssertEqual(MeasurementSystem.imperial.format(mL: 500), "16.9 fl oz")
    }

    func testGoalRangeCoversTheStoredRangeInBothSystems() {
        XCTAssertEqual(MeasurementSystem.metric.goalRange, 500...5000)
        XCTAssertEqual(MeasurementSystem.imperial.goalRange, 17...169)
    }

    func testNonFiniteInputBecomesZeroRatherThanTrapping() {
        XCTAssertEqual(MeasurementSystem.imperial.mL(fromDisplayVolume: .infinity), 0)
        XCTAssertEqual(MeasurementSystem.metric.mL(fromDisplayVolume: .nan), 0)
    }
}

final class ReviewPrompterTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "ReviewPrompterTests")
        defaults.removePersistentDomain(forName: "ReviewPrompterTests")
    }

    func testAsksOnlyFromAWeekLongStreak() {
        XCTAssertFalse(ReviewPrompter.shouldPrompt(streak: 6, version: "1.4", defaults: defaults))
        XCTAssertTrue(ReviewPrompter.shouldPrompt(streak: 7, version: "1.4", defaults: defaults))
        XCTAssertTrue(ReviewPrompter.shouldPrompt(streak: 30, version: "1.4", defaults: defaults))
    }

    func testAsksAtMostOncePerVersion() {
        ReviewPrompter.markPrompted(version: "1.4", defaults: defaults)
        XCTAssertFalse(ReviewPrompter.shouldPrompt(streak: 7, version: "1.4", defaults: defaults))
        XCTAssertTrue(ReviewPrompter.shouldPrompt(streak: 7, version: "1.5", defaults: defaults))
    }
}
