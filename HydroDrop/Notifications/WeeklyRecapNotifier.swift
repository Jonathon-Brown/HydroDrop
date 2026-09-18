import Foundation
import UserNotifications

/// The Sunday evening nudge that there is a recap waiting.
///
/// Deliberately its own identifier and its own category, outside the reminder prefix,
/// so rebuilding the drinking reminders never disturbs it and it never counts against
/// the slots those reminders are rationing.
final class WeeklyRecapNotifier {
    static let shared = WeeklyRecapNotifier()

    static let categoryIdentifier = "HYDRO_WEEKLY_RECAP"
    private let identifier = "hydrodrop.weeklyRecap"
    private let center = UNUserNotificationCenter.current()

    /// Sunday, in `DateComponents` terms, where the week starts on Sunday as weekday 1.
    private let weekday = 1
    private let hour = 19

    private init() {}

    /// Installs or removes the weekly notification to match the current setting.
    ///
    /// Safe to call as often as anything changes: it is one repeating request under a
    /// fixed identifier, so re-adding it replaces rather than stacks.
    func refresh() {
        assert(Thread.isMainThread, "AppSettings is main-actor state; snapshot it on the main thread")
        let wanted = AppSettings.shared.weeklyRecapActive && AppSettings.shared.remindersEnabled

        guard wanted else {
            center.removePendingNotificationRequests(withIdentifiers: [identifier])
            return
        }

        Task { await install() }
    }

    private func install() async {
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let content = UNMutableNotificationContent()
        content.title = "Your week in water"
        content.body = "See how the last seven days went."
        content.sound = .default
        content.categoryIdentifier = Self.categoryIdentifier

        var components = DateComponents()
        components.weekday = weekday
        components.hour = hour
        components.minute = 0

        do {
            try await center.add(
                UNNotificationRequest(
                    identifier: identifier,
                    content: content,
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
                )
            )
        } catch {
            Diagnostics.log("could not schedule the weekly recap: \(error)")
        }
    }
}

/// Where a notification tap wants the app to go.
///
/// A tiny router rather than a deep-link scheme: there is exactly one destination, and
/// the handler that receives the tap has no view to push from.
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var showingWeeklyRecap = false
    private init() {}
}
