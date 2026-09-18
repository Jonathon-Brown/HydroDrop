import Foundation
import SwiftData

/// Recomputes the widget snapshot from the store and publishes it.
///
/// Called from every path that can change what a widget shows: the Today screen, a
/// drink logged from a notification action or from the watch, the onboarding first
/// sip, and the App Intents. Each of those already knows it has changed something;
/// none of them should have to know what a widget needs.
enum WidgetPublisher {
    /// Publishes from a context, reading the entries back so the total is whatever the
    /// store actually holds rather than whatever the caller thought it had just written.
    static func publish(
        context: ModelContext,
        settings: AppSettings = .shared,
        isShared: Bool,
        now: Date = Date()
    ) {
        let entries = (try? context.fetch(FetchDescriptor<WaterEntry>())) ?? []
        publish(entries: entries, settings: settings, isShared: isShared, now: now)
    }

    static func publish(
        entries: [WaterEntry],
        settings: AppSettings = .shared,
        isShared: Bool,
        now: Date = Date()
    ) {
        let calendar = Calendar.current
        let todayTotal = entries
            .filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
            .reduce(0) { $0 + $1.hydratedML }
        let streak = StreakCalculator.currentStreak(
            entries: entries,
            goalML: settings.dailyGoalML,
            frozenDayKeys: settings.frozenStreakDayKeys,
            now: now,
            calendar: calendar
        )
        WidgetBridge.publish(
            HydrationSnapshot(
                dayKey: DayKey.key(for: now, calendar: calendar),
                todayTotalML: todayTotal,
                dailyGoalML: settings.dailyGoalML,
                measurementSystemRawValue: settings.measurementSystem.rawValue,
                quickAddPresetsML: settings.quickAddPresets,
                streak: streak,
                mascotSkinRawValue: settings.activeMascotSkin.rawValue,
                canLogFromExtensions: isShared
            )
        )
    }
}
