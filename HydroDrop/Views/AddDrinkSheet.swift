import SwiftUI

/// Picks a custom amount in the user's display unit and hands back mL.
///
/// The slider, stepper and shortcut buttons all move in whole display units (25 mL
/// or 1 fl oz), so an imperial user sees "12 fl oz", not "11.8". The value only
/// becomes mL once, in `onAdd`.
struct AddDrinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var displayAmount: Int
    let onAdd: (Int) -> Void

    init(onAdd: @escaping (Int) -> Void) {
        self.onAdd = onAdd
        let system = AppSettings.shared.measurementSystem
        _displayAmount = State(initialValue: system.customDrinkPresets[1])
    }

    private var system: MeasurementSystem { settings.measurementSystem }
    private var step: Int { system.customDrinkStep }
    private var range: ClosedRange<Int> { system.customDrinkRange }
    private var amountML: Int { system.mL(fromDisplayVolume: Double(displayAmount)) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Text(system.format(mL: amountML))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: displayAmount)

                HStack(spacing: 24) {
                    stepperButton(systemImage: "minus.circle.fill") {
                        displayAmount = max(range.lowerBound, displayAmount - step)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(displayAmount) },
                            set: { displayAmount = Int($0 / Double(step)) * step }
                        ),
                        in: Double(range.lowerBound)...Double(range.upperBound)
                    )
                    stepperButton(systemImage: "plus.circle.fill") {
                        displayAmount = min(range.upperBound, displayAmount + step)
                    }
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    ForEach(system.customDrinkPresets, id: \.self) { preset in
                        Button("\(preset)") { displayAmount = preset }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("\(preset) \(system.unitLabel)")
                    }
                }

                Spacer()

                Button {
                    onAdd(amountML)
                    dismiss()
                } label: {
                    Text("Add Drink")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Add Water")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func stepperButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.blue)
        }
    }
}

#Preview {
    AddDrinkSheet { _ in }
        .environmentObject(AppSettings.shared)
}
