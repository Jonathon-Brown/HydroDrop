#if DUO_V2
import SwiftUI
import UserNotifications

// The Duo screen's parts that are not the screen itself: the rows it draws under each card, the
// dialog each row presents, what a confirmed dialog does, the
// Settings row and its hand-offs with the router. What to draw and what a tap does are decided in
// HydroCore's `DuoScreenModel`; these only draw its answers and carry out its actions, through
// `DuoStore` and nothing below it. Settings uses the row and the two modifiers below as they are,
// so a test that hosts them hosts exactly what Settings shows.

// MARK: - What the screen reads from the store

extension DuoStore {
    /// Whether the stored credential is the throwaway a refused or cut-short Reconnect left behind
    /// (D68). Leave and Block are hidden then, and Delete my Duo data says it deletes the Duo data
    /// from this phone. Read here so the screen still asks the store alone; named for stage H, as a
    /// member a stage adds to a foundation type must be (it moves onto the store at integration).
    var hCredentialIsAThrowaway: Bool { dependencies?.credentialIsAThrowaway ?? false }
}

// MARK: - Errors said in place

/// Speaks a line to VoiceOver. A test replaces `post` to hear what would be said.
@MainActor
enum DuoVoiceOver {
    static var post: (String) -> Void = { AccessibilityNotification.Announcement($0).post() }
}

extension View {
    /// Says `text` to VoiceOver when this view appears and whenever the text changes (finding 7). An
    /// error drawn in place under a button that keeps the focus (a code that is not one, a failed
    /// Create, Join, Reconnect or Accept) was otherwise never heard. iOS 17 has it, so no check.
    func duoAnnounced(_ text: String) -> some View {
        onAppear { DuoVoiceOver.post(text) }
            .onChange(of: text) { _, changed in DuoVoiceOver.post(changed) }
    }
}

// MARK: - Doing what a dialog confirmed

/// Carries out what a confirmation asked for, once its button was pressed and the model judged it
/// again. Each action looks the duo up in the store afresh rather than trusting the copy the dialog
/// was drawn from, which may be minutes old by the time the button is pressed.
@MainActor
struct DuoScreenActions {
    let duoStore: DuoStore

    func perform(_ action: DuoScreenModel.Action) async {
        switch action {
        case .leave(let id):
            guard let duo = duoStore.duo(id) else { return }
            await duoStore.leave(duo)
        case .block(let id):
            guard let duo = duoStore.duo(id) else { return }
            await duoStore.block(duo)
        case .clear(let id):
            guard let duo = duoStore.duo(id) else { return }
            duoStore.clear(duo)
        case .deleteMyData:
            // The wording was checked against the throwaway marker when the button was pressed
            // (`DuoScreenModel.confirm`). A failure arrives as `duoStore.notice`, which the screen shows.
            _ = await duoStore.deleteMyData()
        case .sendNudge(let preset, let id):
            guard let duo = duoStore.duo(id) else { return }
            await duoStore.sendNudge(preset, in: duo)
        case .startFresh:
            // It may finish up to five seconds later, after one last drain of a queued leave or
            // block; the screen follows `isWorking` and the store, and assumes nothing here.
            duoStore.startFresh()
        }
    }

}

// MARK: - The router

/// The three router flags the Duo screen and its Settings row read and write. `AppRouter` is the
/// one the app uses; a test hands in an object of its own, because the running test host acts on
/// the live router: raising its `showingSettings` presents the real Settings sheet, which with Duo
/// on builds the live store over the real Keychain and App Group defaults.
@MainActor
protocol DuoScreenRouterFlags: AnyObject {
    var showingDuoScreen: Bool { get set }
    var showingSettings: Bool { get set }
    var duoEntrySheetIsOnScreen: Bool { get set }
}

extension AppRouter: DuoScreenRouterFlags {}

