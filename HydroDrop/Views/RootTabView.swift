import SwiftUI

struct RootTabView: View {
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var store = StoreManager.shared

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
        .onChange(of: store.isSubscribed) { _, subscribed in
            guard !subscribed else { return }
            // A lapsed subscription shouldn't leave Plus-only settings switched on.
            if settings.mascotSkin.requiresPlus {
                settings.mascotSkin = .classic
            }
            settings.smartRemindersEnabled = false
        }
    }
}

#Preview {
    RootTabView()
}
