import SwiftUI
import UIKit
import UserNotifications
import StoreKit

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = StoreManager.shared
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var showingPaywall = false
    @State private var showingBugReport = false
    @State private var showingGoalCalculator = false

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
                            showingPaywall = true
                        } label: {
                            Label("Upgrade to HydroDrop+", systemImage: "sparkles")
                        }
                    }
                }

                Section("Daily goal") {
                    Stepper(value: $settings.dailyGoalML, in: 500...5000, step: 100) {
                        HStack {
                            Text("Goal")
                            Spacer()
                            Text(settings.measurementSystem.format(mL: settings.dailyGoalML))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Button {
                        showingGoalCalculator = true
                    } label: {
                        Label("Calculate for me", systemImage: "wand.and.stars")
                    }
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
                            selection: minuteOfDayBinding(for: \.quietStartMinutes),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            "Until",
                            selection: minuteOfDayBinding(for: \.quietEndMinutes),
                            displayedComponents: .hourAndMinute
                        )

                        if store.isSubscribed {
                            Toggle("Smart reminders", isOn: $settings.smartRemindersEnabled)
                        } else {
                            Button {
                                showingPaywall = true
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

                Section("Support") {
                    Button {
                        showingBugReport = true
                    } label: {
                        Label("Report a Bug", systemImage: "ladybug.fill")
                    }
                }

                Section("About") {
                    LabeledContent("App", value: "HydroDrop")
                    LabeledContent("Version", value: appVersionLabel)
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
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
            }
            .sheet(isPresented: $showingBugReport) {
                BugReportView()
            }
            .sheet(isPresented: $showingGoalCalculator) {
                GoalCalculatorView()
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
        }
    }

    private var freezesRemaining: Int {
        StreakFreeze.freezesRemaining(frozenDayKeys: settings.frozenStreakDayKeys)
    }

    /// Locked skins send the user to the paywall rather than silently doing nothing.
    private func selectSkin(_ skin: MascotSkin) {
        if skin.requiresPlus && !store.isSubscribed {
            showingPaywall = true
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
        let total = settings.reminderIntervalMinutes
        let hours = total / 60
        let minutes = total % 60
        switch (hours, minutes) {
        case (0, _):
            return "\(minutes) min"
        case (_, 0):
            return hours == 1 ? "1 hour" : "\(hours) hours"
        default:
            return "\(hours) hr \(minutes) min"
        }
    }

    /// Bridges an Int "minutes since midnight" setting to a DatePicker's Date binding.
    private func minuteOfDayBinding(for keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                let totalMinutes = settings[keyPath: keyPath]
                var components = DateComponents()
                components.hour = totalMinutes / 60
                components.minute = totalMinutes % 60
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let comps = Calendar.current.dateComponents([.hour, .minute], from: newDate)
                settings[keyPath: keyPath] = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
            }
        )
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
}