/// The hand-offs between the Duo screen and the root's routing (`AppRouter`), kept out of the
/// views so a test can hold them to their rules.
@MainActor
enum DuoScreenRouting {
    /// A tapped Duo notification raises `showingDuoScreen` (stage F), which the root turns into
    /// Settings (stage K), often before Settings exists. The Settings row takes it on appear and
    /// whenever it changes: true means push the Duo screen, and the flag is lowered as it is taken,
    /// so an old request never pushes the screen again. Not while Settings is on its way out
    /// (`showingSettings` already false): a screen pushed into a leaving sheet vanishes with it, so
    /// the flag stays up for the root, which opens Settings again once it has gone.
    static func takeDuoScreenRequest(from router: DuoScreenRouterFlags) -> Bool {
        guard router.showingDuoScreen, router.showingSettings else { return false }
        router.showingDuoScreen = false
        return true
    }

    /// The code-entry sheet has come up: the root holds its join sheet back while it is there.
    static func entrySheetDidAppear(router: DuoScreenRouterFlags) {
        router.duoEntrySheetIsOnScreen = true
    }

    /// The code-entry sheet has finished leaving. Settings closes from here, and only when the
    /// sheet published a pending invite (`DuoScreenModel.closesSettingsAfterEntry`): never in the
    /// turn the entry sheet closes itself, because two stacked sheets must not be dismissed
    /// together (CLAUDE.md; `WeeklyRecapView.onSeeInsights` waits the same way). The root's join
    /// sheet then comes up once both have gone.
    static func entrySheetDidDismiss(router: DuoScreenRouterFlags, pendingInvite: DuoPendingInvite?, before: DuoPendingInvite?) {
        router.duoEntrySheetIsOnScreen = false
        if DuoScreenModel.closesSettingsAfterEntry(pendingInvite: pendingInvite, before: before) {
            router.showingSettings = false
        }
    }
}

// MARK: - Settings

/// Settings' one row for Duo Streaks (an area of its own, CLAUDE.md), with how many duos are live in
/// words. A button rather than a `NavigationLink`, so the row and a tapped notification push the
/// screen through the one `showingDuo`: a second push while the screen is up does nothing, where a
/// link and a separate destination used to stack a second Duo screen on the first.
struct DuoSettingsRow: View {
    @ObservedObject var duoStore: DuoStore
    @Binding var showingDuo: Bool

    var body: some View {
        Button {
            showingDuo = true
        } label: {
            HStack(spacing: 8) {
                SettingsRowLabel("Duo Streaks", systemImage: "person.2.fill", color: .green,
                                 value: DuoScreenModel.settingsRowValue(liveDuos: duoStore.activeDuos.count))
                    .foregroundStyle(Color(.secondaryLabel))
                // The disclosure chevron a NavigationLink row draws, so the row reads as its neighbours do.
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(.tertiaryLabel))
                    .accessibilityHidden(true)
            }
        }
        .accessibilityIdentifier("settings.duo")
    }
}

/// What Settings' list does for the Duo screen: pushes it for the row and for a tapped notification
/// (taken on appear, since the request is raised before Settings exists, and whenever it changes).
struct DuoSettingsHooks<Router: DuoScreenRouterFlags & ObservableObject, Destination: View>: ViewModifier {
    @ObservedObject var router: Router
    @Binding var showingDuo: Bool
    @ViewBuilder var destination: () -> Destination

    func body(content: Content) -> some View {
        content
            .navigationDestination(isPresented: $showingDuo, destination: destination)
            // Consuming the request publishes a router change. On appear runs while SwiftUI
            // is updating the navigation tree; the task waits until that update has finished.
            .task(id: router.showingDuoScreen) { take() }
    }

    private func take() {
        if DuoScreenRouting.takeDuoScreenRequest(from: router) { showingDuo = true }
    }
}

