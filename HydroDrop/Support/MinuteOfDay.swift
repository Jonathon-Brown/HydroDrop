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

    /// A minute of the day as an instant on the day that starts at `startOfDay`. Minutes
    /// past 1439 land on the days that follow, which is how an overnight window's slots
    /// and its end are described. Nil for a negative minute or a day the calendar can't
    /// express.
    ///
    /// Set on the day rather than added to its midnight. Adding minutes adds elapsed
    /// time, and on the two days a year the clocks change that put an 8am nudge at 9am,
    /// the morning-after offer an hour early, and the Live Activity's end an hour out.
    /// A clock time that does not exist on the day the clocks go forward is given the
    /// next time that does, which is what the calendar does for any such request.
    static func instant(_ minutes: Int, on startOfDay: Date, calendar: Calendar = .current) -> Date? {
        guard minutes >= 0 else { return nil }
        let minutesPerDay = 24 * 60
        guard let day = calendar.date(byAdding: .day, value: minutes / minutesPerDay, to: startOfDay) else {
            return nil
        }
        let minute = minutes % minutesPerDay
        return calendar.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: day)
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
