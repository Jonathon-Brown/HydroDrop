import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var router = AppRouter.shared

    /// Settings is not a tab: it opens as a sheet from the gear at the top of each of
    /// these, so the bar only holds the two places people actually spend time.
    private enum Tab {
        case today, history
    }

    /// Selected by hand only so a tapped bottle tag can bring Today forward, which is
    /// where the drink appears and where it can be undone.
    @State private var selectedTab = Tab.today

    /// Re-evaluated whenever the chosen skin or the entitlement changes. `activeMascotSkin`
    /// reads `EntitlementCache`, which `StoreManager` writes in the same call that flips
    /// `isSubscribed`, so by the time the task runs the cache matches the flag.
    private var iconSyncKey: String {
        "\(settings.mascotSkin.rawValue)|\(store.isSubscribed)"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Today", systemImage: "drop.fill") }
                .tag(Tab.today)

            HistoryView()
                .tabItem { Label("History", systemImage: "chart.bar.fill") }
                .tag(Tab.history)
        }
        // A bottle tag read with the app closed arrives as a universal link. SwiftUI
        // delivers those through either of these depending on how the app was started,
        // so both lead to the same place.
        .onOpenURL { open($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { open(url) }
        }
        // The in-app scanner reports through the router too, from My Bottles in
        // Settings, so the tab follows the tap rather than the other way round. Today
        // holds the tap until Settings has gone; see `HomeView.handlePendingBottleTap`.
        .onChange(of: router.pendingBottleTagID) { _, tagID in
            guard tagID != nil else { return }
            router.showingSettings = false
            selectedTab = .today
        }
        .onChange(of: router.pendingInsights) { _, wanted in
            guard wanted else { return }
            router.showingSettings = false
            selectedTab = .history
        }
        // A tapped recap notification wins over Settings left open. The recap sheet
        // below waits for it to be fully gone before it comes up.
        .onChange(of: router.showingWeeklyRecap) { _, showing in
            if showing { router.showingSettings = false }
        }
        #if DEBUG
        // `-SimulateBottleTap <address>` hands an address to the same place a real tag
        // read does. The simulator has no NFC and cannot open a universal link that is
        // not live yet, so this is the only way to watch a tap arrive there. Compiled
        // out of Release.
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if let flag = arguments.firstIndex(of: "-SimulateBottleTap"),
               arguments.indices.contains(flag + 1),
               let address = URL(string: arguments[flag + 1]) {
                open(address)
            }
        }
        #endif
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
        .sheet(isPresented: $router.showingSettings, onDismiss: { router.settingsDidDismiss() }) {
            SettingsView()
                .environmentObject(settings)
                .onAppear { router.settingsDidAppear() }
        }
        .sheet(isPresented: weeklyRecapIsPresented) {
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

    private func open(_ url: URL) {
        router.handle(url)
    }

    /// The recap a notification asked for, held back while Settings is still leaving.
    private var weeklyRecapIsPresented: Binding<Bool> {
        Binding(
            get: { router.showingWeeklyRecap && !router.settingsIsOnScreen },
            set: { router.showingWeeklyRecap = $0 }
        )
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
