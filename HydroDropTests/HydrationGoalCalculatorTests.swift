import XCTest
@testable import HydroDrop

final class HydrationGoalCalculatorTests: XCTestCase {
    func testOrdinaryEstimate() {
        XCTAssertEqual(
            HydrationGoalCalculator.recommendedGoalML(weightKG: 70, sex: .male, activity: .sedentary),
            2450
        )
    }

    func testActivityAddsItsBonus() {
        let sedentary = HydrationGoalCalculator.recommendedGoalML(weightKG: 70, sex: .male, activity: .sedentary)
        let active = HydrationGoalCalculator.recommendedGoalML(weightKG: 70, sex: .male, activity: .moderate)
        XCTAssertEqual(active - sedentary, 700)
    }

    func testResultIsClampedToTheValidRange() {
        XCTAssertEqual(
            HydrationGoalCalculator.recommendedGoalML(weightKG: 1, sex: .female, activity: .sedentary),
            HydrationGoalCalculator.validGoalRange.lowerBound
        )
        XCTAssertEqual(
            HydrationGoalCalculator.recommendedGoalML(weightKG: 500, sex: .male, activity: .veryActive),
            HydrationGoalCalculator.validGoalRange.upperBound
        )
    }

    /// Regression: the clamp ran after the `Int` conversion, so a weight the keypad can
    /// actually produce trapped instead of clamping. These crash the app if the order
    /// is ever swapped back.
    func testAbsurdlyLargeWeightsClampInsteadOfTrapping() {
        XCTAssertEqual(
            HydrationGoalCalculator.recommendedGoalML(weightKG: 1e18, sex: .male, activity: .veryActive),
            HydrationGoalCalculator.validGoalRange.upperBound
        )
        XCTAssertEqual(
            HydrationGoalCalculator.recommendedGoalML(weightKG: .greatestFiniteMagnitude, sex: .male, activity: .sedentary),
            HydrationGoalCalculator.validGoalRange.upperBound
        )
    }

    /// `Double("1e400")` parses as +infinity, and a decimal pad accepts a paste.
    func testNonFiniteWeightIsRejectedRatherThanConverted() {
        XCTAssertEqual(
            HydrationGoalCalculator.recommendedGoalML(weightKG: .infinity, sex: .male, activity: .sedentary),
            HydrationGoalCalculator.validGoalRange.lowerBound
        )
        XCTAssertEqual(
            HydrationGoalCalculator.recommendedGoalML(weightKG: .nan, sex: .male, activity: .sedentary),
            HydrationGoalCalculator.validGoalRange.lowerBound
        )
    }
}

final class MeasurementSystemTests: XCTestCase {
    /// mL is the storage unit and conversion happens at the display layer, so a value
    /// entered in one system and read back in the other has to survive the round trip.
    func testWeightRoundTripsThroughImperial() {
        let kg = 82.5
        let displayed = MeasurementSystem.imperial.displayWeight(fromKG: kg)
        let back = MeasurementSystem.imperial.weightInKG(fromDisplayValue: displayed)
        XCTAssertEqual(back, kg, accuracy: 0.0001)
    }

    func testVolumeFormatting() {
        XCTAssertEqual(MeasurementSystem.metric.format(mL: 500), "500 mL")
        XCTAssertEqual(MeasurementSystem.imperial.format(mL: 500), "16.9 fl oz")
    }

    func testZeroAndNegativeVolumesFormatWithoutCrashing() {
        XCTAssertEqual(MeasurementSystem.metric.formattedNumber(mL: 0), "0")
        XCTAssertFalse(MeasurementSystem.imperial.formattedNumber(mL: 0).isEmpty)
    }
}
