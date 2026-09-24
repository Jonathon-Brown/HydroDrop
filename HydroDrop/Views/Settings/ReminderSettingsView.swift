import SwiftUI
import UserNotifications

/// Whether to be reminded, how often, between which hours, and whether to skip a nudge
/// when the day is already on pace.
struct ReminderSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = StoreManager.shared
    @State private var notificationStatus: UNAuthorizationStatus = .notDetermined
    @State private var paywallSource: PaywallSource?
    /// The interval wheels are tall, so they fold away behind their row until asked
    /// for, the way the Calendar app treats its date pickers.
    @State private var showingIntervalWheel = false

    var body: some View {
        List {
            Section {
                Toggle("Reminders", isOn: $settings.remindersEnabled)
                    .onChange(of: settings.remindersEnabled) { _, enabled in
                        if enabled {
                            ReminderManager.shared.requestAuthorizationIfNeeded { granted in
                                notificationStatus = granted ? .authorized : .denied
                            }
                        }
                    }

                if settings.remindersEnabled && notificationStatus == .denied {
                    Label("Notifications are disabled in iOS Settings.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            } footer: {
                if !settings.remindersEnabled {
                    Text("A nudge to drink now and then, only between the hours you choose.")
                }
            }

            if settings.remindersEnabled {
                Section {
                    Button {
                        withAnimation { showingIntervalWheel.toggle() }
                    } label: {
                        LabeledContent("Remind me every") {
                            Text(intervalLabel)
                                .foregroundStyle(showingIntervalWheel ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        }
                        .foregroundStyle(Color.primary)
                    }
                    if showingIntervalWheel {
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

                    if settings.wakingWindowIsEmpty {
                        Label(
                            "Set an end time that differs from the start time, or reminders can't be scheduled.",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.footnote)
                        .foregroundStyle(.orange)
                    }
                } header: {
                    Text("Schedule")
                } footer: {
                    Text("You'll get a nudge every \(intervalLabel) between these times.")
                }

                Section {
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
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                } footer: {
                    Text("Smart reminders skip a nudge whenever you're already ahead of pace for the day.")
                }
            }
        }
        .navigationTitle("Reminders")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            let current = await UNUserNotificationCenter.current().notificationSettings()
            notificationStatus = current.authorizationStatus
        }
        .sheet(item: $paywallSource) { source in
            PaywallView(source: source)
        }
    }

    private var intervalLabel: String {
        DurationLabel.label(minutes: settings.reminderIntervalMinutes)
    }
}

#Preview {
    NavigationStack { ReminderSettingsView() }
        .environmentObject(AppSettings.shared)
}
