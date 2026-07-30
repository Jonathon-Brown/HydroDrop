import Foundation

/// HydroDrop+ streak protection.
///
/// Subscribers get one freeze per calendar month. It is spent automatically on a
/// missed day rather than being something the user has to remember to apply — by
/// the time you notice a broken streak it is already too late to protect it.
///
/// A freeze bridges a gap in the streak but does not itself count as a day, so a
/// protected streak stops growing on the missed day instead of rewarding it.
enum StreakFreeze {
    /// Freezes granted per calendar month while subscribed.
    static let monthlyAllowance = 1

    static func freezesUsed(in month: Date, frozenDays: [Date], calendar: Calendar = .current) -> Int {
        frozenDays.filter { calendar.isDate($0, equalTo: month, toGranularity: .month) }.count
    }

    static func freezesRemaining(frozenDays: [Date], now: Date = Date(), calendar: Calendar = .current) -> Int {
        max(0, monthlyAllowance - freezesUsed(in: now, frozenDays: frozenDays, calendar: calendar))
    }

    /// Returns the day a freeze should be spent on, or nil to leave the streak alone.
    ///
    /// Only yesterday is ever a candidate: today is still in progress, and anything
    /// older has already broken the streak in a way a freeze cannot retroactively fix.
    static func dayToProtect(
        entries: [WaterEntry],
        goalML: Int,
        frozenDays: [Date],
        isSubscribed: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Date? {
        guard isSubscribed, goalML > 0 else { return nil }
        guard freezesRemaining(frozenDays: frozenDays, now: now, calendar: calendar) > 0 else { return nil }

        let today = calendar.startOfDay(for: now)
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: today) else { return nil }
        guard !frozenDays.contains(yesterday) else { return nil }

        let totals = StreakCalculator.totalsByDay(entries, calendar: calendar)
        guard (totals[yesterday] ?? 0) < goalML else { return nil }

        // Only spend a freeze when there is actually a streak behind it to save.
        guard let dayBefore = calendar.date(byAdding: .day, value: -1, to: yesterday) else { return nil }
        let hadStreak = (totals[dayBefore] ?? 0) >= goalML || frozenDays.contains(dayBefore)
        return hadStreak ? yesterday : nil
    }
}
