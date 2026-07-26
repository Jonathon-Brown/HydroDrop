import Foundation
import UserNotifications

/// Schedules repeating local notifications that nudge the user to drink water
/// at a fixed interval within a waking window (e.g. every 2h between 8am-10pm).
final class ReminderManager {
    static let shared = ReminderManager()
    private let center = UNUserNotificationCenter.current()
    private let categoryIdentifier = "HYDRO_REMINDER"

    private static let messages = [
        "Time for a sip! 💧 Your droplet is getting thirsty.",
        "Quick reminder: grab some water and keep the streak alive.",
        "Hydration check! A glass of water goes a long way.",
        "Your body will thank you — drink up! 🥤",
        "Don't forget to hydrate. Every sip counts."
    ]

    private init() {}

    func requestAuthorizationIfNeeded(completion: ((Bool) -> Void)? = nil) {
        center.getNotificationSettings { settings in
            switch settings.authorizationStatus {
            case .notDetermined:
                self.center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                    DispatchQueue.main.async {
                        completion?(granted)
                        if granted { self.refreshSchedule() }
                    }
                }
            case .authorized, .provisional:
                DispatchQueue.main.async {
                    completion?(true)
                    self.refreshSchedule()
                }
            default:
                DispatchQueue.main.async { completion?(false) }
            }
        }
    }

    /// Recomputes and re-installs all pending reminder notifications based on current settings.
    func refreshSchedule() {
        center.removePendingNotificationRequests(withIdentifiers: pendingIdentifiers())

        let settings = AppSettings.shared
        guard settings.remindersEnabled else { return }

        center.getNotificationSettings { status in
            guard status.authorizationStatus == .authorized || status.authorizationStatus == .provisional else { return }

            let startMinutes = settings.quietStartHour * 60
            let endMinutes = settings.quietEndHour * 60
            let intervalMinutes = max(settings.reminderIntervalMinutes, 5)

            guard startMinutes < endMinutes else { return }

            var totalMinutes = startMinutes
            var index = 0
            while totalMinutes < endMinutes {
                var dateComponents = DateComponents()
                dateComponents.hour = totalMinutes / 60
                dateComponents.minute = totalMinutes % 60

                let content = UNMutableNotificationContent()
                content.title = "HydroDrop"
                content.body = Self.messages[index % Self.messages.count]
                content.sound = .default
                content.categoryIdentifier = self.categoryIdentifier

                let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
                let request = UNNotificationRequest(
                    identifier: self.identifier(forSlot: index),
                    content: content,
                    trigger: trigger
                )
                self.center.add(request)

                totalMinutes += intervalMinutes
                index += 1
            }
        }
    }

    private func identifier(forSlot index: Int) -> String {
        "hydrodrop.reminder.\(index)"
    }

    private func pendingIdentifiers() -> [String] {
        (0..<48).map { identifier(forSlot: $0) }
    }
}
