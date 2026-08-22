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

    /// Guards `generation` and `tail`, which are touched from every thread that can
    /// change a setting.
    private let lock = NSLock()
    /// Incremented synchronously by each caller, so rebuilds are ordered by when they
    /// were *requested* rather than by which async continuation happens to resume first.
    private var generation = 0
    /// The most recently enqueued rebuild. Each new rebuild awaits it before starting,
    /// which makes the remove-then-add sequences strictly FIFO instead of interleaved.
    private var tail: Task<Void, Never>?

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
    ///
    /// Settings are read *here*, synchronously on the caller's thread, and carried into
    /// the rebuild as a value. Reading them later, from inside a notification-centre
    /// callback, raced the main thread writing them and — because two rapid changes each
    /// started their own remove-then-add cycle — could leave the schedule matching a
    /// setting the user had already moved past.
    func refreshSchedule(entries: [WaterEntry]? = nil, goalML: Int? = nil) {
        assert(Thread.isMainThread, "AppSettings is main-actor state; snapshot it on the main thread")

        let settings = AppSettings.shared
        let calendar = Calendar.current
        let todayTotal = entries.map { entries in
            entries
                .filter { calendar.isDateInToday($0.timestamp) }
                .reduce(0) { $0 + $1.amountML }
        }
        let snapshot = ScheduleSnapshot(
            remindersEnabled: settings.remindersEnabled,
            intervalMinutes: settings.reminderIntervalMinutes,
            startMinutes: settings.quietStartMinutes,
            endMinutes: settings.quietEndMinutes,
            smartRemindersActive: settings.smartRemindersActive,
            goalML: goalML ?? settings.dailyGoalML,
            todayTotalML: todayTotal ?? 0
        )

        lock.lock()
        generation += 1
        let mine = generation
        let previous = tail
        let task = Task { [weak self] in
            await previous?.value
            await self?.apply(snapshot, generation: mine)
        }
        tail = task
        lock.unlock()
    }

    private func isCurrent(_ generation: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return generation == self.generation
    }

    private func apply(_ snapshot: ScheduleSnapshot, generation: Int) async {
        // Clear out exactly whatever reminder identifiers are currently pending, however many
        // that is — a fixed-size guess can't keep up with schedules the UI can actually produce
        // (e.g. a wide waking window combined with a short interval yields 50+ slots).
        let pending = await center.pendingNotificationRequests()
        guard isCurrent(generation) else { return }
        let staleIdentifiers = pending.map(\.identifier).filter { $0.hasPrefix(identifierPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: staleIdentifiers)

        guard snapshot.remindersEnabled else { return }

        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }
        guard isCurrent(generation) else { return }

        guard let plan = SchedulePlan(snapshot: snapshot) else { return }

        if snapshot.smartRemindersActive {
            await scheduleSmart(plan: plan, snapshot: snapshot, generation: generation)
        } else {
            await scheduleFixed(plan: plan, generation: generation)
        }
    }

    /// The classic schedule: one repeating notification per slot, every day, forever.
    private func scheduleFixed(plan: SchedulePlan, generation: Int) async {
        // iOS keeps only the first 64 pending requests per app and drops the rest with no
        // error, so the cap is enforced here — where which slots survive is a decision —
        // rather than left to the system.
        for (index, offset) in plan.slotOffsets.prefix(Self.maxPendingRequests).enumerated() {
            guard isCurrent(generation) else { return }
            let minuteOfDay = (plan.startMinutes + offset) % SchedulePlan.minutesPerDay

            var dateComponents = DateComponents()
            dateComponents.hour = minuteOfDay / 60
            dateComponents.minute = minuteOfDay % 60

            let trigger = UNCalendarNotificationTrigger(dateMatching: dateComponents, repeats: true)
            await add(trigger: trigger, slot: index, messageIndex: index)
        }
    }

    /// Pace-aware schedule.
    ///
    /// Slots become one-shot so today's can be dropped individually when the user is
    /// already ahead: at a slot `f` of the way through the waking window you are
    /// "on pace" with `f * goal` logged, and a nudge to drink more would be noise.
    ///
    /// One-shots mean a finite horizon, so this re-arms every time the app comes to the
    /// foreground (see `HomeView`) as well as when water is logged. `maxPendingRequests`
    /// stays under the 64-notification cap iOS enforces per app, which a wide window and
    /// short interval can otherwise blow past.
    private func scheduleSmart(plan: SchedulePlan, snapshot: ScheduleSnapshot, generation: Int) async {
        let calendar = Calendar.current
        let now = Date()
        let today = calendar.startOfDay(for: now)
        var scheduled = 0

        for dayOffset in 0..<Self.horizonDays {
            guard let dayStart = calendar.date(byAdding: .day, value: dayOffset, to: today) else { continue }

            for (index, offset) in plan.slotOffsets.enumerated() {
                guard scheduled < Self.maxPendingRequests else { return }
                guard isCurrent(generation) else { return }

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
                    todayTotalML: snapshot.todayTotalML,
                    goalML: snapshot.goalML
                ) {
                    continue
                }

                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireDate)
                let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
                await add(trigger: trigger, slot: scheduled, messageIndex: index)
                scheduled += 1
            }
        }
    }

    /// True when intake already covers what this slot would nudge towards.
    ///
    /// The first slot of the window needs its own answer. Its expected fraction is zero,
    /// and "you have drunk at least nothing" is true of everyone, so the general formula
    /// silently dropped the opening nudge of the day even for a user who had drunk
    /// nothing at all. At that slot the only intake worth staying quiet for is the whole
    /// goal already being met.
    func isAheadOfPace(slotOffset: Int, windowLength: Int, todayTotalML: Int, goalML: Int) -> Bool {
        guard goalML > 0, windowLength > 0 else { return false }
        guard slotOffset > 0 else { return todayTotalML >= goalML }
        let expectedFraction = Double(slotOffset) / Double(windowLength)
        return Double(todayTotalML) >= Double(goalML) * expectedFraction
    }

    private func add(trigger: UNNotificationTrigger, slot: Int, messageIndex: Int) async {
        let content = UNMutableNotificationContent()
        content.title = "HydroDrop"
        content.body = Self.messages[messageIndex % Self.messages.count]
        content.sound = .default
        content.categoryIdentifier = categoryIdentifier

        do {
            try await center.add(UNNotificationRequest(
                identifier: identifier(forSlot: slot),
                content: content,
                trigger: trigger
            ))
        } catch {
            Diagnostics.log("failed to schedule reminder slot \(slot): \(error)")
        }
    }

    private func identifier(forSlot index: Int) -> String {
        "\(identifierPrefix)\(index)"
    }

    /// Days of one-shot reminders to keep armed in pace-aware mode.
    private static let horizonDays = 3
    /// Kept below the 64 pending notifications iOS allows a single app.
    static let maxPendingRequests = 60
}

