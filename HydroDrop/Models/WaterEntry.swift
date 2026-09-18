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
