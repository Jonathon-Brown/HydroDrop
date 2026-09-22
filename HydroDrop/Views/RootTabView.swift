import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var duoStore = DuoStore.shared

    private enum Tab {
        case today, history, settings
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

            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                .tag(Tab.settings)
        }
        // A bottle tag read with the app closed arrives as a universal link. SwiftUI
        // delivers those through either of these depending on how the app was started,
        // so both lead to the same place.
        .onOpenURL { open($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { open(url) }
        }
        // The in-app scanner reports through the router too, from whichever tab it was
        // started on, so the tab follows the tap rather than the other way round.
        .onChange(of: router.pendingBottleTagID) { _, tagID in
            if tagID != nil { selectedTab = .today }
        }
        .onChange(of: router.pendingInsights) { _, wanted in
            if wanted { selectedTab = .history }
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
        .sheet(isPresented: $router.showingWeeklyRecap) {
            WeeklyRecapView()
                .environmentObject(settings)
        }
        // An opened duo invite, from whichever tab was showing. Held back while the intro
        // is up: the invite keeps, and a sheet cannot sit on top of the cover anyway.
        .sheet(item: pendingDuoInvite) { invite in
            DuoJoinSheet(invite: invite)
        }
        .alert(
            "Duo Streaks",
            isPresented: Binding(get: { duoStore.notice != nil }, set: { if !$0 { duoStore.notice = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(duoStore.notice ?? "")
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

    private var pendingDuoInvite: Binding<DuoStore.PendingInvite?> {
        Binding(
            get: { settings.hasCompletedOnboarding ? duoStore.pendingInvite : nil },
            set: { duoStore.pendingInvite = $0 }
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
