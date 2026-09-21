import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var router = AppRouter.shared

    /// Re-evaluated whenever the chosen skin or the entitlement changes. `activeMascotSkin`
    /// reads `EntitlementCache`, which `StoreManager` writes in the same call that flips
    /// `isSubscribed`, so by the time the task runs the cache matches the flag.
    private var iconSyncKey: String {
        "\(settings.mascotSkin.rawValue)|\(store.isSubscribed)"
    }

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Today", systemImage: "drop.fill") }

            HistoryView()
                .tabItem { Label("History", systemImage: "chart.bar.fill") }

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
        }
        .environmentObject(settings)
        .tint(Color(red: 0.18, green: 0.56, blue: 0.93))
        // Same rule as the mascot on screen: the icon follows what the user is entitled to.
        .task(id: iconSyncKey) { AppIconManager.sync(to: settings.activeMascotSkin) }
        // Widgets are a HydroDrop+ feature and draw from the published snapshot, so a
        // purchase, a restore or a lapse has to reach them. Runs on appear as well, which
        // covers an entitlement that changed between launches. `WidgetBridge` drops the
        // publish when nothing differs, so this costs no reload in the common case.
        .task(id: store.isSubscribed) {
            WidgetPublisher.publish(
                context: modelContext,
                isShared: SharedModelContainer.isShared(modelContext.container)
            )
        }
        // Held back until onboarding is out of the way: the tracking alert landing on
        // top of the intro would be the first thing a new user sees.
        .task(id: settings.hasCompletedOnboarding) {
            guard settings.hasCompletedOnboarding else { return }
            try? await Task.sleep(for: .seconds(2))
            AdManager.requestTrackingAuthorizationIfNeeded()
        }
        .sheet(isPresented: $router.showingWeeklyRecap) {
            WeeklyRecapView()
                .environmentObject(settings)
        }
        .fullScreenCover(isPresented: onboardingIsPresented) {
            OnboardingView(mode: .firstLaunch) {
                settings.hasCompletedOnboarding = true
            }
            .environmentObject(settings)
        }
    }

    /// Onboarding is on screen exactly while the flag is off. The flag can also flip from
    /// underneath (another device finishing the intro), which closes the cover too.
    private var onboardingIsPresented: Binding<Bool> {
        Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { presented in
                if !presented { settings.hasCompletedOnboarding = true }
            }
        )
    }
}

// Plus features used to be switched off here, in an `onChange` on the entitlement.
// That only fires on a transition *within a session*: a subscription that lapsed
// between launches started the next launch at false and never changed, so the handler
// never ran and the paid mascot skin and pace-aware reminders stayed on for good.
// Each feature now derives from the entitlement where it is used — see
// `AppSettings.activeMascotSkin` and `AppSettings.smartRemindersActive` — which also
// means the user's choices survive a lapse and come back with them.

#Preview {
    RootTabView()
}
