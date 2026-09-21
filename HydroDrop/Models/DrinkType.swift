import Foundation

/// What was in the glass, and how much of it counts towards the day's hydration.
///
/// The multipliers are a rule of thumb, not a clinical measure. Most things on this
/// list hydrate you, and the ones below 1.0 simply count for a little less than plain
/// water. Water is exactly 1.0 so an entry with no type recorded (every entry logged
/// before this existed) is unchanged. Alcoholic drinks count for nothing: they belong
/// in the log, because they were drunk, and they add nothing to the day's progress.
enum DrinkType: String, CaseIterable, Identifiable, Codable {
    case water
    case coffee
    case espresso
    /// Stored as "tea", which is what this case was called before green tea existed.
    /// Keeping the raw value means every tea already in anyone's log, on any device and
    /// in iCloud, reads back as black tea with nothing to migrate, and a tea logged by
    /// this version still reads as tea on an older one.
    case blackTea = "tea"
    case greenTea
    case sparkling
    case juice
    case cola
    case energyDrink
    case other
    case beer
    case wine
    case cocktail
    case spirits

    var id: String { rawValue }

    var label: String {
        switch self {
        case .water: return "Water"
        case .coffee: return "Coffee"
        case .espresso: return "Espresso"
        case .blackTea: return "Black tea"
        case .greenTea: return "Green tea"
        case .sparkling: return "Sparkling"
        case .juice: return "Juice"
        case .cola: return "Cola"
        case .energyDrink: return "Energy drink"
        case .other: return "Other"
        case .beer: return "Beer"
        case .wine: return "Wine"
        case .cocktail: return "Cocktail"
        case .spirits: return "Spirits"
        }
    }

    /// Symbols that exist on iOS 17, the oldest version HydroDrop supports, so the log
    /// never renders a blank square.
    var icon: String {
        switch self {
        case .water: return "drop.fill"
        case .coffee: return "cup.and.saucer.fill"
        case .espresso: return "cup.and.saucer"
        case .blackTea: return "leaf.fill"
        case .greenTea: return "leaf"
        case .sparkling: return "sparkles"
        case .juice: return "takeoutbag.and.cup.and.straw.fill"
        case .cola: return "bubbles.and.sparkles.fill"
        case .energyDrink: return "bolt.fill"
        case .other: return "ellipsis.circle.fill"
        case .beer: return "mug.fill"
        case .wine: return "wineglass.fill"
        case .cocktail: return "wineglass"
        case .spirits: return "drop.halffull"
        }
    }

    /// How much of the volume counts towards the daily goal.
    var hydrationMultiplier: Double {
        switch self {
        case .water, .sparkling: return 1.0
        case .blackTea, .greenTea: return 0.95
        case .coffee, .espresso, .cola, .other: return 0.9
        case .juice, .energyDrink: return 0.85
        case .beer, .wine, .cocktail, .spirits: return 0
        }
    }

    /// Whether this is an alcoholic drink. Used only to keep it out of the day's
    /// progress and to let Night Out count it. Never to score, rank or estimate.
    var isAlcoholic: Bool {
        switch self {
        case .beer, .wine, .cocktail, .spirits: return true
        default: return false
        }
    }

    /// Whether logging this answers a Night Out "water round": plain or sparkling water.
    var countsAsWaterRound: Bool {
        self == .water || self == .sparkling
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

    // MARK: - Caffeine

    /// How much caffeine a typical serving holds, and how big that serving is.
    ///
    /// Typical figures, not a lab result: a home-brewed mug and a coffee shop's are not
    /// the same drink. Everything is given per 250 mL except espresso, which is given
    /// per 30 mL shot because that is how it is made and drunk, and scaling a shot up to
    /// a quarter of a litre would describe a drink nobody pours.
    var caffeine: (milligrams: Double, perML: Double)? {
        switch self {
        case .coffee: return (95, 250)
        case .espresso: return (63, 30)
        case .blackTea: return (47, 250)
        case .greenTea: return (28, 250)
        case .cola: return (22, 250)
        case .energyDrink: return (80, 250)
        default: return nil
        }
    }

    var hasCaffeine: Bool { caffeine != nil }

    /// The caffeine in `mL` of this drink, in milligrams. Zero for anything without any.
    func caffeineMg(in mL: Int) -> Double {
        guard let caffeine, mL > 0 else { return 0 }
        return Double(mL) / caffeine.perML * caffeine.milligrams
    }
}
