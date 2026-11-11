import SwiftData
import SwiftUI

struct RootTabView: View {
    @Environment(\.modelContext) private var modelContext
    @StateObject private var settings = AppSettings.shared
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var router = AppRouter.shared
    #if DUO_V2
    @ObservedObject private var duoStore = DuoStore.shared
    /// The invite the join sheet is showing, from its appearance to its `onDismiss`. A refusal given
    /// on the sheet's own age screen drops the pending invite, and this keeps the sheet up until the
    /// person has read the refusal and closed it.
    @State private var duoInviteOnScreen: DuoPendingInvite?
    /// A link opened by someone who was refused: `receive` keeps nothing for them, so the root holds
    /// the code in memory only, for the sheet that shows the refusal, and lets go of it when that
    /// sheet closes.
    @State private var duoRefusedLink: DuoPendingInvite?
    /// The weekly recap below, from its appearance to its `onDismiss`, so a Duo notification can
    /// close it and open Settings only once it has gone.
    @State private var duoRecapIsOnScreen = false
    /// The "Duo Streaks" notice alert, from when it is asked for until it has finished leaving the
    /// screen. Every root sheet waits while it is true, and the alert is asked for only while
    /// nothing else of the root's is asked for, up or leaving (D82): an alert and a sheet asked for
    /// in one turn wedged every root presentation until the app was killed.
    // Keep the displayed failure stable while a newer failure waits in the store. Otherwise
    // re-rendering for the new failure makes the old alert's dismissal acknowledge the new one.
    @State private var duoPresentedNotice: String?
    @State private var duoNoticeGeneration = UUID()
    @State private var duoNoticeIsUp = false
    @State private var duoNoticeIsLeaving = false
    @State private var duoSettingsPresented = false
    /// When a tapped Duo notification asked for the Duo screen, while something it waits for is still
    /// in the way; nil when no such tap is waiting. Only a new tap starts one, so a flag the Duo row
    /// has not lowered yet never reopens Settings each time it closes.
    @State private var duoScreenRouteAskedAt: Date?
    #endif

    /// Settings is not a tab: it opens as a sheet from the gear at the top of each of
    /// these, so the bar only holds the two places people actually spend time.
    private enum Tab {
        case today, history
    }

    /// Selected by hand only so a tapped bottle tag can bring Today forward, which is
    /// where the drink appears and where it can be undone.
    @State private var selectedTab = Tab.today

