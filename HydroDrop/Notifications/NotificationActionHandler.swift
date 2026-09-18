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
        let context = modelContainer.mainContext
        context.insert(WaterEntry(amountML: amount))
        do {
            try context.save()
        } catch {
            Diagnostics.log("failed to save a notification drink (\(amount) mL): \(error)")
            context.rollback()
            return
        }
        WatchSessionManager.shared.pushCurrentContext()
        WidgetPublisher.publish(
            context: context,
            settings: settings,
            isShared: SharedModelContainer.isShared(modelContainer)
        )

        // A logged drink changes today's pace, the same as it would from the Today screen.
        let startOfDay = Calendar.current.startOfDay(for: Date())
        let descriptor = FetchDescriptor<WaterEntry>(predicate: #Predicate { $0.timestamp >= startOfDay })
        let todayEntries = (try? context.fetch(descriptor)) ?? []
        ReminderManager.shared.refreshSchedule(entries: todayEntries, goalML: settings.dailyGoalML)
    }
}
