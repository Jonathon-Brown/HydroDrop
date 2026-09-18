import Foundation
import WidgetKit

/// Everything a widget needs to draw itself, as one small value in shared storage.
///
/// The widget renders from this rather than opening the SwiftData store. A timeline
/// refresh happens often and runs under a tight memory budget, and spinning up a
/// CloudKit-backed store to add up a handful of rows is the wrong shape of work for
/// it. The store is still opened from an extension, but only when the user actually
/// taps the quick-add button.
struct HydrationSnapshot: Codable, Equatable {
    /// The day `todayTotalML` belongs to. A snapshot written yesterday is not wrong,
    /// it is simply about yesterday, and `resolved` is what turns that into a zero.
    var dayKey: String
    var todayTotalML: Int
    var dailyGoalML: Int
    var measurementSystemRawValue: String
    var quickAddPresetsML: [Int]
    var streak: Int
    var mascotSkinRawValue: String
    /// Whether the app is running against the shared store. False means the migration
    /// into the App Group has not happened or did not work, and an extension must not
    /// try to log anything.
    var canLogFromExtensions: Bool

    static let placeholder = HydrationSnapshot(
        dayKey: DayKey.key(for: Date()),
        todayTotalML: 1_200,
        dailyGoalML: 2_000,
        measurementSystemRawValue: MeasurementSystem.deviceDefault.rawValue,
        quickAddPresetsML: MeasurementSystem.deviceDefault.defaultQuickAddPresetsML,
        streak: 4,
        mascotSkinRawValue: MascotSkin.classic.rawValue,
        canLogFromExtensions: true
    )

    /// What a widget should show before the app has ever published anything.
    static let empty = HydrationSnapshot(
        dayKey: DayKey.key(for: Date()),
        todayTotalML: 0,
        dailyGoalML: 2_000,
        measurementSystemRawValue: MeasurementSystem.deviceDefault.rawValue,
        quickAddPresetsML: MeasurementSystem.deviceDefault.defaultQuickAddPresetsML,
        streak: 0,
        mascotSkinRawValue: MascotSkin.classic.rawValue,
        canLogFromExtensions: false
    )

    var measurementSystem: MeasurementSystem {
        MeasurementSystem(rawValue: measurementSystemRawValue) ?? .deviceDefault
    }

    var mascotSkin: MascotSkin {
        MascotSkin(rawValue: mascotSkinRawValue) ?? .classic
    }

    var progress: Double {
        guard dailyGoalML > 0 else { return 0 }
        return Double(todayTotalML) / Double(dailyGoalML)
    }

    /// The snapshot as of `now`, which zeroes a total that belongs to an earlier day.
    ///
    /// A widget can be asked to render long after the app last ran, and showing
    /// yesterday's intake as today's is worse than showing nothing.
    func resolved(now: Date = Date()) -> HydrationSnapshot {
        guard dayKey != DayKey.key(for: now) else { return self }
        var rolled = self
        rolled.dayKey = DayKey.key(for: now)
        rolled.todayTotalML = 0
        return rolled
    }
}

/// Reads and writes the snapshot, and pokes WidgetKit when it changes.
enum WidgetBridge {
    private static let snapshotKey = "widget.hydrationSnapshot"

    /// The most recent snapshot the app published, already rolled forward if the day
    /// has turned over since.
    static func currentSnapshot(now: Date = Date()) -> HydrationSnapshot {
        guard let data = AppGroup.defaults?.data(forKey: snapshotKey),
              let snapshot = try? JSONDecoder().decode(HydrationSnapshot.self, from: data) else {
            return .empty
        }
        return snapshot.resolved(now: now)
    }

    /// Stores the snapshot and reloads the timelines, but only when something actually
    /// changed: a reload costs the system a render, and widgets have a refresh budget.
    static func publish(_ snapshot: HydrationSnapshot) {
        guard let defaults = AppGroup.defaults else { return }
        if let existing = defaults.data(forKey: snapshotKey),
           let previous = try? JSONDecoder().decode(HydrationSnapshot.self, from: existing),
           previous == snapshot {
            return
        }
        guard let data = try? JSONEncoder().encode(snapshot) else {
            Diagnostics.log("could not encode the widget snapshot")
            return
        }
        defaults.set(data, forKey: snapshotKey)
        reloadTimelines()
    }

    static func reloadTimelines() {
        WidgetCenter.shared.reloadAllTimelines()
    }
}
