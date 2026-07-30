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
                            Task { try? await AppStore.showManageSubscriptions(in: UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!) }
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
                                Circle()
                                    .fill(skin.ramp[3])
                                    .frame(width: 24, height: 24)
                                Text(skin.label)
                                    .foregroundStyle(.primary)
                                Spacer()
                                if settings.mascotSkin == skin {
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
                        Text("HydroDrop+ unlocks every mascot colour.")
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
        }
    }

    private var freezesRemaining: Int {
        StreakFreeze.freezesRemaining(frozenDays: settings.frozenStreakDays)
    }

    /// Locked skins send the user to the paywall rather than silently doing nothing.
    private func selectSkin(_ skin: MascotSkin) {
        if skin.requiresPlus && !store.isSubscribed {
            showingPaywall = true
        } else {
            settings.mascotSkin = skin
        }
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
