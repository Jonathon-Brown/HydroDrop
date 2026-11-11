import Foundation

/// A calendar day identified by its local year-month-day, not by an instant.
///
/// Storing a day as a `Date` — even one normalised with `startOfDay` — records an
/// instant, and an instant only means "that day" in the timezone it was written in.
/// A freeze recorded at midnight in New York is `04:00Z`; recomputing the same day in
/// London gives `23:00Z` the day before, so an exact-match lookup misses and the
/// freeze silently stops protecting the streak. A `2026-08-20` string means the same
/// day everywhere, which is what the streak rules are actually about.
///
/// It lives in HydroCore because the Duo rules there are written in day keys, and it is
/// public because the app, the widgets and the Watch app all use it from outside the package.
public enum DayKey {
    /// The day `date` falls on, e.g. "2026-08-20".
    ///
    /// Built by hand rather than with `String(format:)`, which gives the same text for
    /// every date but goes through Foundation's formatter and was most of the cost of
    /// grouping a log of several thousand drinks by day, which the app does on every
    /// render of its two screens.
    public static func key(for date: Date, calendar: Calendar = .current) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return padded(components.year ?? 0, to: 4) + "-"
            + padded(components.month ?? 0, to: 2) + "-"
            + padded(components.day ?? 0, to: 2)
    }

    /// `value` as `%0<width>d` would print it: zero-padded to the width, never cut, with
    /// a minus sign counted in the width as printf counts it.
    private static func padded(_ value: Int, to width: Int) -> String {
        if value < 0 { return "-" + padded(-value, to: width - 1) }
        let digits = String(value)
        return digits.count >= width ? digits : String(repeating: "0", count: width - digits.count) + digits
    }

    /// The day before `date`, or nil if the calendar can't express it.
    public static func previousDayKey(before date: Date, calendar: Calendar = .current) -> String? {
        guard let previous = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: date)) else {
            return nil
        }
        return key(for: previous, calendar: calendar)
    }

    /// The day before `dayKey`, derived without leaving day-key space.
    public static func previousDayKey(before dayKey: String, calendar: Calendar = .current) -> String? {
        guard let date = date(from: dayKey, calendar: calendar) else { return nil }
        return previousDayKey(before: date, calendar: calendar)
    }

    /// The day after `dayKey`, derived without leaving day-key space.
    public static func nextDayKey(after dayKey: String, calendar: Calendar = .current) -> String? {
        guard let date = date(from: dayKey, calendar: calendar),
              let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
        return key(for: next, calendar: calendar)
    }

    /// The month a day belongs to, e.g. "2026-08". Used for the monthly freeze allowance.
    public static func monthKey(for date: Date, calendar: Calendar = .current) -> String {
        String(key(for: date, calendar: calendar).prefix(7))
    }

    /// The month portion of a day key.
    public static func month(ofDayKey dayKey: String) -> String {
        String(dayKey.prefix(7))
    }

    /// Midnight local time on `dayKey`. Nil for a malformed key.
    ///
    /// Note that in timezones which start daylight saving at midnight the requested
    /// time doesn't exist, so this is the *start of that day*, which may be 01:00.
    public static func date(from dayKey: String, calendar: Calendar = .current) -> Date? {
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
