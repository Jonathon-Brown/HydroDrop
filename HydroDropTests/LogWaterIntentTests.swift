import XCTest
@testable import HydroDrop

/// The amount an intent actually logs.
///
/// When `unit` reaches `perform()` as nil, the amount is read in the user's display
/// units. The widget's quick-add button used to depend on `unit`, so on a simulator
/// that drops `AppEnum` parameters (Xcode 27 on the iOS 26.5 runtime does; real devices
/// do not) an imperial user's 237 mL preset became 237 fluid ounces — 7009 mL, outside
/// the plausible range, thrown away before the store was even opened and without a
/// word in Console. The button now sends an exact millilitre amount instead.
///
/// The widget tests build the intent with its enum parameters cleared, which is the
/// state that failure mode leaves it in, rather than the way it reads in source.
final class LogWaterIntentTests: XCTestCase {
    private func snapshot(_ system: MeasurementSystem) -> HydrationSnapshot {
        var snapshot = HydrationSnapshot.empty
        snapshot.measurementSystemRawValue = system.rawValue
        snapshot.quickAddPresetsML = system.defaultQuickAddPresetsML
        return snapshot
    }

    /// The intent as the widget's button builds it, with the enum parameters cleared
    /// the way a simulator that drops them leaves it: the worst case the button has to
    /// survive.
    private func fromWidgetButton(amountML: Int) -> LogWaterIntent {
        var intent = LogWaterIntent(amountML: amountML)
        intent.unit = nil
        intent.drink = nil
        return intent
    }

    /// The intent as Shortcuts or Siri builds it on a device, with the unit the user
    /// chose (or left empty) intact.
    private func fromShortcut(amount: Double?, unit: VolumeUnitChoice?) -> LogWaterIntent {
        var intent = LogWaterIntent()
        intent.amount = amount
        intent.unit = unit
        return intent
    }

    // MARK: - The widget's quick-add button

    /// The regression. 237 mL is the imperial 8 fl oz preset, and it used to be read
    /// as 237 fluid ounces.
    func testAnImperialQuickAddLogsTheMillilitresItWasGiven() throws {
        let intent = fromWidgetButton(amountML: 237)
        XCTAssertEqual(try intent.resolvedAmountML(snapshot: snapshot(.imperial)), 237)
    }

    func testAMetricQuickAddLogsTheMillilitresItWasGiven() throws {
        let intent = fromWidgetButton(amountML: 250)
        XCTAssertEqual(try intent.resolvedAmountML(snapshot: snapshot(.metric)), 250)
    }

    /// The amount must not depend on what the user has their units set to: the widget
    /// always speaks millilitres.
    func testAQuickAddMeansTheSameInEitherUnitSystem() throws {
        let intent = fromWidgetButton(amountML: 473)
        XCTAssertEqual(
            try intent.resolvedAmountML(snapshot: snapshot(.imperial)),
            try intent.resolvedAmountML(snapshot: snapshot(.metric))
        )
    }

    /// Every preset the app ships has to log as itself, in both unit systems.
    func testEveryDefaultPresetLogsAsItselfFromTheWidget() throws {
        for system in MeasurementSystem.allCases {
            for preset in system.defaultQuickAddPresetsML {
                let intent = fromWidgetButton(amountML: preset)
                XCTAssertEqual(
                    try intent.resolvedAmountML(snapshot: snapshot(system)),
                    preset,
                    "\(preset) mL should log as itself for \(system.rawValue)"
                )
            }
        }
    }

    func testAnImplausibleMillilitreAmountIsStillRefused() {
        let intent = fromWidgetButton(amountML: 99_999)
        XCTAssertThrowsError(try intent.resolvedAmountML(snapshot: snapshot(.metric)))
    }

    // MARK: - Shortcuts and Siri, which are deliberately unchanged

    func testAShortcutThatNamesItsUnitIsTakenAtItsWord() throws {
        let intent = fromShortcut(amount: 16, unit: .fluidOunces)
        // The app being metric must not change what the shortcut meant.
        XCTAssertEqual(try intent.resolvedAmountML(snapshot: snapshot(.metric)), 473)
    }

    func testAShortcutInMillilitresIsTakenAtItsWord() throws {
        let intent = fromShortcut(amount: 500, unit: .milliliters)
        XCTAssertEqual(try intent.resolvedAmountML(snapshot: snapshot(.imperial)), 500)
    }

    /// A shortcut with no unit still reads in the app's display units, which is what it
    /// has always done. Changing this would silently redefine existing shortcuts.
    func testAShortcutWithNoUnitStillFollowsTheAppsUnits() throws {
        let intent = fromShortcut(amount: 16, unit: nil)
        XCTAssertEqual(try intent.resolvedAmountML(snapshot: snapshot(.imperial)), 473)
        XCTAssertEqual(try intent.resolvedAmountML(snapshot: snapshot(.metric)), 16)
    }

    func testAnEmptyShortcutLogsTheFirstQuickAddPreset() throws {
        let intent = fromShortcut(amount: nil, unit: nil)
        let imperial = snapshot(.imperial)
        XCTAssertEqual(
            try intent.resolvedAmountML(snapshot: imperial),
            imperial.quickAddPresetsML.first
        )
    }

    func testAnImplausibleShortcutAmountIsRefused() {
        XCTAssertThrowsError(
            try fromShortcut(amount: 900, unit: .fluidOunces).resolvedAmountML(snapshot: snapshot(.metric))
        )
        XCTAssertThrowsError(
            try fromShortcut(amount: 0, unit: .milliliters).resolvedAmountML(snapshot: snapshot(.metric))
        )
        XCTAssertThrowsError(
            try fromShortcut(amount: .nan, unit: .milliliters).resolvedAmountML(snapshot: snapshot(.metric))
        )
    }

    // MARK: - Precedence

    /// If both ever arrive together, the unambiguous one wins.
    func testAnExactMillilitreAmountBeatsAmountAndUnit() throws {
        var intent = LogWaterIntent(amountML: 300)
        intent.amount = 16
        intent.unit = .fluidOunces
        XCTAssertEqual(try intent.resolvedAmountML(snapshot: snapshot(.imperial)), 300)
    }
}
