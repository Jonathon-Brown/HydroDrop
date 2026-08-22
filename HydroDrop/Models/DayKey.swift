import Foundation

/// A calendar day identified by its local year-month-day, not by an instant.
///
/// Storing a day as a `Date` — even one normalised with `startOfDay` — records an
/// instant, and an instant only means "that day" in the timezone it was written in.
/// A freeze recorded at midnight in New York is `04:00Z`; recomputing the same day in
/// London gives `23:00Z` the day before, so an exact-match lookup misses and the
/// freeze silently stops protecting the streak. A `2026-08-20` string means the same
/// day everywhere, which is what the streak rules are actually about.
enum DayKey {
    /// The day `date` falls on, e.g. "2026-08-20".
    static func key(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }

    /// The day before `date`, or nil if the calendar can't express it.
    static func previousDayKey(before date: Date, calendar: Calendar = .current) -> String? {
        guard let previous = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) else {
            return nil
        }
        return key(for: previous, calendar: calendar)
    }

    /// The day before `dayKey`, derived without leaving day-key space.
    static func previousDayKey(before dayKey: String, calendar: Calendar = .current) -> String? {
        guard let date = date(from: dayKey, calendar: calendar) else { return nil }
        return previousDayKey(before: date, calendar: calendar)
    }

    /// The month a day belongs to, e.g. "2026-08". Used for the monthly freeze allowance.
    static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        String(key(for: date, calendar: calendar).prefix(7))
    }

    /// The month portion of a day key.
    static func month(ofDayKey dayKey: String) -> String {
        String(dayKey.prefix(7))
    }

    /// Midnight local time on `dayKey`. Nil for a malformed key.
    ///
    /// Note that in timezones which start daylight saving at midnight the requested
    /// time doesn't exist, so this is the *start of that day*, which may be 01:00.
    static func date(from dayKey: String, calendar: Calendar = .current) -> Date? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        return calendar.startOfDay(for: date)
    }
}
