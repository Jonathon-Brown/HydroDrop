import SwiftUI
import SwiftData
import StoreKit

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var nightOut = NightOutCoordinator.shared
    @Query(sort: \WaterEntry.timestamp, order: .reverse) private var allEntries: [WaterEntry]
    @Query(sort: \Bottle.createdAt) private var bottles: [Bottle]

    @State private var showingAddSheet = false
    @State private var showingSayIt = false
    /// A tag that was tapped but means no bottle on this device, waiting on an answer.
    @State private var unknownTagID: UUID?
    @State private var linkingTagID: UUID?
    /// The bottle a tag was just linked to, so the link can be confirmed by name.
    @State private var linkedBottleName: String?
    /// Whether the on-device language model can answer right now. Say it is simply not
    /// there when it cannot, and this is re-read on every foreground because a model
    /// that was still downloading this morning may be ready this afternoon.
    @State private var sayItIsAvailable = false
    @State private var paywallSource: PaywallSource?
    @State private var editingEntry: WaterEntry?
    /// The streak milestone, the new world stage, or both, whose celebration is on screen.
    @State private var celebration: MilestoneCelebrationView.Occasion?
    /// The droplet's world, worked out from the whole log. Kept rather than recomputed
    /// on every render: it walks every day there has ever been.
    @State private var world = WorldState.empty
    @State private var showingWorld = false
    /// How tall the title and streak are, so the world behind lines up under them.
    @State private var worldHeaderHeight: CGFloat = 110
    /// A weather suggestion fetched for today but not yet answered.
    @State private var pendingWeatherBumpML: Int?
    /// The same for today's workouts.
    @State private var pendingWorkoutBumpML: Int?
    /// The day extra water was accepted for something other than the heat, so the line
    /// under the goal does not blame the weather for it.
    @AppStorage("todayBump.otherReasonDayKey") private var otherReasonBumpDayKey = ""
    /// The drink that can still be taken back, and the task that retires the offer.
    @State private var pendingUndo: PendingUndo?
    @State private var undoDismissal: Task<Void, Never>?
    /// A review request already waiting on its short delay, so a burst of changes to
    /// the streak can't queue several.
    @State private var reviewPromptPending = false

    /// The missed day whose streak-break notice was closed, and the one whose impression
    /// has been counted. Device-local on purpose — plain `UserDefaults`, not the iCloud
    /// store — and keyed by day so each broken streak is announced once, not every launch.
    @AppStorage("streakBreakNotice.dismissedDayKey") private var dismissedStreakNoticeDayKey = ""
    @AppStorage("streakBreakNotice.countedDayKey") private var countedStreakNoticeDayKey = ""

    private var todayEntries: [WaterEntry] {
        allEntries.filter { Calendar.current.isDateInToday($0.timestamp) }
    }

    /// What today counts for, which is the hydrating share of each drink rather than
    /// the volume poured. Identical to the poured total for water.
    private var todayTotal: Int {
        todayEntries.reduce(0) { $0 + $1.hydratedML }
    }

    /// What today is measured against on screen: the saved goal plus an accepted
    /// weather bump. Streaks deliberately keep using `dailyGoalML`, so taking the
    /// suggestion on a hot day can never be the thing that breaks one.
    private var todayGoal: Int { settings.todayGoalML() }

    private var progress: Double {
        guard todayGoal > 0 else { return 0 }
        return Double(todayTotal) / Double(todayGoal)
    }

    private var acceptedWeatherBumpML: Int {
        max(0, todayGoal - settings.dailyGoalML)
    }

    /// One offer made from every reason there is to drink a little more today: the heat,
    /// the morning after a Night Out, or both. Never more than the daily cap allows on
    /// top of what has already been accepted.
    private var bumpSuggestion: TodayBump.Suggestion? {
        var parts: [TodayBump.Source: Int] = [:]
        if let heat = pendingWeatherBumpML { parts[.heat] = heat }
        if nightOut.offerIsDue() { parts[.nightOut] = TodayBump.nightOutML }
        if let workout = pendingWorkoutBumpML { parts[.workout] = workout }
        return TodayBump.suggestion(from: parts, alreadyAcceptedML: acceptedWeatherBumpML)
    }

    /// Yes or no to the offer, for every reason that was part of it. Either answer
    /// retires the offer for today. Yes raises today's target only: the streak is still
    /// measured against the saved goal.
    private func answer(_ suggestion: TodayBump.Suggestion, accepted: Bool) {
        if accepted { settings.addToTodayBump(suggestion.addML) }
        if suggestion.sources.contains(.heat) {
            if !accepted { settings.dismissWeatherBump() }
            withAnimation { pendingWeatherBumpML = nil }
        }
        if suggestion.sources.contains(.nightOut) {
            withAnimation { nightOut.answerOffer(accepted: accepted) }
        }
        if suggestion.sources.contains(.workout) {
            // Either answer is the one suggestion for today.
            settings.markWorkoutBumpAnswered()
            withAnimation { pendingWorkoutBumpML = nil }
        }
        if accepted, suggestion.sources != [.heat] { otherReasonBumpDayKey = DayKey.key(for: Date()) }
        if accepted { afterGoalChange() }
    }

    private var streak: Int {
        StreakCalculator.currentStreak(
            entries: allEntries,
            goalML: settings.dailyGoalML,
            frozenDayKeys: settings.frozenStreakDayKeys
        )
    }

    /// True when a freeze is currently holding the streak together, i.e. yesterday
    /// was missed but protected.
    private var streakIsFrozen: Bool {
        guard let yesterday = DayKey.previousDayKey(before: Date()) else { return false }
        return settings.frozenStreakDayKeys.contains(yesterday)
    }

    /// A streak a free user lost yesterday that a freeze would have saved, unless they've
    /// already closed the notice for it.
    ///
    /// Derived rather than stored, so it corrects itself: if the entitlement or a synced
    /// freeze lands a moment after launch, the subscriber's freeze is spent and this
    /// becomes nil before anyone has read it.
    private var visibleLostStreak: StreakFreeze.LostStreak? {
        guard !store.isSubscribed else { return nil }
        guard let lost = StreakFreeze.lostStreakAFreezeWouldHaveSaved(
            entries: allEntries,
            goalML: settings.dailyGoalML,
            frozenDayKeys: settings.frozenStreakDayKeys
        ) else { return nil }
        return lost.missedDayKey == dismissedStreakNoticeDayKey ? nil : lost
    }

    /// Today's margin, named so the world scene can reach past it to the screen edges.
    private static let pagePadding: CGFloat = 16

    var body: some View {
        NavigationStack {
            GeometryReader { screen in
                ZStack {
                    // The world is the page. It stays put and everything else scrolls over it.
                    worldBackdrop(safeTop: screen.safeAreaInsets.top,
                                  fullHeight: screen.size.height + screen.safeAreaInsets.top + screen.safeAreaInsets.bottom)
                        .ignoresSafeArea()
                    ScrollView {
                        VStack(spacing: 0) {
                            worldHeader
                            mascotStage
                            VStack(spacing: 24) {
                                VStack(spacing: 2) {
                                    // The face carries the mood; naming it makes sure the signal
                                    // still lands for anyone who reads the screen quickly.
                                    Text(MascotMood.forProgress(progress).label)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .animation(.easeInOut, value: progress)

                                    if !store.isSubscribed {
                                        moreLooksLink
                                    }
                                }

                                if let lost = visibleLostStreak {
                                    streakBreakNotice(lost)
                                        .transition(.opacity)
                                }

                                if let suggestion = bumpSuggestion {
                                    WeatherBumpCard(
                                        bumpML: suggestion.addML,
                                        system: settings.measurementSystem,
                                        sources: suggestion.sources
                                    ) {
                                        answer(suggestion, accepted: true)
                                    } onDismiss: {
                                        answer(suggestion, accepted: false)
                                    }
                                    .transition(.opacity)
                                }

                                VStack(spacing: 6) {
                                    Text(settings.measurementSystem.format(mL: todayTotal))
                                        .font(.system(size: 34, weight: .bold, design: .rounded))
                                    Text("of \(settings.measurementSystem.format(mL: todayGoal)) goal")
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
                                    if acceptedWeatherBumpML > 0 {
                                        WeatherBumpBadge(
                                            bumpML: acceptedWeatherBumpML,
                                            system: settings.measurementSystem,
                                            isOnlyHeat: nightOut.bumpAcceptedDayKey != DayKey.key(for: Date())
                                                && otherReasonBumpDayKey != DayKey.key(for: Date()),
                                            mayIncludeWeather: settings.weatherGoalActive
                                        )
                                    }
                                    if settings.caffeineTrackingActive {
                                        CaffeineTodayLine(
                                            entries: todayEntries,
                                            cutoffMinutes: settings.caffeineCutoffMinutes,
                                            wakingStartMinutes: settings.quietStartMinutes
                                        )
                                    }
                                }

                                progressBar

                                quickAddSection

                                NightOutSection(nightOut: nightOut, entries: allEntries)

                                todayLogSection

                                if !store.isSubscribed {
                                    BannerAdView(adUnitID: AdManager.bannerAdUnitID)
                                }
                            }
                            .padding(Self.pagePadding)
                            .padding(.top, 4)
                            .background(alignment: .top) {
                                // No hard edge, no card shape: the world just gets hazier as you
                                // scroll into the panel. A short band where the frost ramps in from
                                // nothing, then solid material the rest of the way down, carried on
                                // past the last row so overscroll at the bottom never shows a gap.
                                ZStack(alignment: .top) {
                                    Rectangle()
                                        .fill(.regularMaterial)
                                        .padding(.top, Self.panelFadeHeight)
                                        .padding(.bottom, -1000)
                                    Rectangle()
                                        .fill(.regularMaterial)
                                        .mask(LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom))
                                        .frame(height: Self.panelFadeHeight)
                                }
                            }
                        }
                    }
                }
            }
            // Still named, for the back button on whatever is pushed from here.
            .navigationTitle("Today")
            // The page draws the title itself, in white on the world's sky, which is dark
            // enough at every time of day for it.
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(isPresented: $showingWorld) {
                WorldView(state: world, streak: streak, todayTotalML: todayTotal)
                    .environmentObject(settings)
            }
            .sheet(isPresented: $showingAddSheet) {
                AddDrinkSheet { amount, drinkType, timestamp in
                    addEntry(amount: amount, drinkType: drinkType, timestamp: timestamp)
                }
            }
            .alert(
                "This tag is not linked to a bottle on this device",
                isPresented: Binding(
                    get: { unknownTagID != nil },
                    set: { if !$0 { unknownTagID = nil } }
                ),
                presenting: unknownTagID
            ) { tagID in
                if !bottles.isEmpty {
                    Button("Link it to a bottle") { linkingTagID = tagID }
                }
                Button("Not now", role: .cancel) {}
            } message: { _ in
                Text(bottles.isEmpty
                     ? "Add a bottle in Settings, under My Bottles, then write this tag from there."
                     : "Link it to one of your bottles. After that, tapping it logs that bottle.")
            }
            .alert(
                "Linked to \(linkedBottleName ?? "your bottle")",
                isPresented: Binding(
                    get: { linkedBottleName != nil },
                    set: { if !$0 { linkedBottleName = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("Nothing was logged. Tap the tag again whenever you drink from it.")
            }
            .confirmationDialog(
                "Which bottle is this tag on?",
                isPresented: Binding(
                    get: { linkingTagID != nil },
                    set: { if !$0 { linkingTagID = nil } }
                ),
                titleVisibility: .visible,
                presenting: linkingTagID
            ) { tagID in
                ForEach(bottles) { bottle in
                    Button(bottle.name) { link(tagID, to: bottle) }
                }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(isPresented: $showingSayIt) {
                SayItSheet(defaultML: settings.quickAddPresets.first ?? 250) { drafts in
                    addEntries(drafts)
                }
            }
            .sheet(item: $editingEntry) { entry in
                EditEntrySheet(entry: entry) { orphanedSampleUUID in
                    // The edit may have moved the drink to another day or changed what
                    // it counts for, so everything downstream of the total is stale.
                    saveContext()
                    clearUndo()
                    afterLogChange()
                    retireHealthSample(orphanedSampleUUID)
                } onDelete: {
                    editingEntry = nil
                    // Deleted only once the sheet has gone. SwiftUI re-renders a sheet
                    // while it dismisses, and reading a model that no longer exists
                    // from that render is a crash.
                    Task { @MainActor in delete(entry) }
                }
                .environmentObject(settings)
            }
            .sheet(item: $paywallSource) { source in
                PaywallView(source: source)
            }
            .sheet(item: $celebration) { occasion in
                MilestoneCelebrationView(
                    occasion: occasion,
                    world: WorldCardContent(
                        state: world,
                        decorations: settings.activeWorldDecorations,
                        timeOfDay: WorldTimeOfDay(date: Date())
                    ),
                    streak: streak,
                    skin: settings.activeMascotSkin,
                    todayTotalML: todayTotal,
                    goalML: settings.dailyGoalML,
                    system: settings.measurementSystem
                )
            }
            .overlay(alignment: .bottom) {
                if let pendingUndo {
                    UndoToast(message: pendingUndo.message) {
                        undo(pendingUndo.entries)
                    }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            syncOnForeground()
            refreshWorld()
            checkMilestones()
            considerReviewPrompt()
            // A tag read with the app closed is already waiting by the time this exists.
            handlePendingBottleTap()
        }
        .onChange(of: router.pendingBottleTagID) { _, _ in
            handlePendingBottleTap()
        }
        .onChange(of: router.settingsIsOnScreen) { _, isOnScreen in
            if !isOnScreen { handlePendingBottleTap() }
        }
        // One-shot pace-aware reminders only cover a few days, so they have to be
        // re-armed when the app is opened. Nothing did that before: the schedule was
        // rebuilt on a settings change or a logged drink and nowhere else, so a user who
        // stopped logging stopped being reminded — exactly backwards.
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            syncOnForeground()
        }
        // The entitlement is usually known by the time this view appears, but on a cold
        // launch it can land a moment later. The freeze is only ever spendable on
        // yesterday, so a check that ran too early has to be re-run rather than skipped.
        .onChange(of: store.isSubscribed) { _, _ in
            applyStreakFreezeIfNeeded()
            // The three Plus features all come and go with the entitlement.
            WeeklyRecapNotifier.shared.refresh()
            mirrorToCompanions()
            checkWeather()
            ReminderManager.shared.refreshSchedule(entries: allEntries, goalML: todayGoal)
        }
        .onChange(of: todayTotal) { _, _ in
            mirrorToCompanions()
        }
        .onChange(of: settings.dailyGoalML) { _, _ in
            mirrorToCompanions()
        }
        .onChange(of: settings.measurementSystem) { _, _ in
            mirrorToCompanions()
        }
        .onChange(of: settings.quickAddPresets) { _, _ in
            mirrorToCompanions()
        }
        .onChange(of: settings.activeMascotSkin) { _, _ in
            mirrorToCompanions()
        }
        // The world can grow on a day the streak does not, when a drink is moved onto a
        // day in the past, so it gets a look of its own.
        .onChange(of: world.goalDays) { _, _ in
            checkMilestones()
        }
        .onChange(of: settings.frozenStreakDayKeys) { _, _ in
            refreshWorld()
        }
        .onChange(of: streak) { _, _ in
            checkMilestones()
            considerReviewPrompt()
        }
        // A celebration and a review request must not stack, so the ask waits until
        // the celebration is out of the way.
        .onChange(of: celebration) { _, current in
            guard current == nil else { return }
            considerReviewPrompt()
        }
        .onChange(of: settings.hasCompletedOnboarding) { _, _ in
            considerReviewPrompt()
        }
    }

    /// Asks for an App Store review on reaching a week-long streak, once per version.
    ///
    /// Never while onboarding is up, never with the paywall or the custom-amount sheet
    /// open, and never mid-purchase: the system alert would land on top of whatever the
    /// user was doing, and a rating asked for during a purchase reads as a toll. The
    /// short delay lets the streak badge and haptic finish first. Every condition is
    /// re-checked after the delay, and the version is only marked once the request has
    /// actually been made.
    private func considerReviewPrompt() {
        guard !reviewPromptPending, ReviewPrompter.shouldPrompt(streak: streak) else { return }
        guard isClearOfOtherPresentations else { return }
        reviewPromptPending = true
        Task { @MainActor in
            defer { reviewPromptPending = false }
            try? await Task.sleep(for: .seconds(1.5))
            guard isClearOfOtherPresentations else { return }
            guard scenePhase == .active, ReviewPrompter.shouldPrompt(streak: streak) else { return }
            ReviewPrompter.markPrompted()
            requestReview()
        }
    }

    /// True when there is nothing on screen a system alert would land on top of.
    private var isClearOfOtherPresentations: Bool {
        settings.hasCompletedOnboarding
            && paywallSource == nil
            && celebration == nil
            && editingEntry == nil
            && !showingAddSheet
            && !store.purchaseInProgress
    }

    /// Awards any milestone the streak has reached, and celebrates the newest one.
    ///
    /// The badge is recorded before the celebration is shown, not after: a celebration
    /// interrupted by the app being killed is a small loss, and one shown twice for the
    /// same milestone is a bug the user cannot un-see.
    private func checkMilestones() {
        guard settings.hasCompletedOnboarding else { return }
        // The seeded history is a three day streak, and the sheet that celebrates it
        // covers the quick-add buttons the capture test taps. Nothing is recorded
        // either, so a run leaves no badge behind. Always false in Release.
        guard !AppSettings.isScreenshotMode else { return }

        // Everyone who was already keeping a streak before milestones existed starts
        // with the badges they had earned, awarded quietly and only once.
        if !settings.hasSeededMilestones {
            settings.seedMilestones(
                longestStreak: StreakCalculator.longestStreak(
                    entries: allEntries,
                    goalML: settings.dailyGoalML,
                    frozenDayKeys: settings.frozenStreakDayKeys
                )
            )
        }

        // The same for the world: whatever had already grown before the world existed is
        // marked quietly, once, and the record of goal days never goes down.
        // Worked out afresh here rather than read back from the view's state, which may
        // not have caught up with a drink logged a moment ago.
        let world = currentWorld()
        #if DEBUG
        // A world staged from a launch argument is for looking at. It is not recorded.
        if WorldDebug.state != nil { return }
        #endif
        settings.noteWorld(goalDays: world.goalDays)

        guard celebration == nil else { return }
        let milestone = StreakMilestone.newlyReached(
            streak: streak,
            alreadyCelebrated: Set(settings.celebratedMilestones)
        )
        let stage = WorldStage.newlyReached(
            goalDays: world.goalDays,
            alreadyCelebrated: Set(settings.celebratedWorldStages)
        )
        guard milestone != nil || stage != nil else { return }
        // Three goal days are a three day streak too. One moment for both, not two sheets.
        if let milestone { settings.recordMilestone(milestone) }
        if let stage { settings.recordWorldStage(stage) }
        celebration = .init(milestone: milestone, worldStage: stage)
    }

    /// Works the world out again from the log. Called wherever the log, the goal or the
    /// frozen days can have changed.
    private func refreshWorld() {
        let next = currentWorld()
        if next != world { withAnimation(.easeInOut(duration: 0.6)) { world = next } }
    }

    private func currentWorld() -> WorldState {
        #if DEBUG
        if let staged = WorldDebug.state { return staged }
        #endif
        return WorldEngine.state(
            totalsByDay: StreakCalculator.totalsByDay(allEntries),
            goalML: settings.dailyGoalML,
            frozenDayKeys: settings.frozenStreakDayKeys,
            recordedGoalDays: settings.worldGoalDaysRecord
        )
    }

    private var worldTime: WorldTimeOfDay { WorldTimeOfDay(date: Date()) }
    private var worldWeather: WorldWeather? { WorldWeather.current(isFeatureActive: settings.weatherGoalActive) }

    /// The title and the streak, on the sky. Measured, so the world behind can put its
    /// top edge exactly where this ends, whatever the text size.
    private var worldHeader: some View {
        VStack(spacing: 14) {
            HStack {
                Text("Today")
                    .font(.largeTitle.bold())
                    .foregroundStyle(.white)
                    .accessibilityAddTraits(.isHeader)
                Spacer()
                settingsButton
            }
            .padding(.horizontal, Self.pagePadding)
            .padding(.top, 8)
            streakBadge
                .environment(\.colorScheme, .dark)
        }
        .padding(.bottom, 14)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { worldHeaderHeight = $0 }
    }

    /// A window onto the world as tall as the world itself, with the droplet standing
    /// in the pond. Scrolls with the page, so the droplet rides up over the sky with the
    /// rest of Today while the world stays where it is.
    private var mascotStage: some View {
        MascotView(progress: progress, size: 180, skin: settings.activeMascotSkin)
            .padding(.bottom, 45)
            .frame(maxWidth: .infinity)
            .frame(height: Self.worldHeight, alignment: .bottom)
            .contentShape(Rectangle())
            .onTapGesture { showingWorld = true }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(world.spokenDescription)
            .accessibilityHint("Opens your world")
            .accessibilityAddTraits(.isButton)
    }

    /// The whole screen of world: sky from the very top down to where the header ends,
    /// the world's 400pt below that, lined up with `mascotStage` when Today is scrolled
    /// to the top, and bank the rest of the way down behind the panel.
    /// `screen.size` here is not the whole screen: this `GeometryReader` sits inside
    /// `NavigationStack`/`TabView` with nothing above it ignoring the safe area, so what
    /// it measures is already reduced by both the status bar/Dynamic Island at the top
    /// and the tab bar (plus any home indicator) at the bottom. Adding both insets back
    /// undoes exactly that reduction rather than double-counting it — traced against the
    /// real device height on an iPhone SE (667pt), a notched 13 Pro Max (926pt) and a
    /// Dynamic Island 17 Pro (874pt): `fullHeight` landed on the true point height of the
    /// device every time. `worldBackdrop`'s own canvas, in contrast, does ignore the safe
    /// area, so it always sees the true full height directly.
    private func worldBackdrop(safeTop: CGFloat, fullHeight: CGFloat) -> some View {
        WorldSceneView(
            state: world,
            decorations: settings.activeWorldDecorations,
            timeOfDay: worldTime,
            weather: worldWeather,
            worldHeight: Self.worldHeight,
            groundBelow: max(0, fullHeight - safeTop - worldHeaderHeight - Self.worldHeight)
        )
        .accessibilityHidden(true)
    }

    private static let worldHeight: CGFloat = 400
    /// How gradually the frosted panel fades in over the world, rather than starting flat.
    private static let panelFadeHeight: CGFloat = 160

    /// The way into Settings, in the corner of the sky. Frosted like the streak badge
    /// under it, so it reads as part of the same header at every time of day.
    private var settingsButton: some View {
        Button {
            router.showingSettings = true
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(Circle().fill(.ultraThinMaterial))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, .dark)
        .accessibilityLabel("Settings")
    }

    private var streakBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "flame.fill")
                .foregroundStyle(streak > 0 ? .orange : .secondary)
            Text(streak > 0 ? "\(streak) day streak" : "Start your streak today")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(streak > 0 ? .primary : .secondary)
            if streakIsFrozen {
                Image(systemName: "snowflake")
                    .foregroundStyle(.cyan)
                    .accessibilityLabel("Streak protected by a freeze")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Capsule().fill(.ultraThinMaterial))
    }

    /// Shown once per broken streak, and only to free users. Information first: it says
    /// what happened and what would have prevented it, opens the paywall only if tapped,
    /// and closes for good with the X.
    private func streakBreakNotice(_ lost: StreakFreeze.LostStreak) -> some View {
        Button {
            paywallSource = .streakBreakMessage
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "snowflake")
                    .foregroundStyle(.cyan)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Your \(lost.length)-day streak ended yesterday")
                        .font(.subheadline.weight(.semibold))
                    Text("A HydroDrop+ streak freeze would have kept it going.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 28)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows HydroDrop+")
        .overlay(alignment: .topTrailing) {
            Button {
                withAnimation { dismissedStreakNoticeDayKey = lost.missedDayKey }
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .onAppear {
            guard countedStreakNoticeDayKey != lost.missedDayKey else { return }
            countedStreakNoticeDayKey = lost.missedDayKey
            EventCounter.record(.streakBreakMessageShown)
        }
    }

    /// The one HydroDrop+ way in on Today: a quiet caption link under the mascot, which is
    /// the paid skins' own showcase. The paywall it opens leads with those skins.
    private var moreLooksLink: some View {
        Button {
            paywallSource = .todayEntryPoint
        } label: {
            Label("More looks", systemImage: "sparkles")
                .font(.caption.weight(.semibold))
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityHint("Shows HydroDrop+ mascots")
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color(.secondarySystemBackground))
                Capsule()
                    .fill(
                        LinearGradient(colors: [.blue, .cyan], startPoint: .leading, endPoint: .trailing)
                    )
                    .frame(width: geo.size.width * min(progress, 1))
            }
        }
        .frame(height: 14)
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: progress)
    }

    private var quickAddSection: some View {
        VStack(spacing: 10) {
            HStack {
                Text("Quick add")
                    .font(.headline)
                Spacer()
                if BottleTagSession.showsInterface, !bottles.isEmpty {
                    Button {
                        BottleTagSession.shared.scan { router.handle($0) }
                    } label: {
                        Label("Scan", systemImage: "wave.3.right")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityLabel("Scan bottle")
                    .accessibilityHint("Reads your bottle's sticker and logs a full bottle")
                }
                if sayItIsAvailable {
                    Button {
                        showingSayIt = true
                    } label: {
                        Label("Say it", systemImage: "text.bubble.fill")
                            .font(.subheadline.weight(.semibold))
                    }
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
                    .controlSize(.small)
                    .accessibilityHint("Describe what you drank and log it all at once")
                }
            }
            HStack(spacing: 12) {
                ForEach(Array(settings.quickAddPresets.enumerated()), id: \.offset) { _, amount in
                    Button {
                        addEntry(amount: amount)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: "drop.fill")
                            Text(settings.measurementSystem.format(mL: amount))
                                .font(.caption.weight(.semibold))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(RoundedRectangle(cornerRadius: 14).fill(Color(.secondarySystemBackground)))
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    showingAddSheet = true
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "plus")
                        Text("Custom")
                            .font(.caption.weight(.semibold))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .foregroundStyle(.white)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.blue))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var todayLogSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Today's log")
                    .font(.headline)
                Spacer()
            }
            if todayEntries.isEmpty {
                Text("Nothing logged yet — tap a quick add button above.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 12)
            } else {
                VStack(spacing: 0) {
                    ForEach(todayEntries) { entry in
                        Button {
                            editingEntry = entry
                        } label: {
                            logRow(entry)
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                editingEntry = entry
                            } label: {
                                Label("Edit", systemImage: "pencil")
                            }
                            Button(role: .destructive) {
                                delete(entry)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                        Divider()
                    }
                }
            }
        }
    }

    /// One row of today's log: what it was, how much, and when.
    private func logRow(_ entry: WaterEntry) -> some View {
        let type = entry.drinkType
        return HStack(spacing: 10) {
            Image(systemName: type.icon)
                .foregroundStyle(.blue)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(settings.measurementSystem.format(mL: entry.amountML))
                    .foregroundStyle(.primary)
                if type.countsForLess {
                    // Without this the log's numbers don't add up to the total above it.
                    Text("\(type.label) · counts as \(settings.measurementSystem.format(mL: entry.hydratedML))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if type != .water {
                    Text(type.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Text(entry.timestamp, style: .time)
                .font(.footnote)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Edit this drink")
    }

    private func addEntry(amount: Int, drinkType: DrinkType = .water, timestamp: Date = Date()) {
        // Nothing to catch: a quick add leaves the write to SwiftData's autosave, the
        // way it always has, and only an immediate save can fail.
        guard let logged = try? DrinkLogger.logInApp(
            amountML: amount,
            drinkType: drinkType,
            timestamp: timestamp,
            in: modelContext,
            savesImmediately: false,
            loggedBy: "the Today screen",
            followUp: .init(reminderGoalML: todayGoal, playsHaptic: true),
            settings: settings
        ) else { return }
        offerUndo(of: [logged.entry])
    }

    // MARK: - Bottle tags

    /// Deals with a tag that was tapped or scanned. Every way a tag can reach the app
    /// (a background read, a link, the in-app scanner) ends up here.
    private func handlePendingBottleTap() {
        guard let tagID = router.pendingBottleTagID else { return }
        // A scan from My Bottles closes Settings on its way here. Until the sheet has
        // gone, an unknown tag's alert would have nowhere to appear, so the tap waits
        // and is picked up again once it has.
        guard !router.settingsIsOnScreen else { return }
        router.pendingBottleTagID = nil

        guard let bottle = BottleTag.bottle(for: tagID, in: bottles) else {
            unknownTagID = tagID
            return
        }
        var debouncer = BottleTapDebouncer.load()
        guard debouncer.shouldAccept(bottle.id, at: Date()) else { return }
        debouncer.save()
        log(bottle)
    }

    /// One full bottle, through the same path as every other drink.
    private func log(_ bottle: Bottle) {
        guard MeasurementSystem.plausibleDrinkRangeML.contains(bottle.capacityML) else {
            Diagnostics.log("ignored a tap on a bottle with an implausible capacity: \(bottle.capacityML) mL")
            return
        }
        // Saved straight away, unlike a quick add: a tag read in the background can
        // have the app suspended again before an autosave would have run.
        guard let logged = try? DrinkLogger.logInApp(
            amountML: bottle.capacityML,
            drinkType: bottle.drinkType,
            in: modelContext,
            loggedBy: "a bottle tag",
            followUp: .init(reminderGoalML: todayGoal, playsHaptic: true),
            settings: settings
        ) else { return }
        offerUndo(
            of: [logged.entry],
            message: "Logged \(bottle.name), \(settings.measurementSystem.format(mL: bottle.capacityML))",
            bottleID: bottle.id
        )
    }

    /// Makes an unfamiliar tag mean one of the person's own bottles, and nothing more.
    ///
    /// Deliberately does not log. Linking a tag is setting it up, not drinking from the
    /// bottle, and a drink that appears because of a settings choice is a drink nobody
    /// asked for. The tap that found the tag was never counted by the repeat-tap guard
    /// either, so tapping again straight after linking logs at once.
    private func link(_ tagID: UUID, to bottle: Bottle) {
        bottle.link(tagID: tagID)
        saveContext()
        linkingTagID = nil
        linkedBottleName = bottle.name
    }

    /// Logs everything confirmed on the Say it sheet, as one action with one undo.
    ///
    /// Every drink goes through `DrinkLogger`, one entry each. Only the last uses
    /// `logInApp`: its follow-up reads the whole log back out of the store, so it
    /// republishes the widget and re-paces the reminders for all of them at once
    /// rather than once per drink.
    private func addEntries(_ drafts: [SayItDraft]) {
        guard !drafts.isEmpty else { return }
        let timestamps = SayItMapper.timestamps(count: drafts.count, endingAt: Date())
        var entries: [WaterEntry] = []
        for (index, draft) in drafts.enumerated() {
            let isLast = index == drafts.count - 1
            // Nothing to catch, for the same reason as a quick add: the write is left
            // to SwiftData's autosave, and only an immediate save can fail.
            let logged: DrinkLogger.Logged?
            if isLast {
                logged = try? DrinkLogger.logInApp(
                    amountML: draft.amountML,
                    drinkType: draft.drinkType,
                    timestamp: timestamps[index],
                    in: modelContext,
                    savesImmediately: false,
                    loggedBy: "Say it",
                    followUp: .init(reminderGoalML: todayGoal, playsHaptic: true),
                    settings: settings
                )
            } else {
                logged = try? DrinkLogger.log(
                    amountML: draft.amountML,
                    drinkType: draft.drinkType,
                    timestamp: timestamps[index],
                    in: modelContext,
                    savesImmediately: false,
                    loggedBy: "Say it"
                )
            }
            if let logged { entries.append(logged.entry) }
        }
        offerUndo(of: entries)
    }

    /// Shows the undo bar for a few seconds. A second drink replaces the offer rather
    /// than stacking: only the most recent one can be taken back, which is the one the
    /// user is looking at.
    private func offerUndo(of entries: [WaterEntry], message: String? = nil, bottleID: UUID? = nil) {
        guard let first = entries.first else { return }
        undoDismissal?.cancel()
        // The message is built now rather than read back off the model: the entry can
        // be gone before the toast is, and the bar should describe what was logged.
        let pending = PendingUndo(
            entries: entries,
            message: message ?? (entries.count == 1
                ? "Logged \(settings.measurementSystem.format(mL: first.amountML))"
                : "Logged \(entries.count) drinks"),
            bottleID: bottleID
        )
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
            pendingUndo = pending
        }
        undoDismissal = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled else { return }
            withAnimation(.easeOut(duration: 0.25)) { pendingUndo = nil }
        }
    }

    private func clearUndo() {
        undoDismissal?.cancel()
        undoDismissal = nil
        withAnimation(.easeOut(duration: 0.2)) { pendingUndo = nil }
    }

    /// Takes back what the toast is offering: one drink, or everything a Say it
    /// logged together. A drink that has already gone is skipped, which is what a
    /// delete from the context menu in the same few seconds leaves.
    private func undo(_ entries: [WaterEntry]) {
        // A bottle that was taken back can be tapped again straight away, rather than
        // being ignored as a repeat of the tap that was just undone.
        if let bottleID = pendingUndo?.bottleID {
            var debouncer = BottleTapDebouncer.load()
            debouncer.forget(bottleID)
            debouncer.save()
        }
        clearUndo()
        let remaining = entries.filter { $0.modelContext != nil }
        guard !remaining.isEmpty else { return }
        // Read before the delete: once an entry is gone, so is the only record of
        // which Health sample belonged to it.
        let sampleUUIDs = remaining.map(\.healthKitSampleUUID)
        let caffeineUUIDs = remaining.map(\.caffeineSampleUUID)
        remaining.forEach(modelContext.delete)
        afterLogChange()
        sampleUUIDs.forEach(retireHealthSample)
        caffeineUUIDs.forEach(retireCaffeineSample)
    }

    /// Everything that has to catch up after the log changes in any way.
    private func afterLogChange() {
        mirrorToCompanions()
        syncHealth()
        ReminderManager.shared.refreshSchedule(entries: allEntries, goalML: todayGoal)
    }

    /// Writes anything Health is missing. Cheap and a no-op when sync is off, so it can
    /// sit on every path that changes the log rather than only the ones in this app:
    /// a drink logged by an App Intent in the widget process is picked up here.
    private func syncHealth() {
        guard settings.healthKitSyncEnabled else { return }
        Task { @MainActor in
            await HealthKitManager.shared.reconcile(context: modelContext, settings: settings)
        }
    }

    /// Removes a Health sample whose drink has been deleted or rewritten.
    /// The same, for the caffeine a deleted drink had put in Health.
    private func retireCaffeineSample(_ uuid: String?) {
        guard let uuid, settings.healthKitSyncEnabled else { return }
        Task { @MainActor in
            await HealthKitManager.shared.deleteCaffeineSample(uuidString: uuid)
        }
    }

    private func retireHealthSample(_ uuid: String?) {
        guard let uuid, settings.healthKitSyncEnabled else { return }
        Task { @MainActor in
            await HealthKitManager.shared.deleteSample(uuidString: uuid)
        }
    }

    /// Hands the current state to the two places that render it without the app being
    /// open: the watch and the widgets.
    private func mirrorToCompanions() {
        refreshWorld()
        WatchSessionManager.shared.pushContext(
            totalML: todayTotal,
            goalML: todayGoal,
            measurementSystem: settings.measurementSystem,
            quickAddPresetsML: settings.quickAddPresets
        )
        WidgetPublisher.publish(
            entries: allEntries,
            settings: settings,
            isShared: SharedModelContainer.isShared(modelContext.container),
            goalMLOverride: todayGoal
        )
        let total = todayTotal
        let goal = todayGoal
        let currentStreak = streak
        Task { @MainActor in
            await HydrationLiveActivityController.refresh(
                todayTotalML: total,
                goalML: goal,
                settings: settings,
                streak: currentStreak
            )
        }
    }

    /// SwiftData autosaves, but an edit the user just confirmed should not wait for it:
    /// a background kill in between would lose the change with no sign of it.
    private func saveContext() {
        guard modelContext.hasChanges else { return }
        do {
            try modelContext.save()
        } catch {
            Diagnostics.log("failed to save an edited entry: \(error)")
        }
    }

    /// Work that has to happen every time the app reaches the foreground, not just on
    /// the first appearance: the day may have rolled over, and the reminder horizon may
    /// have run out, while the app was away.
    private func syncOnForeground() {
        sayItIsAvailable = SayIt.isAvailable
        nightOut.expireIfNeeded()
        mirrorToCompanions()
        syncHealth()
        applyStreakFreezeIfNeeded()
        checkWeather()
        checkWorkouts()
        ReminderManager.shared.refreshSchedule(entries: allEntries, goalML: todayGoal)
    }

    /// Asks Health whether a workout worth a suggestion has ended today.
    ///
    /// Only for a subscriber who has connected Insights, which is the one place Health
    /// read access is ever asked for. One suggestion a day: once it has been answered,
    /// either way, a second workout does not bring it back. Silent when there is
    /// nothing to say, like the weather.
    private func checkWorkouts() {
        guard settings.workoutGoalActive, !settings.hasAnsweredWorkoutBump() else { return }
        Task { @MainActor in
            let minutes = await HealthInsightsReader.shared.workoutMinutesEndedToday()
            guard settings.workoutGoalActive, !settings.hasAnsweredWorkoutBump() else { return }
            let suggested = WorkoutBump.suggestedML(workoutMinutes: minutes)
            if suggested != pendingWorkoutBumpML { withAnimation { pendingWorkoutBumpML = suggested } }
        }
    }

    /// Asks the forecast whether today is worth a suggestion.
    ///
    /// Once a day at most, never when the user has already answered for today, and
    /// silently when the answer is no. Everything downstream of it fails quietly too:
    /// a goal suggestion is not worth an error message.
    private func checkWeather() {
        guard settings.weatherGoalActive else { return }
        guard acceptedWeatherBumpML == 0, !settings.hasDismissedWeatherBump() else { return }
        guard pendingWeatherBumpML == nil else { return }
        Task { @MainActor in
            guard let bump = await WeatherGoalAdvisor.shared.suggestedBumpML(baseGoalML: settings.dailyGoalML) else { return }
            guard settings.weatherGoalActive, !settings.hasDismissedWeatherBump() else { return }
            withAnimation { pendingWeatherBumpML = bump }
        }
    }

    /// Today's target moved, so everything measured against it is stale.
    private func afterGoalChange() {
        mirrorToCompanions()
        ReminderManager.shared.refreshSchedule(entries: allEntries, goalML: todayGoal)
    }

    /// Spends a HydroDrop+ freeze on yesterday if it was missed and a streak is at stake.
    private func applyStreakFreezeIfNeeded() {
        guard let day = StreakFreeze.dayToProtect(
            entries: allEntries,
            goalML: settings.dailyGoalML,
            frozenDayKeys: settings.frozenStreakDayKeys,
            isSubscribed: store.isSubscribed
        ) else { return }
        settings.frozenStreakDayKeys.append(day)
    }

    private func delete(_ entry: WaterEntry) {
        // Deleting any drink the toast is offering withdraws the whole offer, so an
        // undo can never half-apply.
        if pendingUndo?.entries.contains(where: { $0.persistentModelID == entry.persistentModelID }) == true {
            clearUndo()
        }
        let sampleUUID = entry.healthKitSampleUUID
        let caffeineUUID = entry.caffeineSampleUUID
        modelContext.delete(entry)
        afterLogChange()
        retireHealthSample(sampleUUID)
        retireCaffeineSample(caffeineUUID)
    }

    /// What can still be taken back, with the words to describe it. One drink for a
    /// quick add, several for a Say it.
    private struct PendingUndo {
        let entries: [WaterEntry]
        let message: String
        /// Set when the drink came from a bottle tag, so undoing it can lift the
        /// repeat-tap guard for that bottle.
        var bottleID: UUID?
    }


}

#Preview {
    HomeView()
        .environmentObject(AppSettings.shared)
        .modelContainer(for: WaterEntry.self, inMemory: true)
}
