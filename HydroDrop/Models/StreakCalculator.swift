import Foundation

enum StreakCalculator {
    /// Hydrating mL logged, grouped by calendar day.
    ///
    /// Built from `hydratedML`, not the poured volume, so a day of coffee counts for
    /// what it actually contributes. Water is a multiplier of exactly 1, which is what
    /// every entry logged before drink types existed reads as.
    ///
    /// Keyed by `DayKey` rather than by a `startOfDay` instant so that a total, a
    /// frozen day and a history bar all refer to the same day after the user changes
    /// timezone.
    static func totalsByDay(_ entries: [WaterEntry], calendar: Calendar = .current) -> [String: Int] {
        Dictionary(grouping: entries) { DayKey.key(for: $0.timestamp, calendar: calendar) }
            .mapValues { $0.reduce(0) { $0 + $1.hydratedML } }
    }

    /// The longest run of goal-meeting days anywhere in the history.
    ///
    /// Measured against the goal as it stands today, because that is the only goal we
    /// have: HydroDrop stores drinks, not the goal each day was judged against. Someone
    /// who has since raised their goal will see a shorter best run than they lived, and
    /// someone who lowered it a longer one. That is why this only ever *adds* badges,
    /// through `AppSettings.seedMilestones`, and never takes one away.
    ///
    /// Frozen days bridge a gap without counting themselves, exactly as they do in
    /// `currentStreak`.
    static func longestStreak(
        entries: [WaterEntry],
        goalML: Int,
        frozenDayKeys: [String] = [],
        calendar: Calendar = .current
    ) -> Int {
        guard goalML > 0 else { return 0 }
        let totals = totalsByDay(entries, calendar: calendar)
        let metDays = Set(totals.filter { $0.value >= goalML }.keys)
        let frozen = Set(frozenDayKeys)
        let linked = metDays.union(frozen)
        guard !linked.isEmpty else { return 0 }

        var best = 0
        for day in linked {
            // Only start counting from the first day of a run, so each run is walked once.
            let previous = DayKey.previousDayKey(before: day, calendar: calendar)
            if let previous, linked.contains(previous) { continue }

            var run = 0
            var cursor: String? = day
            while let current = cursor, linked.contains(current) {
                if metDays.contains(current) { run += 1 }
                cursor = DayKey.nextDayKey(after: current, calendar: calendar)
            }
            best = max(best, run)
        }
        return best
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
