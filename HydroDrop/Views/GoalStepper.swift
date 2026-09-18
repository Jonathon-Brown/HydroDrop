import SwiftUI

/// The daily-goal stepper, stepping in the user's display unit.
///
/// The goal is stored in mL, but an imperial user stepping by 100 mL lands on
/// "71.0 fl oz" and then "74.4 fl oz", which reads as noise. Stepping in whole
/// ounces instead (4 at a time) keeps the number the user sees round, and the
/// conversion back to mL happens once, on the way out.
struct GoalStepper: View {
    @Binding var goalML: Int
    let system: MeasurementSystem
    var title: String = "Goal"

    var body: some View {
        Stepper(value: displayBinding, in: system.goalRange, step: system.goalStep) {
            HStack {
                Text(title)
                Spacer()
                Text(system.format(mL: goalML))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
        }
    }

    private var displayBinding: Binding<Int> {
        Binding(
            get: { system.wholeUnits(fromML: goalML) },
            set: { units in
                let stored = MeasurementSystem.storedGoalRangeML
                goalML = min(max(system.mL(fromDisplayVolume: Double(units)), stored.lowerBound), stored.upperBound)
            }
        )
    }
}

#Preview {
    @Previewable @State var goal = 2000
    Form {
        GoalStepper(goalML: $goal, system: .metric)
        GoalStepper(goalML: $goal, system: .imperial)
    }
}