/// Settings' "Duo Streaks" alert for `duoStore.notice`, which the root's alert cannot show under
/// the sheet. It only presents while the index itself is showing: SwiftUI will not present from
/// the stack's root while the Duo screen covers it, so the Duo screen carries the same alert.
struct DuoSettingsNoticeAlert<Router: DuoScreenRouterFlags & ObservableObject>: ViewModifier {
    @ObservedObject var router: Router
    @ObservedObject var duoStore: DuoStore
    /// No sheet of the index's own is up (the paywall, Event counts, Report a Bug, the intro).
    var nothingCovers = true
    @State private var indexIsVisible = false

    func body(content: Content) -> some View {
        content
            .onAppear { indexIsVisible = true }
            .onDisappear { indexIsVisible = false }
            // NavigationStack retains the index while a detail page is pushed. Its alert must
            // relinquish presentation to that page rather than race the page for the same notice.
            .duoNoticeAlert(duoStore, showsWhen: router.showingSettings && indexIsVisible && nothingCovers)
    }
}

extension View {
    /// The "Duo Streaks" alert (the iCloud version's title, an OK button) for the store's notice.
    func duoNoticeAlert(_ duoStore: DuoStore, showsWhen allowed: Bool) -> some View {
        modifier(DuoNoticePresentation(duoStore: duoStore, allowed: allowed))
    }
}

/// SwiftUI can change the desired alert while UIKit is still animating its entrance. Dropping
/// the binding during that transition crashes UIKit on iOS 27, so both directions wait for the
/// actual transition to complete. Cancelling the task discards a superseded request.
private struct DuoNoticePresentation: ViewModifier {
    @ObservedObject var duoStore: DuoStore
    let allowed: Bool
    @State private var presented = false

    private struct Request: Equatable {
        let allowed: Bool
        let notice: String?
        let presented: Bool
    }

    func body(content: Content) -> some View {
        let notice = duoStore.notice
        return content
            .task(id: Request(allowed: allowed, notice: notice, presented: presented)) {
                await DuoPresentationTransitions.waitUntilSettled()
                guard !Task.isCancelled else { return }
                presented = allowed && notice != nil
            }
            .alert(DuoScreenModel.title, isPresented: $presented) {
                Button("OK", role: .cancel) {
                    if duoStore.notice == notice { duoStore.notice = nil }
                }
            } message: {
                Text(verbatim: notice ?? "")
            }
    }
}

/// UIKit owns the completion boundary, including a sheet's children and its alert. A timer is
/// not proof that an animation has completed on a busy device or with different motion settings.
@MainActor
enum DuoPresentationTransitions {
    // SwiftUI restarts the task when its notice changes. UIKit can still expose the same
    // completed coordinator then, so remember actual completion across those separate waits.
    private static let completed = CompletedTransitions()

    static func waitUntilSettled() async {
        while !Task.isCancelled, let coordinator = currentCoordinator(excluding: completed.identifiers) {
            let completion = TransitionCompletion()
            await withTaskCancellationHandler {
                await withCheckedContinuation { continuation in
                    completion.install(continuation)
                    guard !Task.isCancelled else { completion.resume(); return }
                    let registered = coordinator.animate(alongsideTransition: nil) { [weak coordinator] _ in
                        Task { @MainActor in
                            if let coordinator { completed.record(coordinator) }
                            completion.resume()
                        }
                    }
                    // UIKit may still call completion when registration returns false.
                    if !registered { completion.resume() }
                }
            } onCancel: {
                // Cancellation ends this wait, never the UIKit transition or its completion record.
                Task { @MainActor in completion.resume() }
            }
            await Task.yield()
        }
    }

    @MainActor
    private final class TransitionCompletion {
        private var continuation: CheckedContinuation<Void, Never>?

        private var finished = false

        func install(_ continuation: CheckedContinuation<Void, Never>) {
            if finished { continuation.resume() } else { self.continuation = continuation }
        }

