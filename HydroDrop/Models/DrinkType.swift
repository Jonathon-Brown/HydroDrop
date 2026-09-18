import Foundation

/// What was in the glass, and how much of it counts towards the day's hydration.
///
/// The multipliers are a rule of thumb, not a clinical measure: everything on this
/// list hydrates you, and the ones below 1.0 simply count for a little less than
/// plain water. Water is exactly 1.0 so an entry with no type recorded (every entry
/// logged before this existed) is unchanged.
enum DrinkType: String, CaseIterable, Identifiable, Codable {
    case water
    case coffee
    case tea
    case sparkling
    case juice
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .water: return "Water"
        case .coffee: return "Coffee"
        case .tea: return "Tea"
        case .sparkling: return "Sparkling"
        case .juice: return "Juice"
        case .other: return "Other"
        }
    }

    /// Symbols chosen from the set that predates iOS 17, so the log never renders a
    /// blank square on the oldest version HydroDrop supports.
    var icon: String {
        switch self {
        case .water: return "drop.fill"
        case .coffee: return "cup.and.saucer.fill"
        case .tea: return "leaf.fill"
        case .sparkling: return "sparkles"
        case .juice: return "takeoutbag.and.cup.and.straw.fill"
        case .other: return "ellipsis.circle.fill"
        }
    }

    /// How much of the volume counts towards the daily goal.
    var hydrationMultiplier: Double {
        switch self {
        case .water, .sparkling: return 1.0
        case .tea: return 0.95
        case .coffee, .other: return 0.9
        case .juice: return 0.85
        }
    }

    /// Whether this type counts for less than what was poured, i.e. whether the log
    /// has anything worth explaining next to the amount.
    var countsForLess: Bool { hydrationMultiplier < 1.0 }

    /// The share that counts, as a whole percentage, e.g. "90%".
    var hydrationShareLabel: String {
        "\(Int((hydrationMultiplier * 100).rounded()))%"
    }

    /// The hydrating portion of `mL` for this drink, rounded to the nearest mL.
    func hydratedML(from mL: Int) -> Int {
        guard hydrationMultiplier < 1.0 else { return mL }
        return Int((Double(mL) * hydrationMultiplier).rounded())
    }
}
