import SwiftUI

struct AddDrinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings
    @State private var amount: Int = 250
    let onAdd: (Int) -> Void

    private let step = 25
    private let range = 25...2000

    var body: some View {
        NavigationStack {
            VStack(spacing: 28) {
                Spacer()

                Text(settings.measurementSystem.format(mL: amount))
                    .font(.system(size: 48, weight: .bold, design: .rounded))
                    .contentTransition(.numericText())
                    .animation(.snappy, value: amount)

                HStack(spacing: 24) {
                    stepperButton(systemImage: "minus.circle.fill") {
                        amount = max(range.lowerBound, amount - step)
                    }
                    Slider(
                        value: Binding(
                            get: { Double(amount) },
                            set: { amount = Int($0 / Double(step)) * step }
                        ),
                        in: Double(range.lowerBound)...Double(range.upperBound)
                    )
                    stepperButton(systemImage: "plus.circle.fill") {
                        amount = min(range.upperBound, amount + step)
                    }
                }
                .padding(.horizontal)

                HStack(spacing: 12) {
                    ForEach([100, 250, 500, 750], id: \.self) { preset in
                        Button(settings.measurementSystem.formattedNumber(mL: preset)) { amount = preset }
                            .buttonStyle(.bordered)
                    }
                }

                Spacer()

                Button {
                    onAdd(amount)
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
