#if DUO_V2
import SwiftUI
import UserNotifications

/// Duo Streaks: start one, see how each is going, nudge, leave, block, clear, and delete it all
/// (final design §14's DuoView row). Pushed from Settings > Duo Streaks and from a Today card.
///
/// The screen itself is `DuoScreen`, built over the app's router here; a test builds it over a
/// router of its own, because the live one drives the running app (raising `showingSettings`
/// presents the real Settings sheet).
struct DuoView: View {
    private let duoStore: DuoStore

    init() {
        self.init(duoStore: .shared)
    }

    /// For a test or a preview: a store of its own (`DuoTestKit`, `DuoStore.makePreview`).
    init(duoStore: DuoStore) {
        self.duoStore = duoStore
    }

    var body: some View {
        DuoScreen(duoStore: duoStore, router: AppRouter.shared)
    }
}

/// The Duo Streaks screen. The structure is the iCloud version's (`git show
/// 0ac1327^:HydroDrop/Views/DuoView.swift`): a List with a section per duo, the nudge rows and their
/// preset dialog, an add row with the Plus lock, the notifications toggle and pull to refresh. What
/// each section draws, and what each tap does, is `DuoScreenModel`'s answer; this view draws it,
/// presents the sheets and each row's dialog.
///
/// Consent (§3.1): appearing sends nothing for a phone without a credential. Its one call on
/// appearing is `duoScreenOpened()`, once per time the screen is pushed (not again when it comes
/// back from Diagnostics or a report), the only place the identity is asked about with no duo
/// cached (§3.4 step 2: a restored phone finds out here whether to ask "Continue as <name>?"). Pull
/// to refresh is `refresh()`. Both do nothing without an identity.
struct DuoScreen<Router: DuoScreenRouterFlags & ObservableObject>: View {
    @ObservedObject private var duoStore: DuoStore
    @ObservedObject private var router: Router
    @ObservedObject private var store = StoreManager.shared
    private let notificationStatus: @MainActor () async -> UNAuthorizationStatus
    @Environment(\.scenePhase) private var scenePhase

    /// The dialog that is up, if any. Every row that ends, deletes or sends asks through one, and
    /// each row presents only its own.
    @State private var confirming: DuoScreenModel.Confirmation?
    /// A dialog to ask again (a delete whose words no longer held), held until the one whose button
    /// was pressed has gone: SwiftUI clears `confirming` only as that dialog finishes leaving, and
    /// a dialog set before then is wiped by that, or dropped while the old one is still on screen.
    @State private var askingAgain: DuoScreenModel.Confirmation?
    @State private var showingSetup = false
    @State private var showingAgeRecheck = false
    /// The setup sheet's new duo, held until that sheet has gone so its invite sheet can come up in
    /// its place rather than on top of it.
    @State private var handoff = DuoScreenModel.SetupHandoff()
    @State private var inviting: DuoScreenSheetItem?
    @State private var showingCodeEntry = false
    /// The pending invite when the code-entry sheet opened, so its dismissal can tell a code it
    /// published from an older one still waiting.
    @State private var pendingInviteWhenEntryOpened: DuoPendingInvite?
    @State private var showingReconnect = false
    @State private var reporting: DuoScreenSheetItem?
    @State private var paywallSource: PaywallSource?
    /// The screen has asked about the identity since it was pushed. A screen state, so it lasts
    /// while the screen is in the navigation stack (covered by Diagnostics, say) and starts over
    /// when it is pushed again.
    @State private var opened = false
    /// iOS has notifications off for the app (read, never asked, in `.task`).
    @State private var notificationsDenied = false
    /// The screen is on top of its stack: false while Diagnostics is pushed over it, where an alert
    /// asked for from here would be dropped (finding 12), as Settings' index tracks its own.
    @State private var screenIsVisible = false

    init(duoStore: DuoStore, router: Router,
         notificationStatus: (@MainActor () async -> UNAuthorizationStatus)? = nil) {
        _duoStore = ObservedObject(wrappedValue: duoStore)
        _router = ObservedObject(wrappedValue: router)
        self.notificationStatus = notificationStatus ?? { await DuoScreenNotifications.currentStatus() }
    }

