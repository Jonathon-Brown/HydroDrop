#if DUO_V2
import SwiftUI

/// Neutral month/year entry, with both fields blank and an explicit confirmation for every
/// answer. Birth details live only in BirthEntry while this view is present; the store retains
/// only a policy version and allowed/refused status. Invalid or unreadable answers cannot become
/// a permanent refusal. Existing refusals remain final, including while a legacy approval is
/// being checked again. A successfully saved refusal may survive uninstall; losing every local
/// copy after a failed write remains outside the client-only persistence guarantee.
struct DuoAgeGateView: View {
    @ObservedObject var duoStore: DuoStore
    var onAllowed: () -> Void
    var onRefused: () -> Void

    /// The moment and calendar a typed year is judged against: today's, unless a test says otherwise.
    private let fixedNow: Date?
    private let calendar: Calendar

    /// The field and the confirmation, held only while the screen is up (`DuoConsentFlow.BirthEntry`).
    @State private var entry = DuoConsentFlow.BirthEntry()
    /// The complete input stays visible, including anything that makes it invalid.
    @State private var fieldText = ""
    @State private var monthText = ""
    /// The confirmed answer was the thirteenth-birthday month (decision b): the screen says to try
    /// again next month. Nothing was kept, so it is only this screen's.
    @State private var notYet = false
    private enum Field: Hashable { case month, year }
    @FocusState private var focusedField: Field?

    init(duoStore: DuoStore, onAllowed: @escaping () -> Void, onRefused: @escaping () -> Void,
         now: Date? = nil, calendar: Calendar = .current) {
        _duoStore = ObservedObject(wrappedValue: duoStore)
        self.onAllowed = onAllowed
        self.onRefused = onRefused
        fixedNow = now
        self.calendar = calendar
    }

    private var now: Date { fixedNow ?? Date() }

    /// Whether the screen shows the refusal and nothing else.
    var showsRefusal: Bool { duoStore.ageStatus == .refused }

    var body: some View {
        Form {
            if showsRefusal {
                refusal
            } else if notYet {
                Section {
                    // NEW COPY (decision b): `DuoConsentFlow.NewCopy.ageNotYet`.
                    Text(verbatim: DuoConsentFlow.NewCopy.ageNotYet)
                        .font(.headline)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("duo.agegate.notyet")
                        .duoAnnounced(DuoConsentFlow.NewCopy.ageNotYet)
                }
                Section {
                    Button(action: onRefused) {
                        Text("Close").frame(maxWidth: .infinity)
                    }
                    .accessibilityIdentifier("duo.agegate.close")
                }
            } else if duoStore.ageCheckUnavailable {
                Section {
                    // Approved by Jonathon 2026-11-12 (decision e), reworded from "Unable to check Duo
                    // availability…" to use the feature's full name. No age threshold or answer is disclosed.
                    Text("Couldn't check whether Duo Streaks is available on this iPhone. Try again.")
                        .duoAnnounced("Couldn't check whether Duo Streaks is available on this iPhone. Try again.")
                    Button("Try again") { duoStore.recheckAge() }
                        .accessibilityIdentifier("duo.agegate.retry")
                    Button("Close", action: onRefused)
                }
            } else if let answer = entry.pending {
                confirmation(answer)
            } else {
                question
            }
        }
        // A process that started before the first unlock could not read the Keychain and said
        // "unknown"; asked again here, a refusal kept only there is found before the field shows.
        .onAppear { duoStore.recheckAge() }
    }

