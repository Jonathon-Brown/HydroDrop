import Foundation

/// What the last seven days looked like.
///
/// Computed from the log rather than accumulated as the week goes, so it is always
/// consistent with what History shows and cannot drift. Entirely a value: no dates are
/// captured beyond the ones passed in, which is what lets the tests pin a week down.
struct WeeklyRecap: Equatable {
    struct Day: Equatable, Identifiable {
        let dayKey: String
        let totalML: Int
        var id: String { dayKey }
    }

    /// Oldest first, always seven entries, with zeros for days nothing was logged.
    let days: [Day]
    let goalML: Int
    let averageML: Int
    let bestDay: Day?
    let daysGoalMet: Int
    /// The hour of the day, 0 to 23, where intake most often falls behind the pace the
    /// goal implies. Nil when there is not enough logged to say anything honest.
    let slipHour: Int?

    var hasAnyIntake: Bool { days.contains { $0.totalML > 0 } }

    /// How far below the goal an hour's cumulative intake has to average before it is
    /// worth pointing at. Below this, the "slip" is noise and naming an hour would be
    /// inventing a pattern.
    static let slipSignificanceFraction = 0.12

    static func make(
        entries: [WaterEntry],
        goalML: Int,
        windowStartMinutes: Int,
        windowEndMinutes: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> WeeklyRecap {
        let totals = StreakCalculator.totalsByDay(entries, calendar: calendar)
        let today = calendar.startOfDay(for: now)

        let days: [Day] = (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            let key = DayKey.key(for: date, calendar: calendar)
            return Day(dayKey: key, totalML: totals[key] ?? 0)
        }

        let sum = days.reduce(0) { $0 + $1.totalML }
        let average = days.isEmpty ? 0 : sum / days.count
        let best = days.filter { $0.totalML > 0 }.max { $0.totalML < $1.totalML }
        let met = goalML > 0 ? days.filter { $0.totalML >= goalML }.count : 0

        return WeeklyRecap(
            days: days,
            goalML: goalML,
            averageML: average,
            bestDay: best,
            daysGoalMet: met,
            slipHour: slipHour(
                entries: entries,
                dayKeys: days.map(\.dayKey),
                goalML: goalML,
                windowStartMinutes: windowStartMinutes,
                windowEndMinutes: windowEndMinutes,
                calendar: calendar
            )
        )
    }

    /// The hour at which the week's drinking most consistently trails its own pace.
    ///
    /// At a point `f` of the way through the waking window you are on pace with
    /// `f * goal` logged, which is the same rule the pace-aware reminders use. This
    /// measures the gap at every whole hour of the window, averages it over the days
    /// that had any intake at all, and names the worst hour.
    ///
    /// Days with nothing logged are excluded rather than counted as a total miss: a day
    /// the user did not open the app says nothing about *when* they fall behind, and
    /// including it would drag the answer towards the start of the window every time.
    static func slipHour(
        entries: [WaterEntry],
        dayKeys: [String],
        goalML: Int,
        windowStartMinutes: Int,
        windowEndMinutes: Int,
        calendar: Calendar = .current
    ) -> Int? {
        guard goalML > 0, windowStartMinutes != windowEndMinutes else { return nil }

        let windowLength = windowEndMinutes > windowStartMinutes
            ? windowEndMinutes - windowStartMinutes
            : (SchedulePlan.minutesPerDay - windowStartMinutes) + windowEndMinutes
        guard windowLength > 60 else { return nil }

        // Minutes into the day for each entry, grouped by the day it belongs to.
        var minutesByDay: [String: [(minute: Int, amount: Int)]] = [:]
        for entry in entries {
            let key = DayKey.key(for: entry.timestamp, calendar: calendar)
            guard dayKeys.contains(key) else { continue }
            let components = calendar.dateComponents([.hour, .minute], from: entry.timestamp)
            let minute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            minutesByDay[key, default: []].append((minute, entry.hydratedML))
        }
        let activeDays = minutesByDay.filter { !$0.value.isEmpty }
        guard !activeDays.isEmpty else { return nil }

        var worstHour: Int?
        var worstDeficit = 0.0

        // Every whole hour strictly inside the window. The edges say nothing: at the
        // start nothing is expected yet, and at the end the day is over.
        for offset in stride(from: 60, to: windowLength, by: 60) {
            let cutoff = (windowStartMinutes + offset) % SchedulePlan.minutesPerDay
            let expected = Double(goalML) * Double(offset) / Double(windowLength)

            var totalDeficit = 0.0
            for (_, drinks) in activeDays {
                let logged = drinks
                    .filter { isBefore(minute: $0.minute, cutoff: cutoff, windowStart: windowStartMinutes) }
                    .reduce(0) { $0 + $1.amount }
                totalDeficit += max(0, expected - Double(logged))
            }
            let averageDeficit = totalDeficit / Double(activeDays.count)
            if averageDeficit > worstDeficit {
                worstDeficit = averageDeficit
                worstHour = cutoff / 60
            }
        }

        guard worstDeficit >= Double(goalML) * slipSignificanceFraction else { return nil }
        return worstHour
    }

    /// Whether a minute of the day falls before `cutoff`, counting from the start of
    /// the waking window so an overnight window orders correctly.
    private static func isBefore(minute: Int, cutoff: Int, windowStart: Int) -> Bool {
        let shifted = { (value: Int) in (value - windowStart + SchedulePlan.minutesPerDay) % SchedulePlan.minutesPerDay }
        return shifted(minute) < shifted(cutoff)
    }
}
