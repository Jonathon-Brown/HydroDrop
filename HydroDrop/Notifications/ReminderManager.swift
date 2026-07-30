import Foundation
import UserNotifications

/// Schedules repeating local notifications that nudge the user to drink water
/// at a fixed interval within a waking window (e.g. every 2h between 8am-10pm).
final class ReminderManager {
    static let shared = ReminderManager()
    private let center = UNUserNotificationCenter.current()
    private let categoryIdentifier = "HYDRO_REMINDER"
    private let identifierPrefix = "hydrodrop.reminder."

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
        // Clear out exactly whatever reminder identifiers are currently pending, however many
        // that is — a fixed-size guess can't keep up with schedules the UI can actually produce
        // (e.g. a wide waking window combined with a short interval yields 50+ slots).
        center.getPendingNotificationRequests { [weak self] requests in
            guard let self else { return }
            let staleIdentifiers = requests.map(\.identifier).filter { $0.hasPrefix(self.identifierPrefix) }
            self.center.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)

            let settings = AppSettings.shared
            guard settings.remindersEnabled else { return }

            self.center.getNotificationSettings { status in
                guard status.authorizationStatus == .authorized || status.authorizationStatus == .provisional else { return }

                let startMinutes = settings.quietStartMinutes
                let endMinutes = settings.quietEndMinutes
                let intervalMinutes = max(settings.reminderIntervalMinutes, 5)

                // The window may wrap past midnight (e.g. 10pm...6am for a night-shift schedule).
                let minutesPerDay = 24 * 60
                let windowLength = endMinutes > startMinutes
                    ? endMinutes - startMinutes
                    : (minutesPerDay - startMinutes) + endMinutes

                guard windowLength > 0 else { return }

                var elapsed = 0
                var index = 0
                while elapsed < windowLength {
                    let minuteOfDay = (startMinutes + elapsed) % minutesPerDay

                    var dateComponents = DateComponents()
                    dateComponents.hour = minuteOfDay / 60
                    dateComponents.minute = minuteOfDay % 60

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

                    elapsed += intervalMinutes
                    index += 1
                }
            }
        }
    }

    private func identifier(forSlot index: Int) -> String {
        "\(identifierPrefix)\(index)"
    }
}
