#if DUO_V2
import Foundation
import SwiftData

/// The one piece of Duo that reads the SwiftData water log, so the sync engine can publish with
/// nobody looking: after a background refresh, or a notification that woke the app before Today
/// drew (final design §9.7, §10.6). `HydroDropApp` hands it over at launch with
/// `DuoStore.shared.activate(logReader:)`.
///
/// It reads only what Duo needs: the drinks of the last nine days, as per-day totals of their
/// hydrating amounts, and the day of the oldest drink anywhere, for `coverageStart` (§10.5).
/// Nothing it reads leaves the phone as it stands; the outbox turns the totals into a goal met
/// and a progress quarter per day.
@MainActor
final class SwiftDataDuoLogReader: DuoLogReading, DuoLogSourceVetting {
    /// What one read of the store brings back: the drinks since the horizon, and the time of the
    /// oldest drink there is.
    struct Fetched {
        var recent: [DuoLogEntry]
        var oldest: Date?
    }

    /// Whether the container is the App Group's shared store. `SharedModelContainer.makeForApp`
    /// falls back to SwiftData's default location when the shared store will not open, and that
    /// store is empty, or the log as it was before the App Group existed. Read with the real goal,
    /// it would be a week of missed days, which an old install (no D71) would send over the
    /// partner's streak. So it is no log at all, as a failed read is, and the sync engine publishes
    /// nothing while this is false (`DuoLogSourceVetting`).
    let readsThePersonsLog: Bool
    private let fetch: @MainActor (_ horizon: Date, _ floor: Date) throws -> Fetched
    private let goal: @MainActor () -> Int
    private let calendar: @MainActor () -> Calendar

    convenience init(container: ModelContainer) {
        self.init(container: container, isTheSharedStore: SharedModelContainer.isShared(container),
                  goalML: { AppSettings.shared.dailyGoalML }, calendar: { Calendar.current })
    }

    /// The goal and the calendar are what a test says they are; the app's are the saved goal (the
    /// shared streak, like the solo one, is judged against it, never a raised target) and the
    /// phone's own calendar, read at each call so a change of zone is seen at once (§8.4).
    convenience init(container: ModelContainer, isTheSharedStore: Bool, goalML: @escaping @MainActor () -> Int,
                     calendar: @escaping @MainActor () -> Calendar) {
        self.init(readsThePersonsLog: isTheSharedStore, goalML: goalML, calendar: calendar,
                  fetch: { horizon, floor in try SwiftDataDuoLogReader.fetch(from: container, horizon: horizon, floor: floor) })
    }

    /// The fetch is what a test says it is too, so a read that fails can be tried.
    init(readsThePersonsLog: Bool, goalML: @escaping @MainActor () -> Int, calendar: @escaping @MainActor () -> Calendar,
         fetch: @escaping @MainActor (_ horizon: Date, _ floor: Date) throws -> Fetched) {
        self.readsThePersonsLog = readsThePersonsLog
        self.goal = goalML
        self.calendar = calendar
        self.fetch = fetch
    }

    /// The earliest moment a drink can be counted from. `WaterEntry`'s timestamp defaults to
    /// `Date.distantPast` only to satisfy CloudKit; a row still carrying it is not a drink, and as
    /// the oldest one it would hide the real first day of the log.
    private static let firstPlausibleDrink = Date(timeIntervalSince1970: 946_684_800) // 2000-01-01T00:00:00Z

    func read(now: Date) -> DuoLogSummary {
        guard readsThePersonsLog else { return .empty }
        let calendar = calendar()
        // The correction window and two days more, as `DuoStore.logChanged` keeps: the outbox
        // looks at seven days, and a zone change can move a drink across a day's edge either way.
        let horizon = now.addingTimeInterval(-Double(DuoStreak.correctionWindowDays + 2) * 86_400)
        do {
            let fetched = try fetch(horizon, Self.firstPlausibleDrink)
            return DuoLogSummary(totalsByDay: DuoLogTotals.totalsByDay(fetched.recent, calendar: calendar), goalML: goal(),
                                 earliestEntryDay: fetched.oldest.map { DayKey.key(for: $0, calendar: calendar) })
        } catch {
            // A log that could not be read is not an empty one. `.empty` has no goal, and the sync
            // engine never publishes from a summary without one, so a failed read cannot send a
            // week of missed days over a partner's streak.
            return .empty
        }
    }

    private static func fetch(from container: ModelContainer, horizon: Date, floor: Date) throws -> Fetched {
        let context = container.mainContext
        let recent = FetchDescriptor<WaterEntry>(predicate: #Predicate { $0.timestamp >= horizon })
        var oldest = FetchDescriptor<WaterEntry>(predicate: #Predicate { $0.timestamp >= floor },
                                                 sortBy: [SortDescriptor(\.timestamp, order: .forward)])
        oldest.fetchLimit = 1
        let entries = try context.fetch(recent)
        let first = try context.fetch(oldest).first
        // Every iOS entry is HydroDrop's own: HealthKit is written to, never read from, for water
        // (§8.7), so nothing here is an import.
        return Fetched(recent: entries.map { DuoLogEntry(timestamp: $0.timestamp, hydratedML: $0.hydratedML, source: DuoLogEntry.hydroDropSource) },
                       oldest: first?.timestamp)
    }
}
#endif
