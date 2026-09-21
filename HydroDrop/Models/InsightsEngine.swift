import Foundation

// Insights: what hitting the goal lines up with in someone's own Health data. Everything
// here is a pure function of values handed to it. Nothing is read from Health in this
// file, and nothing that was read from Health is ever written down anywhere.
//
// The wording rule is strict and it is enforced by a test: a finding describes a
// pattern in the person's own data and nothing else. It never says water did anything.

/// The three things compared, and which day's value is set against a day's goal.
enum InsightMetric: String, CaseIterable, Identifiable {
    /// Sleep on the night that FOLLOWED the day.
    case sleep
    /// Resting heart rate on the day that FOLLOWED.
    case restingHeartRate
    /// Active energy on the SAME day.
    case activeEnergy

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sleep: return "Sleep"
        case .restingHeartRate: return "Resting heart rate"
        case .activeEnergy: return "Active energy"
        }
    }

    var icon: String {
        switch self {
        case .sleep: return "bed.double.fill"
        case .restingHeartRate: return "heart.fill"
        case .activeEnergy: return "flame.fill"
        }
    }

    /// How many days after the goal day the value being compared falls on.
    var lagDays: Int {
        switch self {
        case .sleep, .restingHeartRate: return 1
        case .activeEnergy: return 0
        }
    }

    /// Which of the person's days the comparison is about, for the chart's caption.
    var alignmentNote: String {
        switch self {
        case .sleep: return "Sleep on the night after each day"
        case .restingHeartRate: return "Resting heart rate on the day after"
        // Same-day, so said plainly: a busy day tends to have more of both in it.
        case .activeEnergy: return "Active energy on the same day. The two often rise together on busy days"
        }
    }

    /// The name Health files this under, for saying that there is none of it.
    var healthName: String {
        switch self {
        case .sleep: return "sleep"
        case .restingHeartRate: return "resting heart rate"
        case .activeEnergy: return "active energy"
        }
    }

    /// The unit the two bars are labelled in.
    func format(_ value: Double) -> String {
        switch self {
        case .sleep:
            let minutes = Int(value.rounded())
            return "\(minutes / 60) h \(minutes % 60) min"
        case .restingHeartRate:
            return String(format: "%.1f bpm", value)
        case .activeEnergy:
            return "\(Int(value.rounded())) kcal"
        }
    }
}

/// A day's worth of what was read from Health, keyed by the day it belongs to.
///
/// Sleep is keyed by the day the night ENDED on, so "the night following the 20th" is
/// the value stored under the 21st. See `SleepNights`.
struct DailyHealth: Equatable {
    var sleepMinutesByWakeDay: [String: Double] = [:]
    var restingHeartRateByDay: [String: Double] = [:]
    var activeEnergyByDay: [String: Double] = [:]

    func values(for metric: InsightMetric) -> [String: Double] {
        switch metric {
        case .sleep: return sleepMinutesByWakeDay
        case .restingHeartRate: return restingHeartRateByDay
        case .activeEnergy: return activeEnergyByDay
        }
    }

    var isEmpty: Bool {
        sleepMinutesByWakeDay.isEmpty && restingHeartRateByDay.isEmpty && activeEnergyByDay.isEmpty
    }
}

/// Two averages, side by side.
struct InsightFinding: Equatable {
    var metric: InsightMetric
    var metMean: Double
    var missedMean: Double
    var metDays: Int
    var missedDays: Int

    var difference: Double { metMean - missedMean }

    /// One sentence, about a pattern in this person's own data, and nothing more.
    var sentence: String {
        switch metric {
        case .sleep:
            let minutes = Int(abs(difference).rounded())
            return "On days you hit your goal, you slept \(minutes) \(minutes == 1 ? "minute" : "minutes") \(difference > 0 ? "longer" : "less") that night, on average."
        case .restingHeartRate:
            let beats = String(format: "%.1f", abs(difference))
            return "On the day after you hit your goal, your resting heart rate was \(beats) bpm \(difference < 0 ? "lower" : "higher"), on average."
        case .activeEnergy:
            let percent = missedMean > 0 ? Int((abs(difference) / missedMean * 100).rounded()) : 0
            return "On days you hit your goal, your active energy was \(percent) percent \(difference > 0 ? "higher" : "lower"), on average."
        }
    }
}

