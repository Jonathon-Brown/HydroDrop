import Foundation
import Combine

/// User preferences. Owned by the main actor: every property is read and written from
/// SwiftUI, and `ReminderManager` snapshots what it needs synchronously on the caller's
/// thread rather than reading these from a background callback.
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard
    /// Person-level settings go here: written locally *and* to iCloud key-value storage.
    /// Device-level settings (everything about reminders) stay in `defaults`.
    private let synced = CloudSettingsStore.shared

    /// Set while a remote change is being applied, so the property observers don't write
    /// the value straight back out and start a ping-pong between devices.
    private var isApplyingRemoteChange = false

    private enum Keys {
        static let dailyGoalML = "dailyGoalML"
        static let remindersEnabled = "remindersEnabled"
        static let reminderIntervalMinutes = "reminderIntervalMinutes"
        static let quietStartMinutes = "quietStartMinutes"
        static let quietEndMinutes = "quietEndMinutes"
        static let legacyQuietStartHour = "quietStartHour"
        static let legacyQuietEndHour = "quietEndHour"
        static let measurementSystem = "measurementSystem"
        static let weightKG = "weightKG"
        static let biologicalSex = "biologicalSex"
        static let activityLevel = "activityLevel"
        static let frozenStreakDayKeys = "frozenStreakDayKeys"
        static let legacyFrozenStreakDays = "frozenStreakDays"
        static let mascotSkin = "mascotSkin"
        static let smartRemindersEnabled = "smartRemindersEnabled"
    }

    static let reminderIntervalRange = 20...120

    /// Debug-only hook so screenshot automation starts from known preferences rather
    /// than whatever the last run left in the simulator. Without it the units and the
    /// mascot skin both persist between runs, and the capture test — which taps
    /// buttons by their "200 mL" labels — silently taps nothing once a run has
    /// switched the app to imperial. Compiled out of Release, matching `StoreManager`.
    private static var isScreenshotMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-UITestSeedHistory")
        #else
        false
        #endif
    }

    @Published var dailyGoalML: Int {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(dailyGoalML, forKey: Keys.dailyGoalML)
            // Pace-aware scheduling divides the goal across the day's slots, so a new
            // goal invalidates today's remaining nudges.
            ReminderManager.shared.refreshSchedule()
        }
    }

    @Published var remindersEnabled: Bool {
        didSet {
            defaults.set(remindersEnabled, forKey: Keys.remindersEnabled)
            ReminderManager.shared.refreshSchedule()
        }
    }

    /// How often, in minutes, to nudge the user during waking hours. 20...120.
    @Published var reminderIntervalMinutes: Int {
        didSet {
            defaults.set(reminderIntervalMinutes, forKey: Keys.reminderIntervalMinutes)
            ReminderManager.shared.refreshSchedule()
        }
    }

    /// Waking window during which reminders may fire, as minutes since midnight (0...1439).
    /// May wrap past midnight, e.g. start=1320 (10pm), end=360 (6am) for an overnight window.
    @Published var quietStartMinutes: Int {
        didSet {
            defaults.set(quietStartMinutes, forKey: Keys.quietStartMinutes)
            ReminderManager.shared.refreshSchedule()
        }
    }

    @Published var quietEndMinutes: Int {
        didSet {
            defaults.set(quietEndMinutes, forKey: Keys.quietEndMinutes)
            ReminderManager.shared.refreshSchedule()
        }
    }

    /// True when the waking window has no length at all, which is what a start equal to
    /// its own end means. Reminders are paused until the user separates the two — the
    /// alternative readings (nothing, or a 24-hour window that nudges at 3am) are both
    /// worse than saying so on screen.
    var wakingWindowIsEmpty: Bool {
        quietStartMinutes == quietEndMinutes
    }

    /// Preset quick-add cup sizes shown on the home screen, in mL.
    let quickAddPresets: [Int] = [200, 330, 500]

    @Published var measurementSystem: MeasurementSystem {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(measurementSystem.rawValue, forKey: Keys.measurementSystem)
        }
    }

    /// Last-used inputs to the hydration goal calculator, so reopening it is pre-filled.
    @Published var weightKG: Double? {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(weightKG, forKey: Keys.weightKG)
        }
    }

    @Published var biologicalSex: BiologicalSex? {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(biologicalSex?.rawValue, forKey: Keys.biologicalSex)
        }
    }

    @Published var activityLevel: ActivityLevel? {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(activityLevel?.rawValue, forKey: Keys.activityLevel)
        }
    }

    /// Days a HydroDrop+ streak freeze has been spent on, as `DayKey` strings.
    @Published var frozenStreakDayKeys: [String] {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(frozenStreakDayKeys, forKey: Keys.frozenStreakDayKeys)
        }
    }

    /// The skin the user picked. Not necessarily the one on screen — see `activeMascotSkin`.
    @Published var mascotSkin: MascotSkin {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(mascotSkin.rawValue, forKey: Keys.mascotSkin)
        }
    }

    /// The skin actually rendered, which falls back to `.classic` without an entitlement.
    ///
    /// The preference is deliberately left intact when Plus lapses: gating at the point
    /// of use means a resubscriber gets their skin back, and — more importantly — a
    /// lapse that happens between launches can't slip past a one-shot reset.
    var activeMascotSkin: MascotSkin {
        (mascotSkin.requiresPlus && !EntitlementCache.isPlusActive) ? .classic : mascotSkin
    }

    /// Pace-aware reminders (HydroDrop+), as the user set it. Gate reads on
    /// `smartRemindersActive`, never on this.
    @Published var smartRemindersEnabled: Bool {
        didSet {
            defaults.set(smartRemindersEnabled, forKey: Keys.smartRemindersEnabled)
            ReminderManager.shared.refreshSchedule()
        }
    }

    /// Whether pace-aware scheduling should actually be used: the preference *and* a
    /// live entitlement. `EntitlementCache` is a plain `UserDefaults` read, so this is
    /// safe to evaluate wherever the schedule is being built.
    var smartRemindersActive: Bool {
        smartRemindersEnabled && EntitlementCache.isPlusActive
    }

    /// Every stored property is assigned exactly once here, from a local computed above.
    ///
    /// A `didSet` is suppressed only for a property's *first* assignment inside an
    /// initialiser — assigning again later in the same init does fire it. The screenshot
    /// overrides used to be a second round of assignments, which meant they ran the
    /// observers; once one of those observers called back into `ReminderManager`, which
    /// reads `AppSettings.shared`, the singleton's one-time initialiser was re-entered
    /// from inside itself and the app deadlocked on launch. Computing first and assigning
    /// once removes the whole category.
    private init() {
        let d = UserDefaults.standard
        let screenshotMode = Self.isScreenshotMode

        let storedGoal = d.object(forKey: Keys.dailyGoalML) as? Int ?? 2000

        let storedInterval: Int
        if let savedMinutes = d.object(forKey: Keys.reminderIntervalMinutes) as? Int {
            storedInterval = savedMinutes
        } else if let legacyHours = d.object(forKey: "reminderIntervalHours") as? Double {
            storedInterval = Int(legacyHours * 60)
        } else {
            storedInterval = 120
        }

        let storedStart: Int
        if let savedStart = d.object(forKey: Keys.quietStartMinutes) as? Int {
            storedStart = savedStart
        } else if let legacyHour = d.object(forKey: Keys.legacyQuietStartHour) as? Int {
            storedStart = legacyHour * 60
        } else {
            storedStart = 8 * 60
        }

        let storedEnd: Int
        if let savedEnd = d.object(forKey: Keys.quietEndMinutes) as? Int {
            storedEnd = savedEnd
        } else if let legacyHour = d.object(forKey: Keys.legacyQuietEndHour) as? Int {
            storedEnd = legacyHour * 60
        } else {
            storedEnd = 22 * 60
        }

        let storedSystem: MeasurementSystem
        if let raw = d.string(forKey: Keys.measurementSystem), let saved = MeasurementSystem(rawValue: raw) {
            storedSystem = saved
        } else {
            storedSystem = .deviceDefault
        }

        let storedSkin = (d.string(forKey: Keys.mascotSkin)).flatMap(MascotSkin.init(rawValue:)) ?? .classic

        // Everything a captured screenshot actually shows, overridden in memory only —
        // nothing here writes over the defaults on disk.
        self.dailyGoalML = screenshotMode ? 2000 : storedGoal
        self.measurementSystem = screenshotMode ? .metric : storedSystem
        self.mascotSkin = screenshotMode ? .classic : storedSkin
        self.frozenStreakDayKeys = screenshotMode ? [] : Self.loadFrozenDayKeys(from: d)

        self.remindersEnabled = d.object(forKey: Keys.remindersEnabled) as? Bool ?? true
        self.reminderIntervalMinutes = storedInterval
        self.quietStartMinutes = storedStart
        self.quietEndMinutes = storedEnd
        self.weightKG = d.object(forKey: Keys.weightKG) as? Double
        self.biologicalSex = (d.string(forKey: Keys.biologicalSex)).flatMap(BiologicalSex.init(rawValue:))
        self.activityLevel = (d.string(forKey: Keys.activityLevel)).flatMap(ActivityLevel.init(rawValue:))
        self.smartRemindersEnabled = d.object(forKey: Keys.smartRemindersEnabled) as? Bool ?? false
    }

    /// Reads the day-key list, converting anything left by a version that stored
    /// `[Date]`. The conversion uses the current calendar because that is the timezone
    /// those instants were written in for all but the users this migration exists to
    /// rescue — and for them, any day key at all beats an instant that will never match.
    private static func loadFrozenDayKeys(from defaults: UserDefaults) -> [String] {
        if let keys = defaults.array(forKey: Keys.frozenStreakDayKeys) as? [String] {
            return keys
        }
        guard let legacyDates = defaults.array(forKey: Keys.legacyFrozenStreakDays) as? [Date] else {
            return []
        }
        let migrated = legacyDates.map { DayKey.key(for: $0) }
        defaults.set(migrated, forKey: Keys.frozenStreakDayKeys)
        defaults.removeObject(forKey: Keys.legacyFrozenStreakDays)
        return migrated
    }
}
