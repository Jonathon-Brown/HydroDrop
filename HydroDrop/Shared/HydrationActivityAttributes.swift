import ActivityKit
import Foundation

/// The shape of the Live Activity, shared between the app that drives it and the
/// widget extension that draws it.
///
/// Everything the lock screen shows is in the content state rather than the static
/// attributes, because all of it can move while the activity is running: the goal can
/// be bumped for a hot day, the units can be switched, and the skin can change.
struct HydrationActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var todayTotalML: Int
        var goalML: Int
        var measurementSystemRawValue: String
        var mascotSkinRawValue: String
        var streak: Int

        var measurementSystem: MeasurementSystem {
            MeasurementSystem(rawValue: measurementSystemRawValue) ?? .deviceDefault
        }

        var mascotSkin: MascotSkin {
            MascotSkin(rawValue: mascotSkinRawValue) ?? .classic
        }

        var progress: Double {
            guard goalML > 0 else { return 0 }
            return Double(todayTotalML) / Double(goalML)
        }

        var clampedProgress: Double { min(max(progress, 0), 1) }

        var remainingML: Int { max(0, goalML - todayTotalML) }
    }

    /// The day this activity is about. An activity left running past midnight is about
    /// yesterday, and the app ends it rather than quietly relabelling it.
    var dayKey: String
}