enum InsightResult: Equatable {
    case finding(InsightFinding)
    /// Not enough days yet. How many more of each kind are needed, with data.
    case needsMoreData(metric: InsightMetric, goalDaysNeeded: Int, otherDaysNeeded: Int)
    /// Enough days, and the two averages are too close to call anything.
    case noClearPattern(metric: InsightMetric)
    /// Health has nothing of this kind for any of these days: no watch, no sleep
    /// tracking, or access not given. Logging more water will never change that, so it
    /// is not answered with "keep logging".
    case noHealthData(metric: InsightMetric)

    var metric: InsightMetric {
        switch self {
        case .finding(let finding): return finding.metric
        case .needsMoreData(let metric, _, _), .noClearPattern(let metric), .noHealthData(let metric): return metric
        }
    }

    /// What is said when there is no finding to show.
    var waitingMessage: String? {
        switch self {
        case .finding:
            return nil
        case .noClearPattern:
            return "No clear difference so far. This updates as more days come in."
        case .noHealthData(let metric):
            return "Apple Health has no \(metric.healthName) data for these days. If you expected some, check what HydroDrop can read in the Health app, under Sharing, then Apps."
        case .needsMoreData(_, let goalDays, let otherDays):
            var parts: [String] = []
            if goalDays > 0 { parts.append("\(goalDays) more \(goalDays == 1 ? "day" : "days") when you hit your goal") }
            if otherDays > 0 { parts.append("\(otherDays) more \(otherDays == 1 ? "day" : "days") when you did not") }
            return "Keep logging. Insights unlock after a bit more data: " + parts.joined(separator: ", and ") + "."
        }
    }
}

enum InsightsEngine {
    static let windowDays = 60
    static let minimumDaysPerBucket = 7
    static let footer = "Patterns in your own data, not medical advice."

    /// The smallest difference worth showing. Sleep in minutes, resting heart rate in
    /// beats a minute, active energy as a fraction of the other bucket's average.
    static func clearsThreshold(_ finding: InsightFinding) -> Bool {
        switch finding.metric {
        case .sleep: return abs(finding.difference) >= 10
        case .restingHeartRate: return abs(finding.difference) >= 1.5
        case .activeEnergy: return finding.missedMean > 0 && abs(finding.difference) / finding.missedMean >= 0.08
        }
    }

    /// The days being looked at: the sixty before today, newest first, and none from
    /// before the first drink was ever logged. Today is left out because it is not over,
    /// and a day from before the app was in use is not a day the goal was missed.
    static func window(today: String, firstLoggedDay: String?, calendar: Calendar = .current) -> [String] {
        guard let firstLoggedDay else { return [] }
        var days: [String] = []
        var cursor = DayKey.previousDayKey(before: today, calendar: calendar)
        while let day = cursor, days.count < windowDays, day >= firstLoggedDay {
            days.append(day)
            cursor = DayKey.previousDayKey(before: day, calendar: calendar)
        }
        return days
    }

    /// - Parameters:
    ///   - metDays: the days the goal was met, as `DayKey` strings. Judged against the
    ///     goal as it stands today, as the streak is: HydroDrop stores drinks, not the
    ///     goal each day was measured against.
    ///   - firstLoggedDay: the day of the first drink ever logged.
    static func analyse(
        metDays: Set<String>,
        firstLoggedDay: String?,
        health: DailyHealth,
        today: String,
        calendar: Calendar = .current
    ) -> [InsightResult] {
        let days = window(today: today, firstLoggedDay: firstLoggedDay, calendar: calendar)
        return InsightMetric.allCases.map { metric in
            let values = health.values(for: metric)
            guard !values.isEmpty else { return .noHealthData(metric: metric) }
            var met: [Double] = []
            var missed: [Double] = []
            for day in days {
                // The value set against this day: the same day, or the one after it.
                guard let aligned = shifted(day, by: metric.lagDays, calendar: calendar),
                      // A value for today is still being gathered, so it is not compared yet.
                      aligned < today,
                      let value = values[aligned] else { continue }
                if metDays.contains(day) { met.append(value) } else { missed.append(value) }
            }

            guard met.count >= minimumDaysPerBucket, missed.count >= minimumDaysPerBucket else {
                return .needsMoreData(
                    metric: metric,
                    goalDaysNeeded: max(0, minimumDaysPerBucket - met.count),
                    otherDaysNeeded: max(0, minimumDaysPerBucket - missed.count)
                )
            }
            let finding = InsightFinding(
                metric: metric,
                metMean: met.reduce(0, +) / Double(met.count),
                missedMean: missed.reduce(0, +) / Double(missed.count),
                metDays: met.count,
                missedDays: missed.count
            )
            return clearsThreshold(finding) ? .finding(finding) : .noClearPattern(metric: metric)
        }
    }