/// The settings a rebuild runs against, captured at the moment it was requested.
struct ScheduleSnapshot: Sendable {
    let remindersEnabled: Bool
    let intervalMinutes: Int
    let startMinutes: Int
    let endMinutes: Int
    let smartRemindersActive: Bool
    let goalML: Int
    let todayTotalML: Int
}

/// The slot layout implied by the user's waking window and interval.
struct SchedulePlan {
    static let minutesPerDay = 24 * 60

    let startMinutes: Int
    let windowLength: Int
    let slotOffsets: [Int]

    init?(snapshot: ScheduleSnapshot) {
        self.init(
            startMinutes: snapshot.startMinutes,
            endMinutes: snapshot.endMinutes,
            intervalMinutes: snapshot.intervalMinutes
        )
    }

    init?(startMinutes start: Int, endMinutes end: Int, intervalMinutes: Int) {
        let interval = max(intervalMinutes, 5)

        // A start equal to its own end describes no window at all. Reading it as a full
        // 24 hours — which the wrap-around arithmetic below does if you let it — turns a
        // mis-set picker into reminders at 3am, so it produces no schedule instead.
        guard start != end else { return nil }

        // The window may wrap past midnight (e.g. 10pm...6am for a night-shift schedule).
        let length = end > start ? end - start : (Self.minutesPerDay - start) + end
        guard length > 0 else { return nil }

        self.startMinutes = start
        self.windowLength = length
        self.slotOffsets = Array(stride(from: 0, to: length, by: interval))
    }
}
