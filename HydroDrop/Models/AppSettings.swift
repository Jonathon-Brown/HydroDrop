import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let dailyGoalML = "dailyGoalML"
        static let remindersEnabled = "remindersEnabled"
        static let reminderIntervalMinutes = "reminderIntervalMinutes"
        static let quietStartHour = "quietStartHour"
        static let quietEndHour = "quietEndHour"
        static let measurementSystem = "measurementSystem"
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

    /// Waking window during which reminders may fire, in 24h clock hours.
    @Published var quietStartHour: Int {
        didSet {
            defaults.set(quietStartHour, forKey: Keys.quietStartHour)
            ReminderManager.shared.refreshSchedule()
        }
    }

    @Published var quietEndHour: Int {
        didSet {
            defaults.set(quietEndHour, forKey: Keys.quietEndHour)
            ReminderManager.shared.refreshSchedule()
        }
    }

    /// Preset quick-add cup sizes shown on the home screen, in mL.
    let quickAddPresets: [Int] = [200, 330, 500]

    @Published var measurementSystem: MeasurementSystem {
        didSet { defaults.set(measurementSystem.rawValue, forKey: Keys.measurementSystem) }
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
        self.quietStartHour = d.object(forKey: Keys.quietStartHour) as? Int ?? 8
        self.quietEndHour = d.object(forKey: Keys.quietEndHour) as? Int ?? 22
        if let raw = d.string(forKey: Keys.measurementSystem), let saved = MeasurementSystem(rawValue: raw) {
            self.measurementSystem = saved
        } else {
            self.measurementSystem = .deviceDefault
        }
    }
}
