#if DUO_V2
import SwiftUI

/// Shown when an invite is opened, by link, QR code or a typed code (final design §4.2, §4.3 steps 4
/// to 9). Nothing is accepted until Join is tapped: the tap is the consent (§3.1).
///
/// It is the iCloud version's join sheet with the server in it. The one request it makes before the
/// tap is the peek, which says who sent the invite and what the code is for, and it is made only once
/// the consent gate shows the content, so nothing is asked for a person whose age is unknown or who
/// was refused. `DuoStore.peek` decides whether it carries this phone's bearer (D34: then a person
/// someone blocked sees nothing of them, and the sheet shows the same 404 words as for any code that
/// is gone, never who blocked whom). After a failed peek there is no Join to tap, so no redeem
/// follows one.
///
/// Everything the sheet decides is `DuoJoinSheetModel`'s (which rows to draw, the name, the tap, the
/// gate's two callbacks, closing), and the pure rules under it are `DuoJoinPlan`'s in HydroCore, so
/// the tests reach them. The view draws the rows and passes the taps on, and nothing else: an earlier
/// version kept the tap's arguments and the gate's wiring in the view, where no test could see a
/// mutant that sent the wrong name or never tapped Join again after the rules.
///
/// The root presents it for `duoStore.pendingInvite` and drops the invite when it is dismissed by
/// any route, so "Not now" and Close only dismiss. A successful join clears the invite itself (the
/// service does it), and a link's secret `k` is the service's to keep: it is never shown here.
struct DuoJoinSheet: View {
    @ObservedObject var duoStore: DuoStore
    let invite: DuoPendingInvite

    @StateObject private var model: DuoJoinSheetModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// `model` is for tests, which draw the sheet in a given state; the root passes none.
    init(duoStore: DuoStore, invite: DuoPendingInvite, model: DuoJoinSheetModel? = nil) {
        self.duoStore = duoStore
        self.invite = invite
        _model = StateObject(wrappedValue: model ?? DuoJoinSheetModel(store: duoStore))
    }

    var body: some View {
        Group {
            if model.showsReconnectSheet {
                // A code made for this person's new phone is their own duo coming back, not a new one:
                // the reconnect sheet is the whole content, with its own gate and its own consent, and
                // it dismisses itself on success, which drops the invite like any other way out. It is
                // not put inside this sheet's gate as well: two gates would each answer a 428 with a
                // terms sheet, and this one's would tap Join afterwards.
                DuoReconnectSheet(duoStore: duoStore, prefilledCode: invite.code)
            } else {
                DuoConsentGate(duoStore: duoStore, onClose: { model.close() },
                               onTermsAccepted: { Task { await model.termsAccepted(duoStore, invite: invite) } }) {
                    joinStack
                }
            }
        }
        // A swipe while the Join is out would take the sheet away with no word about the duo it is
        // making; the request finishes either way, but the person is left guessing.
        .interactiveDismissDisabled(duoStore.isWorking)
        .onChange(of: model.wantsDismiss) { _, wants in if wants { dismiss() } }
    }

