import Foundation

/// One drink as the language model describes it: words and numbers the person actually
/// said, never millilitres and never the result of any arithmetic.
///
/// Every field is a plain string or number rather than an enum on purpose. The model's
/// output is input, not a given, and `SayItMapper` is where it gets checked.
struct SpokenDrink: Equatable {
    /// A `DrinkType` raw value, or "unknown".
    var kind: String
    /// How many of this drink.
    var quantity: Int
    /// One of `SayItMapper.SizeWord`, or "none".
    var sizeWord: String
    /// An amount the person stated for a single drink, such as the 12 in "12 oz".
    var amount: Double?
    /// The unit that amount was in: "oz", "mL", "L", "cups" or "none".
    var unit: String

    init(kind: String, quantity: Int = 1, sizeWord: String = "none", amount: Double? = nil, unit: String = "none") {
        self.kind = kind
        self.quantity = quantity
        self.sizeWord = sizeWord
        self.amount = amount
        self.unit = unit
    }
}

/// One drink waiting on the confirmation list. Nothing here has been saved.
struct SayItDraft: Identifiable, Equatable {
    let id: UUID
    var drinkType: DrinkType
    var amountML: Int
    /// True when something had to be guessed: a drink that is not on the list, a size
    /// word that was not recognised, an amount that made no sense. The row says so, so
    /// a guess is never logged without the person having seen it.
    var needsReview: Bool

    init(id: UUID = UUID(), drinkType: DrinkType, amountML: Int, needsReview: Bool = false) {
        self.id = id
        self.drinkType = drinkType
        self.amountML = amountML
        self.needsReview = needsReview
    }
}

/// Turns what the model heard into drinks that can be logged.
///
/// The language model is good at reading a sentence and bad at sums, so it is never
/// asked for one: it reports the size word and any amount exactly as said, and every
/// number that ends up in the log is worked out here, where it can be read, argued
/// with and tested.
enum SayItMapper {
    // MARK: - Vocabulary

    /// A size said in words rather than numbers, and what it is taken to mean.
    ///
    /// Rules of thumb in the same spirit as the quick-add sizes: close enough to be
    /// useful, and every one of them can be changed on the confirmation list.
    enum SizeWord: String, CaseIterable {
        case small, medium, large, glass, cup, mug, bottle, can, pint, shot, sip

        var volumeML: Int {
            switch self {
            case .small: return 200
            case .medium: return 350
            case .large: return 500
            case .glass: return 250
            case .cup: return 240
            case .mug: return 350
            case .bottle: return 500
            case .can: return 355
            case .pint: return 473
            case .shot: return 45
            case .sip: return 30
            }
        }
    }

    /// The word for "nothing was said", for sizes and for units.
    static let none = "none"
    /// The word for a drink that is not one of the app's drink types.
    static let unknownKind = "unknown"

    /// What the model may answer with. Built from `DrinkType` so a new drink type is
    /// understood the day it is added, without anyone remembering to come here.
    static var kindVocabulary: [String] { DrinkType.allCases.map(\.rawValue) + [unknownKind] }
    static var sizeVocabulary: [String] { SizeWord.allCases.map(\.rawValue) + [none] }
    static let unitVocabulary = ["oz", "mL", "L", "cups", none]

    /// "A hundred glasses of water" is a typo or a joke, not a log entry.
    static let maximumQuantity = 12
    /// However the sentence is phrased, one Say it never produces more rows than this.
    static let maximumDrafts = 20
    /// Half an ounce. Nobody states an amount smaller than this, but the model will
    /// sometimes turn the "a" in "a pint" into an amount of 1, and 1 mL of beer is not
    /// what was said. Anything below this is not believed.
    static let minimumStatedML = 15

    private static let millilitersPerFluidOunce = MeasurementSystem.mLPerFluidOunce
    private static let millilitersPerCup = 240.0
    private static let millilitersPerLiter = 1_000.0

    // MARK: - Pieces