    @ViewBuilder
    private var refusal: some View {
        Section {
            Text(verbatim: DuoConsentFlow.NewCopy.ageRefusal)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("duo.agegate.refusal")
            // Decision a: what became of the Duo data this phone held. NEW COPY, except the approved
            // line for a delete the service could not confirm.
            // A Reconnect's throwaway holds none of the person's data (D68), so it gets no line.
            if let line = Self.refusalDeletionLine(duoStore.refusalDeletion,
                                                   holdsIdentity: duoStore.hasIdentity && !duoStore.hCredentialIsAThrowaway) {
                HStack(spacing: 10) {
                    if duoStore.refusalDeletion == .deleting { ProgressView() }
                    Text(verbatim: line)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("duo.agegate.refusal.deletion")
                .duoAnnounced(line)
            }
        }
        Section {
            Button(action: onRefused) {
                Text("Close").frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("duo.agegate.close")
        }
    }

    /// The refusal screen's line about the Duo data (decision a): the request under way, its answer,
    /// or, when it failed and the identity is still held, where to delete it by hand. Nothing when no
    /// request was sent: an identity this install never answered for may be someone else's, and
    /// calling it "your Duo data" would point a child at deleting it.
    static func refusalDeletionLine(_ deletion: DuoStore.RefusalDeletion?, holdsIdentity: Bool) -> String? {
        switch deletion {
        case .deleting?: return DuoConsentFlow.NewCopy.refusalDeleting
        case .deleted?: return DuoConsentFlow.NewCopy.refusalDeleted
        case .removedFromThisPhone?: return DuoUserMessage.removedFromThisPhoneOnly
        case .failed?: return holdsIdentity ? DuoConsentFlow.NewCopy.refusalDataRemains : nil
        case nil: return nil
        }
    }

    @ViewBuilder
    private var question: some View {
        Section {
            TextField(DuoConsentFlow.NewCopy.monthPlaceholder, text: $monthText)
                .keyboardType(.numberPad)
                .focused($focusedField, equals: .month)
                .accessibilityLabel(DuoConsentFlow.NewCopy.monthLabel)
                .accessibilityIdentifier("duo.agegate.month")
                .onChange(of: monthText) { _, text in entry.typeMonth(text) }
            TextField(text: $fieldText, prompt: Text(verbatim: DuoConsentFlow.NewCopy.yearPlaceholder)) {
                Text(verbatim: DuoConsentFlow.NewCopy.monthYearQuestion)
            }
            .onChange(of: fieldText) { _, typed in
                let kept = DuoConsentFlow.limitedYearInput(typed)
                if kept != typed { fieldText = kept }
                entry.typeYear(kept)
            }
            // "Birth year", as the month field is "Birth month" (finding 15): the field used to be read
            // as the whole question, so a VoiceOver user typed the month and year into it.
            .accessibilityLabel(Text(verbatim: DuoConsentFlow.NewCopy.yearLabel))
            .keyboardType(.numberPad)
            .textContentType(nil)
            .autocorrectionDisabled()
            .textInputAutocapitalization(.never)
            .font(.title2.monospacedDigit())
            .focused($focusedField, equals: .year)
            .accessibilityIdentifier("duo.agegate.year")
        } header: {
            VStack(alignment: .leading, spacing: 6) {
                Text(verbatim: DuoConsentFlow.NewCopy.ageTitle)
                    .font(.title2.bold())
                    .accessibilityAddTraits(.isHeader)
                Text(verbatim: DuoConsentFlow.NewCopy.monthYearQuestion)
                    .font(.body)
            }
            .foregroundStyle(.primary)
            .textCase(nil)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.bottom, 8)
        }

        Section {
            Button {
                // The keyboard goes first and the question comes on the next turn: taking away the
                // row of a field that still has the keyboard, in the same update, trips an assertion
                // in the list underneath the form.
                focusedField = nil
                DispatchQueue.main.async { entry.confirm(now: now, calendar: calendar) }
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            .disabled(!entry.canContinue(now: now, calendar: calendar))
            .accessibilityIdentifier("duo.agegate.continue")
        }
    }

    @ViewBuilder
    private func confirmation(_ birth: DuoConsentFlow.BirthAnswer) -> some View {
        Section {
            Text(verbatim: birth.confirmation)
                .font(.title2.bold())
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("duo.agegate.bornin")
        }
        Section {
            Button {
                guard let confirmed = entry.take() else { return }
                fieldText = ""
                monthText = ""
                answer(confirmed.year, month: confirmed.month)
            } label: {
                Text("Continue").frame(maxWidth: .infinity)
            }
            // A centred label would start the line under it mid-row.
            .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
            .accessibilityIdentifier("duo.agegate.confirm")
            Button {
                entry.change()
                fieldText = entry.yearText
                monthText = entry.monthText
                // Focus once the field's row is back.
                DispatchQueue.main.async { focusedField = .year }
            } label: {
                Text(verbatim: DuoConsentFlow.NewCopy.change).frame(maxWidth: .infinity)
            }
            .accessibilityIdentifier("duo.agegate.change")
        }
    }

    /// The confirmed year. The store decides and keeps the status (a refusal it already holds wins
    /// over any year); an allowed answer moves the sheet on, a refusal redraws this screen as the
    /// refusal, and an unreadable year leaves the question up.
    @discardableResult
    func answer(_ year: Int, month: Int) -> DuoAgeStatus {
        let wasRecheck = duoStore.needsAgeRecheck
        let status = duoStore.recordBirthYear(year, month: month, now: now)
        if status == .unknown, DuoAgeGate.isNotYet(birthYear: year, birthMonth: month, now: now, calendar: calendar) { notYet = true }
        if status == .allowed {
            onAllowed()
            // A fresh person's answer still sends nothing before Create/Join. Only an explicit
            // recheck resumes the sharing that migration paused, whichever sheet asked it.
            if wasRecheck { Task { await duoStore.resumeAfterAgeRecheck() } }
        }
        return status
    }
}

/// Wraps the body of the three consent sheets (setup, join, reconnect), so the age screen and
/// the terms are handled in one place and not three: it shows `content` once the person is
/// old enough and has accepted the current rules, the birth-year screen first when the age is not
/// known yet, the rules in place of the form when they have not been accepted on this phone, and
/// nothing but a way out after a refusal. While the server wants the terms again
/// (`duoStore.needsTerms`, a `428 terms_required` met by this form's own request) it presents the
/// terms sheet over the form, and calls `onTermsAccepted` once they are accepted and that sheet has
/// gone, so the sheet can send the request that was refused.
///
/// Put the gate outermost, as the sheet's whole body, with the sheet's own `NavigationStack`
/// inside `content`: each step brings a `NavigationStack` of its own, and the form is not built at
/// all until the step is `.form`, so a person who is refused, or whose age is not known, never sees
/// it, not even for a frame, and nothing inside it (a peek on appear, say) can run for them. Nested
/// the other way round it still fails safe: of two gates with a form on screen, only the deeper
/// one, or with equal depth the later one, brings the rules up.
struct DuoConsentGate<Content: View>: View {
    @ObservedObject var duoStore: DuoStore
    /// The person was refused or backed out of the terms: the sheet dismisses itself.
    var onClose: () -> Void
    var onTermsAccepted: () -> Void
    @ViewBuilder var content: () -> Content

    @StateObject private var model: DuoConsentGateModel
    /// The consent forms on screen, so only the one on top brings the rules up again.
    @ObservedObject private var forms = DuoConsentForms.shared
    /// How many gates this one is drawn inside, where the environment reaches.
    @Environment(\.duoConsentGateDepth) private var depth

    /// `model` is for a test that needs to see or drive what the gate holds; the sheets that are not
    /// tested through it leave it out.
    init(duoStore: DuoStore, onClose: @escaping () -> Void, onTermsAccepted: @escaping () -> Void,
         model: DuoConsentGateModel? = nil, @ViewBuilder content: @escaping () -> Content) {
        _duoStore = ObservedObject(wrappedValue: duoStore)
        self.onClose = onClose
        self.onTermsAccepted = onTermsAccepted
        _model = StateObject(wrappedValue: model ?? DuoConsentGateModel())
        self.content = content
    }

    /// The step this phone's answers put the sheet on.
    var step: DuoConsentFlow.Step {
        DuoConsentFlow.step(ageStatus: duoStore.ageStatus, acceptedTermsVersion: duoStore.acceptedTermsVersion)
    }

    /// The step drawn. An Accept made in place records the rules at once, which makes the step
    /// `.form` while the service may still be telling the server; the rules stay up, showing
    /// progress, until it has finished, because a Create tapped meanwhile would be refused without
    /// a word by the service's one-flow-at-a-time guard.
    func shownStep(_ model: DuoConsentGateModel) -> DuoConsentFlow.Step {
        step == .form && model.accepting == .inPlace ? .terms : step
    }

    var body: some View {
        Group {
            switch shownStep(model) {
            case .askAge, .refused:
                NavigationStack {
                    ageScreen()
                        .navigationBarTitleDisplayMode(.inline)
                        .toolbar {
                            // After a refusal Close is the one way out, so the bar offers none.
                            if step == .askAge {
                                ToolbarItem(placement: .cancellationAction) {
                                    Button("Cancel", action: onClose)
                                        .accessibilityIdentifier("duo.agegate.cancel")
                                }
                            }
                        }
                }
            case .terms:
                inPlaceTerms(model)
            case .form:
                content()
                    .environment(\.duoConsentGateDepth, depth + 1)
                    .onAppear {
                        model.formAppeared(duoStore)
                        forms.appeared(model, depth: depth)
                    }
                    .onDisappear {
                        model.formGone()
                        forms.gone(model)
                    }
                    .sheet(isPresented: Binding(
                        get: { showsTermsAgain(model) },
                        // Accept and Cancel are the only ways the sheet goes (it cannot be swiped
                        // away), and each says what it wants through the model.
                        set: { _ in }
                    ), onDismiss: { termsAgainGone(model) }) {
                        termsAgain(model)
                            .interactiveDismissDisabled()
                            .onAppear {
                                model.termsAgainOnScreen = true
                                model.termsAgainPresentations += 1
                            }
                            .onDisappear { model.termsAgainOnScreen = false }
                    }
            }
        }
        .onAppear {
            model.gateAppeared()
            duoStore.recheckAge()
        }
        .onDisappear {
            model.gateGone()
            // `needsTerms` means "the form that is up should show the rules". With this sheet gone
            // there is no request of its to send again.
            if duoStore.needsTerms { duoStore.needsTerms = false }
        }
    }

    /// Whether this gate brings the rules up over its form now: the server answered `428` to this
    /// form's request (the form is live: anything left up from before it appeared was put down
    /// then), and no other consent form is on top of this one.
    func showsTermsAgain(_ model: DuoConsentGateModel) -> Bool {
        DuoConsentFlow.presentsTermsAgain(step: step, needsTerms: duoStore.needsTerms, formIsLive: model.formIsLive,
                                          isTopmostForm: forms.isTopmost(model))
    }

    /// The birth-year screen. Its Close after a refusal closes the sheet; an allowed answer needs
    /// no call, since `ageStatus` is published and the step moves on by itself.
    func ageScreen() -> DuoAgeGateView {
        DuoAgeGateView(duoStore: duoStore, onAllowed: {}, onRefused: onClose)
    }

    /// The rules in place of the form. Accept records them on this phone (what the mint sends as
    /// `terms_version`) and the step moves to the form by itself; nothing was refused, so nothing
    /// is sent again and `onTermsAccepted` is not called. Cancel closes the sheet.
    func inPlaceTerms(_ model: DuoConsentGateModel) -> DuoTermsSheet {
        DuoTermsSheet(onAccept: { model.acceptInPlace(duoStore) }, onCancel: onClose,
                      message: duoStore.sheetError, isWorking: model.accepting == .inPlace)
    }

    /// The rules again, over the form, after a `428 terms_required`. Accept records them and tells
    /// the server; once that worked the sheet goes and the refused request is sent again. Cancel
    /// takes the sheet away and then closes the consent sheet, one sheet at a time.
    func termsAgain(_ model: DuoConsentGateModel) -> DuoTermsSheet {
        DuoTermsSheet(onAccept: { model.acceptOverForm(duoStore) }, onCancel: { model.cancelOverForm(duoStore) },
                      message: duoStore.sheetError ?? DuoConsentFlow.writesBlockedMessage(duoStore.availability),
                      isWorking: model.accepting == .overForm)
    }

    /// The rules sheet over the form has gone: only now is the refused request sent again, or the
    /// consent sheet closed, since closing a sheet while the one over it is still on its way out
    /// is dropped (repo CLAUDE.md: never dismiss two stacked sheets in the same turn).
    func termsAgainGone(_ model: DuoConsentGateModel) {
        model.termsSheetGone(onClose: onClose, onTermsAccepted: onTermsAccepted)
    }
}

/// What a consent gate does with the two terms screens' buttons and with its own comings and
/// goings, kept out of the view so it holds its state across redraws and a test can see and drive
/// it: one Accept at a time, what to do once the sheet over the form has gone, and nothing at all
/// once the gate itself has gone.
@MainActor
final class DuoConsentGateModel: ObservableObject {
    enum Acceptance: Equatable {
        /// The rules shown in place of the form.
        case inPlace
        /// The rules shown again over the form after a `428`.
        case overForm
    }

    /// An Accept under way, and where.
    @Published private(set) var accepting: Acceptance?
    /// The form is on screen and has put down whatever was left up before it appeared, so a `428`
    /// from now on is one its own request met.
    @Published private(set) var formIsLive = false
    /// Whether this gate's own rules sheet is on screen now, and how many times it has come up, so
    /// a test can tell which of two nested gates brought it up and that it never flashed up over a
    /// form for a flag left from before. Nothing is drawn from either.
    fileprivate(set) var termsAgainOnScreen = false
    fileprivate(set) var termsAgainPresentations = 0
    /// The gate has been on screen and has gone: whatever is still out may finish, but nothing is
    /// sent again and nobody is told (the parent may already have presented something else).
    private(set) var hasGone = false
    private(set) var isOnScreen = false
    /// The sheet's own request met a `428`: only then does an Accept send it again.
    private(set) var requestRefusedForTerms = false
    /// The last Accept's work, so a test can wait for it.
    private(set) var acceptance: Task<Void, Never>?

    /// Each time the sheet over the form goes, this moves on, so an Accept that was still out when
    /// the person cancelled cannot ask, later, for a request to be sent again.
    private var presentation = 0
    private var resendWhenGone = false
    private var closeWhenGone = false
    /// An Accept in place failed: its words (`sheetError`) are kept for the form that comes next.
    private var keepFailureForForm = false

    func gateAppeared() {
        isOnScreen = true
        hasGone = false
    }

    func gateGone() {
        isOnScreen = false
        hasGone = true
        formIsLive = false
    }

    /// The form came on screen. A `needsTerms` or a `sheetError` that is up now was raised before it
    /// existed, by a request of a sheet that has since gone (a Create still out when its sheet was
    /// closed, answered `428` afterwards), and left up it would bring the rules up over a form nobody
    /// has tapped, whose Accept would then send that form's request. The one exception is the words
    /// of this gate's own Accept in place, which failed just before the form came up.
    func formAppeared(_ store: DuoStore) {
        if store.needsTerms { store.needsTerms = false }
        if !keepFailureForForm, store.sheetError != nil { store.sheetError = nil }
        keepFailureForForm = false
        requestRefusedForTerms = false
        formIsLive = true
    }

    func formGone() {
        formIsLive = false
    }

    /// Accept on the rules in place of the form. `DuoStore.acceptTerms` records them on this phone
    /// and, for a phone that already has an identity, tells the server. A flag left up from earlier
    /// is put down by the form when it appears (`formAppeared`); the words of a failure here are
    /// kept for it.
    func acceptInPlace(_ store: DuoStore) {
        guard accepting == nil else { return }
        accepting = .inPlace
        acceptance = Task {
            if await !store.acceptTerms() {
                keepFailureForForm = store.sheetError != nil
            }
            accepting = nil
        }
    }

    /// Accept on the rules over the form. Only an acceptance that worked takes the sheet away and
    /// asks for the refused request to go again; one that failed leaves the sheet up with the
    /// service's words in it.
    func acceptOverForm(_ store: DuoStore) {
        guard accepting == nil else { return }
        accepting = .overForm
        let startedFor = presentation
        acceptance = Task {
            let accepted = await store.acceptTerms()
            accepting = nil
            guard accepted, startedFor == presentation, !closeWhenGone else { return }
            resendWhenGone = true
            store.needsTerms = false
        }
    }

    /// Cancel on the rules over the form: the sheet goes first, and the consent sheet closes once
    /// it has (`termsSheetGone`).
    func cancelOverForm(_ store: DuoStore) {
        closeWhenGone = true
        store.needsTerms = false
    }

    /// The sheet over the form has gone, for whichever reason. A gate that has itself gone does
    /// nothing: a rules sheet torn down with its parent fires this too, and a request sent then
    /// would go out, and its duo be handed on, after the person had left.
    func termsSheetGone(onClose: () -> Void, onTermsAccepted: () -> Void) {
        let resend = resendWhenGone
        let close = closeWhenGone
        resendWhenGone = false
        closeWhenGone = false
        presentation += 1
        guard isOnScreen, !hasGone else { return }
        if close {
            onClose()
        } else if resend {
            onTermsAccepted()
        }
    }

    /// The sheet's request was refused for the rules (`428`).
    func noteRequestRefusedForTerms() {
        requestRefusedForTerms = true
    }

    /// Whether there is a refused request to send again after an Accept, asked once.
    func takeRequestRefusedForTerms() -> Bool {
        defer { requestRefusedForTerms = false }
        return requestRefusedForTerms
    }
}

/// The consent forms on screen, so that of two gates whose forms are both up (one consent sheet
/// drawn inside another, nested either way round) only the one on top brings the rules up again:
/// the deeper one, or with equal depth (a gate pushed inside a `NavigationStack`, where the
/// environment does not reach) the one that appeared last. The person tapped the one on top, and
/// the other gate's Accept would send the other sheet's request.
@MainActor
final class DuoConsentForms: ObservableObject {
    static let shared = DuoConsentForms()

    private struct Entry {
        weak var model: DuoConsentGateModel?
        let depth: Int
        let order: Int
    }

    private var entries: [Entry] = []
    private var counter = 0
    @Published private(set) var revision = 0

    func appeared(_ model: DuoConsentGateModel, depth: Int) {
        entries.removeAll { $0.model == nil || $0.model === model }
        counter += 1
        entries.append(Entry(model: model, depth: depth, order: counter))
        revision += 1
    }

    func gone(_ model: DuoConsentGateModel) {
        entries.removeAll { $0.model == nil || $0.model === model }
        revision += 1
    }

    /// Whether `model`'s form is the one on top. A model that never told it its form appeared is
    /// not, so a gate whose form has not appeared yet brings nothing up.
    func isTopmost(_ model: DuoConsentGateModel) -> Bool {
        let live = entries.filter { $0.model != nil }
        guard let top = live.max(by: { ($0.depth, $0.order) < ($1.depth, $1.order) }) else { return false }
        return top.model === model
    }
}

private struct DuoConsentGateDepthKey: EnvironmentKey {
    static let defaultValue = 0
}

extension EnvironmentValues {
    fileprivate var duoConsentGateDepth: Int {
        get { self[DuoConsentGateDepthKey.self] }
        set { self[DuoConsentGateDepthKey.self] = newValue }
    }
}
#endif
