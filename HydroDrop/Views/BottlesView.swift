import SwiftData
import SwiftUI

/// The bottles an NFC sticker can stand for: add one, rename it, change what it holds,
/// write its tag, or let it go.
///
/// One bottle is free and more come with HydroDrop+, so the limit lives on the Add
/// button rather than on anything already made: a lapsed subscriber keeps every bottle
/// and every tag they have, and simply cannot add another.
struct BottlesView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = StoreManager.shared
    @Query(sort: \Bottle.createdAt) private var bottles: [Bottle]

    @State private var editor: BottleEditorTarget?
    @State private var bottleToDelete: Bottle?
    @State private var paywallSource: PaywallSource?

    private var system: MeasurementSystem { settings.measurementSystem }

    private var canAddBottle: Bool {
        BottleLimit.canAddBottle(existingCount: bottles.count, isSubscribed: store.isSubscribed)
    }

    var body: some View {
        List {
            if bottles.isEmpty {
                Section {
                    Text("No bottles yet. Add the one you drink from most.")
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(bottles) { bottle in
                Section {
                    Button {
                        editor = .existing(bottle)
                    } label: {
                        bottleRow(bottle)
                    }
                    .buttonStyle(.plain)

                    Button {
                        BottleTagSession.shared.writeTag(for: bottle.id, bottleName: bottle.name)
                    } label: {
                        Label("Write tag", systemImage: "wave.3.right.circle")
                    }
                    .accessibilityHint("Writes this bottle to an NFC sticker")
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button(role: .destructive) {
                        bottleToDelete = bottle
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                }
            }

            Section {
                Button {
                    if canAddBottle {
                        editor = .new
                    } else {
                        paywallSource = .settingsLockedBottle
                    }
                } label: {
                    HStack {
                        Label("Add a bottle", systemImage: "plus.circle.fill")
                        Spacer()
                        if !canAddBottle {
                            Image(systemName: "lock.fill")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if !bottles.isEmpty {
                    Button {
                        BottleTagSession.shared.scan { AppRouter.shared.handle($0) }
                    } label: {
                        Label("Scan bottle", systemImage: "wave.3.right")
                    }
                    .accessibilityHint("Reads a bottle's sticker and logs it")
                }
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !canAddBottle {
                        Text("One bottle is free. HydroDrop+ lets you add as many as you like.")
                    }
                    Text("NTAG213 or NTAG215 stickers work well. Writing a tag replaces whatever was on it. Once it is written, just hold your iPhone to the sticker, even with HydroDrop closed.")
                }
            }
        }
        .navigationTitle("My Bottles")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $editor) { target in
            BottleEditor(target: target, system: system) { name, capacityML, drinkType in
                save(target, name: name, capacityML: capacityML, drinkType: drinkType)
            }
        }
        .sheet(item: $paywallSource) { source in
            PaywallView(source: source)
        }
        .confirmationDialog(
            "Delete \(bottleToDelete?.name ?? "this bottle")?",
            isPresented: Binding(
                get: { bottleToDelete != nil },
                set: { if !$0 { bottleToDelete = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete bottle", role: .destructive) {
                if let bottle = bottleToDelete { delete(bottle) }
            }
        } message: {
            Text("Its tag will stop logging drinks. Drinks you already logged stay in your history.")
        }
    }

    private func bottleRow(_ bottle: Bottle) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "waterbottle.fill")
                .foregroundStyle(.blue)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(bottle.name)
                    .foregroundStyle(.primary)
                Text("\(system.format(mL: bottle.capacityML)) of \(bottle.drinkType.label.lowercased())")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit this bottle")
    }

    private func save(_ target: BottleEditorTarget, name: String, capacityML: Int, drinkType: DrinkType) {
        switch target {
        case .new:
            // Checked again here, not just on the button: an entitlement can lapse while
            // the editor is open.
            guard canAddBottle else { return }
            modelContext.insert(Bottle(name: name, capacityML: capacityML, drinkType: drinkType))
        case .existing(let bottle):
            bottle.name = name
            bottle.capacityML = capacityML
            bottle.drinkType = drinkType
        }
        saveContext()
    }

    private func delete(_ bottle: Bottle) {
        modelContext.delete(bottle)
        bottleToDelete = nil
        saveContext()
    }

    private func saveContext() {
        do {
            try modelContext.save()
        } catch {
            Diagnostics.log("could not save a change to the bottles: \(error)")
            modelContext.rollback()
        }
    }
}

/// What the editor is editing: a bottle that exists, or one that does not yet.
enum BottleEditorTarget: Identifiable {
    case new
    case existing(Bottle)

    var id: String {
        switch self {
        case .new: return "new"
        case .existing(let bottle): return bottle.id.uuidString
        }
    }
}

/// Name, capacity and usual drink for one bottle. Hands the values back rather than
/// writing them, so cancelling never has anything to undo.
private struct BottleEditor: View {
    let target: BottleEditorTarget
    let system: MeasurementSystem
    let onSave: (String, Int, DrinkType) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var capacityML: Int
    @State private var drinkType: DrinkType

    private static let maximumNameLength = 30

    init(target: BottleEditorTarget, system: MeasurementSystem, onSave: @escaping (String, Int, DrinkType) -> Void) {
        self.target = target
        self.system = system
        self.onSave = onSave
        switch target {
        case .new:
            _name = State(initialValue: "")
            // A round number in whichever units the person thinks in.
            _capacityML = State(initialValue: system == .imperial ? system.mL(fromDisplayVolume: 24) : 750)
            _drinkType = State(initialValue: .water)
        case .existing(let bottle):
            _name = State(initialValue: bottle.name)
            _capacityML = State(initialValue: bottle.capacityML)
            _drinkType = State(initialValue: bottle.drinkType)
        }
    }

    private var isNew: Bool {
        if case .new = target { return true }
        return false
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Name") {
                    TextField("My bottle", text: $name)
                        .textInputAutocapitalization(.words)
                        .onChange(of: name) { _, newValue in
                            if newValue.count > Self.maximumNameLength {
                                name = String(newValue.prefix(Self.maximumNameLength))
                            }
                        }
                }

                Section {
                    AmountPicker(amountML: $capacityML, system: system)
                        .padding(.vertical, 8)
                } header: {
                    Text("How much it holds")
                } footer: {
                    Text("One tap of the tag logs this much.")
                }

                Section {
                    DrinkTypePicker(drinkType: $drinkType)
                } footer: {
                    Text("What is usually in it.")
                }
            }
            .navigationTitle(isNew ? "New bottle" : "Edit bottle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                        onSave(trimmed.isEmpty ? "My bottle" : trimmed, capacityML, drinkType)
                        dismiss()
                    }
                }
            }
        }
    }
}

#Preview {
    NavigationStack { BottlesView() }
        .environmentObject(AppSettings.shared)
        .modelContainer(for: [WaterEntry.self, Bottle.self], inMemory: true)
}