    /// What a size word means in millilitres, or nil for "none" and anything unknown.
    static func volumeML(forSizeWord word: String) -> Int? {
        SizeWord(rawValue: normalized(word))?.volumeML
    }

    /// A stated amount in millilitres, or nil when the unit or the number is unusable.
    static func milliliters(amount: Double, unit: String) -> Int? {
        guard amount.isFinite, amount > 0 else { return nil }
        let perUnit: Double
        switch normalized(unit) {
        case "oz", "fl oz", "floz", "ounce", "ounces", "fluid ounce", "fluid ounces":
            perUnit = millilitersPerFluidOunce
        case "ml", "milliliter", "milliliters", "millilitre", "millilitres":
            perUnit = 1
        case "l", "liter", "liters", "litre", "litres":
            perUnit = millilitersPerLiter
        case "cup", "cups":
            perUnit = millilitersPerCup
        default:
            return nil
        }
        return Int((amount * perUnit).rounded())
    }

    // MARK: - Drafts

    /// The confirmation list for what was said.
    ///
    /// - Parameter defaultML: what a drink with no size at all is taken to be, which
    ///   is the person's own first quick-add size: "a water" means their usual glass.
    static func drafts(from drinks: [SpokenDrink], defaultML: Int) -> [SayItDraft] {
        var drafts: [SayItDraft] = []
        for drink in drinks {
            var needsReview = false

            let drinkType: DrinkType
            if let known = DrinkType(rawValue: normalized(drink.kind)) {
                drinkType = known
                // "Other" is a real drink type, so the model reaches for it rather than
                // for "unknown" when it cannot place a drink. It is the same admission,
                // and it gets the same flag.
                if known == .other { needsReview = true }
            } else {
                // Not on the list. Water is the safe assumption, and the row says it
                // was one.
                drinkType = .water
                needsReview = true
            }

            var amountML: Int
            if let amount = drink.amount {
                if let stated = milliliters(amount: amount, unit: drink.unit), stated >= minimumStatedML {
                    amountML = stated
                } else {
                    // A number with no usable unit, or one too small to be a real amount.
                    // Fall back to the size word, and ask.
                    amountML = volumeML(forSizeWord: drink.sizeWord) ?? defaultML
                    needsReview = true
                }
            } else if let sized = volumeML(forSizeWord: drink.sizeWord) {
                amountML = sized
            } else {
                amountML = defaultML
                // "none" is an ordinary answer. Anything else is a word we do not know.
                if normalized(drink.sizeWord) != none { needsReview = true }
            }

            let plausible = MeasurementSystem.plausibleDrinkRangeML
            if !plausible.contains(amountML) {
                amountML = min(max(amountML, plausible.lowerBound), plausible.upperBound)
                needsReview = true
            }

            var quantity = drink.quantity
            if quantity < 1 { quantity = 1 }
            if quantity > maximumQuantity {
                quantity = maximumQuantity
                needsReview = true
            }

            for _ in 0..<quantity {
                guard drafts.count < maximumDrafts else { return drafts }
                drafts.append(SayItDraft(drinkType: drinkType, amountML: amountML, needsReview: needsReview))
            }
        }
        return drafts
    }

    // MARK: - Timestamps

    /// When each of `count` drinks logged together should say it was drunk.
    ///
    /// They are all "now", but not the same instant: the store's launch dedupe pass
    /// treats rows that match on timestamp, amount and type as one drink synced twice,
    /// and two identical glasses of water logged in the same instant would be exactly
    /// that. Stepping back a second at a time keeps every drink in the same minute on
    /// screen, none of them in the future, and no two of them mistakable for a duplicate.
    static func timestamps(count: Int, endingAt now: Date) -> [Date] {
        guard count > 0 else { return [] }
        return (0..<count).map { now.addingTimeInterval(-Double($0)) }
    }

    private static func normalized(_ word: String) -> String {
        let trimmed = word.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        // The vocabulary is handed to the model in its own casing ("mL", "L").
        return trimmed.hasSuffix(".") ? String(trimmed.dropLast()) : trimmed
    }
}
