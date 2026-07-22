import Foundation
import Combine

final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let dailyGoalML = "dailyGoalML"
        static let remindersEnabled = "remindersEnabled"
        static let reminderIntervalHours = "reminderIntervalHours"
        static let quietStartHour = "quietStartHour"
        static let quietEndHour = "quietEndHour"
    }

    @Published var dailyGoalML: Int {
        didSet { defaults.set(dailyGoalML, forKey: Keys.dailyGoalML) }
    }

    @Published var remindersEnabled: Bool {
        didSet {
            defaults.set(remindersEnabled, forKey: Keys.remindersEnabled)
            ReminderManager.shared.refreshSchedule()
        }
    }

    /// How often, in hours, to nudge the user during waking hours.
    @Published var reminderIntervalHours: Double {
        didSet {
            defaults.set(reminderIntervalHours, forKey: Keys.reminderIntervalHours)
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

    private init() {
        let d = UserDefaults.standard
        self.dailyGoalML = d.object(forKey: Keys.dailyGoalML) as? Int ?? 2000
        self.remindersEnabled = d.object(forKey: Keys.remindersEnabled) as? Bool ?? true
        self.reminderIntervalHours = d.object(forKey: Keys.reminderIntervalHours) as? Double ?? 2.0
        self.quietStartHour = d.object(forKey: Keys.quietStartHour) as? Int ?? 8
        self.quietEndHour = d.object(forKey: Keys.quietEndHour) as? Int ?? 22
    }
}
