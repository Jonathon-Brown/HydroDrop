import XCTest
@testable import HydroDrop

/// The stored preset list crosses iCloud and comes back as whatever another device
/// wrote, so `AppSettings` vets it before putting a button on the home screen. These
/// exercise that rule through the one public door onto it.
final class QuickAddPresetTests: XCTestCase {
    private var settings: AppSettings { AppSettings.shared }
    private var original: [Int]?

    override func setUp() {
        super.setUp()
        original = settings.customQuickAddPresetsML
    }

    override func tearDown() {
        settings.customQuickAddPresetsML = original
        super.tearDown()
    }

    func testDefaultsFollowTheUnitSystemUntilEdited() {
        settings.customQuickAddPresetsML = nil
        XCTAssertEqual(settings.quickAddPresets, settings.measurementSystem.defaultQuickAddPresetsML)
    }

    func testAnEditedSlotIsKeptAndTheOthersSeededFromWhatWasShowing() {
        settings.customQuickAddPresetsML = nil
        let before = settings.quickAddPresets
        settings.setQuickAddPreset(1000, at: 1)
        XCTAssertEqual(settings.quickAddPresets, [before[0], 1000, before[2]])
    }

    func testResettingGoesBackToTheSuggestedSizes() {
        settings.setQuickAddPreset(1000, at: 0)
        settings.customQuickAddPresetsML = nil
        XCTAssertEqual(settings.quickAddPresets, settings.measurementSystem.defaultQuickAddPresetsML)
    }

    /// A list of the wrong length, or one holding an impossible amount, must not reach
    /// the home screen.
    func testAMalformedStoredListFallsBackToTheDefaults() {
        let defaults = settings.measurementSystem.defaultQuickAddPresetsML
        for malformed in [[250], [250, 500, 750, 1000], [250, 0, 500], [250, 99_999, 500], [-1, 250, 500]] {
            settings.customQuickAddPresetsML = malformed
            XCTAssertEqual(settings.quickAddPresets, defaults, "\(malformed) should have been rejected")
        }
    }

    /// The biggest amount either picker can produce has to survive the round trip.
    func testTheLargestPickableDrinkIsAccepted() {
        let largest = MeasurementSystem.imperial.mL(
            fromDisplayVolume: Double(MeasurementSystem.imperial.customDrinkRange.upperBound)
        )
        XCTAssertTrue(MeasurementSystem.plausibleDrinkRangeML.contains(largest))
        settings.customQuickAddPresetsML = [largest, largest, largest]
        XCTAssertEqual(settings.quickAddPresets, [largest, largest, largest])
    }

    func testSettingAnOutOfRangeSlotIndexChangesNothing() {
        settings.customQuickAddPresetsML = nil
        let before = settings.quickAddPresets
        settings.setQuickAddPreset(1000, at: 7)
        XCTAssertEqual(settings.quickAddPresets, before)
    }
}
