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
        /// Every caller that re-paces passes today's target, `AppSettings.todayGoalML()`,
        /// which is the saved goal plus whatever extra has been accepted for today, for
        /// any reason. Pace is about the goal the person is working towards today; the
        /// streak is the thing measured against the saved goal, and it never comes
        /// through here. The Today screen, a notification action and onboarding used to
        /// disagree about this, which meant a glass logged from a notification on a
        /// bumped day re-paced against the wrong number.
        ///
        /// Nil is still allowed and still means "do not re-pace": a drink arriving from
        /// the watch has never rebuilt the schedule.
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

        // Night Out listens to every drink logged in the app, from any of the ways in,
        // so a water logged from the reminder's own button still answers the reminder.
        NightOutCoordinator.shared.didLog(drinkType, settings: settings)

        // A duo partner hears about progress from every way in too. Costs nothing for
        // anyone without a duo, and is spaced out by the store for anyone with one.
        DuoStore.shared.logChanged(entries: logged.allEntries, goalML: settings.dailyGoalML)

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
