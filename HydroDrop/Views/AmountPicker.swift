import SwiftUI

/// Picks a volume in the user's display unit and reports it back in mL.
///
/// There is deliberately no second copy of the amount in here: the display value is
/// derived from the binding on every read and converted back on every write, so the
/// picker can never drift out of step with what its owner is about to save.
struct AmountPicker: View {
    @Binding var amountML: Int
    let system: MeasurementSystem

    private var step: Int { system.customDrinkStep }
    private var range: ClosedRange<Int> { system.customDrinkRange }
    private var displayAmount: Int { system.wholeUnits(fromML: amountML) }

    var body: some View {
        VStack(spacing: 24) {
            Text(system.format(mL: amountML))
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .contentTransition(.numericText())
                .animation(.snappy, value: amountML)
                .accessibilityLabel(system.format(mL: amountML))

            HStack(spacing: 24) {
                stepperButton(systemImage: "minus.circle.fill", label: "Less") {
                    set(displayAmount - step)
                }
                Slider(
                    value: Binding(
                        get: { Double(displayAmount) },
                        set: { set(Int(($0 / Double(step)).rounded()) * step) }
                    ),
                    in: Double(range.lowerBound)...Double(range.upperBound)
                )
                .accessibilityLabel("Amount")
                .accessibilityValue(system.format(mL: amountML))
                stepperButton(systemImage: "plus.circle.fill", label: "More") {
                    set(displayAmount + step)
                }
            }

            HStack(spacing: 12) {
                ForEach(system.customDrinkPresets, id: \.self) { preset in
                    Button("\(preset)") {
                        set(preset)
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("\(preset) \(system.unitLabel)")
                }
            }
        }
    }

    private func set(_ units: Int) {
        let clamped = min(max(units, range.lowerBound), range.upperBound)
        amountML = system.mL(fromDisplayVolume: Double(clamped))
    }

    private func stepperButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.blue)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// The drink-type row shared by the add and edit sheets.
struct DrinkTypePicker: View {
    @Binding var drinkType: DrinkType

    var body: some View {
        Picker("Drink", selection: $drinkType) {
            ForEach(DrinkType.allCases) { type in
                Label(type.label, systemImage: type.icon).tag(type)
            }
        }
    }
}

#Preview {
    @Previewable @State var amount = 250
    @Previewable @State var type = DrinkType.water
    VStack {
        AmountPicker(amountML: $amount, system: .metric)
        Form { DrinkTypePicker(drinkType: $type) }
    }
}
