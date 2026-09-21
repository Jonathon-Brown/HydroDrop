import Foundation
import UserNotifications

/// Runs a Night Out: remembers when it started, sends the water reminders, and sets up
/// the next morning's offer of a little extra water.
///
/// Everything here stays on this device. It is not synced, not shared and not shown on
/// anything that can be shared, and it keeps no history: when a Night Out ends, the
/// only thing left of it is the drinks in the log, which look like any other drinks.
@MainActor
final class NightOutCoordinator: ObservableObject {
    static let shared = NightOutCoordinator()

    private enum Keys {
        static let startedAt = "nightOut.startedAt"
        static let morningOfferAt = "nightOut.morningOfferAt"
        static let offerAnsweredDayKey = "nightOut.offerAnsweredDayKey"
        static let bumpAcceptedDayKey = "nightOut.bumpAcceptedDayKey"
    }

    /// Outside `ReminderManager`'s prefix, so rebuilding the reminder schedule, which
    /// happens every time a drink is logged, leaves these alone.
    private static let waterRoundIdentifier = "hydrodrop.nightout.waterround"
    private static let morningIdentifier = "hydrodrop.nightout.morning"

    private let defaults: UserDefaults
    private let center = UNUserNotificationCenter.current()

    @Published private(set) var startedAt: Date?
    /// When the morning-after offer becomes due, if a Night Out earned one.
    @Published private(set) var morningOfferAt: Date?
    @Published private(set) var offerAnsweredDayKey: String
    /// The day a rehydration bump was accepted, so the badge under the goal can say the
    /// extra is not only about the heat.
    @Published private(set) var bumpAcceptedDayKey: String

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        startedAt = Self.date(defaults, Keys.startedAt)
        morningOfferAt = Self.date(defaults, Keys.morningOfferAt)
        offerAnsweredDayKey = defaults.string(forKey: Keys.offerAnsweredDayKey) ?? ""
        bumpAcceptedDayKey = defaults.string(forKey: Keys.bumpAcceptedDayKey) ?? ""
    }

    // MARK: - The evening

    func isActive(now: Date = Date(), settings: AppSettings = .shared) -> Bool {
        guard let startedAt else { return false }
        return NightOut.isActive(startedAt: startedAt, now: now, wakingEndMinutes: settings.quietEndMinutes)
    }

    func start(now: Date = Date()) {
        startedAt = now
        defaults.set(now.timeIntervalSinceReferenceDate, forKey: Keys.startedAt)
    }

    /// Ends it by hand. The morning offer, if one was earned, still stands: turning
    /// Night Out off on the way home is not a reason to skip the water tomorrow.
    func end() {
        startedAt = nil
        defaults.removeObject(forKey: Keys.startedAt)
        center.removePendingNotificationRequests(withIdentifiers: [Self.waterRoundIdentifier])
    }

    /// Lets a Night Out that has run its course go. Called whenever Today comes forward.
    func expireIfNeeded(now: Date = Date(), settings: AppSettings = .shared) {
        if startedAt != nil, !isActive(now: now, settings: settings) { end() }
    }

    /// Told about every drink logged inside the app, by `DrinkLogger.logInApp`.
    func didLog(_ drinkType: DrinkType, now: Date = Date(), settings: AppSettings = .shared) {
        guard isActive(now: now, settings: settings) else { return }
        if drinkType.isAlcoholic {
            scheduleWaterRound(after: now)
            scheduleMorningOffer(after: now, settings: settings)
        } else if drinkType.countsAsWaterRound {
            center.removePendingNotificationRequests(withIdentifiers: [Self.waterRoundIdentifier])
        }
    }

    /// One reminder at a time. A second drink before the first reminder simply moves
    /// it, so nobody is ever sent a run of them.
    private func scheduleWaterRound(after now: Date) {
        let content = UNMutableNotificationContent()
        content.title = "Water round"
        content.body = "Your droplet is asking nicely."
        content.sound = .default
        // The reminder's own buttons, so a glass can be logged from the notification.
        content.categoryIdentifier = ReminderManager.reminderCategoryIdentifier
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: NightOut.waterRoundDelay, repeats: false)
        add(UNNotificationRequest(identifier: Self.waterRoundIdentifier, content: content, trigger: trigger))
    }

    /// Set up by the first alcoholic drink, not by the switch: a Night Out with nothing
    /// logged in it has nothing to follow up on.
    private func scheduleMorningOffer(after now: Date, settings: AppSettings) {
        let morning = NightOut.nextWakingStart(after: now, wakingStartMinutes: settings.quietStartMinutes)
        morningOfferAt = morning
        defaults.set(morning.timeIntervalSinceReferenceDate, forKey: Keys.morningOfferAt)

        let content = UNMutableNotificationContent()
        content.title = "Good morning"
        content.body = "Want a little extra water in today's goal? It is one tap in HydroDrop."
        content.sound = .default
        content.categoryIdentifier = ReminderManager.reminderCategoryIdentifier
        let parts = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: morning)
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)
        add(UNNotificationRequest(identifier: Self.morningIdentifier, content: content, trigger: trigger))
    }

    private func add(_ request: UNNotificationRequest) {
        center.add(request) { error in
            // Most often because notifications are off, which is the user's call and
            // not worth a word on screen.
            if let error { Diagnostics.log("could not schedule a Night Out notification: \(error)") }
        }
    }

    // MARK: - The morning after

    /// Whether the rehydration offer should be on Today right now.
    func offerIsDue(now: Date = Date()) -> Bool {
        guard let morningOfferAt, now >= morningOfferAt else { return false }
        // Only on the morning it was meant for. An offer nobody saw does not follow
        // them around for the rest of the week.
        guard Calendar.current.isDate(now, inSameDayAs: morningOfferAt) else { return false }
        return offerAnsweredDayKey != DayKey.key(for: now)
    }

    /// Records that the offer was answered, either way, so it is not made twice.
    func answerOffer(accepted: Bool, now: Date = Date()) {
        let today = DayKey.key(for: now)
        offerAnsweredDayKey = today
        defaults.set(today, forKey: Keys.offerAnsweredDayKey)
        if accepted {
            bumpAcceptedDayKey = today
            defaults.set(today, forKey: Keys.bumpAcceptedDayKey)
        }
        morningOfferAt = nil
        defaults.removeObject(forKey: Keys.morningOfferAt)
        center.removePendingNotificationRequests(withIdentifiers: [Self.morningIdentifier])
    }

    private static func date(_ defaults: UserDefaults, _ key: String) -> Date? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return Date(timeIntervalSinceReferenceDate: defaults.double(forKey: key))
    }
}
