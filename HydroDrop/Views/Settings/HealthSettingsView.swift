import SwiftUI
import SwiftData

/// Writing drinks to Apple Health, and adding the ones logged before sync was on.
struct HealthSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @State private var healthAuthorizationMessage: String?
    @State private var showingBackfillConfirmation = false
    @State private var isSyncingHealth = false

    var body: some View {
        List {
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
            } footer: {
                Text(healthFooter)
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
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
            // Caffeine is only mentioned when it will actually be written: tracked, and
            // allowed in Health's own permission sheet.
            Text(settings.caffeineTrackingActive && HealthKitManager.shared.isAuthorizedToWriteCaffeine
                 ? "Every drink you have logged in HydroDrop will be added to Health as dietary water, and its caffeine too. You can remove them again in the Health app at any time."
                 : "Every drink you have logged in HydroDrop will be added to Health as dietary water. You can remove them again in the Health app at any time.")
        }
    }

    /// Both versions mention other devices. An edit reaches Health through whichever device
    /// wrote the drink there, even when this one has sync off (see `HealthWrittenRecord`), and
    /// a device with sync on adds drinks logged on the others. A delete made with sync off
    /// never reaches Health, because the deleted drink leaves nothing behind to act on.
    private var healthFooter: String {
        if settings.healthKitSyncEnabled {
            return "New drinks are added to Health as dietary water, using the amount HydroDrop counts, so a coffee adds what it actually hydrates. If you track caffeine, that is added too. Deleting or editing a drink updates Health too, including an edit made on another of your devices. Turning this off stops this device writing to Health and leaves whatever is already there in place. HydroDrop reads from Health only if you connect Insights, in History."
        }
        return "Off by default. When on, the drinks you log are added to Health as dietary water, and their caffeine if you track it. If another of your devices has this on, it adds the drinks you log here and updates Health when you edit one, but deleting a drink here leaves it in Health. HydroDrop reads from Health only if you connect Insights, in History, and nothing is sent to us either way."
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
                // Edits to samples this device owns, or claimed while sync was off, are
                // corrected now. Samples another device owns wait for it, or for a week.
                HealthKitManager.shared.requestPendingScan()
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
}

#Preview {
    NavigationStack { HealthSettingsView() }
        .environmentObject(AppSettings.shared)
}
