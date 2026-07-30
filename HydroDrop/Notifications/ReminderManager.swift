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
    ///
    /// Passing today's `entries` and `goalML` enables pace-aware scheduling for
    /// subscribers who have turned it on; without them the fixed-interval schedule is
    /// used, which is also what every free user gets.
    func refreshSchedule(entries: [WaterEntry]? = nil, goalML: Int? = nil) {
        let todayTotal = entries.map { entries in
            let calendar = Calendar.current
            return entries
                .filter { calendar.isDateInToday($0.timestamp) }
                .reduce(0) { $0 + $1.amountML }
        }

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

                guard let plan = SchedulePlan(settings: settings) else { return }

                if settings.smartRemindersEnabled {
                    self.scheduleSmart(plan: plan, todayTotalML: todayTotal ?? 0, goalML: goalML ?? settings.dailyGoalML)
                } else {
                    self.scheduleFixed(plan: plan)
                }
            }
        }
    }

    /// The classic schedule: one repeating notification per slot, every day, forever.
    private func scheduleFixed(plan: SchedulePlan) {
        for (index, offset) in plan.slotOffsets.enumerated() {
            let minuteOfDay = (plan.startMinutes + offset) % SchedulePlan.minutesPerDay

            var dateComponents = DateComponents()
            dateComponents.hour = minuteOfDay / 60
            dateComponents.minute = minuteOfDay % 60

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            add(trigger: trigger, slot: index, messageIndex: index)
        }
    }

    /// Pace-aware schedule.
    ///
    /// Slots become one-shot so today's can be dropped individually when the user is
    /// already ahead: at a slot `f` of the way through the waking window you are
    /// "on pace" with `f * goal` logged, and a nudge to drink more would be noise.
    ///
    /// One-shots mean a finite horizon, so this re-arms every time the app opens or
    /// water is logged. `maxPendingRequests` stays under the 64-notification cap iOS
    /// enforces per app, which a wide window and short interval can otherwise blow past.
    private func scheduleSmart(plan: SchedulePlan, todayTotalML: Int, goalML: Int) {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        var scheduled = 0

        for dayOffset in 0..<Self.horizonDays {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }

            for (index, offset) in plan.slotOffsets.enumerated() {
                guard scheduled < Self.maxPendingRequests else { return }

                // Adding to the day's start rolls past midnight correctly for
                // overnight windows, where a slot belongs to the following date.
                guard let fireDate = calendar.date(
                    byAdding: .minute,
                    value: plan.startMinutes + offset,
                    to: dayStart
                ), fireDate > now else { continue }

                if dayOffset == 0 && isAheadOfPace(
                    slotOffset: offset,
                    windowLength: plan.windowLength,
                    todayTotalML: todayTotalML,
                    goalML: goalML
                ) {
                    continue
                }

                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                add(trigger: trigger, slot: scheduled, messageIndex: index)
                scheduled += 1
            }
        }
    }

    /// True when intake already covers what this slot would nudge towards.
    private func isAheadOfPace(slotOffset: Int, windowLength: Int, todayTotalML: Int, goalML: Int) -> Bool {
        guard goalML > 0, windowLength > 0 else { return false }
        let expectedFraction = Double(slotOffset) / Double(windowLength)
        return Double(todayTotalML) >= Double(goalML) * expectedFraction
    }

    private func add(trigger: UNNotificationTrigger, slot: Int, messageIndex: Int) {
        let content = UNMutableNotificationContent()
        content.title = "HydroDrop"
        content.body = Self.messages[messageIndex % Self.messages.count]
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        center.add(UNNotificationRequest(
            identifier: identifier(forSlot: slot),
            content: content,
            trigger: trigger
        ))
    }

    private func identifier(forSlot index: Int) -> String {
        "\(identifierPrefix)\(index)"
    }

    /// Days of one-shot reminders to keep armed in pace-aware mode.
    private static let horizonDays = 3
    /// Kept below the 64 pending notifications iOS allows a single app.
    private static let maxPendingRequests = 60
}

/// The slot layout implied by the user's waking window and interval.
private struct SchedulePlan {
    static let minutesPerDay = 24 * 60

    let startMinutes: Int
    let windowLength: Int
    let slotOffsets: [Int]

    init?(settings: AppSettings) {
        let start = settings.quietStartMinutes
        let end = settings.quietEndMinutes
        let interval = max(settings.reminderIntervalMinutes, 5)

        // The window may wrap past midnight (e.g. 10pm...6am for a night-shift schedule).
        let length = end > start ? end - start : (Self.minutesPerDay - start) + end
        guard length > 0 else { return nil }

        self.startMinutes = start
        self.windowLength = length
        self.slotOffsets = Array(stride(from: 0, to: length, by: interval))
    }
}
