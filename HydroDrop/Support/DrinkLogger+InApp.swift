import Foundation
import SwiftData
import UIKit

/// Logging a drink from inside the app, where there is a widget to republish, a
/// reminder schedule to re-pace, a watch to tell and sometimes a person watching.
///
/// Deliberately a separate file from `DrinkLogger` itself: everything referenced here
/// — `AppSettings`, `WidgetPublisher`, `ReminderManager`, `WatchSessionManager` —
/// exists only in the app target, and `DrinkLogger` has to keep compiling inside the
/// widget extension. Anything new that logs a drink from the app should call this
/// rather than the core, so it inherits the whole list without having to know it.
extension DrinkLogger {
    /// The parts of logging a drink that differ by where it was logged from.
    struct FollowUp {
        /// The goal today's pace is measured against when the reminder schedule is
        /// rebuilt, or nil to leave the schedule alone entirely.
        ///
        /// Callers pass exactly what they passed before this type existed, and they do
        /// not agree. The Today screen uses today's target, which an accepted hot-day
        /// bump raises; a notification action and onboarding use the saved goal; and a
        /// drink arriving from the watch does not re-pace the schedule at all. Those
        /// disagreements are older than this refactor, so they are carried across
        /// unchanged rather than quietly settled here.
        ///
        /// Settling them is deliberately deferred: Phase 3's Night Out rehydration and
        /// Phase 7's workout goal both add bump sources, and picking one rule once they
        /// exist beats picking it twice. The two callers that disagree carry a TODO.
        var reminderGoalML: Int?

        /// Whether to hand the watch the new total.
        ///
        /// The Today screen leaves this off: it mirrors to the watch, the widgets and
        /// the Live Activity together from its own `onChange(of: todayTotal)`, and a
        /// push from here as well would be a duplicate.
        var mirrorsToWatch: Bool = false

        /// A success haptic, for the places where someone is looking at the screen.
        var playsHaptic: Bool = false
    }

    /// Writes the drink and then tells everything in the app that renders it.
    ///
    /// The undo toast and the Apple Health reconcile are not here: both belong to the
    /// Today screen, which owns the toast's state and already reconciles Health on a
    /// change or a foreground. Callers that want either do it with the returned value.
    @discardableResult
    static func logInApp(
        amountML: Int,
        drinkType: DrinkType = .water,
        timestamp: Date = Date(),
        in context: ModelContext,
        savesImmediately: Bool = true,
        loggedBy source: String,
        followUp: FollowUp,
        settings: AppSettings = .shared
    ) throws -> Logged {
        let logged = try log(
            amountML: amountML,
            drinkType: drinkType,
            timestamp: timestamp,
            in: context,
            savesImmediately: savesImmediately,
            loggedBy: source
        )

        if followUp.playsHaptic {
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        if followUp.mirrorsToWatch {
            WatchSessionManager.shared.pushCurrentContext()
        }
        WidgetPublisher.publish(
            entries: logged.allEntries,
            settings: settings,
            isShared: SharedModelContainer.isShared(context.container)
        )
        // A logged drink moves today's pace, so the rest of the day's nudges are stale.
        if let reminderGoalML = followUp.reminderGoalML {
            ReminderManager.shared.refreshSchedule(
                entries: logged.allEntries,
                goalML: reminderGoalML
            )
        }
        return logged
    }
}
