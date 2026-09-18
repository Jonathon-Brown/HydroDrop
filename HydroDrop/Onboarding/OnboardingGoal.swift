import Foundation

/// The three-way activity question onboarding asks, mapped onto the levels the
/// existing goal calculator already prices.
///
/// The calculator's own four levels and its sex adjustment are more than a first
/// launch should ask for. These three cover the same ground with the same numbers
/// (0, 350 and 700 mL on top of 33 mL per kg), so the suggestion a new user accepts
/// here is the one "Calculate for me" in Settings would reproduce.
enum OnboardingActivity: String, CaseIterable, Identifiable {
    case low
    case moderate
    case high

    var id: String { rawValue }

    var label: String {
        switch self {
        case .low: return "Low"
        case .moderate: return "Moderate"
        case .high: return "High"
        }
    }

    var detail: String {
        switch self {
        case .low: return "Mostly sitting, little exercise"
        case .moderate: return "On your feet or a few workouts a week"
        case .high: return "Daily training or a physical job"
        }
    }

    var activityLevel: ActivityLevel {
        switch self {
        case .low: return .sedentary
        case .moderate: return .light
        case .high: return .moderate
        }
    }
}

enum OnboardingGoal {
    /// Suggested daily goal for a new user: the calculator's estimate without a sex
    /// adjustment, rounded to the nearest 100 mL so the number reads as a round target
    /// rather than a measurement. The calculator already clamps to the goal range.
    static func suggestedGoalML(weightKG: Double, activity: OnboardingActivity) -> Int {
        HydrationGoalCalculator.recommendedGoalML(
            weightKG: weightKG,
            sex: .notSpecified,
            activity: activity.activityLevel,
            roundedTo: 100
        )
    }
}