    /// Re-evaluated whenever the chosen skin or the entitlement changes. `activeMascotSkin`
    /// reads `EntitlementCache`, which `StoreManager` writes in the same call that flips
    /// `isSubscribed`, so by the time the task runs the cache matches the flag.
    private var iconSyncKey: String {
        "\(settings.mascotSkin.rawValue)|\(store.isSubscribed)"
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            HomeView()
                .tabItem { Label("Today", systemImage: "drop.fill") }
                .tag(Tab.today)

            HistoryView()
                .tabItem { Label("History", systemImage: "chart.bar.fill") }
                .tag(Tab.history)
        }
        // A bottle tag read with the app closed arrives as a universal link. SwiftUI
        // delivers those through either of these depending on how the app was started,
        // so both lead to the same place.
        .onOpenURL { open($0) }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            if let url = activity.webpageURL { open(url) }
        }
        // The in-app scanner reports through the router too, from My Bottles in
        // Settings, so the tab follows the tap rather than the other way round. Today
        // holds the tap until Settings has gone; see `HomeView.handlePendingBottleTap`.
        .onChange(of: router.pendingBottleTagID) { _, tagID in
            guard tagID != nil else { return }
            router.showingSettings = false
            selectedTab = .today
        }
        .onChange(of: router.pendingInsights) { _, wanted in
            guard wanted else { return }
            router.showingSettings = false
            selectedTab = .history
        }
        // A tapped recap notification wins over Settings left open. The recap sheet
        // below waits for it to be fully gone before it comes up.
        .onChange(of: router.showingWeeklyRecap) { _, showing in
            if showing { router.showingSettings = false }
        }
        #if DUO_V2
        // A Duo invite that arrived as a link or a scanned QR code, kept by the router until a
        // screen exists to take it (final design §4.2); `initial` takes one that was there first.
        .onChange(of: router.pendingDuoLink, initial: true) { _, link in takeDuoLink(link) }
        // A tapped Duo notification asks for the Duo screen, which lives inside Settings. Each
        // presentation in the way is waited out, or closed and then waited out, before Settings
        // opens: each of the handlers below is a moment one may have gone.
        .onChange(of: router.showingDuoScreen, initial: true) { _, wanted in if wanted { askForDuoScreen() } }
        .onChange(of: router.settingsIsOnScreen) { _, onScreen in if !onScreen { duoSettingsLeft() } }
        .onChange(of: router.duoEntrySheetIsOnScreen) { _, onScreen in if !onScreen { duoSomethingLeft() } }
        .onChange(of: settings.hasCompletedOnboarding) { _, done in if done { duoSomethingLeft() } }
        .onChange(of: duoStore.notice) { _, notice in duoNoticeChanged(notice) }
        // Leaving the app drops a tap that is still waiting: Settings opening on the person's return,
        // long after the tap, would come out of nowhere.
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            duoWentToBackground()
        }
        #endif
        #if DEBUG
        // `-SimulateBottleTap <address>` hands an address to the same place a real tag
        // read does. The simulator has no NFC and cannot open a universal link that is
        // not live yet, so this is the only way to watch a tap arrive there. Compiled
        // out of Release.
        .task {
            let arguments = ProcessInfo.processInfo.arguments
            if let flag = arguments.firstIndex(of: "-SimulateBottleTap"),
               arguments.indices.contains(flag + 1),
               let address = URL(string: arguments[flag + 1]) {
                open(address)
            }
        }
        #endif
        .environmentObject(settings)
        .tint(Color(red: 0.18, green: 0.56, blue: 0.93))
        // Same rule as the mascot on screen: the icon follows what the user is entitled to.
        .task(id: iconSyncKey) { AppIconManager.sync(to: settings.activeMascotSkin) }
        // Widgets are a HydroDrop+ feature and draw from the published snapshot, so a
        // purchase, a restore or a lapse has to reach them. Runs on appear as well, which
        // covers an entitlement that changed between launches. `WidgetBridge` drops the
        // publish when nothing differs, so this costs no reload in the common case.
        .task(id: store.isSubscribed) {
            WidgetPublisher.publish(
                context: modelContext,
                isShared: SharedModelContainer.isShared(modelContext.container)
            )
        }
        #if DUO_V2
        .task(id: [router.showingSettings, duoNoticeIsUp, duoNoticeIsLeaving]) {
            await reconcileDuoSettingsPresentation()
        }
        .sheet(isPresented: duoSettingsIsPresented, onDismiss: { router.settingsDidDismiss() }) {
            SettingsView()
                .environmentObject(settings)
                .onAppear { router.settingsDidAppear() }
        }
        #else
        .sheet(isPresented: $router.showingSettings, onDismiss: { router.settingsDidDismiss() }) {
            SettingsView()
                .environmentObject(settings)
                .onAppear { router.settingsDidAppear() }
        }
        #endif
        #if DUO_V2
        // The same recap, with its time on screen kept: a tapped Duo notification closes it and
        // opens Settings only from here, once it has gone.
        .sheet(isPresented: weeklyRecapIsPresented, onDismiss: {
            duoRecapIsOnScreen = false
            duoSomethingLeft()
        }) {
            WeeklyRecapView()
                .environmentObject(settings)
                .onAppear { duoRecapIsOnScreen = true }
        }
        // An opened Duo invite, from whichever tab was showing (final design §4.2, §4.3), or the
        // refusal for a link opened by someone who was refused. Held back while the intro is up,
        // while Settings or the code-entry sheet is leaving, while the recap is up and while the
        // notice alert is up or leaving; the invite keeps. Dismissing the sheet by any route drops it.
        .sheet(item: pendingDuoInvite, onDismiss: {
            duoInviteOnScreen = nil
            duoRefusedLink = nil
            duoSomethingLeft()
        }) { invite in
            DuoJoinSheet(duoStore: duoStore, invite: invite)
                .onAppear { duoInviteOnScreen = invite }
        }
        // Settings shows this itself while it is up, Duo Streaks being inside it. Here it waits for
        // every other presentation of the root's to be gone, and they wait for it (D82).
        .alert("Duo Streaks", isPresented: duoNoticeIsPresented) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(duoPresentedNotice ?? "")
        }
        #else
        .sheet(isPresented: weeklyRecapIsPresented) {
            WeeklyRecapView()
                .environmentObject(settings)
        }
        #endif
        .fullScreenCover(isPresented: onboardingIsPresented) {
            OnboardingView(mode: .firstLaunch) {
                settings.hasCompletedOnboarding = true
            }
            .environmentObject(settings)
        }
    }

    private func open(_ url: URL) {
        router.handle(url)
    }

    #if DUO_V2
    // MARK: - Duo: links

    /// A link from outside wins over Settings left open, as a bottle tag and the recap do: Settings
    /// is asked to close and the join sheet comes up once it has gone. A code typed or scanned inside
    /// Settings never comes this way: the Duo screen closes Settings from the code-entry sheet's
    /// `onDismiss`, since two stacked sheets must never be dismissed in one turn, and the root only
    /// waits.
    private func takeDuoLink(_ link: DuoParsedInvite?) {
        guard let link else { return }
        if let refused = Self.duoTake(link, router: router, store: duoStore, now: Date()) { duoRefusedLink = refused }
    }

    /// What taking a link does, apart from the view so a test can hold it: the router lets go of it,
    /// Settings is asked to close, and `receive` keeps the invite (on disk, without its `k`). For
    /// someone who was refused `receive` keeps nothing, and the code comes back to be shown with the
    /// refusal instead of nothing at all; Settings is closed for them too, so the refusal can come up.
    static func duoTake(_ link: DuoParsedInvite, router: AppRouter, store: DuoStore, now: Date) -> DuoPendingInvite? {
        router.pendingDuoLink = nil
        store.receive(link, now: now)
        router.showingSettings = false
        guard store.ageStatus == .refused else { return nil }
        return DuoPendingInvite(code: link.code, k: nil, receivedAt: now)
    }

    private var pendingDuoInvite: Binding<DuoPendingInvite?> {
        Binding(
            get: {
                DuoJoinPlan.invite(toShow: duoStore.pendingInvite, refusedLink: duoRefusedLink, onScreen: duoInviteOnScreen,
                                   ageRefused: duoStore.ageStatus == .refused,
                                   onboardingDone: settings.hasCompletedOnboarding,
                                   settingsIsOnScreen: router.settingsIsOnScreen,
                                   entrySheetIsOnScreen: router.duoEntrySheetIsOnScreen,
                                   anotherSheetIsOnScreen: duoRecapIsOnScreen,
                                   noticeIsUp: duoNoticeIsUp)
            },
            set: { invite in
                if invite == nil {
                    duoInviteOnScreen = nil
                    duoRefusedLink = nil
                }
                duoStore.pendingInvite = invite
            }
        )
    }

    private var duoJoinSheetIsUp: Bool { duoInviteOnScreen != nil || pendingDuoInvite.wrappedValue != nil }

    private var duoRootSheets: DuoJoinPlan.RootSheets {
        DuoJoinPlan.RootSheets(
            onboardingDone: settings.hasCompletedOnboarding,
            settingsRequested: router.showingSettings,
            settingsIsOnScreen: router.settingsIsOnScreen,
            recapRequested: router.showingWeeklyRecap,
            recapIsOnScreen: duoRecapIsOnScreen,
            joinSheetIsUp: duoJoinSheetIsUp,
            entrySheetIsOnScreen: router.duoEntrySheetIsOnScreen,
            noticeIsUp: duoNoticeIsUp
        )
    }

    // MARK: - Duo: one presentation at a time

    /// Something of the root's has gone (a sheet's `onDismiss`, the code-entry sheet, the intro, the
    /// alert): a tapped notification still waiting goes first, then the notice, which waits for
    /// whatever that opened.
    private func duoSomethingLeft() {
        routeToDuoScreen()
        showDuoNoticeIfFree()
    }

    /// Settings has gone. A tap that was waiting for it opens it again; otherwise the Duo flag the row
    /// inside it did not take is lowered, so a later visit to Settings does not open the Duo screen
    /// out of nowhere.
    private func duoSettingsLeft() {
        if duoScreenRouteAskedAt != nil {
            routeToDuoScreen()
        } else if router.showingDuoScreen {
            router.showingDuoScreen = false
        }
        showDuoNoticeIfFree()
    }

    private func duoWentToBackground() {
        guard duoScreenRouteAskedAt != nil else { return }
        duoScreenRouteAskedAt = nil
        if !router.showingSettings, !router.settingsIsOnScreen { router.showingDuoScreen = false }
    }

    // MARK: - Duo: a tapped notification

    /// A tap on a Duo notification raised `showingDuoScreen` (stage F sets nothing else).
    private func askForDuoScreen() {
        duoScreenRouteAskedAt = Date()
        routeToDuoScreen()
    }

    /// One step toward the Duo screen, asked again each time something in the way has gone. Settings
    /// already up takes only the flag, which the Duo row reads on appear and lowers.
    private func routeToDuoScreen() {
        guard let askedAt = duoScreenRouteAskedAt else { return }
        guard router.showingDuoScreen, !DuoJoinPlan.duoScreenRouteIsStale(askedAt: askedAt, now: Date()) else {
            duoScreenRouteAskedAt = nil
            if router.showingDuoScreen, !router.showingSettings, !router.settingsIsOnScreen { router.showingDuoScreen = false }
            return
        }
        switch DuoJoinPlan.duoScreenStep(duoRootSheets) {
        case .waitForIntro, .waitForSheet:
            break
        case .settingsIsUp:
            duoScreenRouteAskedAt = nil
        case .closeRecap:
            router.showingWeeklyRecap = false
            // A recap that was asked for but never came up has no `onDismiss` to wait for.
            if !duoRecapIsOnScreen { routeToDuoScreen() }
        case .openSettings:
            duoScreenRouteAskedAt = nil
            router.showingSettings = true
        }
    }

    /// The router records intent immediately, but UIKit must finish the alert above Settings
    /// before its sheet can leave. Closing both during the alert's entrance crashes UIKit on
    /// iOS 27. Opening Settings likewise waits for the root's notice to finish leaving.
    private var duoSettingsIsPresented: Binding<Bool> {
        Binding(get: { duoSettingsPresented }, set: { showing in
            duoSettingsPresented = showing
            guard !showing, router.settingsIsOnScreen, router.showingSettings else { return }
            Task { @MainActor in
                guard !duoSettingsPresented else { return }
                router.showingSettings = false
            }
        })
    }

    @MainActor
    private func reconcileDuoSettingsPresentation() async {
        let requested = router.showingSettings
        // Let the child alert observe the changed request and begin its own dismissal first.
        do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        while !Task.isCancelled {
            guard router.showingSettings == requested else { return }
            if requested {
                if !duoNoticeIsUp, !duoNoticeIsLeaving, !Self.duoAnAlertIsUp() {
                    duoSettingsPresented = true
                    return
                }
            } else if !Self.duoAnAlertIsUp() {
                duoSettingsPresented = false
                return
            }
            do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return }
        }
    }

    // MARK: - Duo: the notice alert

    private var duoNoticeIsPresented: Binding<Bool> {
        let dismissedNotice = duoPresentedNotice
        let generation = duoNoticeGeneration
        return Binding(
            get: { duoNoticeIsUp && !duoNoticeIsLeaving && duoStore.notice != nil },
            set: { showing in
                guard !showing else { return }
                // SwiftUI resets bindings during its presentation update. Publish after that
                // update and do not consume a replacement failure that arrived in the meantime.
                Task { @MainActor in
                    guard duoNoticeGeneration == generation else { return }
                    duoNoticeWentAway(acknowledging: dismissedNotice)
                }
            }
        )
    }

    private func duoNoticeChanged(_ notice: String?) {
        if notice != nil {
            showDuoNoticeIfFree()
        } else if duoNoticeIsUp {
            // Taken away from elsewhere (a wipe) while it was up.
            duoNoticeWentAway()
        }
    }

    /// Asks for the alert when nothing else of the root's is asked for, up or leaving. An alert the
    /// system did not put up after all (one of Today's sheets in the way on an older iOS) is let go
    /// of again, so it cannot hold every root sheet back for good; the notice keeps for the next try.
    private func showDuoNoticeIfFree() {
        guard DuoJoinPlan.noticeMayShow(hasNotice: duoStore.notice != nil, duoRootSheets) else { return }
        let generation = UUID()
        duoNoticeGeneration = generation
        duoPresentedNotice = duoStore.notice
        duoNoticeIsUp = true
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard duoNoticeGeneration == generation else { return }
            if duoNoticeIsUp, !duoNoticeIsLeaving, !Self.duoAnAlertIsUp() {
                duoNoticeIsUp = false
                duoPresentedNotice = nil
                duoSomethingLeft()
            }
        }
    }

    /// The notice was answered (or taken away). Root sheets go on waiting until the alert has left
    /// the screen, not just until it was answered: SwiftUI sets the binding as the alert starts to
    /// leave, and a sheet asked for then is dropped like one asked for under it.
    private func duoNoticeWentAway(acknowledging notice: String? = nil) {
        guard duoNoticeIsUp, !duoNoticeIsLeaving else { return }
        if let notice, duoStore.notice == notice { duoStore.notice = nil }
        duoNoticeIsLeaving = true
        let generation = duoNoticeGeneration
        Task { @MainActor in
            for _ in 0..<60 {
                try? await Task.sleep(nanoseconds: 50_000_000)
                if !Self.duoAnAlertIsUp() { break }
            }
            guard duoNoticeGeneration == generation else { return }
            duoNoticeIsLeaving = false
            duoNoticeIsUp = false
            duoPresentedNotice = nil
            duoSomethingLeft()
        }
    }

    /// Whether any window has an alert presented, leaving included: UIKit is the one that knows when
    /// an alert has gone, and SwiftUI says nothing when it has.
    private static func duoAnAlertIsUp() -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.contains { window in
            var presented = window.rootViewController?.presentedViewController
            while let controller = presented {
                if controller is UIAlertController { return true }
                presented = controller.presentedViewController
            }
            return false
        }
    }

    #endif
    /// The recap a notification asked for, held back while Settings is still leaving.
    #if DUO_V2
    private var weeklyRecapIsPresented: Binding<Bool> {
        Binding(
            // Also held back while the join sheet is up (it would replace it and take the typed name
            // with it) and while the notice alert is up or leaving (D82). Once it is up, nothing here
            // takes it down.
            get: {
                router.showingWeeklyRecap && !router.settingsIsOnScreen
                    && (duoRecapIsOnScreen || DuoJoinPlan.recapMayShow(joinSheetIsUp: duoJoinSheetIsUp, noticeIsUp: duoNoticeIsUp))
            },
            set: { router.showingWeeklyRecap = $0 }
        )
    }
    #else
    private var weeklyRecapIsPresented: Binding<Bool> {
        Binding(
            get: { router.showingWeeklyRecap && !router.settingsIsOnScreen },
            set: { router.showingWeeklyRecap = $0 }
        )
    }
    #endif

    /// Onboarding is on screen exactly while the flag is off. The flag can also flip from
    /// underneath (another device finishing the intro), which closes the cover too.
    private var onboardingIsPresented: Binding<Bool> {
        Binding(
            get: { !settings.hasCompletedOnboarding },
            set: { presented in
                if !presented { settings.hasCompletedOnboarding = true }
            }
        )
    }
}

// Plus features used to be switched off here, in an `onChange` on the entitlement.
// That only fires on a transition *within a session*: a subscription that lapsed
// between launches started the next launch at false and never changed, so the handler
// never ran and the paid mascot skin and pace-aware reminders stayed on for good.
// Each feature now derives from the entitlement where it is used — see
// `AppSettings.activeMascotSkin` and `AppSettings.smartRemindersActive` — which also
// means the user's choices survive a lapse and come back with them.

#Preview {
    RootTabView()
}
