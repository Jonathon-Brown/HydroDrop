import Foundation
import SwiftData

/// The one place a drink becomes a `WaterEntry`.
///
/// Five things can log one: the Today screen, an App Intent from Siri or the widget's
/// quick-add button, a notification action, the watch, and the first sip in
/// onboarding. Each of them used to insert its own row and then remember, or forget,
/// to tell the things that care — which is why a drink logged from a notification
/// reached the widget but not the Live Activity, and one logged by an intent in the
/// widget process reached neither the reminder schedule nor the watch.
///
/// This type owns the part that is identical everywhere: building the entry, putting
/// it in the store, and reporting back what the store holds afterwards. The part that
/// is not identical — the widget republish, the reminder re-pace, the watch push, a
/// haptic, an undo toast — lives in `logInApp`, which is deliberately not compiled
/// into the widget extension, because none of it exists there.
///
/// It lives in `Shared` rather than alongside the app's own code so that the App
/// Intents, which run in whichever process invoked them, can use it from either side.
@MainActor
enum DrinkLogger {
    enum Failure: Error {
        /// The insert could not be committed. The context has been rolled back, so the
        /// drink is gone rather than left sitting unsaved where a later, unrelated save
        /// would revive it and surprise the user with a drink they never logged.
        case couldNotSave
    }

    /// The drink that was logged, and the state of the store once it was in.
    struct Logged {
        let entry: WaterEntry

        /// Every entry, read back out of the store rather than assembled by the caller.
        ///
        /// A caller's own list can be stale — a `@Query` that has not refreshed, or a
        /// total from before an extension wrote something — and the widget and the
        /// reminder schedule should both describe what is actually there.
        let allEntries: [WaterEntry]

        /// Today's hydrating total, which is what the goal is measured against. Built
        /// from `hydratedML`, so a coffee counts for what a coffee counts for.
        let todayTotalML: Int
    }

    /// Writes one drink into the store.
    ///
    /// - Parameters:
    ///   - savesImmediately: `false` leaves the write to SwiftData's autosave, which is
    ///     what the Today screen has always done for a quick add. Nothing can be thrown
    ///     in that case, because nothing has been attempted yet.
    ///   - source: how to describe the caller in a Console log, e.g. "the watch". Only
    ///     ever read by a person reading diagnostics.
    /// - Throws: `Failure.couldNotSave` when an immediate save fails.
    @discardableResult
    static func log(
        amountML: Int,
        drinkType: DrinkType = .water,
        timestamp: Date = Date(),
        in context: ModelContext,
        savesImmediately: Bool = true,
        loggedBy source: String,
        now: Date = Date(),
        calendar: Calendar = .current
    ) throws -> Logged {
        let entry = WaterEntry(amountML: amountML, timestamp: timestamp, drinkType: drinkType)
        context.insert(entry)

        if savesImmediately {
            do {
                try context.save()
            } catch {
                Diagnostics.log("\(source) could not save a \(amountML) mL drink: \(error)")
                context.rollback()
                throw Failure.couldNotSave
            }
        }

        let stored = allEntries(in: context)
        return Logged(
            entry: entry,
            allEntries: stored,
            todayTotalML: todayTotalML(of: stored, now: now, calendar: calendar)
        )
    }

    /// Every entry in the store, including one inserted but not yet saved.
    static func allEntries(in context: ModelContext) -> [WaterEntry] {
        do {
            return try context.fetch(FetchDescriptor<WaterEntry>())
        } catch {
            Diagnostics.log("could not read the log back after writing to it: \(error)")
            return []
        }
    }

    /// The hydrating total of whichever of `entries` belong to `now`'s day.
    static func todayTotalML(
        of entries: [WaterEntry],
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Int {
        entries
            .filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
            .reduce(0) { $0 + $1.hydratedML }
    }
}
