import SwiftUI
import SwiftData
import UIKit
import UserNotifications
import StoreKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var store = StoreManager.shared
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var paywallSource: PaywallSource?
    @State private var showingEventCounts = false
    @State private var showingBugReport = false
    @State private var showingGoalCalculator = false
    @State private var showingIntroReplay = false
    @State private var editingPreset: PresetSlot?
    @State private var healthAuthorizationMessage: String?
    @State private var showingBackfillConfirmation = false
    @State private var isSyncingHealth = false
    @State private var showingWeeklyRecap = false
    @State private var locationMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if store.isSubscribed {
                        Label("HydroDrop+ is active", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(.green)
                        Button("Manage Subscription") {
                            Task { await presentManageSubscriptions() }
                        }
                    } else {
                        Button {
                            paywallSource = .settingsRow
                        } label: {
                            Label("Upgrade to HydroDrop+", systemImage: "sparkles")
                        }
                    }
                }

                Section("Daily goal") {
                    GoalStepper(goalML: $settings.dailyGoalML, system: settings.measurementSystem)
                    Button {
                        showingGoalCalculator = true
                    } label: {
                        Label("Calculate for me", systemImage: "wand.and.stars")
                    }
                }

                Section {
                    ForEach(Array(settings.quickAddPresets.enumerated()), id: \.offset) { index, amount in
                        Button {
                            editingPreset = PresetSlot(index: index, amountML: amount)
                        } label: {
                            HStack {
                                Image(systemName: "drop.fill")
                                    .foregroundStyle(.blue)
                                Text("Button \(index + 1)")
                                    .foregroundStyle(.primary)
                                Spacer()
                                Text(settings.measurementSystem.format(mL: amount))
                                    .foregroundStyle(.secondary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.tertiary)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    if settings.customQuickAddPresetsML != nil {
                        Button("Use suggested sizes") {
                            settings.customQuickAddPresetsML = nil
                        }
                    }
                } header: {
                    Text("Quick add")
                } footer: {
                    Text("The three buttons on the Today screen, and the size the Log a glass reminder button adds.")
                }

                if BottleTagSession.showsInterface {
                    Section {
                        NavigationLink {
                            BottlesView()
                        } label: {
                            Label("My Bottles", systemImage: "waterbottle.fill")
                        }
                    } footer: {
                        Text("Put an NFC sticker on a bottle, tap your iPhone to it, and a full bottle is logged.")
                    }
                }

                Section {
                    NavigationLink {
                        DuoView()
                    } label: {
                        Label("Duo Streaks", systemImage: "person.2.fill")
                    }
                } footer: {
                    Text("Keep one streak with one other person. It grows on the days you both meet your goal.")
                }

                Section("Units") {
                    Picker("Measurement system", selection: $settings.measurementSystem) {
                        ForEach(MeasurementSystem.allCases) { system in
                            Text(system.label).tag(system)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    ForEach(MascotSkin.allCases) { skin in
                        Button {
                            selectSkin(skin)
                        } label: {
                            HStack(spacing: 12) {
                                // A still mascot rather than a swatch — the charms are
                                // half of what separates the skins, and a dot hides them.
                                MascotView(progress: 1.0, size: 30, skin: skin, isAnimated: false)
                                    // Decorative here. Left visible it prefixes every
                                    // row with "Fully hydrated!", which says nothing
                                    // about the skin being chosen.
                                    .accessibilityHidden(true)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(skin.label)
                                        .foregroundStyle(.primary)
                                    Text(skin.tagline)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                if settings.activeMascotSkin == skin {
                                    Image(systemName: "checkmark")
                                        .foregroundStyle(.tint)
                                } else if skin.requiresPlus && !store.isSubscribed {
                                    Image(systemName: "lock.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .contentShape(Rectangle())
                        }
                        // Without this the Form tints the whole row like a link,
                        // which reads as an action rather than a selection list.
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("Mascot")
                } footer: {
                    if !store.isSubscribed {
                        Text("HydroDrop+ unlocks every mascot skin.")
                    }
                }

                Section {
                    Toggle("Reminders", isOn: $settings.remindersEnabled)
                        .onChange(of: settings.remindersEnabled) { _, enabled in
                            if enabled {
                                ReminderManager.shared.requestAuthorizationIfNeeded { granted in
                                    notificationStatus = granted ? .authorized : .denied
                                }
                            }
                        }

                    if settings.remindersEnabled {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Remind me every")
                            DurationWheelPicker(
                                totalMinutes: $settings.reminderIntervalMinutes,
                                range: AppSettings.reminderIntervalRange
                            )
                        }

                        DatePicker(
                            "From",
                            selection: MinuteOfDay.dateBinding($settings.quietStartMinutes),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            "Until",
                            selection: MinuteOfDay.dateBinding($settings.quietEndMinutes),
                            displayedComponents: .hourAndMinute
                        )

                        if store.isSubscribed {
                            Toggle("Smart reminders", isOn: $settings.smartRemindersEnabled)
                        } else {
                            Button {
                                paywallSource = .settingsLockedReminder
                            } label: {
                                HStack {
                                    Text("Smart reminders")
                                        .foregroundStyle(.primary)
                                    Spacer()
                                    Image(systemName: "lock.fill")
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }

                        if settings.wakingWindowIsEmpty {
                            Label(
                                "Set an end time that differs from the start time, or reminders can't be scheduled.",
                                systemImage: "exclamationmark.triangle.fill"
                            )
                            .font(.footnote)
                            .foregroundStyle(.orange)
                        }

                        if notificationStatus == .denied {
                            Label("Notifications are disabled in iOS Settings.", systemImage: "exclamationmark.triangle.fill")
                                .font(.footnote)
                                .foregroundStyle(.orange)
                        }
                    }
                } header: {
                    Text("Reminders")
                } footer: {
                    if settings.remindersEnabled {
                        if settings.smartRemindersEnabled && store.isSubscribed {
                            Text("Nudges every \(intervalLabel) between the times above, skipped whenever you're already ahead of pace for the day.")
                        } else {
                            Text("You'll get a nudge every \(intervalLabel) between the times above.")
                        }
                    }
                }

                if store.isSubscribed {
                    Section {
                        LabeledContent("Freezes left this month", value: "\(freezesRemaining) of \(StreakFreeze.monthlyAllowance)")
                    } header: {
                        Text("Streak freeze")
                    } footer: {
                        Text("If you miss a day, a freeze is spent automatically to keep your streak alive.")
                    }
                }

                smartSection

                caffeineSection

                if HealthKitManager.isAvailable {
                    healthSection
                }

                Section("Support") {
                    Button {
                        showingBugReport = true
                    } label: {
                        Label("Report a Bug", systemImage: "ladybug.fill")
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "HydroDrop")
                    Button {
                        showingIntroReplay = true
                    } label: {
                        Label("Replay intro", systemImage: "play.circle")
                    }
                    NavigationLink {
                        WeatherDataSourcesView()
                    } label: {
                        Label("Apple Weather", systemImage: "cloud.sun")
                    }
                    LabeledContent("Version", value: appVersionLabel)
                        .contentShape(Rectangle())
                        // Hidden way into the on-device paywall counts. Does nothing in
                        // App Store builds; see `EventCountsView.isAvailable`.
                        .onLongPressGesture(minimumDuration: 1.5) {
                            Task {
                                if await EventCountsView.isAvailable {
                                    showingEventCounts = true
                                }
                            }
                        }
                }
            }
            .navigationTitle("Settings")
            .task {
                let current = await UNUserNotificationCenter.current().notificationSettings()
                notificationStatus = current.authorizationStatus
                // Permission can be taken away in iOS Settings while the app is
                // backgrounded, and granted back the same way. Rebuilding here means the
                // schedule matches the permission the user actually left us with.
                ReminderManager.shared.refreshSchedule()
            }
            .sheet(item: $paywallSource) { source in
                PaywallView(source: source)
            }
            .sheet(isPresented: $showingEventCounts) {
                EventCountsView()
            }
            .sheet(isPresented: $showingBugReport) {
                BugReportView()
            }
            .sheet(isPresented: $showingGoalCalculator) {
                GoalCalculatorView()
            }
            .alert(
                "Apple Health",
                isPresented: Binding(
                    get: { healthAuthorizationMessage != nil },
                    set: { if !$0 { healthAuthorizationMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { healthAuthorizationMessage = nil }
            } message: {
                Text(healthAuthorizationMessage ?? "")
            }
            .confirmationDialog(
                "Add your existing drinks to Apple Health?",
                isPresented: $showingBackfillConfirmation,
                titleVisibility: .visible
            ) {
                Button("Add them") { backfillHealth() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every drink you have logged in HydroDrop will be added to Health as dietary water. You can remove them again in the Health app at any time.")
            }
            .alert(
                "Location",
                isPresented: Binding(
                    get: { locationMessage != nil },
                    set: { if !$0 { locationMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { locationMessage = nil }
            } message: {
                Text(locationMessage ?? "")
            }
            .sheet(isPresented: $showingWeeklyRecap) {
                WeeklyRecapView()
                    .environmentObject(settings)
            }
            .sheet(item: $editingPreset) { slot in
                QuickAddPresetSheet(slot: slot) { amountML in
                    settings.setQuickAddPreset(amountML, at: slot.index)
                }
                .environmentObject(settings)
            }
            .fullScreenCover(isPresented: $showingIntroReplay) {
                OnboardingView(mode: .replay) {
                    showingIntroReplay = false
                }
                .environmentObject(settings)
            }
            // Same alert the paywall shows for purchase and restore failures. Gated on
            // the entitlement because only the subscribed branch of this screen can set
            // the message (Manage Subscription); the paywall sheet presents its own copy
            // for the unsubscribed flows, and two views presenting the same error at
            // once is one too many.
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { store.isSubscribed && store.lastErrorMessage != nil },
                    set: { if !$0 { store.lastErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { store.lastErrorMessage = nil }
            } message: {
                Text(store.lastErrorMessage ?? "")
            }
            // The daily goal, the unit system and the quick-add sizes all appear on the
            // widget, and none of them flow through a store write that would republish
            // on their own. Republish whenever one changes so the widget matches Settings
            // immediately rather than at the next logged drink or foreground.
            .onChange(of: settings.dailyGoalML) { _, _ in republishWidget() }
            .onChange(of: settings.measurementSystem) { _, _ in republishWidget() }
            .onChange(of: settings.quickAddPresets) { _, _ in republishWidget() }
        }
    }

    /// Recomputes the widget snapshot from the store after a settings change the widget
    /// renders. The totals come straight back out of the store rather than being carried
    /// in, so a goal or unit change never disturbs today's count.
    private func republishWidget() {
        WidgetPublisher.publish(
            context: modelContext,
            isShared: SharedModelContainer.isShared(modelContext.container)
        )
    }

    // MARK: - HydroDrop+ smart features

    /// The three Plus features, each following the pattern the smart-reminders row
    /// already set: a real control for subscribers, and a locked row that opens the
    /// paywall for everyone else.
    @ViewBuilder
    /// Caffeine is HydroDrop+, off until switched on, and shown nowhere until it is.
    private var caffeineSection: some View {
        Section {
            if store.isSubscribed {
                Toggle("Caffeine tracking", isOn: caffeineToggleBinding)
                if settings.caffeineTrackingEnabled {
                    DatePicker(
                        "No caffeine after",
                        selection: caffeineCutoffBinding,
                        displayedComponents: .hourAndMinute
                    )
                }
            } else {
                lockedRow("Caffeine tracking")
            }
        } header: {
            Text("Caffeine")
        } footer: {
            Text("Shows today's caffeine on Today, with a gentle note if a drink lands after the time you pick. The figures are typical ones, not a lab result.")
        }
    }

    /// Turning it on is the one moment Health is asked about caffeine, and only if
    /// Health sync is already on. A no is fine: the total still shows in HydroDrop, and
    /// nothing is written to Health.
    private var caffeineToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.caffeineTrackingEnabled },
            set: { isOn in
                settings.caffeineTrackingEnabled = isOn
                guard isOn, settings.healthKitSyncEnabled else { return }
                Task { @MainActor in
                    _ = await HealthKitManager.shared.requestAuthorization(includingCaffeine: true)
                    await HealthKitManager.shared.reconcile(context: modelContext, settings: settings)
                }
            }
        )
    }

    private var caffeineCutoffBinding: Binding<Date> {
        Binding(
            get: {
                let minutes = settings.caffeineCutoffMinutes
                return Calendar.current.date(
                    bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()
                ) ?? Date()
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings.caffeineCutoffMinutes = (parts.hour ?? 14) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var smartSection: some View {
        Section {
            if store.isSubscribed {
                Toggle("Weekly recap", isOn: $settings.weeklyRecapEnabled)
                Button {
                    showingWeeklyRecap = true
                } label: {
                    Label("See this week's recap", systemImage: "calendar")
                }

                Toggle("Hot day suggestions", isOn: weatherToggleBinding)

                // Rests on Health access, which is only ever asked for from Insights.
                Toggle("Workout suggestions", isOn: $settings.workoutGoalEnabled)
                    .disabled(!HealthInsightsReader.isConnected)

                Toggle("Live Activity", isOn: $settings.liveActivityEnabled)
            } else {
                lockedRow("Weekly recap")
                lockedRow("Hot day suggestions")
                lockedRow("Workout suggestions")
                lockedRow("Live Activity")
            }
        } header: {
            Text("Smart features")
        } footer: {
            Text(smartFooter)
        }
    }

    private var smartFooter: String {
        guard store.isSubscribed else {
            return "HydroDrop+ adds a Sunday recap of your week, a suggestion to drink more on hot days, and today's progress on your Lock Screen."
        }
        let workouts = HealthInsightsReader.isConnected
            ? "Workout suggestions, off until you turn them on, offer extra water on a day you exercised for 20 minutes or more."
            : "Workout suggestions need Apple Health, which you connect from Insights, in History."
        return "The recap arrives on Sunday evening. Hot day suggestions use your location to check the weather. \(workouts) Both only ever offer extra water for that day; your saved goal and your streak never change on their own. The Live Activity starts with your first drink and ends when you reach your goal."
    }

    private func lockedRow(_ title: String) -> some View {
        Button {
            paywallSource = .settingsLockedSmartFeature
        } label: {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Turning hot day suggestions on asks for location first and only commits once
    /// permission is granted, for the same reason the Health toggle does.
    private var weatherToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.weatherGoalEnabled },
            set: { wantsOn in
                guard wantsOn else {
                    settings.weatherGoalEnabled = false
                    return
                }
                Task { @MainActor in
                    switch await WeatherGoalAdvisor.shared.requestLocationAccess() {
                    case .granted:
                        settings.weatherGoalEnabled = true
                    case .denied:
                        settings.weatherGoalEnabled = false
                        locationMessage = "HydroDrop needs your location to check the weather where you are. You can allow it in iOS Settings, under Privacy and Security, Location Services, HydroDrop."
                    case .failed(let reason):
                        settings.weatherGoalEnabled = false
                        locationMessage = reason
                    }
                }
            }
        )
    }

    // MARK: - Apple Health

    @ViewBuilder
    private var healthSection: some View {
        Section {
            Toggle("Sync to Apple Health", isOn: healthToggleBinding)

            if settings.healthKitSyncEnabled {
                if settings.hasBackfilledHealth {
                    Label("Your earlier drinks have been added.", systemImage: "checkmark.circle")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Button {
                        showingBackfillConfirmation = true
                    } label: {
                        Label("Add past drinks to Health", systemImage: "clock.arrow.circlepath")
                    }
                    .disabled(isSyncingHealth)
                }
            }
        } header: {
            Text("Apple Health")
        } footer: {
            Text(healthFooter)
        }
    }

    private var healthFooter: String {
        if settings.healthKitSyncEnabled {
            return "New drinks are added to Health as dietary water, using the amount HydroDrop counts, so a coffee adds what it actually hydrates. Deleting or editing a drink here updates Health too. Turning this off leaves whatever is already there in place. HydroDrop reads from Health only if you connect Insights, in History."
        }
        return "Off by default. When on, the drinks you log are added to Health as dietary water. This only writes. HydroDrop reads from Health only if you connect Insights, in History, and nothing is sent to us either way."
    }

    /// Turning the toggle on asks Health for permission first, and only commits the
    /// setting once permission is actually granted. Flipping a switch that then does
    /// nothing is worse than the switch refusing to move.
    private var healthToggleBinding: Binding<Bool> {
        Binding(
            get: { settings.healthKitSyncEnabled },
            set: { wantsOn in
                if wantsOn {
                    enableHealthSync()
                } else {
                    settings.healthKitSyncEnabled = false
                }
            }
        )
    }

    private func enableHealthSync() {
        isSyncingHealth = true
        Task { @MainActor in
            defer { isSyncingHealth = false }
            switch await HealthKitManager.shared.requestAuthorization(includingCaffeine: settings.caffeineTrackingActive) {
            case .granted:
                // Only from here on. Turning sync on is not a request to hand Health
                // everything logged before it.
                settings.healthSyncStartDate = Date()
                settings.healthKitSyncEnabled = true
                await HealthKitManager.shared.reconcile(context: modelContext, settings: settings)
            case .denied:
                settings.healthKitSyncEnabled = false
                healthAuthorizationMessage = "HydroDrop needs permission to add water to Health. You can grant it in the Health app, under Sharing, Apps and Services, HydroDrop."
            case .unavailable:
                settings.healthKitSyncEnabled = false
                healthAuthorizationMessage = "Apple Health is not available on this device."
            case .failed(let reason):
                settings.healthKitSyncEnabled = false
                healthAuthorizationMessage = reason
            }
        }
    }

    private func backfillHealth() {
        isSyncingHealth = true
        Task { @MainActor in
            defer { isSyncingHealth = false }
            settings.healthSyncStartDate = .distantPast
            await HealthKitManager.shared.reconcile(context: modelContext, settings: settings)
        }
    }

    private var freezesRemaining: Int {
        StreakFreeze.freezesRemaining(frozenDayKeys: settings.frozenStreakDayKeys)
    }

    /// Locked skins send the user to the paywall rather than silently doing nothing.
    private func selectSkin(_ skin: MascotSkin) {
        if skin.requiresPlus && !store.isSubscribed {
            paywallSource = .settingsLockedSkin
        } else {
            settings.mascotSkin = skin
        }
    }

    /// Presents the App Store's manage-subscriptions sheet. Both ways this used to fail
    /// were silent: `try?` dropped whatever the sheet threw, and a missing window scene
    /// returned without a word — the "button does nothing" reported against 1.0 and
    /// 1.0.1. Errors now surface through `store.lastErrorMessage`, the alert path the
    /// paywall already uses, and with no scene to host the sheet the same page opens in
    /// the App Store app instead.
    @MainActor
    private func presentManageSubscriptions() async {
        guard let scene = activeWindowScene else {
            await openSubscriptionsInAppStore()
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            store.lastErrorMessage = error.localizedDescription
        }
    }

    /// The foreground scene when there is one, otherwise any connected window scene.
    private var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Fallback for when no window scene can host the sheet: the same subscriptions
    /// page, opened in the App Store app.
    @MainActor
    private func openSubscriptionsInAppStore() async {
        if let url = URL(string: "https://apps.apple.com/account/subscriptions"),
           await UIApplication.shared.open(url) {
            return
        }
        store.lastErrorMessage = "Couldn't open your subscriptions. "
            + "You can manage them in Settings > Apple Account > Subscriptions."
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    private var intervalLabel: String {
        DurationLabel.label(minutes: settings.reminderIntervalMinutes)
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
}

/// One of the three quick-add buttons, identified by its position.
struct PresetSlot: Identifiable {
    let index: Int
    let amountML: Int
    var id: Int { index }
}

/// Sets the size of a single quick-add button.
private struct QuickAddPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let slot: PresetSlot
    let onSave: (Int) -> Void

    @State private var amountML: Int

    init(slot: PresetSlot, onSave: @escaping (Int) -> Void) {
        self.slot = slot
        self.onSave = onSave
        _amountML = State(initialValue: slot.amountML)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                AmountPicker(amountML: $amountML, system: settings.measurementSystem)
                Spacer()
            }
            .padding()
            .navigationTitle("Quick add \(slot.index + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(amountML)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}
