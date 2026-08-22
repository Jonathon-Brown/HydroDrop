import SwiftUI

struct RootTabView: View {
    @StateObject private var settings = AppSettings.shared

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
