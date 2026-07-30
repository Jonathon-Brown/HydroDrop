import SwiftUI

struct GoalCalculatorView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    @State private var weightText: String
    @State private var sex: BiologicalSex
    @State private var activity: ActivityLevel

    init() {
        let settings = AppSettings.shared
        let initialWeightKG = settings.weightKG
        let initialWeightText = initialWeightKG.map {
            String(format: "%.1f", settings.measurementSystem.displayWeight(fromKG: $0))
        } ?? ""
        _weightText = State(initialValue: initialWeightText)
        _sex = State(initialValue: settings.biologicalSex ?? .notSpecified)
        _activity = State(initialValue: settings.activityLevel ?? .sedentary)
    }

    private var weightKG: Double? {
        guard let value = Double(weightText), value > 0 else { return nil }
        return settings.measurementSystem.weightInKG(fromDisplayValue: value)
    }

    private var recommendedML: Int? {
        guard let weightKG else { return nil }
        return HydrationGoalCalculator.recommendedGoalML(weightKG: weightKG, sex: sex, activity: activity)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("About you") {
                    HStack {
                        Text("Weight")
                        Spacer()
                        TextField("Weight", text: $weightText)
                            .keyboardType(.decimalPad)
                            .multilineTextAlignment(.trailing)
                            .frame(width: 80)
                        Text(settings.measurementSystem.weightUnitLabel)
                            .foregroundStyle(.secondary)
                    }

                    Picker("Sex", selection: $sex) {
                        ForEach(BiologicalSex.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }

                    Picker("Activity level", selection: $activity) {
                        ForEach(ActivityLevel.allCases) { level in
                            Text(level.label).tag(level)
                        }
                    }

                    Text(activity.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section {
                    HStack {
                        Text("Recommended goal")
                        Spacer()
                        if let recommendedML {
                            Text(settings.measurementSystem.format(mL: recommendedML))
                                .font(.headline)
                                .foregroundStyle(.blue)
                        } else {
                            Text("Enter your weight")
                                .foregroundStyle(.secondary)
                        }
                    }
                } footer: {
                    Text("This is a general estimate based on common hydration guidelines, not medical advice. If you're pregnant, nursing, or managing a health condition, check with your doctor for personalized guidance.")
                }
            }
            .navigationTitle("Goal Calculator")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Apply") { apply() }
                        .disabled(recommendedML == nil)
                }
            }
        }
    }

    private func apply() {
        guard let weightKG, let recommendedML else { return }
        settings.weightKG = weightKG
        settings.biologicalSex = sex
        settings.activityLevel = activity
        settings.dailyGoalML = recommendedML
        dismiss()
    }
}

#Preview {
    GoalCalculatorView()
        .environmentObject(AppSettings.shared)
}
