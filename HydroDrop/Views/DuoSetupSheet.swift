#if DUO_V2
import SwiftUI

/// The consent sheet whose "Create and invite" button is the first request this phone makes
/// (final design §3.1, §4.3 steps 1 and 2). `onCreated` is called with the new duo once it exists,
/// so the caller can bring up the invite sheet.
///
/// Inside a `DuoConsentGate`, so a person meets the birth-year screen and then the rules before
/// this form, and a person who was refused never meets the form at all. The form asks for an
/// optional first name, with the footer saying who sees it, and then says what else is shared and
/// with whom (the explainer, the honesty lines, the processors, the rules and the privacy policy)
/// above the button; nothing is sent until the tap: opening it, typing a name or cancelling makes
/// no request, attests nothing and writes nothing to the Keychain.
///
/// The iCloud version's sheet had a line under the button about picking someone from iCloud;
/// it is gone with iCloud, and nothing replaces it, since the invite sheet that comes next
/// explains the code itself.
struct DuoSetupSheet: View {
    @ObservedObject var duoStore: DuoStore
    var onCreated: (DuoState) -> Void

    @Environment(\.dismiss) private var dismiss
    /// What is in the name field. Held here, outside the gate, so it survives the rules sheet a
    /// `428 terms_required` brings up over the form.
    @State private var name: String
    /// The gate's state, held here too: it says whether this sheet's own Create was refused for the
    /// rules (only then does Accept send it again) and whether the sheet has gone.
    @StateObject private var gateModel: DuoConsentGateModel

    /// `gateModel` is for a test that drives the gate through this sheet; the app leaves it out.
    init(duoStore: DuoStore, onCreated: @escaping (DuoState) -> Void, gateModel: DuoConsentGateModel? = nil) {
        _duoStore = ObservedObject(wrappedValue: duoStore)
        self.onCreated = onCreated
        // The name typed last time, so the person does not have to type it again.
        _name = State(initialValue: DuoConsentFlow.limitedInput(duoStore.myDisplayName))
        _gateModel = StateObject(wrappedValue: gateModel ?? DuoConsentGateModel())
    }

    var body: some View {
        DuoConsentGate(duoStore: duoStore, onClose: { dismiss() }, onTermsAccepted: { createAgainAfterTerms() }, model: gateModel) {
            NavigationStack {
                form
                    .navigationTitle("Start a duo streak")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel") { dismiss() }
                                .accessibilityIdentifier("duo.setup.cancel")
                        }
                    }
            }
        }
        // The service's words belong to this sheet; the next one opened starts without them,
        // as the iCloud version's did.
        .onDisappear { duoStore.sheetError = nil }
    }

    private var form: some View {
        Form {
            Section {
                TextField("Your first name", text: $name)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .onChange(of: name) { _, typed in
                        let kept = DuoConsentFlow.limitedInput(typed)
                        if kept != typed { name = kept }
                    }
                    .onSubmit { name = DuoConsentFlow.trimmedName(name) }
                    .accessibilityIdentifier("duo.setup.name")
            } footer: {
                Text(verbatim: DuoCopy.partnerSeesFooter)
            }

            // Two sections: what the partner sees, then the honesty lines, the processors and the
            // two links.
            DuoExplainer(context: .setup)

            // One thing said above the button: why it is off, in the Duo screen's own words (the
            // service would refuse the tap without a word), or else the last failure.
            switch DuoConsentFlow.formNotice(sheetError: duoStore.sheetError, availability: duoStore.availability) {
            case .error(let words):
                Section {
                    Text(verbatim: words)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("duo.setup.error")
                        .duoAnnounced(words)
                }
            case .unavailable(let words):
                Section {
                    Text(verbatim: words)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("duo.setup.unavailable")
                }
            case nil:
                EmptyView()
            }

            Section {
                Button(action: createTapped) {
                    if duoStore.isWorking {
                        ProgressView().frame(maxWidth: .infinity)
                    } else {
                        Text(verbatim: DuoCopy.createAndInvite).frame(maxWidth: .infinity)
                    }
                }
                .disabled(!DuoConsentFlow.canConfirm(allowed: duoStore.availability.allowsWrites, isWorking: duoStore.isWorking))
                .accessibilityLabel(Text(verbatim: DuoCopy.createAndInvite))
                .accessibilityValue(Text(verbatim: duoStore.isWorking ? DuoConsentFlow.NewCopy.inProgress : ""))
                .accessibilityIdentifier("duo.setup.create")
            }
        }
    }

    /// The tap that is the consent. The service identifies this phone (minting an identity only
    /// now), makes the duo, and leaves any failure in `sheetError`, which the form shows in place.
    private func createTapped() {
        let typed = name
        Task { await create(named: typed) }
    }

    /// The rules were accepted over the form. Create goes again only if this sheet's own Create
    /// was what the server refused: a `needsTerms` left up by another sheet's request, answered
    /// after that sheet had gone, must not send a request nobody tapped here.
    private func createAgainAfterTerms() {
        guard gateModel.takeRequestRefusedForTerms() else { return }
        createTapped()
    }

    /// What a Create tap does with the name in the field: the trimmed name, or none, and the new
    /// duo handed on. Nothing is sent once the sheet has gone (a resend from a rules sheet torn down
    /// with it), and a duo made by a request that was still out when the sheet went is not handed
    /// on: the card shows it, and the caller may already have moved on. Returns the duo, for a test.
    @discardableResult
    func create(named typed: String) async -> DuoState? {
        guard !gateModel.hasGone else { return nil }
        guard let duo = await duoStore.createDuo(named: DuoConsentFlow.nameForRequest(typed)) else {
            if duoStore.needsTerms { gateModel.noteRequestRefusedForTerms() }
            return nil
        }
        guard !gateModel.hasGone else { return duo }
        onCreated(duo)
        return duo
    }
}
#endif
