import SwiftUI

/// A palette for the mascot, unlocked with HydroDrop+.
///
/// Each skin supplies one colour per `MascotMood`, ordered parched → overjoyed.
/// Every ramp keeps the same readability contract as the original blue: the dry
/// end stays desaturated so "parched" still reads as unwell, and saturation and
/// depth climb towards "overjoyed" so progress is legible from colour alone.
enum MascotSkin: String, CaseIterable, Identifiable {
    case classic
    case sunrise
    case forest
    case grape
    case midnight

    var id: String { rawValue }

    /// Only `classic` is available without a subscription.
    var requiresPlus: Bool { self != .classic }

    var label: String {
        switch self {
        case .classic: return "Classic"
        case .sunrise: return "Sunrise"
        case .forest: return "Forest"
        case .grape: return "Grape"
        case .midnight: return "Midnight"
        }
    }

    /// Parched, thirsty, content, happy, overjoyed.
    var ramp: [Color] {
        switch self {
        case .classic:
            return [
                Color(red: 0.75, green: 0.78, blue: 0.80),
                Color(red: 0.60, green: 0.78, blue: 0.92),
                Color(red: 0.35, green: 0.68, blue: 0.92),
                Color(red: 0.18, green: 0.56, blue: 0.93),
                Color(red: 0.10, green: 0.45, blue: 0.95),
            ]
        case .sunrise:
            return [
                Color(red: 0.82, green: 0.76, blue: 0.72),
                Color(red: 0.96, green: 0.76, blue: 0.60),
                Color(red: 0.97, green: 0.62, blue: 0.42),
                Color(red: 0.95, green: 0.46, blue: 0.35),
                Color(red: 0.90, green: 0.31, blue: 0.32),
            ]
        case .forest:
            return [
                Color(red: 0.76, green: 0.79, blue: 0.74),
                Color(red: 0.63, green: 0.83, blue: 0.64),
                Color(red: 0.40, green: 0.74, blue: 0.48),
                Color(red: 0.22, green: 0.62, blue: 0.38),
                Color(red: 0.11, green: 0.50, blue: 0.31),
            ]
        case .grape:
            return [
                Color(red: 0.79, green: 0.76, blue: 0.82),
                Color(red: 0.75, green: 0.66, blue: 0.90),
                Color(red: 0.62, green: 0.48, blue: 0.89),
                Color(red: 0.50, green: 0.34, blue: 0.85),
                Color(red: 0.40, green: 0.22, blue: 0.78),
            ]
        case .midnight:
            return [
                Color(red: 0.72, green: 0.74, blue: 0.80),
                Color(red: 0.52, green: 0.59, blue: 0.80),
                Color(red: 0.35, green: 0.43, blue: 0.72),
                Color(red: 0.23, green: 0.30, blue: 0.60),
                Color(red: 0.14, green: 0.19, blue: 0.47),
            ]
        }
    }
}
