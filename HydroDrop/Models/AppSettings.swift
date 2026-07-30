import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

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
        static let frozenStreakDays = "frozenStreakDays"
        static let mascotSkin = "mascotSkin"
        static let smartRemindersEnabled = "smartRemindersEnabled"
    }

    static let reminderIntervalRange = 20...120

    @Published var dailyGoalML: Int {
        didSet { defaults.set(dailyGoalML, forKey: Keys.dailyGoalML) }
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

    /// Preset quick-add cup sizes shown on the home screen, in mL.
    let quickAddPresets: [Int] = [200, 330, 500]

    @Published var measurementSystem: MeasurementSystem {
        didSet { defaults.set(measurementSystem.rawValue, forKey: Keys.measurementSystem) }
    }

    /// Last-used inputs to the hydration goal calculator, so reopening it is pre-filled.
    @Published var weightKG: Double? {
        didSet {
            if let weightKG {
                defaults.set(weightKG, forKey: Keys.weightKG)
            } else {
                defaults.removeObject(forKey: Keys.weightKG)
            }
        }
    }

    @Published var biologicalSex: BiologicalSex? {
        didSet { defaults.set(biologicalSex?.rawValue, forKey: Keys.biologicalSex) }
    }

    @Published var activityLevel: ActivityLevel? {
        didSet { defaults.set(activityLevel?.rawValue, forKey: Keys.activityLevel) }
    }

    /// Start-of-day dates a HydroDrop+ streak freeze has been spent on.
    @Published var frozenStreakDays: [Date] {
        didSet { defaults.set(frozenStreakDays, forKey: Keys.frozenStreakDays) }
    }

    @Published var mascotSkin: MascotSkin {
        didSet { defaults.set(mascotSkin.rawValue, forKey: Keys.mascotSkin) }
    }

    /// Pace-aware reminders (HydroDrop+). Kept as plain state rather than reading
    /// `StoreManager` so `ReminderManager` can consult it off the main actor; the
    /// UI is responsible for only offering it to subscribers.
    @Published var smartRemindersEnabled: Bool {
        didSet {
            defaults.set(smartRemindersEnabled, forKey: Keys.smartRemindersEnabled)
            ReminderManager.shared.refreshSchedule()
        }
    }

    private init() {
        let d = UserDefaults.standard
        self.dailyGoalML = d.object(forKey: Keys.dailyGoalML) as? Int ?? 2000
        self.remindersEnabled = d.object(forKey: Keys.remindersEnabled) as? Bool ?? true
        if let savedMinutes = d.object(forKey: Keys.reminderIntervalMinutes) as? Int {
            self.reminderIntervalMinutes = savedMinutes
        } else if let legacyHours = d.object(forKey: "reminderIntervalHours") as? Double {
            self.reminderIntervalMinutes = Int(legacyHours * 60)
        } else {
            self.reminderIntervalMinutes = 120
        }
        if let savedStart = d.object(forKey: Keys.quietStartMinutes) as? Int {
            self.quietStartMinutes = savedStart
        } else if let legacyHour = d.object(forKey: Keys.legacyQuietStartHour) as? Int {
            self.quietStartMinutes = legacyHour * 60
        } else {
            self.quietStartMinutes = 8 * 60
        }
        if let savedEnd = d.object(forKey: Keys.quietEndMinutes) as? Int {
            self.quietEndMinutes = savedEnd
        } else if let legacyHour = d.object(forKey: Keys.legacyQuietEndHour) as? Int {
            self.quietEndMinutes = legacyHour * 60
        } else {
            self.quietEndMinutes = 22 * 60
        }
        if let raw = d.string(forKey: Keys.measurementSystem), let saved = MeasurementSystem(rawValue: raw) {
            self.measurementSystem = saved
        } else {
            self.measurementSystem = .deviceDefault
        }
        self.weightKG = d.object(forKey: Keys.weightKG) as? Double
        self.biologicalSex = (d.string(forKey: Keys.biologicalSex)).flatMap(BiologicalSex.init(rawValue:))
        self.activityLevel = (d.string(forKey: Keys.activityLevel)).flatMap(ActivityLevel.init(rawValue:))
        self.frozenStreakDays = d.array(forKey: Keys.frozenStreakDays) as? [Date] ?? []
        self.mascotSkin = (d.string(forKey: Keys.mascotSkin)).flatMap(MascotSkin.init(rawValue:)) ?? .classic
        self.smartRemindersEnabled = d.object(forKey: Keys.smartRemindersEnabled) as? Bool ?? false
    }
}
