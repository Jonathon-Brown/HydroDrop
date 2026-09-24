import SwiftUI
import SwiftData

/// The HydroDrop+ features that are switches: the weekly recap, the extra-water
/// suggestions, the Live Activity and caffeine tracking.
///
/// Each follows the pattern the smart-reminders row set: a real control for
/// subscribers, and a locked row that opens the paywall for everyone else. Each group
/// explains itself underneath, rather than one paragraph covering all of them.
struct SmartFeaturesSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var store = StoreManager.shared
    @State private var paywallSource: PaywallSource?
    @State private var showingWeeklyRecap = false
    @State private var locationMessage: String?

    var body: some View {
        List {
            Section {
                if store.isSubscribed {
                    Toggle("Weekly recap", isOn: $settings.weeklyRecapEnabled)
                    Button {
                        showingWeeklyRecap = true
                    } label: {
                        Label("See this week's recap", systemImage: "calendar")
                    }
                } else {
                    lockedRow("Weekly recap")
                }
            } header: {
                Text("Your week")
            } footer: {
                Text("A look back at your week, sent on Sunday evening while reminders are on.")
            }

            Section {
                if store.isSubscribed {
                    Toggle("Hot day suggestions", isOn: weatherToggleBinding)
                    // Rests on Health access, which is only ever asked for from Insights.
                    Toggle("Workout suggestions", isOn: $settings.workoutGoalEnabled)
                        .disabled(!HealthInsightsReader.isConnected)
                } else {
                    lockedRow("Hot day suggestions")
                    lockedRow("Workout suggestions")
                }
            } header: {
                Text("Extra water")
            } footer: {
                Text(extraWaterFooter)
            }

            Section {
                if store.isSubscribed {
                    Toggle("Live Activity", isOn: $settings.liveActivityEnabled)
                } else {
                    lockedRow("Live Activity")
                }
            } header: {
                Text("Lock Screen")
            } footer: {
                Text("Today's progress on your Lock Screen. It starts with your first drink and ends when you reach your goal.")
            }

            // Caffeine is off until switched on, and shown nowhere until it is.
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
        .navigationTitle("Smart features")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $paywallSource) { source in
            PaywallView(source: source)
        }
        .sheet(isPresented: $showingWeeklyRecap) {
            WeeklyRecapView()
                .environmentObject(settings)
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
    }

    private var extraWaterFooter: String {
        let workouts = store.isSubscribed && !HealthInsightsReader.isConnected
            ? "Workout suggestions need Apple Health, which you connect from Insights, in History."
            : "Workout suggestions, off until you turn them on, offer extra water on a day you exercised for 20 minutes or more."
        return "Hot day suggestions use your location to check the weather. \(workouts) Both only ever offer extra water for that day; your saved goal and your streak never change on their own."
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
}

#Preview {
    NavigationStack { SmartFeaturesSettingsView() }
        .environmentObject(AppSettings.shared)
}