    private static func shifted(_ day: String, by days: Int, calendar: Calendar) -> String? {
        guard days != 0 else { return day }
        var cursor: String? = day
        for _ in 0..<days { cursor = cursor.flatMap { DayKey.nextDayKey(after: $0, calendar: calendar) } }
        return cursor
    }
}

/// Turns stretches of sleep into minutes per night.
///
/// Health can hold the same night twice, once from a watch and once from a phone, so
/// overlapping stretches are merged before they are added up. A night belongs to the day
/// it ended on: anything that started between one noon and the next counts towards the
/// morning in the middle, which puts a nap in with the night that follows it rather
/// than splitting a night in two at midnight.
enum SleepNights {
    static func minutesByWakeDay(_ asleep: [DateInterval], calendar: Calendar = .current) -> [String: Double] {
        let sorted = asleep.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for interval in sorted {
            if let last = merged.last, interval.start <= last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, interval.end))
            } else {
                merged.append(interval)
            }
        }
        var minutes: [String: Double] = [:]
        for interval in merged {
            let wakeDay = DayKey.key(for: interval.start.addingTimeInterval(12 * 60 * 60), calendar: calendar)
            minutes[wakeDay, default: 0] += interval.duration / 60
        }
        return minutes
    }
}

/// The extra water suggested after exercise. Today only, like every other bump, and
/// through the same mechanism: see `TodayBump`.
enum WorkoutBump {
    /// A workout shorter than this is not counted.
    static let minimumMinutes = 20.0
    static let mLPerHalfHour = 350.0

    /// What to suggest for today's workouts, given how long each one lasted in minutes.
    /// Nil when none of them was long enough. The daily cap across every reason is
    /// applied later, by `TodayBump.suggestion`, not here.
    /// How long each of a day's workouts lasted, in minutes, with the same workout
    /// counted once. A run recorded by a watch and again by another app is two records
    /// of one run, so stretches that overlap are merged first, as sleep is.
    static func minutes(of workouts: [DateInterval]) -> [Double] {
        let sorted = workouts.filter { $0.duration > 0 }.sorted { $0.start < $1.start }
        var merged: [DateInterval] = []
        for workout in sorted {
            if let last = merged.last, workout.start < last.end {
                merged[merged.count - 1] = DateInterval(start: last.start, end: max(last.end, workout.end))
            } else {
                merged.append(workout)
            }
        }
        return merged.map { $0.duration / 60 }
    }

    static func suggestedML(workoutMinutes: [Double]) -> Int? {
        let counted = workoutMinutes.filter { $0 >= minimumMinutes }.reduce(0, +)
        guard counted > 0 else { return nil }
        let exact = counted / 30 * mLPerHalfHour
        // To the nearest 50 mL, so the offer is a number a person would say out loud.
        return Int((exact / 50).rounded()) * 50
    }
}

/// Every fixed line Insights shows, in one place, so that one test can read all of it.
/// The rule is the same for these as for a finding: describe, never explain, and never
/// sound like medicine.
enum InsightsCopy {
    static let cardTitle = "See what your goal days line up with"
    static let lockedBody = "Your sleep, resting heart rate and active energy on the days you hit your goal, next to the days you did not. Part of HydroDrop+."
    static let connectBody = "Connect Apple Health to compare your sleep, resting heart rate and active energy on the days you hit your goal with the days you did not. It also reads your workouts, so it can suggest extra water on the day if you turn that on in Settings."
    static let unavailable = "Apple Health is not available on this device, so there is nothing to compare with."

    static let primerIntro = "Insights compares the days you hit your goal with the days you did not, using four things from Apple Health."
    static let primerReads = [
        "Sleep",
        "Resting heart rate",
        "Active energy",
        "Workouts, to suggest extra water on the day if you turn that on",
    ]
    static let primerPromises = [
        "Worked out on this iPhone. None of your sleep, heart rate, energy or workout readings are saved, synced, shared with a duo or shown in a widget.",
        "If you say yes to extra water after a workout, today's goal goes up like it does on a hot day. That number is all that is kept.",
        "HydroDrop reads only these four, and only after you say yes on the next screen.",
        "Saying no changes nothing else. Everything in HydroDrop works the same without it.",
        "Never used for advertising.",
    ]

    static let workoutCardTitle = "Nice workout"

    static var all: [String] {
        [cardTitle, lockedBody, connectBody, unavailable, primerIntro, workoutCardTitle, InsightsEngine.footer]
            + primerReads + primerPromises
    }
}

