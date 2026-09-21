import Foundation
import UserNotifications

/// Turns duo announcements into local notifications.
///
/// Local on purpose. The push that brings the news is silent and says nothing; what the
/// user is told is decided here, on their own phone, from their own preset table and
/// their own waking window. Nothing a partner wrote is ever shown, because a partner
/// never writes anything.
enum DuoNotifier {
    /// Outside `ReminderManager`'s prefix, so rebuilding the reminder schedule, which
    /// happens every time a drink is logged, leaves these alone.
    static let identifierPrefix = "hydrodrop.duo."

    /// Returns the keys of anything iOS refused to take, so the caller can forget it
    /// was ever announced and try again. Turned off is not refused: that is an answer.
    @discardableResult
    static func deliver(
        _ announcements: [DuoAnnouncement],
        settings: AppSettings = .shared,
        now: Date = Date()
    ) async -> [String] {
        guard !announcements.isEmpty, DuoCache.notificationsEnabled() else { return [] }
        let center = UNUserNotificationCenter.current()
        var refused: [String] = []

        for announcement in announcements {
            let content = UNMutableNotificationContent()
            content.title = announcement.title
            content.body = announcement.body
            content.sound = .default
            content.threadIdentifier = identifierPrefix + announcement.duoID.uuidString
            if announcement.isActionable {
                // The reminder's own buttons, so a glass can be logged from the nudge.
                content.categoryIdentifier = ReminderManager.reminderCategoryIdentifier
            }

            // Held until the waking window opens if it arrived outside it. A partner in
            // another time zone is wide awake at three in the morning here.
            var trigger: UNNotificationTrigger?
            if let opening = DuoQuietHours.holdUntil(
                now,
                startMinutes: settings.quietStartMinutes,
                endMinutes: settings.quietEndMinutes
            ) {
                trigger = UNTimeIntervalNotificationTrigger(
                    timeInterval: max(1, opening.timeIntervalSince(now)),
                    repeats: false
                )
            }

            // Named after the ledger key, so the same news scheduled twice is one request.
            let request = UNNotificationRequest(
                identifier: identifierPrefix + announcement.key,
                content: content,
                trigger: trigger
            )
            do {
                try await center.add(request)
            } catch {
                Diagnostics.log("could not post a duo notification: \(error)")
                refused.append(announcement.key)
            }
        }
        return refused
    }

    /// Takes back anything still waiting for a duo that is no longer there.
    static func withdrawAll(for duoID: UUID) {
        let center = UNUserNotificationCenter.current()
        let thread = identifierPrefix + duoID.uuidString
        center.getPendingNotificationRequests { requests in
            let ids = requests.filter { $0.content.threadIdentifier == thread }.map(\.identifier)
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }
}
