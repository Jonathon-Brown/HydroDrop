import Foundation
import SwiftData

@Model
final class WaterEntry {
    var amountML: Int
    var timestamp: Date

    init(amountML: Int, timestamp: Date = Date()) {
        self.amountML = amountML
        self.timestamp = timestamp
    }
}
