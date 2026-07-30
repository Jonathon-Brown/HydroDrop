import Foundation

enum BiologicalSex: String, CaseIterable, Identifiable, Codable {
    case male
    case female
    case notSpecified

    var id: String { rawValue }

    var label: String {
        switch self {
        case .male: return "Male"
        case .female: return "Female"
        case .notSpecified: return "Prefer not to say"
        }
    }

    /// Rule-of-thumb mL of water per kg of body weight.
    fileprivate var mLPerKG: Double {
        switch self {
        case .male: return 35
        case .female: return 31
        case .notSpecified: return 33
        }
    }
}

enum ActivityLevel: String, CaseIterable, Identifiable, Codable {
    case sedentary
    case light
    case moderate
    case veryActive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .sedentary: return "Sedentary"
        case .light: return "Light"
        case .moderate: return "Moderate"
        case .veryActive: return "Very Active"
        }
    }

    var detail: String {
        switch self {
        case .sedentary: return "Little to no exercise"
        case .light: return "1-2 workouts/week"
        case .moderate: return "3-5 workouts/week"
        case .veryActive: return "6-7 workouts/week or physical job"
        }
    }

    /// Flat mL bonus added on top of the weight-based baseline.
    fileprivate var bonusML: Double {
        switch self {
        case .sedentary: return 0
        case .light: return 350
        case .moderate: return 700
        case .veryActive: return 1050
        }
    }
}

/// A simple, transparent rule-of-thumb hydration goal estimate.
/// This is not medical advice.
enum HydrationGoalCalculator {
    static let validGoalRange = 500...5000

    static func recommendedGoalML(weightKG: Double, sex: BiologicalSex, activity: ActivityLevel) -> Int {
        let raw = weightKG * sex.mLPerKG + activity.bonusML
        let roundedToNearest50 = (raw / 50).rounded() * 50
        return Int(roundedToNearest50).clamped(to: validGoalRange)
    }
}

private extension Int {
    func clamped(to range: ClosedRange<Int>) -> Int {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