        func resume() {
            guard !finished else { return }
            finished = true
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    @MainActor
    private final class CompletedTransitions {
        private final class Entry {
            weak var coordinator: UIViewControllerTransitionCoordinator?
            init(_ coordinator: UIViewControllerTransitionCoordinator) { self.coordinator = coordinator }
        }
        private var entries: [Entry] = []

        var identifiers: Set<ObjectIdentifier> {
            // Dead entries cannot hide a new coordinator whose allocation reuses the address.
            // Weak references also avoid retaining UIKit's completed presentation hierarchy.
            entries.removeAll { $0.coordinator == nil }
            return Set(entries.compactMap { $0.coordinator }.map { ObjectIdentifier($0) })
        }

        func record(_ coordinator: UIViewControllerTransitionCoordinator) {
            guard !identifiers.contains(ObjectIdentifier(coordinator)) else { return }
            entries.append(Entry(coordinator))
        }
    }

    private static func currentCoordinator(excluding completed: Set<ObjectIdentifier>) -> UIViewControllerTransitionCoordinator? {
        func find(_ controller: UIViewController, in window: UIWindow) -> UIViewControllerTransitionCoordinator? {
            if let presented = controller.presentedViewController, let found = find(presented, in: window) { return found }
            for child in controller.children {
                if let found = find(child, in: window) { return found }
            }
            guard controller.viewIfLoaded?.window === window,
                  let coordinator = controller.transitionCoordinator,
                  !completed.contains(ObjectIdentifier(coordinator)) else { return nil }
            return coordinator
        }
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            guard scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive else { continue }
            for window in scene.windows where !window.isHidden && window.alpha > 0 {
                if let root = window.rootViewController, let found = find(root, in: window) { return found }
            }
        }
        return nil
    }
}

// MARK: - Dialogs

/// A row's own confirmation dialog: presented only while the screen's one `confirming` is this
/// row's (`Confirmation.anchor`), so iOS 26 anchors the popover to the row that asked rather than
/// to the middle of the list.
struct DuoRowDialog: ViewModifier {
    @Binding var confirming: DuoScreenModel.Confirmation?
    let anchor: String
    let onConfirm: (DuoScreenModel.Action) -> Void

    private var mine: DuoScreenModel.Confirmation? { confirming?.id == anchor ? confirming : nil }

