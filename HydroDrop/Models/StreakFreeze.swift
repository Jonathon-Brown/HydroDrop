import Foundation

/// HydroDrop+ streak protection.
///
/// Subscribers get one freeze per calendar month. It is spent automatically on a
/// missed day rather than being something the user has to remember to apply — by
/// the time you notice a broken streak it is already too late to protect it.
///
/// A freeze bridges a gap in the streak but does not itself count as a day, so a
/// protected streak stops growing on the missed day instead of rewarding it.
///
/// Days are `DayKey` strings throughout: the monthly allowance is decided by which
/// month a frozen day is *in*, and a stored instant changes month when the user
/// changes timezone, which handed a second freeze to anyone who flew west across a
/// month boundary.
enum StreakFreeze {
    /// Freezes granted per calendar month while subscribed.
    static let monthlyAllowance = 1

    static func freezesUsed(inMonthOf now: Date, frozenDayKeys: [String], calendar: Calendar = .current) -> Int {
        let month = DayKey.monthKey(for: now, calendar: calendar)
        return frozenDayKeys.filter { DayKey.month(ofDayKey: $0) == month }.count
    }

    static func freezesRemaining(frozenDayKeys: [String], now: Date = Date(), calendar: Calendar = .current) -> Int {
        max(0, monthlyAllowance - freezesUsed(inMonthOf: now, frozenDayKeys: frozenDayKeys, calendar: calendar))
    }

    /// Combines two devices' ledgers of spent freezes into the same answer on both.
    ///
    /// A union alone would let two devices that each spent "their" freeze in the same
    /// month end up with two, so the union is trimmed back to the monthly allowance,
    /// keeping the earliest days. Sorting before trimming makes the result independent of
    /// which side merged first, which is what stops two devices from oscillating.
    static func merged(_ ledger: [String], _ other: [String]) -> [String] {
        let union = Set(ledger).union(other)
        var byMonth: [String: [String]] = [:]
        for day in union {
            byMonth[DayKey.month(ofDayKey: day), default: []].append(day)
        }
        return byMonth.values
            .flatMap { $0.sorted().prefix(monthlyAllowance) }
            .sorted()
    }

    /// Returns the day a freeze should be spent on, or nil to leave the streak alone.
    ///
    /// Only yesterday is ever a candidate: today is still in progress, and anything
    /// older has already broken the streak in a way a freeze cannot retroactively fix.
    static func dayToProtect(
        entries: [WaterEntry],
        goalML: Int,
        frozenDayKeys: [String],
        isSubscribed: Bool,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> String? {
        guard isSubscribed, goalML > 0 else { return nil }
        guard freezesRemaining(frozenDayKeys: frozenDayKeys, now: now, calendar: calendar) > 0 else { return nil }

        guard let yesterday = DayKey.previousDayKey(before: now, calendar: calendar) else { return nil }
        guard !frozenDayKeys.contains(yesterday) else { return nil }

        let totals = StreakCalculator.totalsByDay(entries, calendar: calendar)
        guard (totals[yesterday] ?? 0) < goalML else { return nil }

        // Only spend a freeze when there is actually a streak behind it to save.
        guard let dayBefore = DayKey.previousDayKey(before: yesterday, calendar: calendar) else { return nil }
        let hadStreak = (totals[dayBefore] ?? 0) >= goalML || frozenDayKeys.contains(dayBefore)
        return hadStreak ? yesterday : nil
    }
}