    var body: some View {
        let context = makeContext(now: Date())
        List {
            if duoStore.needsAgeRecheck || duoStore.needsTermsAgain {
                Section {
                    Button(duoStore.needsAgeRecheck ? DuoScreenModel.recheckAgeRow : DuoScreenModel.recheckTermsRow) {
                        showingAgeRecheck = true
                    }
                    .accessibilityIdentifier("duo.agegate.recheck")
                } footer: {
                    Text(DuoScreenModel.recheckFooter)
                }
            }
            if duoStore.hasNoticeCards {
                Section {
                    DuoNoticeCards(duoStore: duoStore) { showingReconnect = true }
                }
            }

            ForEach(duoStore.duos) { duo in
                duoSection(duo, in: context)
            }

            addSection(in: context)

            if DuoScreenModel.showsNotificationsToggle(in: context) {
                Section {
                    Toggle(isOn: $duoStore.notificationsEnabled) {
                        Text(DuoScreenModel.notificationsToggle)
                    }
                    .accessibilityIdentifier("duo.notifications")
                    // The Reminders page's line: the switch says On while iOS will show nothing.
                    if duoStore.notificationsEnabled && notificationsDenied {
                        // Orange text was about 2.2:1 in light mode (finding 16): the words stay secondary
                        // and only the warning sign is orange.
                        Label {
                            Text(DuoScreenModel.notificationsDisabledInIOS).foregroundStyle(.secondary)
                        } icon: {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                            .font(.footnote)
                            .accessibilityIdentifier("duo.notifications.denied")
                    }
                } footer: {
                    Text(DuoCopy.notificationsFooter)
                }
            }

            if DuoScreenModel.showsDiagnostics(in: context) || DuoScreenModel.showsDelete(in: context) {
                identitySection(in: context)
            }

            Section {
                Link(destination: DuoScreenModel.rulesURL) {
                    Text(DuoScreenModel.rulesLink)
                }
                .accessibilityIdentifier("duo.terms.link")
            } footer: {
                // The last line, so a clean run still leaves an id to quote (§14); the list of
                // recent requests is Diagnostics'. Drawn only for an id the filter accepts.
                if let line = DuoScreenModel.requestIDLine(duoStore.lastRequestID) {
                    Text(verbatim: line)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .accessibilityIdentifier("duo.requestid")
                }
            }
        }
        .accessibilityIdentifier("duo.screen")
        .onAppear { screenIsVisible = true }
        .onDisappear { screenIsVisible = false }
        // A failure an Accept left is this sheet's and goes with it.
        .sheet(isPresented: $showingAgeRecheck, onDismiss: { duoStore.sheetError = nil }) {
            DuoAgeRecheckSheet(duoStore: duoStore) { showingAgeRecheck = false }
        }
        .navigationTitle(DuoScreenModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await duoStore.refresh() }
        .task {
            await readNotificationStatus()
            guard !opened else { return }
            opened = true
            await duoStore.duoScreenOpened()
        }
        .onChange(of: confirming == nil) { _, cleared in
            guard cleared, let next = askingAgain else { return }
            askingAgain = nil
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(450))
                confirming = next
            }
        }
        .onChange(of: duoStore.notificationsEnabled) { _, _ in Task { await readNotificationStatus() } }
        .onChange(of: scenePhase) { _, phase in
            // Back from iOS Settings, where the person may have turned notifications on or off.
            if phase == .active { Task { await readNotificationStatus() } }
        }
        // Starting, joining, leaving, deleting or a Start fresh waiting on its last drain: nothing
        // else is tapped until it is done, and the store says when it is.
        .disabled(duoStore.isWorking)
        .overlay {
            if duoStore.isWorking {
                ProgressView()
                    .controlSize(.large)
                    .accessibilityLabel(DuoScreenModel.workingLabel)
            }
        }
        // What went wrong, said here while the screen is pushed inside Settings (D87): Settings' own
        // alert sits on the stack's root, which SwiftUI will not present from while this screen
        // covers it. Not while a dialog or a sheet of this screen is up (it would be dropped under
        // it), and not when the screen was pushed from Today, where the root's alert says it. Not on
        // the stack's container either: presenting from there tore down an open code-entry sheet.
        .duoNoticeAlert(duoStore, showsWhen: noticeShowsHere)
        // The setup sheet is dismissed before the invite sheet is presented, from its onDismiss:
        // never two sheets in one turn.
        .sheet(isPresented: $showingSetup, onDismiss: setupDidDismiss) {
            DuoSetupSheet(duoStore: duoStore) { created in
                handoff.created(created.id)
                showingSetup = false
            }
        }
        .sheet(item: $inviting) { item in
            DuoInviteSheet(duoStore: duoStore, duoID: item.id)
        }
        .sheet(isPresented: $showingCodeEntry, onDismiss: codeEntryDidDismiss) {
            DuoCodeEntrySheet(duoStore: duoStore)
                .onAppear { DuoScreenRouting.entrySheetDidAppear(router: router) }
        }
        .sheet(isPresented: $showingReconnect) {
            DuoReconnectSheet(duoStore: duoStore)
        }
        .sheet(item: $reporting) { item in
            if let duo = duoStore.duo(item.id) {
                DuoReportSheet(duoStore: duoStore, duo: duo)
            }
        }
        .sheet(item: $paywallSource) { source in
            PaywallView(source: source)
        }
    }

    /// Whether this screen presents the store's notice now: inside Settings, with nothing of its
    /// own on top.
    private var noticeShowsHere: Bool {
        router.showingSettings && screenIsVisible && confirming == nil && !showingAgeRecheck && !showingSetup && inviting == nil && !showingCodeEntry
            && !showingReconnect && reporting == nil && paywallSource == nil && askingAgain == nil
    }

    // MARK: - Sections

    @ViewBuilder
    private func duoSection(_ duo: DuoState, in context: DuoScreenModel.Context) -> some View {
        let verdict = duoStore.nudgeVerdict(for: duo, now: context.now)
        let rows = DuoScreenModel.rows(for: duo, verdict: verdict, in: context)
        Section {
            // The card's own row holds stage G's actions too ("Not them? Leave & block", "Reconnect
            // <name>'s new phone"): G decides what applies and keeps its dialog and sheet there, so
            // neither is torn down when the offer goes. Nothing of it adds a row when it draws nothing.
            VStack(alignment: .leading, spacing: 12) {
                DuoCard(duoStore: duoStore, duo: duo, showsBackground: false)
                DuoCardActions(duoStore: duoStore, duo: duo)
            }
            DuoNudgeRows(rows: rows, confirming: $confirming, anchor: DuoScreenModel.Confirmation.anchor(.nudge, duo.id),
                         onSend: { tap(.nudge, on: duo, verdict: verdict) }, onConfirm: confirmed)
            if rows.showsInvite {
                Button { tap(.invite, on: duo) } label: {
                    Label(DuoScreenModel.sendInviteAgain, systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("duo.invite.show")
            }
            if let nickname = rows.nickname {
                DuoNicknameRow(duoStore: duoStore, duoID: duo.id, nickname: nickname)
            }
            if rows.showsReport {
                Button { tap(.report, on: duo) } label: {
                    Label(DuoCopy.reportAProblem, systemImage: "exclamationmark.bubble")
                }
                .accessibilityIdentifier("duo.report")
            }
            // The destructive rows colour their icons too: a destructive button in a List reddens only
            // its text, which left a red label beside a blue icon.
            if rows.showsLeave {
                Button(role: .destructive) { tap(.leave, on: duo) } label: {
                    Label(DuoScreenModel.leaveRow, systemImage: "rectangle.portrait.and.arrow.right")
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("duo.leave")
                .duoRowDialog($confirming, anchor: DuoScreenModel.Confirmation.anchor(.leave, duo.id), onConfirm: confirmed)
            }
            if rows.showsClear {
                Button(role: .destructive) { tap(.clear, on: duo) } label: {
                    Label(DuoScreenModel.clearRow, systemImage: "xmark.circle")
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("duo.clear")
                .duoRowDialog($confirming, anchor: DuoScreenModel.Confirmation.anchor(.clear, duo.id), onConfirm: confirmed)
            }
            if let block = rows.block {
                Button(role: .destructive) { tap(.block, on: duo) } label: {
                    // Holds the partner's name, isolated: verbatim, never a localized key or markdown.
                    Label { Text(verbatim: block) } icon: { Image(systemName: "hand.raised.fill") }
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("duo.block")
                .duoRowDialog($confirming, anchor: DuoScreenModel.Confirmation.anchor(.block, duo.id), onConfirm: confirmed)
            }
            if rows.showsStartFresh {
                Button(role: .destructive) { tap(.startFresh, on: duo) } label: {
                    Label(DuoCopy.disconnectedStartFresh, systemImage: "arrow.counterclockwise")
                        .foregroundStyle(.red)
                }
                .accessibilityIdentifier("duo.startFresh")
                .duoRowDialog($confirming, anchor: DuoScreenModel.Confirmation.anchor(.startFresh, duo.id), onConfirm: confirmed)
            }
        }
    }

    @ViewBuilder
    private func addSection(in context: DuoScreenModel.Context) -> some View {
        Section {
            switch DuoScreenModel.addRow(in: context) {
            case .start:
                Button { tap(.start) } label: {
                    Label(DuoScreenModel.startADuoStreak, systemImage: "person.2.fill")
                }
                .accessibilityIdentifier("duo.start")
            case .locked:
                Button { tap(.locked) } label: {
                    HStack {
                        Label(DuoScreenModel.startAnotherDuoStreak, systemImage: "person.2.fill")
                        Spacer(minLength: 8)
                        Image(systemName: "lock.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityHint(DuoScreenModel.partOfPlus)
                .accessibilityIdentifier("duo.start.locked")
            case .full:
                Label(DuoScreenModel.atTheLimit, systemImage: "person.2.fill")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("duo.start.full")
            case .hidden:
                EmptyView()
            }
            if DuoScreenModel.showsHaveCode(in: context) {
                Button { tap(.haveCode) } label: {
                    Label(DuoScreenModel.haveAnInviteCode, systemImage: "keyboard")
                }
                .accessibilityIdentifier("duo.haveCode")
            }
        } footer: {
            Text(DuoScreenModel.footer)
        }
    }

    /// Diagnostics while this phone holds a credential; Delete my Duo data too, except during the
    /// restore question. Not behind the availability banner: a banned member and a superseded phone
    /// can still delete (D33).
    private func identitySection(in context: DuoScreenModel.Context) -> some View {
        Section {
            if DuoScreenModel.showsDiagnostics(in: context) {
                NavigationLink {
                    DuoDiagnosticsView(duoStore: duoStore)
                } label: {
                    Text(DuoCopy.diagnostics)
                }
                .accessibilityIdentifier("duo.diagnostics")
            }
            if DuoScreenModel.showsDelete(in: context) {
                Button(role: .destructive) { tap(.delete) } label: {
                    Text(DuoScreenModel.deleteRow(credentialIsAThrowaway: context.credentialIsAThrowaway))
                }
                .accessibilityIdentifier("duo.delete")
                .duoRowDialog($confirming, anchor: DuoScreenModel.Confirmation.anchor(.delete, nil), onConfirm: confirmed)
            }
        } footer: {
            // A refused phone whose refusal DELETE /me failed: the way out, said (finding 1). Not for
            // one that was never sent, whose identity may be someone else's.
            if duoStore.refusalDeletion == .failed, DuoScreenModel.showsDelete(in: context), !context.credentialIsAThrowaway {
                Text(verbatim: DuoConsentFlow.NewCopy.refusalDataRemainsHere)
                    .accessibilityIdentifier("duo.refused.delete")
            }
        }
    }

    // MARK: - Taps

    private func makeContext(now: Date) -> DuoScreenModel.Context {
        DuoScreenModel.Context(duos: duoStore.duos, availability: duoStore.availability, nudgesPerDay: duoStore.nudgesPerDay,
                               hasIdentity: duoStore.hasIdentity, credentialIsAThrowaway: duoStore.hCredentialIsAThrowaway,
                               isSubscribed: store.isSubscribed, blocksSent: duoStore.blockedDuoIDs, now: now,
                               myToday: DayKey.key(for: now), sharingPaused: !duoStore.ageAllowsSharing)
    }

    /// Asks the model what a tap does, against the store as it is now, and does that.
    private func tap(_ row: DuoScreenModel.Row, on duo: DuoState? = nil, verdict: DuoNudgeRules.Verdict = .nobodyToNudge) {
        switch DuoScreenModel.tap(row, on: duo, verdict: verdict, in: makeContext(now: Date())) {
        case .confirm(let confirmation):
            confirming = confirmation
        case .present(let sheet):
            present(sheet)
        case .perform, .nothing:
            // A tap never acts by itself: everything that acts asks first.
            break
        }
    }

    /// A dialog's confirm button: the action is judged again against the store as it is now.
    private func confirmed(_ action: DuoScreenModel.Action) {
        var verdict = DuoNudgeRules.Verdict.nobodyToNudge
        if case .sendNudge(_, let id) = action, let duo = duoStore.duo(id) { verdict = duoStore.nudgeVerdict(for: duo) }
        switch DuoScreenModel.confirm(action, verdict: verdict, in: makeContext(now: Date())) {
        case .perform(let judged):
            let actions = DuoScreenActions(duoStore: duoStore)
            Task { await actions.perform(judged) }
        case .confirm(let again):
            // The words no longer held (a delete's throwaway marker came or went): ask again with the
            // right ones, once this dialog has gone (`askingAgain`). If SwiftUI has already cleared
            // it, the old dialog is still on its way out: wait for that instead.
            if confirming == nil {
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(900))
                    confirming = again
                }
            } else {
                askingAgain = again
            }
        case .present, .nothing:
            break
        }
    }

    private func present(_ sheet: DuoScreenModel.Sheet) {
        switch sheet {
        case .setup:
            showingSetup = true
        case .invite(let id):
            inviting = DuoScreenSheetItem(id: id)
        case .codeEntry:
            pendingInviteWhenEntryOpened = duoStore.pendingInvite
            showingCodeEntry = true
        case .report(let id):
            reporting = DuoScreenSheetItem(id: id)
        case .paywall:
            paywallSource = .lockedDuo
        }
    }

    private func setupDidDismiss() {
        if let id = handoff.setupDidDismiss() { inviting = DuoScreenSheetItem(id: id) }
    }

    private func codeEntryDidDismiss() {
        DuoScreenRouting.entrySheetDidDismiss(router: router, pendingInvite: duoStore.pendingInvite, before: pendingInviteWhenEntryOpened)
        pendingInviteWhenEntryOpened = nil
    }

    private func readNotificationStatus() async {
        let denied = await notificationStatus() == .denied
        if denied != notificationsDenied { notificationsDenied = denied }
    }
}

/// The age question, then the rules if a reinstall cleared them, through the consent sheets' own
/// gate, Cancel included (findings 5 and 11). It used to be the age screen alone, so a reinstalled
/// phone answered it and stayed suspended for want of the rules. Its form is nothing: reaching it
/// means both are answered, so sharing resumes and the sheet closes. The Duo screen and Today
/// (finding 8) both present it.
struct DuoAgeRecheckSheet: View {
    @ObservedObject var duoStore: DuoStore
    var close: () -> Void

    var body: some View {
        DuoConsentGate(duoStore: duoStore, onClose: close, onTermsAccepted: {}) {
            Color.clear.onAppear {
                close()
                Task { await duoStore.resumeAfterAgeRecheck() }
            }
        }
    }
}
#endif
