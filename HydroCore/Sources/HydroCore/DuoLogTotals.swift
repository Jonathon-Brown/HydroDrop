import Foundation

// What a duo is told about the water log, and how far back the log can be believed (final
// design §8.7, §10.5; vectors KV14 and X10). The app reads its SwiftData log into these plain
// values, and the Android app reads its Room log into the same shape, so both sides total a
// day the same way and can be held to one set of vectors.

/// One drink as Duo sees it: when it was logged, how much of it counts towards the goal, and
/// which way it came in. Nothing else about a drink is ever looked at.
public struct DuoLogEntry: Equatable, Sendable {
    /// Every way in that is HydroDrop's own: a tap, a widget, NFC, Say it, the watch. iOS has no
    /// other source today, since HealthKit is written to and never read from for water (§8.7).
    public static let hydroDropSource = "hydrodrop"

    public var timestamp: Date
    /// The drink's hydrating amount (`WaterEntry.hydratedML`), not what was poured: the duo
    /// shares the same progress the person sees on their own ring.
    public var hydratedML: Int
    /// `hydrodrop`, or what the Android app calls an import (`health_connect`).
    public var source: String

    public init(timestamp: Date, hydratedML: Int, source: String) {
        self.timestamp = timestamp
        self.hydratedML = hydratedML
        self.source = source
    }
}

public enum DuoLogTotals {
    /// Hydrating mL per day, keyed by `DayKey` in `calendar`, counting only what was logged in
    /// HydroDrop itself (§8.7, vector KV14): an import from Health Connect is somebody else's
    /// number, and a partner's streak must not grow or break on it. For entries that all come
    /// from HydroDrop, which is every entry on iOS, this is exactly what
    /// `StreakCalculator.totalsByDay` gives, so the duo and the person's own streak agree.
    ///
    /// The calendar is the phone's own and is read at each call: moving to another time zone
    /// moves an evening drink onto another day, here as in the solo streak (§8.4, vector X10).
    public static func totalsByDay(_ entries: [DuoLogEntry], calendar: Calendar) -> [String: Int] {
        var totals: [String: Int] = [:]
        for entry in entries where entry.source == DuoLogEntry.hydroDropSource {
            totals[DayKey.key(for: entry.timestamp, calendar: calendar), default: 0] += entry.hydratedML
        }
        return totals
    }
}

/// The first day this phone's log can speak for (§10.5, CON F1). Before it the outbox only ever
/// raises a day, because an empty day there means this install was not keeping a log yet, not
/// that nobody drank: without it, a reinstall opened before the log came back from iCloud would
/// publish a week of empty days over a partner's shared streak.
public enum DuoCoverage {
    /// What `start` answers when neither day can be read: later than any real day, so every past
    /// day counts as uncovered and can only be raised. Today is exempt from coverage whatever it
    /// says (`DuoOutbox.unsent`), so today's row is still written.
    public static let coversNoPastDay = "9999-12-31"

    /// The earlier of the day this install first ran and the day of the oldest drink in the log,
    /// as `min(installDay, earliestLogEntryDay)` (§10.5). Only real day keys take part: a drink
    /// stamped with `Date.distantPast` (the model's default, never a real drink) gives year 1,
    /// which as a string sorts before every day and would have made the whole log "covered",
    /// letting the outbox lower any past day; an unreadable install day would have done the same.
    /// With neither readable, nothing in the past is covered.
    public static func start(installDay: String, earliestEntryDay: String?) -> String {
        let readable = [installDay, earliestEntryDay].compactMap { $0 }.filter(DuoStreak.isDayKey)
        return readable.min() ?? coversNoPastDay
    }

    /// How long it is since the end of the day this install first ran, for D71's young-install
    /// rule (`DuoSyncPlan.youngInstallWindow`). The install file keeps only the day, so the age is
    /// counted from the end of that day in the phone's calendar, the latest the install can have
    /// been (D78): the window then lasts at least 48 hours after the install and at most 72.
    /// Counted from the start of the day, as it used to be, an evening reinstall was protected for
    /// little more than a day, and a partial iCloud import could lower the covered week at +25 h.
    /// The calendar is the phone's now, so a change of time zone since the install moves the end
    /// of that day by as much as the change, up to 26 hours either way. Before the day is over
    /// the age is negative. A day that cannot be read is an install of just now, the safe answer
    /// (nothing is lowered).
    public static func installAge(installDay: String, now: Date, calendar: Calendar) -> TimeInterval {
        guard DuoStreak.isDayKey(installDay), let start = DayKey.date(from: installDay, calendar: calendar),
              let end = calendar.date(byAdding: .day, value: 1, to: start) else { return 0 }
        return now.timeIntervalSince(end)
    }
}
