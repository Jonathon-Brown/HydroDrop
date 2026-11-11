#if DUO_V2
import SwiftUI

// "I had a duo" (final design §3.4, §3.5; plan P2 items 6 and 9): getting a duo back on a new
// phone, or on this one after another phone took its identity over, with the reconnect code the
// partner made. It shows the same explainer as the setup sheet, inside the same consent gate
// (the birth-year screen and the rules come first), and its Reconnect button is the consent:
// on a fresh install that one tap mints this phone's identity and then redeems the code, so
// nothing is sent before it, and nothing at all is sent when the sheet appears.
//
// Only the button is the consent (D88). The first version also sent from the keyboard's Go key,
// with the explainer below the field: with the keyboard up, a person could mint an identity and
// take a duo over from the field alone, without the button or the explainer on screen. The
// return key now only puts the keyboard away, and the explainer comes before the field.
//
// The disconnected card's "I had a duo" opens it, and so does the join sheet for a code whose
// peek said it is a reconnect code (with `prefilledCode`). A disconnected phone is the one that
// needs it, and `allowsWrites` is false there, so the button follows `allowsReconnect` instead.
// What the sheet draws in each state is `DuoCodeEntryModel.reconnectLayout`'s answer.

/// The state behind the sheet, kept apart from the view so a test can call exactly what the
/// button calls.
@MainActor
final class DuoReconnectController: ObservableObject {
    /// What the person typed, when no code came with the sheet.
    @Published var typed = ""
    /// A code the sheet was opened with, from a link or a scanned QR code: shown, not editable.
    let prefilledCode: String?
    /// A tap is out. The store's `isWorking` says the same once the service has started, but not
    /// in the moment between the tap and that, when a second tap could otherwise get through.
    @Published private(set) var isSending = false
    /// The reconnect landed. The sheet is on its way out (or, with `onReconnected:`, handed back to
    /// the sheet it is part of), and a second tap would send a second reconnect.
    @Published private(set) var hasLanded = false
    /// The sheet has gone. An answer that arrives later is said to nobody, and its words must not
    /// wait in the store for the next sheet that shows `sheetError`.
    private(set) var hasClosed = false

    // Nonisolated so a view's initialiser, which SwiftUI does not run on the main actor, can make one.
    nonisolated init(prefilledCode: String?) {
        self.prefilledCode = prefilledCode.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// The code a tap sends: the one the sheet came with, or the one typed.
    var code: String { prefilledCode ?? typed }

    /// Whether the button may send now.
    func canReconnect(in store: DuoStore) -> Bool { request(in: store) != nil }

    /// Whether to draw the progress indicator.
    func isWorking(in store: DuoStore) -> Bool { isSending || store.isWorking }

    /// What the sheet draws now.
    func layout(in store: DuoStore) -> DuoCodeEntryModel.ReconnectLayout {
        DuoCodeEntryModel.reconnectLayout(code: code, isPrefilled: prefilledCode != nil, ageStatus: store.ageStatus,
                                          availability: store.availability, isWorking: isWorking(in: store), hasLanded: hasLanded,
                                          sheetError: store.sheetError)
    }

    private func request(in store: DuoStore) -> String? {
        DuoCodeEntryModel.reconnectRequest(code: code, ageStatus: store.ageStatus, availability: store.availability,
                                           isWorking: isWorking(in: store), hasLanded: hasLanded)
    }

    /// The Reconnect button, and the same tap again after the rules were accepted on a `428`.
    /// True once the phone holds the duo's identity; on a refusal the service has put its words
    /// in `sheetError`, which the sheet shows in place.
    func reconnect(in store: DuoStore) async -> Bool {
        guard let code = request(in: store) else { return false }
        isSending = true
        defer { isSending = false }
        let landed = await store.reconnect(code: code)
        if landed { hasLanded = true }
        if hasClosed { store.sheetError = nil }
        return landed
    }

    /// The tap itself: sends, and calls `landed` once the phone holds the duo's identity, so the
    /// sheet can close (or hand back to the sheet it is part of). Nothing is called on a refusal:
    /// the sheet stays, with the service's words in place.
    @discardableResult
    func tap(in store: DuoStore, landed: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            // The service may finish after Cancel or parent navigation removed this sheet.
            // Keep its result, but do not navigate or dismiss a different sheet from that answer.
            if await reconnect(in: store), !hasClosed { landed() }
        }
    }

    /// The sheet came on screen: a refusal kept only in the Keychain (a process that started before
    /// the first unlock read "unknown") is found now, so the gate shows it before anything else.
    func appeared(in store: DuoStore) {
        hasClosed = false
        store.recheckAge()
    }

    /// The sheet went: the words of a refusal belong to this attempt; the next sheet starts clean.
    func disappeared(in store: DuoStore) {
        hasClosed = true
        store.sheetError = nil
    }
}

