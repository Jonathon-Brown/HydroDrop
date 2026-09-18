import Foundation

/// The unit system used to *display* volumes. All data is stored internally in
/// milliliters regardless of this setting — this only affects formatting.
///
/// Anything that lets the user *choose* a volume (steppers, sliders, presets) works
/// in this system's display unit, so imperial users step in whole ounces and land on
/// round ounce values rather than on whatever 25 mL happens to convert to. The chosen
/// value is converted back to mL at the edge, once, for storage.
enum MeasurementSystem: String, CaseIterable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }

    static let mLPerFluidOunce = 29.5735

    /// The daily goal the app accepts, in the storage unit. Lives here rather than on
    /// the calculator because the watch target compiles this file and not that one.
    static let storedGoalRangeML = 500...5000

    var label: String {
        switch self {
        case .metric: return "Metric (mL)"
        case .imperial: return "Imperial (fl oz)"
        }
    }

    var unitLabel: String {
        switch self {
        case .metric: return "mL"
        case .imperial: return "fl oz"
        }
    }

    static var deviceDefault: MeasurementSystem {
        Locale.current.measurementSystem == .us ? .imperial : .metric
    }

    // MARK: - Volume conversion

    /// A stored volume in this system's display unit.
    func displayVolume(fromML mL: Int) -> Double {
        switch self {
        case .metric: return Double(mL)
        case .imperial: return Double(mL) / Self.mLPerFluidOunce
        }
    }

    /// A value chosen in this system's display unit, as the mL to store.
    func mL(fromDisplayVolume value: Double) -> Int {
        guard value.isFinite else { return 0 }
        switch self {
        case .metric: return Int(value.rounded())
        case .imperial: return Int((value * Self.mLPerFluidOunce).rounded())
        }
    }

    /// A stored volume rounded to whole display units, for steppers and pickers.
    func wholeUnits(fromML mL: Int) -> Int {
        Int(displayVolume(fromML: mL).rounded())
    }

    // MARK: - Volume formatting

    /// Just the numeric portion, converted for this system, no unit suffix.
    ///
    /// Imperial shows one decimal only when there is one worth showing: a preset of
    /// 8 oz reads "8", not "8.0", while 500 mL still reads "16.9".
    func formattedNumber(mL: Int) -> String {
        switch self {
        case .metric:
            return "\(mL)"
        case .imperial:
            let text = String(format: "%.1f", displayVolume(fromML: mL))
            return text.hasSuffix(".0") ? String(text.dropLast(2)) : text
        }
    }

    /// Number + unit suffix, e.g. "500 mL" or "16.9 fl oz".
    func format(mL: Int) -> String {
        "\(formattedNumber(mL: mL)) \(unitLabel)"
    }

    // MARK: - Sensible values per system, in display units unless named ML

    /// The quick-add cup sizes a new user starts with, in mL.
    /// Imperial is 8, 12 and 16 oz; metric is a glass, a can and a bottle.
    var defaultQuickAddPresetsML: [Int] {
        switch self {
        case .metric: return [200, 330, 500]
        case .imperial: return [8, 12, 16].map { mL(fromDisplayVolume: Double($0)) }
        }
    }

    /// Custom-drink stepper increment, in display units.
    var customDrinkStep: Int {
        switch self {
        case .metric: return 25
        case .imperial: return 1
        }
    }

    /// Custom-drink range, in display units.
    var customDrinkRange: ClosedRange<Int> {
        switch self {
        case .metric: return 25...2000
        case .imperial: return 1...68
        }
    }

    /// Custom-drink shortcut buttons, in display units.
    var customDrinkPresets: [Int] {
        switch self {
        case .metric: return [100, 250, 500, 750]
        case .imperial: return [8, 12, 16, 24]
        }
    }

    /// Daily-goal stepper increment, in display units.
    var goalStep: Int {
        switch self {
        case .metric: return 100
        case .imperial: return 4
        }
    }

    /// Daily-goal range, in display units. Both ends are the 500...5000 mL range the
    /// app has always enforced, rounded to whole units of this system.
    var goalRange: ClosedRange<Int> {
        let stored = Self.storedGoalRangeML
        return wholeUnits(fromML: stored.lowerBound)...wholeUnits(fromML: stored.upperBound)
    }

    // MARK: - Weight

    /// Weight is always stored internally in kilograms; these only affect display/input.
    var weightUnitLabel: String {
        switch self {
        case .metric: return "kg"
        case .imperial: return "lb"
        }
    }

    /// Converts a canonical kg value into this system's display value (kg or lb).
    func displayWeight(fromKG kg: Double) -> Double {
        switch self {
        case .metric: return kg
        case .imperial: return kg * 2.20462
        }
    }

    /// Converts a value entered in this system's unit back into canonical kg.
    func weightInKG(fromDisplayValue value: Double) -> Double {
        switch self {
        case .metric: return value
        case .imperial: return value / 2.20462
        }
    }

    /// Number + unit suffix, e.g. "70 kg" or "154.3 lb".
    func formatWeight(kg: Double) -> String {
        let value = displayWeight(fromKG: kg)
        return String(format: "%.1f %@", value, weightUnitLabel)
    }
}