    func body(content: Content) -> some View {
        content.confirmationDialog(
            Text(verbatim: mine?.title ?? ""),
            isPresented: Binding(get: { mine != nil }, set: { if !$0, confirming?.id == anchor { confirming = nil } }),
            titleVisibility: .visible,
            presenting: mine
        ) { confirmation in
            if confirmation.presets.isEmpty {
                Button(role: .destructive) {
                    if let action = confirmation.action() { onConfirm(action) }
                } label: {
                    Text(verbatim: confirmation.confirmLabel ?? "")
                }
            } else {
                ForEach(confirmation.presets) { preset in
                    Button {
                        if let action = confirmation.action(preset: preset) { onConfirm(action) }
                    } label: {
                        Text(verbatim: preset.text)
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { confirmation in
            Text(verbatim: confirmation.message)
        }
    }
}

extension View {
    func duoRowDialog(_ confirming: Binding<DuoScreenModel.Confirmation?>, anchor: String,
                      onConfirm: @escaping (DuoScreenModel.Action) -> Void) -> some View {
        modifier(DuoRowDialog(confirming: confirming, anchor: anchor, onConfirm: onConfirm))
    }
}

// MARK: - Rows

/// The way to send a nudge, or the reason there is none to send, and the last thing the partner
/// sent: the iCloud screen's rows, drawn from the model. At the accessibility sizes the label and
/// "N left today" stack, where side by side they broke "Send a nudge" mid-word.
struct DuoNudgeRows: View {
    let rows: DuoScreenModel.DuoRows
    @Binding var confirming: DuoScreenModel.Confirmation?
    let anchor: String
    let onSend: () -> Void
    let onConfirm: (DuoScreenModel.Action) -> Void

    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        switch rows.nudge {
        case .send(let remaining, let enabled)?:
            Button(action: onSend) {
                let stacked = typeSize.isAccessibilitySize
                let layout = stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout())
                layout {
                    Label(DuoScreenModel.sendNudge, systemImage: "hand.wave.fill")
                    if !stacked { Spacer(minLength: 8) }
                    Text(DuoScreenModel.nudgesLeft(remaining))
                        .font(.caption)
                        .foregroundStyle(Color(.secondaryLabel))
                }
            }
            .disabled(!enabled)
            .accessibilityIdentifier("duo.nudge")
            .duoRowDialog($confirming, anchor: anchor, onConfirm: onConfirm)
        case .allSent(let line)?:
            Label { Text(verbatim: line) } icon: { Image(systemName: "hand.wave") }
                .foregroundStyle(.secondary)
        case .partnerMet(let line)?:
            // Holds the partner's name: drawn verbatim, never as a localized key or markdown.
            Label { Text(verbatim: line) } icon: { Image(systemName: "checkmark.circle") }
                .foregroundStyle(.secondary)
        case nil:
            EmptyView()
        }

        if let last = rows.lastNudge {
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: last.line)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                Text(last.at, format: .relative(presentation: .named))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

/// "Show as:" (D29): what this person calls their partner, kept on this phone. The field's
/// placeholder is the server's name; an empty field takes the nickname away. Saved when editing
/// ends (Return, the field losing focus, the screen going away, or the app going to the background,
/// where iOS may end it); limited to the name length as it is typed, as the setup sheet's name
/// field is; the store does the cleaning and the field then shows what was kept.
struct DuoNicknameRow: View {
    @ObservedObject var duoStore: DuoStore
    let duoID: UUID
    let nickname: DuoScreenModel.DuoRows.Nickname

    @State private var text: String
    @FocusState private var focused: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(duoStore: DuoStore, duoID: UUID, nickname: DuoScreenModel.DuoRows.Nickname) {
        self.duoStore = duoStore
        self.duoID = duoID
        self.nickname = nickname
        _text = State(initialValue: nickname.current)
    }

    var body: some View {
        LabeledContent {
            TextField(text: $text, prompt: Text(verbatim: nickname.placeholder)) {
                Text(DuoCopy.showAs)
            }
            .multilineTextAlignment(.trailing)
            .textInputAutocapitalization(.words)
            .autocorrectionDisabled()
            .submitLabel(.done)
            .focused($focused)
            .onSubmit(commit)
            .frame(minWidth: 120, minHeight: 44)
            .contentShape(Rectangle())
            .accessibilityLabel(Text(DuoCopy.showAs))
            .accessibilityIdentifier("duo.nickname")
        } label: {
            Text(DuoCopy.showAs)
        }
        .onChange(of: text) { _, typed in
            if typed.count > DuoState.maximumNameLength { text = String(typed.prefix(DuoState.maximumNameLength)) }
        }
        .onChange(of: focused) { _, isFocused in
            if !isFocused { commit() }
        }
        // A nickname saved elsewhere (or cleaned on the way in) shows here, unless the person is
        // typing over it.
        .onChange(of: nickname.current) { _, saved in
            if !focused { text = saved }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { commit() }
        }
        .onDisappear(perform: commit)
    }

    private func commit() {
        guard text != nickname.current else { return }
        duoStore.setNickname(text, for: duoID)
        text = duoStore.duo(duoID)?.partnerNickname ?? ""
    }
}

/// A sheet presented for one duo, by its id, so it follows the duo as the store changes it.
struct DuoScreenSheetItem: Identifiable, Equatable {
    let id: UUID
}

/// How the screen reads whether iOS lets the app notify. It never asks: asking is the push
/// service's, when the toggle is turned on (stage F).
enum DuoScreenNotifications {
    @MainActor
    static func currentStatus() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }
}
#endif
