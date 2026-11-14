import Foundation

/// When to ask iOS for the next background refresh (final design §10.6, §9.7, vector X4). Pure:
/// the app's background service hands the answer to `BGTaskScheduler` as the request's
/// `earliestBeginDate`, which iOS treats as "no sooner than", at its own discretion after that.
///
/// Two requests share the one task identifier, so only one can be pending, and this picks which:
/// in the six hours before local midnight it is the one-shot just after midnight, which closes a
/// day the writer missed for their partner within about 35 minutes rather than up to a day and a
/// half later; at any other time it is the regular net, half an hour on. Each run asks again, so
/// a phone that is never opened still gets one run after each local midnight.
public enum DuoBackgroundSchedule {
    /// The regular net's spacing.
    public static let regularInterval: TimeInterval = 30 * 60
    /// How close local midnight has to be for the one-shot to be the request.
    public static let midnightHorizon: TimeInterval = 6 * 60 * 60
    /// How long after midnight the one-shot may begin, in seconds: 5 to 35 minutes, so a million
    /// phones in one zone do not all ask the server for the same thing in the same second.
    public static let jitterRange: ClosedRange<Int> = 300...2100

    /// The `earliestBeginDate` to ask for. A jitter outside `jitterRange` is brought into it.
    /// Never at or before `now`.
    public static func nextEarliestBegin(now: Date, calendar: Calendar, jitterSeconds: Int) -> Date {
        let regular = now.addingTimeInterval(regularInterval)
        guard let midnight = nextMidnight(after: now, calendar: calendar), midnight > now,
              midnight.timeIntervalSince(now) <= midnightHorizon else { return regular }
        let jitter = min(max(jitterSeconds, jitterRange.lowerBound), jitterRange.upperBound)
        return midnight.addingTimeInterval(TimeInterval(jitter))
    }

    /// The first instant of the next local day in `calendar`'s zone. On a day the clocks go
    /// forward at midnight (Chile, Cuba, Lebanon) there is no 00:00, and the day begins when the
    /// clock reads 01:00; that is the instant meant, which `Calendar.startOfDay` gives. On a day
    /// they go back across midnight, the one midnight still ahead.
    public static func nextMidnight(after now: Date, calendar: Calendar) -> Date? {
        let today = calendar.startOfDay(for: now)
        // Noon of today, plus a day, then the start of that day: adding a day to midnight itself
        // lands on a time that does not exist on the day midnight is skipped, which Calendar
        // resolves forward and backward differently from one release to the next.
        guard let noon = calendar.date(byAdding: .hour, value: 12, to: today),
              let tomorrowNoon = calendar.date(byAdding: .day, value: 1, to: noon) else { return nil }
        return calendar.startOfDay(for: tomorrowNoon)
    }

    /// A jitter in `jitterRange`, from two random bytes.
    public static func jitterSeconds(random: DuoRandom) -> Int {
        let bytes = random.bytes(2)
        let value = bytes.reduce(0) { $0 << 8 | Int($1) }
        return jitterRange.lowerBound + value % (jitterRange.count)
    }
}
