import SwiftUI

/// One authored colour, kept as components rather than a `Color`.
///
/// The mascot body needs a lit crown, a mid tone and a shaded belly for every mood
/// of every skin. Deriving those from a single value keeps each skin to five
/// authored colours instead of fifteen, and guarantees the gradient behaves the
/// same way on a pale "parched" grey as it does on deep indigo.
struct MascotTone: Equatable {
    let red: Double
    let green: Double
    let blue: Double

    var color: Color { Color(red: red, green: green, blue: blue) }

    /// Blends toward white.
    func lit(_ amount: Double) -> Color {
        Color(
            red: red + (1 - red) * amount,
            green: green + (1 - green) * amount,
            blue: blue + (1 - blue) * amount
        )
    }

    /// Blends toward a deep tone that keeps more blue than it loses, so a shaded
    /// belly still reads as water in shadow rather than as dirt.
    func shaded(_ amount: Double) -> Color {
        Color(
            red: red * (1 - amount),
            green: green * (1 - amount * 0.90),
            blue: blue * (1 - amount * 0.68)
        )
    }
}

/// The decorative flourish that gives a skin a character of its own, beyond colour.
///
/// This is what makes the paid skins feel like different mascots rather than the
/// same drop repainted.
enum MascotCharm {
    case none
    /// A warm halo with slowly turning rays.
    case sunGlow
    /// A two-leaf sprout growing out of the tip.
    case sprout
    /// Bubbles rising through the body.
    case fizz
    /// Stars twinkling in the surrounding air.
    case starlight
}

/// A mascot skin, unlocked with HydroDrop+.
///
/// Each skin supplies one tone per `MascotMood`, ordered parched → overjoyed.
/// Every ramp keeps the same readability contract: the dry end stays desaturated
/// so "parched" still reads as unwell, and saturation and depth climb towards
/// "overjoyed" so progress is legible from colour alone.
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

    /// One line of personality, shown beside the skin in Settings and on the paywall.
    var tagline: String {
        switch self {
        case .classic: return "The original drop"
        case .sunrise: return "Warm morning halo"
        case .forest: return "Grows a leafy sprout"
        case .grape: return "Fizzing with bubbles"
        case .midnight: return "Lit by tiny stars"
        }
    }

    var charm: MascotCharm {
        switch self {
        case .classic: return .none
        case .sunrise: return .sunGlow
        case .forest: return .sprout
        case .grape: return .fizz
        case .midnight: return .starlight
        }
    }

    /// Used for sparkles, charms and other light accents. Deliberately much lighter
    /// than the body so it stays visible against the "overjoyed" end of the ramp.
    var accent: Color {
        switch self {
        case .classic: return Color(red: 0.62, green: 0.89, blue: 1.00)
        case .sunrise: return Color(red: 1.00, green: 0.85, blue: 0.52)
        case .forest: return Color(red: 0.73, green: 0.93, blue: 0.55)
        case .grape: return Color(red: 0.90, green: 0.79, blue: 1.00)
        case .midnight: return Color(red: 1.00, green: 0.94, blue: 0.73)
        }
    }

    /// Parched, thirsty, content, happy, overjoyed.
    var tones: [MascotTone] {
        switch self {
        case .classic:
            return [
                MascotTone(red: 0.72, green: 0.76, blue: 0.79),
                MascotTone(red: 0.55, green: 0.75, blue: 0.90),
                MascotTone(red: 0.33, green: 0.66, blue: 0.93),
                MascotTone(red: 0.16, green: 0.54, blue: 0.94),
                MascotTone(red: 0.06, green: 0.42, blue: 0.96),
            ]
        case .sunrise:
            return [
                MascotTone(red: 0.80, green: 0.75, blue: 0.71),
                MascotTone(red: 0.97, green: 0.77, blue: 0.55),
                MascotTone(red: 0.98, green: 0.62, blue: 0.38),
                MascotTone(red: 0.96, green: 0.46, blue: 0.32),
                MascotTone(red: 0.92, green: 0.30, blue: 0.30),
            ]
        case .forest:
            return [
                MascotTone(red: 0.75, green: 0.78, blue: 0.73),
                MascotTone(red: 0.61, green: 0.83, blue: 0.62),
                MascotTone(red: 0.38, green: 0.74, blue: 0.46),
                MascotTone(red: 0.20, green: 0.62, blue: 0.36),
                MascotTone(red: 0.09, green: 0.50, blue: 0.29),
            ]
        case .grape:
            return [
                MascotTone(red: 0.78, green: 0.75, blue: 0.81),
                MascotTone(red: 0.75, green: 0.65, blue: 0.91),
                MascotTone(red: 0.61, green: 0.47, blue: 0.90),
                MascotTone(red: 0.49, green: 0.33, blue: 0.86),
                MascotTone(red: 0.38, green: 0.20, blue: 0.79),
            ]
        case .midnight:
            return [
                MascotTone(red: 0.70, green: 0.73, blue: 0.79),
                MascotTone(red: 0.50, green: 0.57, blue: 0.79),
                MascotTone(red: 0.33, green: 0.41, blue: 0.71),
                MascotTone(red: 0.21, green: 0.28, blue: 0.59),
                MascotTone(red: 0.12, green: 0.17, blue: 0.45),
            ]
        }
    }

    /// Flat colours for callers that only need a swatch.
    var ramp: [Color] { tones.map(\.color) }
}
