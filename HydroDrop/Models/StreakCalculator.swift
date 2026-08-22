import Foundation

enum StreakCalculator {
    /// Total mL logged, grouped by calendar day.
    ///
    /// Keyed by `DayKey` rather than by a `startOfDay` instant so that a total, a
    /// frozen day and a history bar all refer to the same day after the user changes
    /// timezone.
    static func totalsByDay(_ entries: [WaterEntry], calendar: Calendar = .current) -> [String: Int] {
        Dictionary(grouping: entries) { DayKey.key(for: $0.timestamp, calendar: calendar) }
            .mapValues { $0.reduce(0) { $0 + $1.amountML } }
    }

    /// Consecutive days (ending today or yesterday) where intake met the goal.
    ///
    /// Days in `frozenDayKeys` bridge a miss without counting towards the total, so a
    /// streak protected by a HydroDrop+ freeze survives but doesn't grow.
    static func currentStreak(
        entries: [WaterEntry],
        goalML: Int,
        frozenDayKeys: [String] = [],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        guard goalML > 0 else { return 0 }
        let totals = totalsByDay(entries, calendar: calendar)
        let frozen = Set(frozenDayKeys)
        var streak = 0
        var day = calendar.startOfDay(for: now)

        // If today hasn't hit the goal yet, start counting from yesterday
        // so an in-progress day doesn't zero out an existing streak.
        if (totals[DayKey.key(for: day, calendar: calendar)] ?? 0) < goalML {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }

        while true {
            let key = DayKey.key(for: day, calendar: calendar)
            if (totals[key] ?? 0) >= goalML {
                streak += 1
            } else if !frozen.contains(key) {
                break
            }
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }
}
