import Foundation
import SwiftData

/// CloudKit-backed SwiftData requires every attribute to be optional or carry a
/// default, and forbids unique constraints — the defaults below exist to satisfy
/// that, not because a zero-millilitre entry is meaningful.
@Model
final class WaterEntry {
    var amountML: Int = 0
    var timestamp: Date = Date.distantPast

    init(amountML: Int, timestamp: Date = Date()) {
        self.amountML = amountML
        self.timestamp = timestamp
    }
}
