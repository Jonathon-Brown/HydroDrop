import SwiftUI

/// Logs a drink of any size, type and time.
///
/// The amount is chosen in the user's display unit and handed back in mL. The time
/// defaults to now, and can be moved back up to a week for a glass that was drunk
/// before it was tapped. It can never be moved forward.
struct AddDrinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    @State private var amountML: Int
    @State private var drinkType: DrinkType = .water
    @State private var usesCustomTime = false
    @State private var timestamp = Date()
    /// Captured when the sheet opens, so the picker's upper bound holds still while it
    /// is on screen. The saved time is clamped again on the way out.
    private let openedAt = Date()

    let onAdd: (Int, DrinkType, Date) -> Void

    init(onAdd: @escaping (Int, DrinkType, Date) -> Void) {
        self.onAdd = onAdd
        let system = AppSettings.shared.measurementSystem
        _amountML = State(initialValue: system.mL(fromDisplayVolume: Double(system.customDrinkPresets[1])))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AmountPicker(amountML: $amountML, system: settings.measurementSystem)
                    .padding(.horizontal)
                    .padding(.top, 12)

                Form {
                    DrinkTypePicker(drinkType: $drinkType)

                    Toggle("Log at another time", isOn: $usesCustomTime.animation())
                    if usesCustomTime {
                        DatePicker(
                            "Time",
                            selection: $timestamp,
                            in: DrinkTime.range(now: openedAt)
                        )
                    }
                }

                Button {
                    onAdd(amountML, drinkType, usesCustomTime ? DrinkTime.clamped(timestamp) : Date())
                    dismiss()
                } label: {
                    Text("Add Drink")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding()
                }
                .buttonStyle(.borderedProminent)
                .padding(.horizontal)
                .padding(.bottom, 12)
            }
            .navigationTitle("Add Water")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    AddDrinkSheet { _, _, _ in }
        .environmentObject(AppSettings.shared)
}
