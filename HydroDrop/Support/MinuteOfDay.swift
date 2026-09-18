import SwiftUI

/// Bridges an Int "minutes since midnight" value to the `Date` a `DatePicker` wants.
///
/// Reminder windows are stored as minutes of the day, not instants, so they mean the
/// same clock time after a timezone change. The picker only ever reads and writes
/// the hour and minute of the date it is handed.
enum MinuteOfDay {
    static func date(from minutes: Int, calendar: Calendar = .current) -> Date {
        var components = DateComponents()
        components.hour = minutes / 60
        components.minute = minutes % 60
        return calendar.date(from: components) ?? Date()
    }

    static func dateBinding(_ minutes: Binding<Int>, calendar: Calendar = .current) -> Binding<Date> {
        Binding(
            get: { date(from: minutes.wrappedValue, calendar: calendar) },
            set: { newDate in
                let components = calendar.dateComponents([.hour, .minute], from: newDate)
                minutes.wrappedValue = (components.hour ?? 0) * 60 + (components.minute ?? 0)
            }
        )
    }

    /// The clock time, in the user's locale, e.g. "8:00 AM" or "08:00".
    static func label(_ minutes: Int, calendar: Calendar = .current) -> String {
        date(from: minutes, calendar: calendar).formatted(date: .omitted, time: .shortened)
    }
}

/// "Every 2 hours", "every 45 min": the reminder interval in words.
enum DurationLabel {
    static func label(minutes total: Int) -> String {
        let hours = total / 60
        let minutes = total % 60
        switch (hours, minutes) {
        case (0, _):
            return "\(minutes) min"
        case (_, 0):
            return hours == 1 ? "1 hour" : "\(hours) hours"
        default:
            return "\(hours) hr \(minutes) min"
        }
    }
}