    private var joinStack: some View {
        NavigationStack {
            Form {
                ForEach(model.rows(duoStore), id: \.self) { row in
                    draw(row)
                }
            }
            .navigationTitle("Join a duo streak")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(model.closesWithNotNow ? "Not now" : "Close") { model.close() }
                        .accessibilityIdentifier("duo.join.cancel")
                }
            }
        }
        // Here, on the content the gate lets through, and nowhere above it: the gate keeps this off
        // screen until the person is old enough and has accepted the rules. The model holds the age
        // rule a second time, where the request is made, so content shown too early (the gate's
        // stub, or a gate that misjudged) waits rather than asks. The task runs again when the answer
        // changes or the person asks to try again; the model asks once for each.
        .task(id: DuoJoinSheetModel.PeekKey(ageStatus: duoStore.ageStatus, attempt: model.attempt)) {
            await model.peekIfNeeded(duoStore, invite: invite)
        }
        .onDisappear { model.disappeared(duoStore) }
    }

    @ViewBuilder
    private func draw(_ row: DuoJoinSheetModel.Row) -> some View {
        switch row {
        case .loading:
            Section {
                ProgressView()
                    .frame(maxWidth: .infinity)
            }
        case .banner(let text, let skin, let isSample):
            Section { banner(text: text, skin: skin, isSample: isSample) }
        case .name:
            Section {
                TextField("Your first name", text: $model.name)
                    .textContentType(.givenName)
                    .textInputAutocapitalization(.words)
                    .autocorrectionDisabled()
                    .submitLabel(.done)
                    .accessibilityIdentifier("duo.join.name")
            } footer: {
                Text(verbatim: DuoCopy.partnerSeesFooter)
            }
        case .explainer:
            DuoExplainer(context: .join)
        case .error(let text), .failure(let text):
            Section { Self.line(text, color: .red) }
        case .blocked(let text):
            Section { Self.line(text, color: .secondary) }
        case .restore(let question):
            Section {
                Self.line(question, color: .primary)
                Button {
                    Task { await model.continueRestored(duoStore) }
                } label: {
                    Text(verbatim: DuoCopy.restoreContinue)
                }
                .accessibilityIdentifier("duo.join.restore.continue")
                Button(role: .destructive) {
                    model.startFresh(duoStore, invite: invite)
                } label: {
                    Text(verbatim: DuoCopy.restoreStartFresh)
                }
                .accessibilityIdentifier("duo.join.restore.fresh")
            }
        case .join(let enabled, let working):
            Section {
                Self.joinButton(enabled: enabled, working: working) {
                    Task { await model.tapJoin(duoStore, invite: invite) }
                }
            }
        case .tryAgain:
            Section {
                Button {
                    model.tryAgain()
                } label: {
                    Text(verbatim: DuoJoinPlan.tryAgain) // NEW COPY
                }
                .accessibilityIdentifier("duo.join.retry")
            }
        case .hadADuo:
            // A disconnected phone is not asked the peek (its bearer earns only `device_revoked`), and
            // it is the phone a reconnect code is for: "I had a duo" takes this code to the reconnect
            // sheet.
            Section {
                Button {
                    model.showReconnect()
                } label: {
                    Text(verbatim: DuoCopy.disconnectedHadADuo)
                }
            }
        case .unsupported:
            Section { Self.line(DuoJoinPlan.unsupportedLine, color: .primary) } // NEW COPY
        }
    }

    private func banner(text: String, skin: String?, isSample: Bool) -> some View {
        let layout = dynamicTypeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
                                                         : AnyLayout(HStackLayout(spacing: 14))
        return layout {
            MascotView(progress: 1, size: 72, skin: MascotSkin(rawValue: skin ?? "") ?? .classic, isAnimated: false)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                Self.bannerText(text)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                if isSample {
                    // The App Review partner (§7.13), marked as the card marks it.
                    Text(verbatim: DuoCopy.sampleBadge)
                        .font(.caption.weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.secondary.opacity(0.15)))
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    // MARK: - The drawing that tests render on their own

    /// The banner's sentence, which holds the inviter's name: verbatim, so a name that looks like
    /// markdown or a link is drawn as the characters it is.
    static func bannerText(_ text: String) -> Text { Text(verbatim: text) }

    static func line(_ text: String, color: Color) -> some View {
        Text(verbatim: text)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Join, with a progress indicator while the request is out, and off while it is or while the
    /// phone may not write.
    static func joinButton(enabled: Bool, working: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if working {
                    ProgressView()
                } else {
                    Text(verbatim: DuoCopy.join)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .disabled(!enabled)
        .accessibilityLabel(Text(verbatim: DuoCopy.join))
        .accessibilityIdentifier("duo.join.confirm")
    }
}

/// What the join sheet has learned about its invite and what it draws, kept apart from the view so a
/// test drives the very methods the sheet calls and reads the very rows it draws.
@MainActor
final class DuoJoinSheetModel: ObservableObject {
    enum Stage: Equatable {
        /// Nothing asked yet, or the peek is out.
        case waiting
        case answered(DuoPeek)
        /// The peek brought no answer, and this is what the sheet says about it, fixed when the
        /// answer came back.
        case failed(String)
        /// "I had a duo" on a disconnected phone's failure: the reconnect sheet, with no peek.
        case reconnect
    }

    /// One section of the sheet, in order.
    enum Row: Hashable {
        case loading
        case banner(text: String, skin: String?, isSample: Bool)
        case name
        case explainer
        case error(String)
        case blocked(String)
        /// The restore question, with "Continue" and "Not me, start fresh".
        case restore(String)
        case join(enabled: Bool, working: Bool)
        case failure(String)
        case tryAgain
        case hadADuo
        case unsupported
    }

    /// What the peek's task is keyed on: it runs again when the age answer changes or the person
    /// asks to try again.
    struct PeekKey: Equatable {
        var ageStatus: DuoAgeStatus
        var attempt: Int
    }

    @Published private(set) var stage: Stage
    /// The first-name field. Stopped at the longest name that can be sent as it is typed.
    @Published var name: String {
        didSet {
            let capped = DuoJoinPlan.cappedName(name)
            if capped != name { name = capped }
        }
    }
    @Published private(set) var attempt = 0
    /// Set when the sheet should go: Close, "Not now", the gate's own close, or a join that worked.
    @Published private(set) var wantsDismiss = false
    private var peekStarted: Bool

    init(stage: Stage = .waiting, name: String = "") {
        self.stage = stage
        self.name = DuoJoinPlan.cappedName(name)
        peekStarted = stage != .waiting
    }

    /// The model the sheet makes for itself: the field starts from the name last typed, or the one
    /// the server holds (`DuoJoinPlan.prefilledName`).
    convenience init(store: DuoStore) {
        self.init(name: DuoJoinPlan.prefilledName(typed: store.myDisplayName, serverName: store.memberInfo?.displayName))
    }

    var plan: DuoJoinPlan.Plan? {
        guard case .answered(let peek) = stage else { return nil }
        return DuoJoinPlan.make(peek: peek)
    }

    /// Only an answered invite (or the sample partner's) has a Join to tap. A failed peek, a code
    /// this version cannot use and a reconnect code have none, so no redeem ever follows them.
    var offersJoin: Bool {
        if case .invite = plan { return true }
        return false
    }

    var showsReconnectSheet: Bool {
        if stage == .reconnect { return true }
        if case .reconnect = plan { return true }
        return false
    }

    /// "Not now" on the form and while waiting, as the iCloud sheet said; Close where there is
    /// nothing to join.
    var closesWithNotNow: Bool { offersJoin || stage == .waiting }

    func rows(_ store: DuoStore) -> [Row] {
        switch stage {
        case .waiting:
            return [.loading]
        case .failed(let text):
            if let prompt = DuoJoinPlan.restorePrompt(in: store.availability) {
                return [.restore(DuoJoinPlan.restoreQuestion(prompt))]
            }
            var rows: [Row] = [.failure(text)]
            if DuoJoinPlan.failureMayPass(text) { rows.append(.tryAgain) }
            if DuoJoinPlan.offersReconnect(availability: store.availability) { rows.append(.hadADuo) }
            return rows
        case .answered:
            switch plan {
            case .invite(let inviterName, let inviterSkin, _, let isSample):
                var rows: [Row] = [.banner(text: DuoJoinPlan.banner(inviterName: inviterName), skin: inviterSkin, isSample: isSample),
                                   .name, .explainer]
                if let error = store.sheetError, !error.isEmpty { rows.append(.error(error)) }
                if let prompt = DuoJoinPlan.restorePrompt(in: store.availability) {
                    rows.append(.restore(DuoJoinPlan.restoreQuestion(prompt)))
                } else if let blocked = DuoJoinPlan.joinBlockedLine(availability: store.availability), blocked != store.sheetError {
                    rows.append(.blocked(blocked))
                }
                rows.append(.join(enabled: DuoJoinPlan.joinIsEnabled(isWorking: store.isWorking, availability: store.availability),
                                  working: store.isWorking))
                return rows
            case .unsupported, .none:
                return [.unsupported]
            case .reconnect:
                return []
            }
        case .reconnect:
            return []
        }
    }

    // MARK: - What the sheet does

    /// The peek, once for each attempt, and only for someone the birth-year screen let through.
    func peekIfNeeded(_ store: DuoStore, invite: DuoPendingInvite) async {
        guard !peekStarted, DuoJoinPlan.mayPeek(ageStatus: store.ageStatus) else { return }
        peekStarted = true
        if let answer = await store.peek(code: invite.code) {
            stage = .answered(answer)
        } else if Task.isCancelled {
            // The sheet went away while the peek was out. A cancelled request says nothing about the
            // code and the service said nothing, so there is no failure to show: the next time the
            // content appears it asks again, and nothing is scheduled meanwhile.
            peekStarted = false
        } else {
            stage = .failed(DuoJoinPlan.failureText(sheetError: store.sheetError, availability: store.availability))
        }
    }

    /// The Join tap, which is the consent, with the name as typed: the service cleans it
    /// (`DuoState.cleanedName`) and sends none for an empty field. The sheet goes once the person is
    /// in the duo; a refusal stays on screen in the service's words. A second tap while the first is
    /// out is the service's to refuse, which it does before anything else (one flow at a time), and
    /// the button is off while it works.
    func tapJoin(_ store: DuoStore, invite: DuoPendingInvite) async {
        guard offersJoin else { return }
        if await store.join(invite, named: name) != nil { wantsDismiss = true }
    }

    /// The gate's `onTermsAccepted`: the rules a `428` brought up were accepted, so the refused Join
    /// is tapped again, once. Nothing for a sheet with no Join.
    func termsAccepted(_ store: DuoStore, invite: DuoPendingInvite) async {
        await tapJoin(store, invite: invite)
    }

    /// Close, "Not now", or the gate's `onClose` (a refusal read, the rules declined).
    func close() { wantsDismiss = true }

    /// A failure that may pass: ask again, once.
    func tryAgain() {
        guard case .failed = stage else { return }
        restartPeek()
    }

    private func restartPeek() {
        stage = .waiting
        peekStarted = false
        attempt += 1
    }

    /// "Continue" on the restore question: the identity takes the restored answer, and the peek is
    /// asked again with it.
    func continueRestored(_ store: DuoStore) async {
        await store.continueAsRestored()
        restartPeek()
    }

    /// "Not me, start fresh" on the restore question. During the question the wipe happens at once
    /// (nothing queued is drained for an identity the person is disowning), and it forgets the pending
    /// invite with everything else, which would take this sheet down; so the invite this sheet is for
    /// is received again in the same turn, before anything is drawn, and asked about anew, now from a
    /// phone with no identity.
    func startFresh(_ store: DuoStore, invite: DuoPendingInvite) {
        store.startFresh()
        store.receive(DuoParsedInvite(code: invite.code, k: invite.k))
        // An anonymous preview may already have answered while the restore question was up.
        // Forget that attempt and the previous person's name even in the answered phase.
        name = ""
        restartPeek()
    }

    func showReconnect() {
        guard case .failed = stage else { return }
        stage = .reconnect
    }

    /// The sheet left the screen: its words go with it, as the setup and reconnect sheets' do, so
    /// the next sheet does not open on them.
    func disappeared(_ store: DuoStore) { store.sheetError = nil }
}
#endif
