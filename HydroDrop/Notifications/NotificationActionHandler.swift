import Foundation
import SwiftData
import UserNotifications

/// Handles the buttons on a reminder notification without the app's UI opening.
///
/// "Log a glass" writes a real `WaterEntry` straight into the shared store, so the
/// Today screen, the watch and the reminder schedule all see it the same way they
/// would a tap on a quick-add button. "Snooze" asks `ReminderManager` for a single
/// follow-up nudge and leaves the regular schedule alone.
///
/// Installed as the notification centre's delegate from `HydroDropApp.init`, which
/// is early enough to catch a response that launched the app in the background.
final class NotificationActionHandler: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationActionHandler()

    private var modelContainer: ModelContainer?

    private override init() {
        super.init()
    }

    func activate(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        UNUserNotificationCenter.current().delegate = self
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        // A tap on the weekly recap opens it, wherever the app happens to be.
        if response.notification.request.content.categoryIdentifier == WeeklyRecapNotifier.categoryIdentifier,
           response.actionIdentifier == UNNotificationDefaultActionIdentifier {
            await MainActor.run { AppRouter.shared.showingWeeklyRecap = true }
            return
        }

        switch response.actionIdentifier {
        case ReminderManager.logGlassActionIdentifier:
            await MainActor.run { logGlass() }
        case ReminderManager.snoozeActionIdentifier:
            await ReminderManager.shared.scheduleSnooze()
        default:
            // The default action opens the app, which is all a plain tap should do.
            break
        }
    }

    /// Logs one glass at the user's first quick-add size.
    @MainActor
    private func logGlass() {
        guard let modelContainer else {
            Diagnostics.log("dropped a notification drink: no model container")
            return
        }
        let settings = AppSettings.shared
        let amount = settings.quickAddPresets.first ?? 250
        _ = try? DrinkLogger.logInApp(
            amountML: amount,
            in: modelContainer.mainContext,
            loggedBy: "a notification action",
            followUp: .init(
                // TODO: the saved goal, where the Today screen uses today's target and
                // so re-paces against a hot-day bump that this path ignores. Carried
                // across unchanged by cb4e64a; settle it once Phase 3 (Night Out) or
                // Phase 7 (workout) adds more bump sources, so it is settled once.
                reminderGoalML: settings.dailyGoalML,
                mirrorsToWatch: true
            ),
            settings: settings
        )
    }
}
