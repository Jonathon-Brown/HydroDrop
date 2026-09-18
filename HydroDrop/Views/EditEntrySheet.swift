import SwiftUI
import SwiftData

/// Changes an entry that has already been logged: its amount, what it was, and when.
///
/// Edits are written to the model only on Save, so backing out with Cancel leaves the
/// drink exactly as it was.
struct EditEntrySheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var settings: AppSettings

    let entry: WaterEntry
    /// Called after the edit lands, so the caller can save, re-arm reminders and
    /// update the watch. Carries the Apple Health sample this edit has orphaned, if
    /// there is one, since the entry no longer remembers it.
    let onSave: (String?) -> Void
    /// Called instead of dismissing: the caller closes this sheet and then deletes,
    /// because a model read back after deletion is a crash.
    let onDelete: () -> Void

    @State private var amountML: Int
    @State private var drinkType: DrinkType
    @State private var timestamp: Date
    @State private var showingDeleteConfirmation = false
    private let openedAt = Date()
    private let originalTimestamp: Date

    init(entry: WaterEntry, onSave: @escaping (String?) -> Void, onDelete: @escaping () -> Void) {
        self.entry = entry
        self.onSave = onSave
        self.onDelete = onDelete
        _amountML = State(initialValue: entry.amountML)
        _drinkType = State(initialValue: entry.drinkType)
        _timestamp = State(initialValue: entry.timestamp)
        originalTimestamp = entry.timestamp
    }

    private var hydratedML: Int { drinkType.hydratedML(from: amountML) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                AmountPicker(amountML: $amountML, system: settings.measurementSystem)
                    .padding(.horizontal)
                    .padding(.top, 12)

                Form {
                    Section {
                        DrinkTypePicker(drinkType: $drinkType)

                        DatePicker(
                            "Time",
                            selection: $timestamp,
                            in: DrinkTime.editingRange(existing: originalTimestamp, now: openedAt)
                        )
                    } footer: {
                        if drinkType.countsForLess {
                            Text("\(drinkType.label) counts as \(drinkType.hydrationShareLabel) of what you drink, so this adds \(settings.measurementSystem.format(mL: hydratedML)) towards your goal.")
                        }
                    }

                    Section {
                        Button(role: .destructive) {
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete Drink", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle("Edit Drink")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                }
            }
            .confirmationDialog(
                "Delete this drink?",
                isPresented: $showingDeleteConfirmation,
                titleVisibility: .visible
            ) {
                Button("Delete", role: .destructive) { onDelete() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func save() {
        let newTimestamp = timestamp == originalTimestamp ? originalTimestamp : DrinkTime.clamped(timestamp)
        let isUnchanged = entry.amountML == amountML
            && entry.drinkType == drinkType
            && entry.timestamp == newTimestamp

        // Health only needs disturbing when something it recorded actually moved.
        var orphanedSampleUUID: String?
        if !isUnchanged {
            orphanedSampleUUID = entry.healthKitSampleUUID
            // Cleared so the next reconcile writes the corrected drink. The old sample
            // is deleted by the caller.
            entry.healthKitSampleUUID = nil
        }

        entry.amountML = amountML
        entry.drinkType = drinkType
        // An entry being edited may already be older than the backfill window, so the
        // clamp only applies when the user actually moved it.
        entry.timestamp = newTimestamp
        onSave(orphanedSampleUUID)
        dismiss()
    }
}

#Preview {
    EditEntrySheet(entry: WaterEntry(amountML: 330, drinkType: .coffee), onSave: { _ in }, onDelete: {})
        .environmentObject(AppSettings.shared)
}
