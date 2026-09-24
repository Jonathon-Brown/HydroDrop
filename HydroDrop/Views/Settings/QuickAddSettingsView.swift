import SwiftUI

/// The sizes of the three quick-add buttons on Today.
struct QuickAddSettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @State private var editingPreset: PresetSlot?

    var body: some View {
        List {
            Section {
                ForEach(Array(settings.quickAddPresets.enumerated()), id: \.offset) { index, amount in
                    Button {
                        editingPreset = PresetSlot(index: index, amountML: amount)
                    } label: {
                        HStack {
                            Image(systemName: "drop.fill")
                                .foregroundStyle(.blue)
                            Text("Button \(index + 1)")
                                .foregroundStyle(.primary)
                            Spacer()
                            Text(settings.measurementSystem.format(mL: amount))
                                .foregroundStyle(.secondary)
                            Image(systemName: "chevron.right")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.tertiary)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                if settings.customQuickAddPresetsML != nil {
                    Button("Use suggested sizes") {
                        settings.customQuickAddPresetsML = nil
                    }
                }
            } footer: {
                Text("The three buttons on the Today screen, and the size the Log a glass reminder button adds.")
            }
        }
        .navigationTitle("Quick add")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editingPreset) { slot in
            QuickAddPresetSheet(slot: slot) { amountML in
                settings.setQuickAddPreset(amountML, at: slot.index)
            }
            .environmentObject(settings)
        }
    }
}

/// One of the three quick-add buttons, identified by its position.
struct PresetSlot: Identifiable {
    let index: Int
    let amountML: Int
    var id: Int { index }
}

/// Sets the size of a single quick-add button.
private struct QuickAddPresetSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let slot: PresetSlot
    let onSave: (Int) -> Void

    @State private var amountML: Int

    init(slot: PresetSlot, onSave: @escaping (Int) -> Void) {
        self.slot = slot
        self.onSave = onSave
        _amountML = State(initialValue: slot.amountML)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                Spacer()
                AmountPicker(amountML: $amountML, system: settings.measurementSystem)
                Spacer()
            }
            .padding()
            .navigationTitle("Quick add \(slot.index + 1)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(amountML)
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }
}

#Preview {
    NavigationStack { QuickAddSettingsView() }
        .environmentObject(AppSettings.shared)
}
