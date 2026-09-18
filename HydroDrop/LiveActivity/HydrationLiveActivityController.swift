import ActivityKit
import Foundation

/// Starts, updates and ends the today's-progress Live Activity.
///
/// Every call is safe to make unconditionally: the entitlement, the user's preference
/// and the system permission are all checked here, so the callers on the logging paths
/// do not have to know whether an activity is wanted or even possible.
///
/// The activity begins with the day's first drink, follows every change after that, and
/// ends when the goal is reached or the waking window closes. It never survives into a
/// day it is not about.
@MainActor
enum HydrationLiveActivityController {
    /// Whether the system will let this app run one at all. The user can switch Live
    /// Activities off per app in iOS Settings.
    static var isSystemEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    private static var running: Activity<HydrationActivityAttributes>? {
        Activity<HydrationActivityAttributes>.activities.first
    }

    /// Brings the Live Activity into line with the day as it now stands.
    ///
    /// Starts one if the day has intake and none is running, updates the one that is,
    /// and ends it when the day is done with. Called from the same places that publish
    /// the widget snapshot, so there is one description of "the state changed".
    static func refresh(
        todayTotalML: Int,
        goalML: Int,
        settings: AppSettings,
        streak: Int,
        now: Date = Date(),
        calendar: Calendar = .current
    ) async {
        let today = DayKey.key(for: now, calendar: calendar)

        // An activity from an earlier day is about a day that has ended, whatever it
        // says on it.
        await endActivitiesNotAbout(today)

        guard settings.liveActivityActive, isSystemEnabled else {
            await endAll()
            return
        }

        let state = HydrationActivityAttributes.ContentState(
            todayTotalML: todayTotalML,
            goalML: goalML,
            measurementSystemRawValue: settings.measurementSystem.rawValue,
            mascotSkinRawValue: settings.activeMascotSkin.rawValue,
            streak: streak
        )

        // Nothing logged yet today: there is no progress to show anyone.
        guard todayTotalML > 0 else {
            await endAll()
            return
        }

        if todayTotalML >= goalML, goalML > 0 {
            // The goal is met. Show it for a moment, then let it go rather than leaving
            // a finished thing on the lock screen all evening.
            await end(state: state, dismissAfter: now.addingTimeInterval(120))
            return
        }

        if isPastWakingWindow(settings: settings, now: now, calendar: calendar) {
            await endAll()
            return
        }

        if let running {
            await running.update(ActivityContent(state: state, staleDate: staleDate(settings: settings, now: now, calendar: calendar)))
            return
        }
        start(state: state, dayKey: today, settings: settings, now: now, calendar: calendar)
    }

    private static func start(
        state: HydrationActivityAttributes.ContentState,
        dayKey: String,
        settings: AppSettings,
        now: Date,
        calendar: Calendar
    ) {
        do {
            _ = try Activity.request(
                attributes: HydrationActivityAttributes(dayKey: dayKey),
                content: ActivityContent(
                    state: state,
                    staleDate: staleDate(settings: settings, now: now, calendar: calendar)
                ),
                pushType: nil
            )
        } catch {
            Diagnostics.log("could not start the Live Activity: \(error)")
        }
    }

    static func endAll() async {
        for activity in Activity<HydrationActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    private static func end(state: HydrationActivityAttributes.ContentState, dismissAfter date: Date) async {
        for activity in Activity<HydrationActivityAttributes>.activities {
            await activity.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(date))
        }
    }

    private static func endActivitiesNotAbout(_ dayKey: String) async {
        for activity in Activity<HydrationActivityAttributes>.activities where activity.attributes.dayKey != dayKey {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// When the system should start showing the activity as out of date: the end of the
    /// waking window, which is also when HydroDrop stops having anything to say.
    private static func staleDate(settings: AppSettings, now: Date, calendar: Calendar) -> Date? {
        windowEnd(settings: settings, now: now, calendar: calendar)
    }

    private static func isPastWakingWindow(settings: AppSettings, now: Date, calendar: Calendar) -> Bool {
        guard let end = windowEnd(settings: settings, now: now, calendar: calendar) else { return false }
        return now >= end
    }

    /// The instant today's waking window closes, or nil when the window is unusable.
    ///
    /// An overnight window (say 10pm to 6am) closes on the following calendar day, which
    /// is why this is built by adding minutes to the start of today rather than by
    /// setting an hour on it.
    private static func windowEnd(settings: AppSettings, now: Date, calendar: Calendar) -> Date? {
        guard !settings.wakingWindowIsEmpty else { return nil }
        let startOfDay = calendar.startOfDay(for: now)
        let endMinutes = settings.quietEndMinutes > settings.quietStartMinutes
            ? settings.quietEndMinutes
            : settings.quietEndMinutes + SchedulePlan.minutesPerDay
        return calendar.date(byAdding: .minute, value: endMinutes, to: startOfDay)
    }
}
