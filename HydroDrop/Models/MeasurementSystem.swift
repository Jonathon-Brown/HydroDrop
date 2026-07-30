import Foundation

/// The unit system used to *display* volumes. All data is stored internally in
/// milliliters regardless of this setting — this only affects formatting.
enum MeasurementSystem: String, CaseIterable, Identifiable {
    case metric
    case imperial

    var id: String { rawValue }

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

    /// Just the numeric portion, converted for this system, no unit suffix.
    func formattedNumber(mL: Int) -> String {
        switch self {
        case .metric:
            return "\(mL)"
        case .imperial:
            return String(format: "%.1f", Double(mL) / 29.5735)
        }
    }

    /// Number + unit suffix, e.g. "500 mL" or "16.9 fl oz".
    func format(mL: Int) -> String {
        "\(formattedNumber(mL: mL)) \(unitLabel)"
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
