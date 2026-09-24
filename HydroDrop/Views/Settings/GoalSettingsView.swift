import SwiftUI

/// The daily goal, and the calculator that can suggest one.
struct GoalSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var showingCalculator = false

    var body: some View {
        List {
            Section {
                GoalStepper(goalML: $settings.dailyGoalML, system: settings.measurementSystem)
            } footer: {
                Text("Your streak counts the days you reach this.")
            }

            Section {
                Button {
                    showingCalculator = true
                } label: {
                    Label("Calculate for me", systemImage: "wand.and.stars")
                }
            } footer: {
                Text("Suggests a goal from your weight and how active you are.")
            }
        }
        .navigationTitle("Daily goal")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingCalculator) {
            GoalCalculatorView()
                .environmentObject(settings)
        }
    }
}

#Preview {
    NavigationStack { GoalSettingsView() }
        .environmentObject(AppSettings.shared)
}
