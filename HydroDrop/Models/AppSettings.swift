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
        static let hasCompletedOnboarding = "hasCompletedOnboarding"
        static let customQuickAddPresets = "customQuickAddPresets"
        static let celebratedMilestones = "celebratedMilestones"
        static let hasSeededMilestones = "hasSeededMilestones"
        static let worldDecorations = "worldDecorations"
        static let celebratedWorldStages = "celebratedWorldStages"
        static let hasSeededWorld = "hasSeededWorld"
        static let worldGoalDaysRecord = "worldGoalDaysRecord"
        static let healthKitSyncEnabled = "healthKitSyncEnabled"
        static let healthSyncStartDate = "healthSyncStartDate"
        static let weeklyRecapEnabled = "weeklyRecapEnabled"
        static let weatherGoalEnabled = "weatherGoalEnabled"
        static let workoutGoalEnabled = "workoutGoalEnabled"
        static let workoutBumpAnsweredDayKey = "workoutBumpAnsweredDayKey"
        static let liveActivityEnabled = "liveActivityEnabled"
        static let weatherBumpDayKey = "weatherBumpDayKey"
        static let weatherBumpML = "weatherBumpML"
        static let weatherBumpDismissedDayKey = "weatherBumpDismissedDayKey"
        static let caffeineTrackingEnabled = "caffeineTrackingEnabled"
        static let caffeineCutoffMinutes = "caffeineCutoffMinutes"
    }

    static let reminderIntervalRange = 20...120

    /// Debug-only hook so screenshot automation starts from known preferences rather
    /// than whatever the last run left in the simulator. Without it the units and the
    /// mascot skin both persist between runs, and the capture test — which taps
    /// buttons by their "200 mL" labels — silently taps nothing once a run has
    /// switched the app to imperial. Compiled out of Release, matching `StoreManager`.
    static var isScreenshotMode: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-UITestSeedHistory")
        #else
        false
        #endif
    }

    /// UI tests that drive the tab bar on a fresh simulator would otherwise start
    /// underneath first-launch onboarding. In memory only, and compiled out of Release.
    private static var isSkippingOnboardingForUITests: Bool {
        #if DEBUG
        ProcessInfo.processInfo.arguments.contains("-UITestSkipOnboarding")
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

    /// The three quick-add cup sizes shown on the home screen, in mL.
    ///
    /// nil means "whatever suits the unit system", which is how every install starts
    /// and what a reset goes back to: an imperial user then gets 8, 12 and 16 oz
    /// rather than the metric sizes converted. Once the user edits a slot their sizes
    /// are kept verbatim, including across a change of units, because at that point
    /// the numbers are theirs and not ours to round.
    @Published var customQuickAddPresetsML: [Int]? {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(customQuickAddPresetsML, forKey: Keys.customQuickAddPresets)
            // The "Log a glass" notification button names the first preset.
            ReminderManager.shared.registerCategories()
        }
    }

    /// Preset quick-add cup sizes shown on the home screen, in mL.
    var quickAddPresets: [Int] {
        Self.sanitisedPresets(customQuickAddPresetsML) ?? measurementSystem.defaultQuickAddPresetsML
    }

    static let quickAddSlotCount = 3

    /// A stored preset list is only usable if it has the right shape and plausible
    /// amounts. Anything else (a truncated write, a value from a future version) falls
    /// back to the defaults rather than putting a nonsense button on the home screen.
    private static func sanitisedPresets(_ presets: [Int]?) -> [Int]? {
        guard let presets, presets.count == quickAddSlotCount else { return nil }
        let range = MeasurementSystem.plausibleDrinkRangeML
        guard presets.allSatisfy(range.contains) else { return nil }
        return presets
    }

    /// Replaces one quick-add slot, seeding the other two from whatever is on screen
    /// now so the first edit doesn't blank the rest.
    func setQuickAddPreset(_ amountML: Int, at index: Int) {
        var presets = quickAddPresets
        guard presets.indices.contains(index) else { return }
        presets[index] = amountML
        customQuickAddPresetsML = presets
    }

    /// Whether first-launch onboarding has been finished (or skipped) on this account.
    ///
    /// Person-level and synced, so a second device usually inherits the answer. Set
    /// once in the initialiser for every install that predates onboarding, and again by
    /// `completeOnboardingIfExistingUser(entryCount:)` once the store has been opened,
    /// so nobody who already has history is shown the intro.
    @Published var hasCompletedOnboarding: Bool {
        didSet {
            guard !isApplyingRemoteChange else { return }
            Self.persistOnboarding(hasCompletedOnboarding, synced: synced, local: defaults)
        }
    }

    /// Only a `true` ever reaches iCloud. A fresh install's "not yet" is a fact about
    /// that device; written to the cloud it would be mirrored down onto a device that
    /// finished the intro long ago and reopen it there on the next launch.
    private static func persistOnboarding(_ completed: Bool, synced: CloudSettingsStore, local: UserDefaults) {
        if completed {
            synced.set(true, forKey: Keys.hasCompletedOnboarding)
        } else {
            local.set(false, forKey: Keys.hasCompletedOnboarding)
        }
    }

    @Published var measurementSystem: MeasurementSystem {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(measurementSystem.rawValue, forKey: Keys.measurementSystem)
            // The "Log a glass" notification button names an amount in these units.
            ReminderManager.shared.registerCategories()
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

    /// Streak milestones the user has earned, in days.
    ///
    /// The record of what has been *awarded*, not a recomputation of what today's
    /// history would justify: goals change, and a badge someone earned at a lower goal
    /// is still theirs. Merged as a union across devices for the same reason.
    @Published var celebratedMilestones: [Int] {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(celebratedMilestones, forKey: Keys.celebratedMilestones)
        }
    }

    /// Whether the badge shelf has been filled in from the history that existed before
    /// milestones did. Stops an upgrading user being handed a stack of celebrations for
    /// streaks they finished months ago.
    @Published var hasSeededMilestones: Bool {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(hasSeededMilestones, forKey: Keys.hasSeededMilestones)
        }
    }

    /// Awards every milestone `longestStreak` has already passed, silently.
    ///
    /// Runs once per person. Anything reached after this earns its celebration in the
    /// usual way.
    func seedMilestones(longestStreak: Int) {
        guard !hasSeededMilestones else { return }
        let earned = StreakMilestone.reached(by: longestStreak).map(\.days)
        celebratedMilestones = Array(Set(celebratedMilestones).union(earned)).sorted()
        hasSeededMilestones = true
    }

    /// Records a milestone as earned. Idempotent, so a celebration shown twice by two
    /// devices still leaves one badge.
    func recordMilestone(_ milestone: StreakMilestone) {
        guard !celebratedMilestones.contains(milestone.days) else { return }
        celebratedMilestones = (celebratedMilestones + [milestone.days]).sorted()
    }

    // MARK: The droplet's world

    /// Decorations switched on in the world, as `WorldDecoration` raw values. Kept with
    /// the mascot skin, and like it, a choice rather than an entitlement: see
    /// `activeWorldDecorations` for what is actually drawn.
    @Published var worldDecorations: [String] {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(worldDecorations, forKey: Keys.worldDecorations)
        }
    }

    /// The chosen decorations the entitlement covers. Derived at the point of use, so a
    /// lapse hides the paid ones and a resubscription brings them straight back.
    var activeWorldDecorations: [WorldDecoration] {
        #if DEBUG
        if WorldDebug.showsAllDecorations { return WorldDecoration.allCases }
        #endif
        return WorldDecoration.active(from: worldDecorations, isPlusActive: EntitlementCache.isPlusActive)
    }

    func toggle(_ decoration: WorldDecoration) {
        if worldDecorations.contains(decoration.rawValue) {
            worldDecorations.removeAll { $0 == decoration.rawValue }
        } else {
            worldDecorations.append(decoration.rawValue)
        }
    }

    /// World stages whose arrival has been marked, as goal-day counts. A union across
    /// devices, like milestones, so the same stage is never announced twice.
    @Published var celebratedWorldStages: [Int] {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(celebratedWorldStages, forKey: Keys.celebratedWorldStages)
        }
    }

    /// Whether the stages already reached by the history that existed before the world
    /// did have been marked quietly. Without it, everyone updating would be greeted by
    /// an announcement about days they finished months ago.
    @Published var hasSeededWorld: Bool {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(hasSeededWorld, forKey: Keys.hasSeededWorld)
        }
    }

    /// The most goal days this person has ever had. The world is worked out from the log
    /// against today's goal, so a raised goal or a deleted drink could shrink the count.
    /// Growth never decreases, and this is what holds it up.
    @Published var worldGoalDaysRecord: Int {
        didSet {
            guard !isApplyingRemoteChange else { return }
            synced.set(worldGoalDaysRecord, forKey: Keys.worldGoalDaysRecord)
        }
    }

    /// Notes what the world has grown to. Marks every stage already reached the first
    /// time it runs, silently, and keeps the record of goal days from ever going down.
    func noteWorld(goalDays: Int) {
        if goalDays > worldGoalDaysRecord { worldGoalDaysRecord = goalDays }
        guard !hasSeededWorld else { return }
        let reached = WorldStage.allCases.filter { $0.goalDays <= goalDays }.map(\.goalDays)
        celebratedWorldStages = Array(Set(celebratedWorldStages).union(reached)).sorted()
        hasSeededWorld = true
    }

    func recordWorldStage(_ stage: WorldStage) {
        guard !celebratedWorldStages.contains(stage.goalDays) else { return }
        celebratedWorldStages = (celebratedWorldStages + [stage.goalDays]).sorted()
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

    /// Whether drinks are mirrored into Apple Health.
    ///
    /// Device-level and deliberately not synced: Health authorization is granted per
    /// device, and a phone that has been given permission cannot grant it on behalf of
    /// an iPad that has not.
    @Published var healthKitSyncEnabled: Bool {
        didSet {
            defaults.set(healthKitSyncEnabled, forKey: Keys.healthKitSyncEnabled)
        }
    }

    /// The earliest drink eligible to be written to Health.
    ///
    /// Set to the moment sync is switched on, so turning it on does not silently hand
    /// Health a year of history nobody asked it to hold. Moved back to the distant past
    /// only when the user explicitly asks for their existing drinks to be added.
    @Published var healthSyncStartDate: Date {
        didSet {
            defaults.set(healthSyncStartDate, forKey: Keys.healthSyncStartDate)
        }
    }

    /// Whether the user has already had their history written to Health.
    var hasBackfilledHealth: Bool {
        healthSyncStartDate <= Date.distantPast
    }

    /// Pace-aware reminders (HydroDrop+), as the user set it. Gate reads on
    /// `smartRemindersActive`, never on this.
    @Published var smartRemindersEnabled: Bool {
        didSet {
            defaults.set(smartRemindersEnabled, forKey: Keys.smartRemindersEnabled)
            ReminderManager.shared.refreshSchedule()
        }
    }

    // MARK: - HydroDrop+ smart features
    //
    // All three follow the pattern `smartRemindersEnabled` established: the stored
    // preference is what the user set, and the `...Active` computed property is the
    // preference *and* a live entitlement. Gate behaviour on the latter, never the
    // former, so a lapsed subscription stops the feature without erasing the choice.

    /// Sunday evening recap of the week just gone.
    @Published var weeklyRecapEnabled: Bool {
        didSet {
            defaults.set(weeklyRecapEnabled, forKey: Keys.weeklyRecapEnabled)
            WeeklyRecapNotifier.shared.refresh()
        }
    }

    var weeklyRecapActive: Bool { weeklyRecapEnabled && EntitlementCache.isPlusActive }

    /// Suggesting extra water on a hot day. Off until asked for, because it is the one
    /// feature here that wants the user's location.
    @Published var weatherGoalEnabled: Bool {
        didSet {
            defaults.set(weatherGoalEnabled, forKey: Keys.weatherGoalEnabled)
            if !weatherGoalEnabled { clearWeatherBump() }
        }
    }

    var weatherGoalActive: Bool { weatherGoalEnabled && EntitlementCache.isPlusActive }

    /// Whether to suggest extra water after a workout. Device-level, like the hot-day
    /// switch: it rests on Health access, which is granted per device.
    @Published var workoutGoalEnabled: Bool {
        didSet { defaults.set(workoutGoalEnabled, forKey: Keys.workoutGoalEnabled) }
    }

    /// On, entitled, and Health has been connected through Insights, which is the only
    /// place HydroDrop ever asks to read anything.
    var workoutGoalActive: Bool {
        workoutGoalEnabled && EntitlementCache.isPlusActive && HealthInsightsReader.isConnected
    }

    /// The day the workout suggestion was last answered, yes or no. One a day at most.
    @Published private(set) var workoutBumpAnsweredDayKey: String

    func markWorkoutBumpAnswered(now: Date = Date()) {
        workoutBumpAnsweredDayKey = DayKey.key(for: now)
        defaults.set(workoutBumpAnsweredDayKey, forKey: Keys.workoutBumpAnsweredDayKey)
    }

    func hasAnsweredWorkoutBump(now: Date = Date()) -> Bool {
        workoutBumpAnsweredDayKey == DayKey.key(for: now)
    }

    // MARK: Caffeine

    /// Whether the person asked to see their caffeine. Off until they turn it on, and
    /// per device like the other display choices.
    @Published var caffeineTrackingEnabled: Bool {
        didSet { defaults.set(caffeineTrackingEnabled, forKey: Keys.caffeineTrackingEnabled) }
    }

    /// After this time of day a caffeinated drink gets a gentle note. Minutes since
    /// midnight, 0...1439.
    @Published var caffeineCutoffMinutes: Int {
        didSet { defaults.set(caffeineCutoffMinutes, forKey: Keys.caffeineCutoffMinutes) }
    }

    /// Caffeine is a HydroDrop+ feature, so the switch alone is not enough.
    var caffeineTrackingActive: Bool { caffeineTrackingEnabled && EntitlementCache.isPlusActive }

    /// Today's progress on the Lock Screen while the day is in progress.
    @Published var liveActivityEnabled: Bool {
        didSet {
            defaults.set(liveActivityEnabled, forKey: Keys.liveActivityEnabled)
        }
    }

    var liveActivityActive: Bool { liveActivityEnabled && EntitlementCache.isPlusActive }

    // MARK: Weather bump

    /// The day an accepted weather bump applies to, and how much it adds.
    ///
    /// Device-level and one day long by design. A suggestion accepted on a hot Tuesday
    /// is about Tuesday, and the saved goal is never touched: `dailyGoalML` is what the
    /// user chose, and this rides on top of it for the day.
    @Published private(set) var weatherBumpDayKey: String
    @Published private(set) var weatherBumpML: Int
    /// A suggestion the user waved away, so it is not offered again the same day.
    @Published private(set) var weatherBumpDismissedDayKey: String

    /// Today's target: the saved goal plus an accepted bump, if there is one for today.
    ///
    /// Used for what is on screen and for pacing the day's reminders. Streaks
    /// deliberately still count at `dailyGoalML`: the bump is advice for one hot day,
    /// and accepting advice should never be what breaks a streak.
    func todayGoalML(now: Date = Date()) -> Int {
        guard weatherBumpDayKey == DayKey.key(for: now), weatherBumpML > 0 else { return dailyGoalML }
        return min(dailyGoalML + weatherBumpML, MeasurementSystem.storedGoalRangeML.upperBound)
    }

    func acceptWeatherBump(_ amountML: Int, now: Date = Date()) {
        weatherBumpDayKey = DayKey.key(for: now)
        weatherBumpML = max(0, amountML)
        defaults.set(weatherBumpDayKey, forKey: Keys.weatherBumpDayKey)
        defaults.set(weatherBumpML, forKey: Keys.weatherBumpML)
    }

    /// Adds to whatever extra has already been accepted today, for any reason, and
    /// never past the daily cap. The heat, the morning after a Night Out and anything
    /// later all share this one today-only amount, which is why the streak never has to
    /// know about any of them.
    func addToTodayBump(_ amountML: Int, now: Date = Date()) {
        let accepted = weatherBumpDayKey == DayKey.key(for: now) ? weatherBumpML : 0
        acceptWeatherBump(TodayBump.total(alreadyAcceptedML: accepted, adding: amountML), now: now)
    }

    func dismissWeatherBump(now: Date = Date()) {
        weatherBumpDismissedDayKey = DayKey.key(for: now)
        defaults.set(weatherBumpDismissedDayKey, forKey: Keys.weatherBumpDismissedDayKey)
    }

    func hasDismissedWeatherBump(now: Date = Date()) -> Bool {
        weatherBumpDismissedDayKey == DayKey.key(for: now)
    }

    private func clearWeatherBump() {
        weatherBumpDayKey = ""
        weatherBumpML = 0
        defaults.removeObject(forKey: Keys.weatherBumpDayKey)
        defaults.removeObject(forKey: Keys.weatherBumpML)
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
        let synced = CloudSettingsStore.shared
        let screenshotMode = Self.isScreenshotMode

        let storedGoal = synced.int(forKey: Keys.dailyGoalML) ?? 2000

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
        if let raw = synced.string(forKey: Keys.measurementSystem), let saved = MeasurementSystem(rawValue: raw) {
            storedSystem = saved
        } else {
            storedSystem = .deviceDefault
        }

        let storedSkin = synced.string(forKey: Keys.mascotSkin).flatMap(MascotSkin.init(rawValue:)) ?? .classic

        // Anyone who installed before onboarding existed has no stored answer, and must
        // not be shown the intro. Any trace of an earlier launch counts: a stored goal
        // or unit system (which the first cloud sync seeds for every existing user), a
        // touched reminder setting, or the entitlement cache `StoreManager` writes on
        // every launch. A fresh install has none of these when this runs.
        let storedOnboarding: Bool
        let onboardingNeedsPersisting: Bool
        if let answer = synced.bool(forKey: Keys.hasCompletedOnboarding) {
            storedOnboarding = answer
            onboardingNeedsPersisting = false
        } else {
            let earlierLaunchKeys = [
                Keys.dailyGoalML, Keys.measurementSystem, Keys.mascotSkin, Keys.weightKG,
                Keys.remindersEnabled, Keys.reminderIntervalMinutes, "reminderIntervalHours",
                Keys.quietStartMinutes, Keys.quietEndMinutes,
                Keys.legacyQuietStartHour, Keys.legacyQuietEndHour,
                Keys.smartRemindersEnabled, Keys.legacyFrozenStreakDays,
                "plus.entitlementActive", "watch.seenLogIdentifiers",
            ]
            let looksLikeExistingUser = earlierLaunchKeys.contains { key in
                synced.object(forKey: key) != nil || d.object(forKey: key) != nil
            } || !(synced.stringArray(forKey: Keys.frozenStreakDayKeys) ?? []).isEmpty
            storedOnboarding = looksLikeExistingUser
            onboardingNeedsPersisting = true
        }

        // Everything a captured screenshot actually shows, overridden in memory only —
        // nothing here writes over the defaults on disk.
        self.dailyGoalML = screenshotMode ? 2000 : storedGoal
        self.measurementSystem = screenshotMode ? .metric : storedSystem
        self.mascotSkin = screenshotMode ? .classic : storedSkin
        self.frozenStreakDayKeys = screenshotMode ? [] : Self.loadFrozenDayKeys(synced: synced, local: d)

        self.remindersEnabled = d.object(forKey: Keys.remindersEnabled) as? Bool ?? true
        self.reminderIntervalMinutes = storedInterval
        self.quietStartMinutes = storedStart
        self.quietEndMinutes = storedEnd
        self.weightKG = synced.double(forKey: Keys.weightKG)
        self.biologicalSex = synced.string(forKey: Keys.biologicalSex).flatMap(BiologicalSex.init(rawValue:))
        self.activityLevel = synced.string(forKey: Keys.activityLevel).flatMap(ActivityLevel.init(rawValue:))
        self.smartRemindersEnabled = d.object(forKey: Keys.smartRemindersEnabled) as? Bool ?? false
        self.healthKitSyncEnabled = d.object(forKey: Keys.healthKitSyncEnabled) as? Bool ?? false
        self.healthSyncStartDate = d.object(forKey: Keys.healthSyncStartDate) as? Date ?? Date()
        // On for subscribers who have not said otherwise; the weather one stays off
        // until asked for, because it is the one that wants a location.
        self.weeklyRecapEnabled = d.object(forKey: Keys.weeklyRecapEnabled) as? Bool ?? true
        self.weatherGoalEnabled = d.object(forKey: Keys.weatherGoalEnabled) as? Bool ?? false
        // Off until it is turned on. Connecting Insights is a yes to seeing patterns, and
        // a card appearing on Today after a run is a separate thing to say yes to.
        self.workoutGoalEnabled = d.object(forKey: Keys.workoutGoalEnabled) as? Bool ?? false
        self.workoutBumpAnsweredDayKey = d.string(forKey: Keys.workoutBumpAnsweredDayKey) ?? ""
        self.caffeineTrackingEnabled = d.object(forKey: Keys.caffeineTrackingEnabled) as? Bool ?? false
        self.caffeineCutoffMinutes = d.object(forKey: Keys.caffeineCutoffMinutes) as? Int ?? CaffeineCutoff.defaultMinutes
        self.liveActivityEnabled = d.object(forKey: Keys.liveActivityEnabled) as? Bool ?? true
        self.weatherBumpDayKey = d.string(forKey: Keys.weatherBumpDayKey) ?? ""
        self.weatherBumpML = d.object(forKey: Keys.weatherBumpML) as? Int ?? 0
        self.weatherBumpDismissedDayKey = d.string(forKey: Keys.weatherBumpDismissedDayKey) ?? ""
        self.hasCompletedOnboarding = (screenshotMode || Self.isSkippingOnboardingForUITests) ? true : storedOnboarding
        // Screenshot automation taps buttons by their "200 mL" labels, so it has to
        // start from the suggested sizes rather than whatever a previous run stored.
        self.customQuickAddPresetsML = screenshotMode ? nil : synced.intArray(forKey: Keys.customQuickAddPresets)
        // Screenshot runs start with a clean shelf, so a capture never depends on what
        // a previous run happened to earn.
        self.celebratedMilestones = screenshotMode ? [] : (synced.intArray(forKey: Keys.celebratedMilestones) ?? [])
        self.hasSeededMilestones = screenshotMode ? true : (synced.bool(forKey: Keys.hasSeededMilestones) ?? false)
        // A screenshot run gets a bare, already-announced world: nothing chosen, and no
        // "your world grew" sheet landing on top of the buttons the run is about to tap.
        self.worldDecorations = screenshotMode ? [] : (synced.stringArray(forKey: Keys.worldDecorations) ?? [])
        self.celebratedWorldStages = screenshotMode
            ? WorldStage.allCases.map(\.goalDays)
            : (synced.intArray(forKey: Keys.celebratedWorldStages) ?? [])
        self.hasSeededWorld = screenshotMode ? true : (synced.bool(forKey: Keys.hasSeededWorld) ?? false)
        self.worldGoalDaysRecord = screenshotMode ? 0 : (synced.int(forKey: Keys.worldGoalDaysRecord) ?? 0)

        // Written now rather than left to the observer: a first-launch decision of
        // "not yet" has to survive the cloud seeding that follows, which would otherwise
        // make the next launch read this install as a pre-onboarding one.
        if onboardingNeedsPersisting && !screenshotMode && !Self.isSkippingOnboardingForUITests {
            Self.persistOnboarding(storedOnboarding, synced: synced, local: d)
        }
    }

    /// Marks onboarding complete for an install that already has water logged.
    ///
    /// The initialiser can only see preferences; the entries live in the store, which
    /// is opened afterwards. A user restoring from iCloud onto a new phone has history
    /// and nothing else, and is exactly who this catches.
    func completeOnboardingIfExistingUser(entryCount: Int) {
        guard !hasCompletedOnboarding, entryCount > 0 else { return }
        hasCompletedOnboarding = true
    }

    /// Reads the day-key list, converting anything left by a version that stored
    /// `[Date]`. The conversion uses the current calendar because that is the timezone
    /// those instants were written in for all but the users this migration exists to
    /// rescue — and for them, any day key at all beats an instant that will never match.
    private static func loadFrozenDayKeys(synced: CloudSettingsStore, local: UserDefaults) -> [String] {
        if let keys = synced.stringArray(forKey: Keys.frozenStreakDayKeys) {
            return keys
        }
        guard let legacyDates = local.array(forKey: Keys.legacyFrozenStreakDays) as? [Date] else {
            return []
        }
        let migrated = legacyDates.map { DayKey.key(for: $0) }
        synced.set(migrated, forKey: Keys.frozenStreakDayKeys)
        local.removeObject(forKey: Keys.legacyFrozenStreakDays)
        return migrated
    }

    // MARK: - iCloud

    /// Person-level keys, i.e. the ones that follow the user rather than the device.
    private static let syncedKeys = [
        Keys.dailyGoalML,
        Keys.measurementSystem,
        Keys.mascotSkin,
        Keys.frozenStreakDayKeys,
        Keys.weightKG,
        Keys.biologicalSex,
        Keys.activityLevel,
        Keys.hasCompletedOnboarding,
        Keys.customQuickAddPresets,
        Keys.celebratedMilestones,
        Keys.hasSeededMilestones,
        Keys.worldDecorations,
        Keys.celebratedWorldStages,
        Keys.hasSeededWorld,
        Keys.worldGoalDaysRecord,
    ]

    /// Starts mirroring person-level settings through iCloud.
    ///
    /// Called from `HydroDropApp.init` rather than from this initialiser: anything that
    /// can call back into `AppSettings.shared` must not run while `AppSettings.shared` is
    /// still being constructed.
    func startCloudSync() {
        guard !Self.isScreenshotMode else { return }
        seedCloudFromLocalIfNeeded()
        synced.startObserving { [weak self] keys in
            self?.applyRemoteChanges(keys)
        }
    }

    /// Pushes this device's existing settings up the first time, so upgrading users
    /// don't start out looking like a device with no preferences at all. Only fills keys
    /// iCloud has no value for, so it can never overwrite another device's answer.
    private func seedCloudFromLocalIfNeeded() {
        for key in Self.syncedKeys where !synced.hasCloudValue(forKey: key) {
            switch key {
            case Keys.dailyGoalML: synced.set(dailyGoalML, forKey: key)
            case Keys.measurementSystem: synced.set(measurementSystem.rawValue, forKey: key)
            case Keys.mascotSkin: synced.set(mascotSkin.rawValue, forKey: key)
            case Keys.frozenStreakDayKeys: synced.set(frozenStreakDayKeys, forKey: key)
            case Keys.weightKG: synced.set(weightKG, forKey: key)
            case Keys.biologicalSex: synced.set(biologicalSex?.rawValue, forKey: key)
            case Keys.activityLevel: synced.set(activityLevel?.rawValue, forKey: key)
            case Keys.hasCompletedOnboarding: if hasCompletedOnboarding { synced.set(true, forKey: key) }
            case Keys.customQuickAddPresets: synced.set(customQuickAddPresetsML, forKey: key)
            case Keys.celebratedMilestones: synced.set(celebratedMilestones, forKey: key)
            case Keys.hasSeededMilestones: synced.set(hasSeededMilestones, forKey: key)
            case Keys.worldDecorations: synced.set(worldDecorations, forKey: key)
            case Keys.celebratedWorldStages: synced.set(celebratedWorldStages, forKey: key)
            case Keys.hasSeededWorld: synced.set(hasSeededWorld, forKey: key)
            case Keys.worldGoalDaysRecord: synced.set(worldGoalDaysRecord, forKey: key)
            default: break
            }
        }
    }

    /// Applies an edit made on another device.
    ///
    /// Scalars are last-writer-wins, which is what key-value storage already gives us.
    /// The freeze ledger is not: it is merged, because two devices can each legitimately
    /// have spent a freeze the other hasn't seen, and a plain overwrite would either lose
    /// one or leave the month over its allowance.
    private func applyRemoteChanges(_ keys: [String]) {
        let changed = Set(keys)
        var freezesToPublish: [String]?
        var milestonesToPublish: [Int]?
        var worldStagesToPublish: [Int]?
        var worldRecordToPublish: Int?

        isApplyingRemoteChange = true
        if changed.contains(Keys.dailyGoalML), let goal = synced.int(forKey: Keys.dailyGoalML) {
            dailyGoalML = goal
        }
        if changed.contains(Keys.measurementSystem),
           let raw = synced.string(forKey: Keys.measurementSystem),
           let system = MeasurementSystem(rawValue: raw) {
            measurementSystem = system
        }
        if changed.contains(Keys.mascotSkin),
           let raw = synced.string(forKey: Keys.mascotSkin),
           let skin = MascotSkin(rawValue: raw) {
            mascotSkin = skin
        }
        if changed.contains(Keys.weightKG) {
            weightKG = synced.double(forKey: Keys.weightKG)
        }
        if changed.contains(Keys.biologicalSex) {
            biologicalSex = synced.string(forKey: Keys.biologicalSex).flatMap(BiologicalSex.init(rawValue:))
        }
        if changed.contains(Keys.activityLevel) {
            activityLevel = synced.string(forKey: Keys.activityLevel).flatMap(ActivityLevel.init(rawValue:))
        }
        // Only ever promoted to true: another device finishing the intro should close it
        // here, but nothing remote should reopen it.
        if changed.contains(Keys.hasCompletedOnboarding), synced.bool(forKey: Keys.hasCompletedOnboarding) == true {
            hasCompletedOnboarding = true
        }
        if changed.contains(Keys.customQuickAddPresets) {
            customQuickAddPresetsML = synced.intArray(forKey: Keys.customQuickAddPresets)
        }
        // A union, never an overwrite: two devices can each have awarded a badge the
        // other has not seen, and a badge is never taken back.
        if changed.contains(Keys.celebratedMilestones) {
            let remote = synced.intArray(forKey: Keys.celebratedMilestones) ?? []
            let merged = Array(Set(celebratedMilestones).union(remote)).sorted()
            celebratedMilestones = merged
            if merged != remote { milestonesToPublish = merged }
        }
        if changed.contains(Keys.hasSeededMilestones), synced.bool(forKey: Keys.hasSeededMilestones) == true {
            hasSeededMilestones = true
        }
        // Decorations are a choice, so the newest choice wins. What has been announced
        // and how far the world has grown only ever accumulate.
        if changed.contains(Keys.worldDecorations) {
            worldDecorations = synced.stringArray(forKey: Keys.worldDecorations) ?? []
        }
        if changed.contains(Keys.celebratedWorldStages) {
            let remote = synced.intArray(forKey: Keys.celebratedWorldStages) ?? []
            let merged = Array(Set(celebratedWorldStages).union(remote)).sorted()
            celebratedWorldStages = merged
            if merged != remote { worldStagesToPublish = merged }
        }
        if changed.contains(Keys.hasSeededWorld), synced.bool(forKey: Keys.hasSeededWorld) == true {
            hasSeededWorld = true
        }
        if changed.contains(Keys.worldGoalDaysRecord) {
            let remote = synced.int(forKey: Keys.worldGoalDaysRecord) ?? 0
            let larger = max(worldGoalDaysRecord, remote)
            worldGoalDaysRecord = larger
            if larger != remote { worldRecordToPublish = larger }
        }
        if changed.contains(Keys.frozenStreakDayKeys) {
            let remote = synced.stringArray(forKey: Keys.frozenStreakDayKeys) ?? []
            let merged = StreakFreeze.merged(frozenStreakDayKeys, remote)
            frozenStreakDayKeys = merged
            // Only write back when the merge actually knows something iCloud doesn't;
            // otherwise two devices would answer each other forever.
            if merged != remote { freezesToPublish = merged }
        }
        isApplyingRemoteChange = false

        if let freezesToPublish {
            synced.set(freezesToPublish, forKey: Keys.frozenStreakDayKeys)
        }
        if let milestonesToPublish {
            synced.set(milestonesToPublish, forKey: Keys.celebratedMilestones)
        }
        if let worldStagesToPublish {
            synced.set(worldStagesToPublish, forKey: Keys.celebratedWorldStages)
        }
        if let worldRecordToPublish {
            synced.set(worldRecordToPublish, forKey: Keys.worldGoalDaysRecord)
        }
        if changed.contains(Keys.dailyGoalML) {
            // Pace-aware scheduling is keyed to the goal that just changed underneath it.
            ReminderManager.shared.refreshSchedule()
        }
        // Both of these name the amount on the "Log a glass" button. The observers that
        // would normally do this are suppressed while a remote change is being applied.
        if changed.contains(Keys.customQuickAddPresets) || changed.contains(Keys.measurementSystem) {
            ReminderManager.shared.registerCategories()
        }
    }
}
