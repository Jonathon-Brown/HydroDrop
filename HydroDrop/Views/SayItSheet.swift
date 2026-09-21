import SwiftUI

/// Log drinks by describing them: "a large iced coffee and two glasses of water".
///
/// Two steps, and the second one is not optional. The on-device model reads the
/// sentence, `SayItMapper` turns what it heard into amounts, and then every drink is
/// shown as a row that can be changed or removed. Nothing is written until the person
/// has seen that list and tapped Log, because a model that mishears is only harmless
/// when it cannot save anything by itself.
///
/// Voice is the keyboard's own dictation key. The app never records anything, which is
/// why it asks for no microphone or speech permission.
struct SayItSheet: View {
    /// What a drink with no size at all is taken to be: the first quick-add size.
    let defaultML: Int
    /// Hands the confirmed drinks back to the Today screen, which owns logging and undo.
    let onLog: ([SayItDraft]) -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss

    private enum Phase {
        case composing, reading, reviewing
    }

    @State private var phase: Phase = .composing
    @State private var text = ""
    @State private var drafts: [SayItDraft] = []
    /// The one friendly line shown when a sentence did not work out.
    @State private var message: String?
    /// One parser, and so one model session, for the life of this presentation.
    @State private var parser: (any SayItParsing)?
    @FocusState private var isEditorFocused: Bool

    private var system: MeasurementSystem { settings.measurementSystem }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        NavigationStack {
            Group {
                switch phase {
                case .composing: composing
                case .reading: reading
                case .reviewing: reviewing
                }
            }
            .navigationTitle("Say it")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .task {
            // Made here rather than at init so a sheet that is only ever previewed does
            // not spin up a model session, and warmed straight away so the first answer
            // is not the slow one.
            guard parser == nil else { return }
            parser = SayIt.makeParser()
            parser?.prewarm()
            isEditorFocused = true
        }
    }

    // MARK: - 1. Say it

    private var composing: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Tell me what you drank")
                        .font(.title3.weight(.bold))
                    Text("Type it, or tap the mic on your keyboard and say it.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                ZStack(alignment: .topLeading) {
                    TextEditor(text: $text)
                        .focused($isEditorFocused)
                        .frame(minHeight: 130)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .accessibilityLabel("What you drank")
                    if text.isEmpty {
                        Text("A large iced coffee and two glasses of water")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 13)
                            .padding(.vertical, 16)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))

                if let message {
                    Label(message, systemImage: "exclamationmark.bubble.fill")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                        .transition(.opacity)
                }

                Button {
                    findDrinks()
                } label: {
                    Text("Find my drinks")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)
                .disabled(trimmedText.isEmpty)

                Label("Read on your iPhone. Nothing you say leaves it.", systemImage: "lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding()
        }
    }

    // MARK: - 2. Reading

    private var reading: some View {
        VStack(spacing: 14) {
            ProgressView()
            Text("Working it out")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 3. Check and log

    private var reviewing: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach($drafts) { $draft in
                        SayItDraftRow(draft: $draft, system: system) {
                            remove(draft)
                        }
                    }
                } header: {
                    Text("Here is what I heard")
                } footer: {
                    Text("Change anything that looks off. Nothing is saved until you tap Log.")
                }
            }
            .listStyle(.insetGrouped)

            VStack(spacing: 10) {
                Button {
                    onLog(drafts)
                    dismiss()
                } label: {
                    Text(drafts.count == 1 ? "Log 1 drink" : "Log \(drafts.count) drinks")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                }
                .buttonStyle(.borderedProminent)

                Button("Change what I said") {
                    withAnimation { phase = .composing }
                    isEditorFocused = true
                }
                .font(.subheadline.weight(.medium))
            }
            .padding()
            .background(.bar)
        }
    }

    // MARK: - Actions

    private func findDrinks() {
        let said = trimmedText
        guard !said.isEmpty else { return }
        guard let parser else {
            show("Say it is not available right now. Your words are still here.")
            return
        }
        isEditorFocused = false
        withAnimation { message = nil; phase = .reading }

        Task {
            do {
                let spoken = try await parser.parse(said)
                let found = SayItMapper.drafts(from: spoken, defaultML: defaultML)
                if found.isEmpty {
                    show("I could not find a drink in that. Try saying it another way.")
                } else {
                    drafts = found
                    withAnimation { phase = .reviewing }
                }
            } catch SayItError.declined {
                show("I could not read that one. Try saying it another way.")
            } catch {
                show("Something went wrong reading that. Give it another try.")
            }
        }
    }

    /// Back to the text, which is left exactly as it was so it can be edited.
    private func show(_ line: String) {
        withAnimation {
            message = line
            phase = .composing
        }
        isEditorFocused = true
    }

    private func remove(_ draft: SayItDraft) {
        withAnimation { drafts.removeAll { $0.id == draft.id } }
        if drafts.isEmpty {
            show("Nothing left to log. Want to try again?")
        }
    }
}

/// One drink on the confirmation list: what it was, how much, and a way to drop it.
private struct SayItDraftRow: View {
    @Binding var draft: SayItDraft
    let system: MeasurementSystem
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Picker("Drink", selection: $draft.drinkType) {
                    ForEach(DrinkType.allCases) { type in
                        Label(type.label, systemImage: type.icon).tag(type)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Drink")

                Spacer(minLength: 0)

                Button(role: .destructive, action: onRemove) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Remove this drink")
            }

            HStack(spacing: 14) {
                stepButton(systemImage: "minus.circle.fill", label: "Less") { step(-1) }
                Text(system.format(mL: draft.amountML))
                    .font(.title3.weight(.semibold))
                    .monospacedDigit()
                    .frame(minWidth: 96)
                    .contentTransition(.numericText())
                    .accessibilityLabel("Amount")
                    .accessibilityValue(system.format(mL: draft.amountML))
                stepButton(systemImage: "plus.circle.fill", label: "More") { step(1) }
                Spacer(minLength: 0)
            }

            if draft.needsReview {
                Label("I guessed at this one. Please check it.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 4)
        .onChange(of: draft.drinkType) { _, _ in
            // Picking a drink is the person checking it, so the flag has done its job.
            draft.needsReview = false
        }
    }

    private func stepButton(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title2)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(label)
    }

    /// Moves the amount one step in the person's own units, the way the custom drink
    /// picker does, so an ounce user steps in ounces and never sees a fraction.
    private func step(_ direction: Int) {
        let range = system.customDrinkRange
        let next = system.wholeUnits(fromML: draft.amountML) + direction * system.customDrinkStep
        let clamped = min(max(next, range.lowerBound), range.upperBound)
        withAnimation(.snappy) {
            draft.amountML = system.mL(fromDisplayVolume: Double(clamped))
            draft.needsReview = false
        }
    }
}

#Preview {
    SayItSheet(defaultML: 250) { _ in }
        .environmentObject(AppSettings.shared)
}
