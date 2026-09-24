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
            Text("Every drink you have logged in HydroDrop will be added to Health as dietary water. You can remove them again in the Health app at any time.")
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
}

#Preview {
    NavigationStack { HealthSettingsView() }
        .environmentObject(AppSettings.shared)
}
