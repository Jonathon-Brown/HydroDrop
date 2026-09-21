import Foundation
import SwiftData

/// CloudKit-backed SwiftData requires every attribute to be optional or carry a
/// default, and forbids unique constraints — the defaults below exist to satisfy
/// that, not because a zero-millilitre entry is meaningful.
@Model
final class WaterEntry {
    var amountML: Int = 0
    var timestamp: Date = Date.distantPast

    /// The `DrinkType` raw value, or nil for an entry logged before drink types
    /// existed. Optional rather than defaulted on purpose: a record already in
    /// CloudKit has no such field at all, and nil is exactly what it comes back as.
    /// `drinkType` reads that as water, which is what those entries were.
    var drinkTypeRawValue: String?

    /// What was in the glass. Unrecognised and missing values read as water, so a
    /// record written by a newer version can never make an older one lose the entry.
    var drinkType: DrinkType {
        get { drinkTypeRawValue.flatMap(DrinkType.init(rawValue:)) ?? .water }
        set { drinkTypeRawValue = newValue.rawValue }
    }

    /// The Apple Health sample this drink was written as, if it has been.
    ///
    /// Doubles as the record of what is already in Health, which is what stops a drink
    /// being written twice. Optional for the same reason as `drinkTypeRawValue`: a
    /// record already in CloudKit has no such field and comes back as nil, which is
    /// exactly right for a drink that predates Health sync.
    var healthKitSampleUUID: String?

    /// The Apple Health caffeine sample written for this drink, if one was. Separate
    /// from the water sample because they are different Health types and either can
    /// exist without the other. Optional for the same reason as the fields above.
    var caffeineSampleUUID: String?

    /// How much of this drink counts towards the daily goal. Totals, streaks and the
    /// history chart are all built from this rather than from `amountML`.
    var hydratedML: Int {
        drinkType.hydratedML(from: amountML)
    }

    init(amountML: Int, timestamp: Date = Date(), drinkType: DrinkType = .water) {
        self.amountML = amountML
        self.timestamp = timestamp
        self.drinkTypeRawValue = drinkType.rawValue
    }
}