struct DuoReconnectSheet: View {
    @ObservedObject var duoStore: DuoStore
    /// A code that arrived as a link or a scanned QR code, shown filled in so the person only
    /// confirms. Nil when they will type it.
    var prefilledCode: String? = nil
    /// Called instead of closing the sheet once the reconnect has landed, for a caller that shows
    /// this sheet as part of its own (the join sheet, which also lets the pending invite go).
    var onReconnected: (() -> Void)? = nil
    @StateObject private var controller: DuoReconnectController
    @Environment(\.dismiss) private var dismiss
    @FocusState private var fieldIsFocused: Bool
    /// For tests: stands in for `dismiss`, which only a presented sheet has.
    private var closeForTests: (() -> Void)?

    init(duoStore: DuoStore, prefilledCode: String? = nil, onReconnected: (() -> Void)? = nil) {
        self.duoStore = duoStore
        self.prefilledCode = prefilledCode
        self.onReconnected = onReconnected
        _controller = StateObject(wrappedValue: DuoReconnectController(prefilledCode: prefilledCode))
    }

    /// For tests: a sheet whose closing is seen without presenting it.
    init(duoStore: DuoStore, prefilledCode: String? = nil, onReconnected: (() -> Void)? = nil, closeForTests: @escaping () -> Void) {
        self.init(duoStore: duoStore, prefilledCode: prefilledCode, onReconnected: onReconnected)
        self.closeForTests = closeForTests
    }

    var body: some View {
        let layout = controller.layout(in: duoStore)
        DuoConsentGate(duoStore: duoStore, onClose: { close() }, onTermsAccepted: { tapReconnect() }) {
            NavigationStack {
                form(layout)
                    .navigationTitle(DuoCopy.disconnectedHadADuo)
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { close() }
                                .accessibilityIdentifier("duo.reconnect.cancel")
                        }
                    }
            }
        }
        // While a reconnect is out the sheet stays: an answer for a sheet nobody sees would leave
        // its words, or its success, unexplained (stage K's join sheet does the same).
        .interactiveDismissDisabled(!layout.mayBeSwipedAway)
        .onAppear { controller.appeared(in: duoStore) }
        .onDisappear { controller.disappeared(in: duoStore) }
    }

    private func form(_ layout: DuoCodeEntryModel.ReconnectLayout) -> some View {
        Form {
            // Why the button is off comes first, where it is seen before anything else.
            DuoEntryNoticeSection(duoStore: duoStore, notice: layout.notice)
            Section {
                Text("Enter the code your partner made for your new phone.") // NEW COPY
                    .fixedSize(horizontal: false, vertical: true)
            }
            // What the tap agrees to, above the field and the button, so it is on screen with them
            // (stage I gives it the heading `DuoExplainer.heading(for: .reconnect)` at integration).
            DuoExplainer(context: .reconnect)
            Section {
                codeField(layout)
            }
            if let error = layout.error {
                Section {
                    // The service's words (§4.4, through `DuoUserMessage`), with any `(ref ...)`.
                    Text(verbatim: error)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("duo.reconnect.error")
                }
            }
            Section {
                Button(action: tapReconnect) {
                    Group {
                        if layout.showsProgress {
                            ProgressView()
                        } else {
                            Text("Reconnect") // NEW COPY
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .disabled(!layout.buttonIsEnabled)
                .accessibilityLabel(Text("Reconnect")) // NEW COPY (the button's own words)
                .accessibilityIdentifier("duo.reconnect.confirm")
            }
        }
    }

    @ViewBuilder private func codeField(_ layout: DuoCodeEntryModel.ReconnectLayout) -> some View {
        if let prefilled = controller.prefilledCode {
            // Filled in and not editable: the person only confirms the code that came with the link.
            // Not selectable either: a takeover code copied to the pasteboard would outlive the sheet
            // and travel to other devices by Universal Clipboard (D79).
            Text(verbatim: DuoInviteCode.normalize(prefilled).map(DuoInviteCode.display) ?? prefilled)
                .font(.body.monospaced())
                .speechSpellsOutCharacters()
                .accessibilityIdentifier("duo.reconnect.field")
        } else {
            // The prompt is the final design's own example code (§4.1), a shape rather than words.
            TextField(text: $controller.typed, prompt: Text(verbatim: DuoInviteCode.display("H7K39QWX"))) {
                Text("Enter the code your partner made for your new phone.") // NEW COPY (the line above)
            }
            .textInputAutocapitalization(.characters)
            .autocorrectionDisabled()
            .keyboardType(.asciiCapable)
            // The return key only puts the keyboard away: the Reconnect button is the consent.
            .submitLabel(.done)
            .focused($fieldIsFocused)
            .onSubmit { fieldIsFocused = false }
            .font(.body.monospaced())
            .disabled(!layout.fieldIsEditable)
            .accessibilityIdentifier("duo.reconnect.field")
        }
    }

    private func close() {
        if let closeForTests { closeForTests() } else { dismiss() }
    }

    private func tapReconnect() {
        let onReconnected = onReconnected
        controller.tap(in: duoStore) {
            if let onReconnected { onReconnected() } else { close() }
        }
    }
}
#endif
