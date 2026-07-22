import Foundation

enum StreakCalculator {
    /// Total mL logged, grouped by calendar day.
    static func totalsByDay(_ entries: [WaterEntry], calendar: Calendar = .current) -> [Date: Int] {
        Dictionary(grouping: entries) { calendar.startOfDay(for: $0.timestamp) }
            .mapValues { $0.reduce(0) { $0 + $1.amountML } }
    }

    /// Consecutive days (ending today or yesterday) where intake met the goal.
    static func currentStreak(entries: [WaterEntry], goalML: Int, calendar: Calendar = .current) -> Int {
        guard goalML > 0 else { return 0 }
        let totals = totalsByDay(entries, calendar: calendar)
        var streak = 0
        var day = calendar.startOfDay(for: Date())

        // If today hasn't hit the goal yet, start counting from yesterday
        // so an in-progress day doesn't zero out an existing streak.
        if (totals[day] ?? 0) < goalML {
            guard let yesterday = calendar.date(byAdding: .day, value: -1, to: day) else { return 0 }
            day = yesterday
        }

        while let total = totals[day], total >= goalML {
            streak += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else { break }
            day = previous
        }
        return streak
    }
}
