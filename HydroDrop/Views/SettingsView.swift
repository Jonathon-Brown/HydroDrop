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
                            Text("\(settings.dailyGoalML) mL")
                                .foregroundStyle(.secondary)
                        }
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
                        Picker("Remind me every", selection: $settings.reminderIntervalHours) {
                            Text("1 hour").tag(1.0)
                            Text("1.5 hours").tag(1.5)
                            Text("2 hours").tag(2.0)
                            Text("3 hours").tag(3.0)
                            Text("4 hours").tag(4.0)
                        }

                        DatePicker(
                            "From",
                            selection: hourBinding(for: \.quietStartHour),
                            displayedComponents: .hourAndMinute
                        )
                        DatePicker(
                            "Until",
                            selection: hourBinding(for: \.quietEndHour),
                            displayedComponents: .hourAndMinute
                        )

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
                        Text("You'll get a nudge every \(intervalLabel) between the times above.")
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
                    LabeledContent("Version", value: "1.0 (prototype)")
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
        }
    }

    private var intervalLabel: String {
        let hours = settings.reminderIntervalHours
        return hours == 1 ? "hour" : "\(hours.formatted()) hours"
    }

    /// Bridges an Int "hour of day" setting to a DatePicker's Date binding.
    private func hourBinding(for keyPath: ReferenceWritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(
            get: {
                var components = DateComponents()
                components.hour = settings[keyPath: keyPath]
                components.minute = 0
                return Calendar.current.date(from: components) ?? Date()
            },
            set: { newDate in
                let hour = Calendar.current.component(.hour, from: newDate)
                settings[keyPath: keyPath] = hour
            }
        )
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
}
