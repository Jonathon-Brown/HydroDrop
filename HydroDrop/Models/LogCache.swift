import Foundation

/// The log's totals by day, worked out once per change to the log rather than once per
/// use per render.
///
/// Today and History each hold every drink there has ever been, and each derives the
/// streak, the lost streak, the world and the chart from `StreakCalculator.totalsByDay`,
/// which walks all of them with a calendar call and a formatted key per drink. Both
/// screens asked for that half a dozen times per render, and render on every published
/// change, so with a few years of history every drink logged, every toast and every
/// setting cost well over a hundred milliseconds on the main thread. The totals are kept
/// here against a digest of the log and recomputed only when the digest moves.
///
/// A reference held in `@State`, so it outlives renders, and deliberately not Observable:
/// it is written from inside `body`, which SwiftUI must not see as a state change.
final class LogCache {
    private var digest: LogDigest?
    private var totals: [String: Int] = [:]
    /// How many times the totals have been worked out, for the tests.
    private(set) var recomputeCount = 0

    func totalsByDay(of entries: [WaterEntry], calendar: Calendar = .current) -> [String: Int] {
        let current = LogDigest(of: entries, calendar: calendar)
        if current != digest {
            totals = StreakCalculator.totalsByDay(entries, calendar: calendar)
            digest = current
            recomputeCount += 1
        }
        return totals
    }
}

/// What the totals depend on, read cheaply: every drink's time, amount and type, and the
/// calendar's time zone, which decides which day a time falls on. One pass over three
/// stored properties per drink, against the calendar arithmetic and the string building
/// of the totals themselves. Hashing rather than keeping the values, so the cache holds
/// one dictionary and not a second copy of the log.
struct LogDigest: Equatable {
    let count: Int
    let hash: Int
    let timeZone: String

    init(of entries: [WaterEntry], calendar: Calendar) {
        var hasher = Hasher()
        for entry in entries {
            hasher.combine(entry.timestamp)
            hasher.combine(entry.amountML)
            hasher.combine(entry.drinkTypeRawValue)
        }
        count = entries.count
        hash = hasher.finalize()
        timeZone = calendar.timeZone.identifier
    }
}
