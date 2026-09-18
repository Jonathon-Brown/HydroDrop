import Foundation

/// The window a drink may be logged in.
///
/// Backfilling is for the glass you forgot to tap, so it reaches back a week and
/// never forward: a future timestamp would sit in a day that has not happened yet and
/// quietly count towards a goal nobody has had the chance to miss.
enum DrinkTime {
    static let backfillDays = 7

    static func earliest(now: Date = Date(), calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -backfillDays, to: now) ?? now
    }

    static func range(now: Date = Date(), calendar: Calendar = .current) -> ClosedRange<Date> {
        earliest(now: now, calendar: calendar)...now
    }

    /// `date` pulled inside the window. Used on save as well as in the picker, because
    /// a sheet left open drifts past the upper bound it was given.
    static func clamped(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Date {
        let bounds = range(now: now, calendar: calendar)
        return min(max(date, bounds.lowerBound), bounds.upperBound)
    }

    /// The window for editing an entry that already exists, widened to include the
    /// entry's own timestamp so an older one can still be nudged rather than refused.
    static func editingRange(
        existing: Date,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> ClosedRange<Date> {
        let bounds = range(now: now, calendar: calendar)
        return min(existing, bounds.lowerBound)...max(existing, bounds.upperBound)
    }
}
