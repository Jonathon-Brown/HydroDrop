import SwiftUI
import SwiftData
import StoreKit

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.requestReview) private var requestReview
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = StoreManager.shared
    @Query(sort: \WaterEntry.timestamp, order: .reverse) private var allEntries: [WaterEntry]

    @State private var showingAddSheet = false
    @State private var paywallSource: PaywallSource?
    @State private var editingEntry: WaterEntry?
    /// The milestone whose celebration is on screen.
    @State private var celebration: StreakMilestone?
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

    private var progress: Double {
        guard settings.dailyGoalML > 0 else { return 0 }
        return Double(todayTotal) / Double(settings.dailyGoalML)
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

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    streakBadge

                    if let lost = visibleLostStreak {
                        streakBreakNotice(lost)
                            .transition(.opacity)
                    }

                    VStack(spacing: 2) {
                        MascotView(progress: progress, size: 150, skin: settings.activeMascotSkin)
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

                    VStack(spacing: 6) {
                        Text(settings.measurementSystem.format(mL: todayTotal))
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                        Text("of \(settings.measurementSystem.format(mL: settings.dailyGoalML)) goal")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    progressBar

                    quickAddSection

                    todayLogSection

                    if !store.isSubscribed {
                        BannerAdView(adUnitID: AdManager.bannerAdUnitID)
                    }
                }
                .padding()
            }
            .navigationTitle("Today")
            .sheet(isPresented: $showingAddSheet) {
                AddDrinkSheet { amount, drinkType, timestamp in
                    addEntry(amount: amount, drinkType: drinkType, timestamp: timestamp)
                }
            }
            .sheet(item: $editingEntry) { entry in
                EditEntrySheet(entry: entry) {
                    // The edit may have moved the drink to another day or changed what
                    // it counts for, so everything downstream of the total is stale.
                    saveContext()
                    clearUndo()
                    afterLogChange()
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
            .sheet(item: $celebration) { milestone in
                MilestoneCelebrationView(
                    milestone: milestone,
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
                        undo(pendingUndo.entry)
                    }
                    .padding(.bottom, 8)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
        }
        .onAppear {
            syncOnForeground()
            checkMilestones()
            considerReviewPrompt()
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
            ReminderManager.shared.refreshSchedule(entries: allEntries, goalML: settings.dailyGoalML)
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

        guard celebration == nil else { return }
        guard let milestone = StreakMilestone.newlyReached(
            streak: streak,
            alreadyCelebrated: Set(settings.celebratedMilestones)
        ) else { return }
        settings.recordMilestone(milestone)
        celebration = milestone
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
        .background(Capsule().fill(Color(.secondarySystemBackground)))
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
        let entry = WaterEntry(amountML: amount, timestamp: timestamp, drinkType: drinkType)
        modelContext.insert(entry)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        offerUndo(of: entry)
        WidgetPublisher.publish(
            entries: allEntries + [entry],
            settings: settings,
            isShared: SharedModelContainer.isShared(modelContext.container)
        )
        // Logging changes today's pace, so the rest of the day's nudges are now stale.
        ReminderManager.shared.refreshSchedule(entries: allEntries + [entry], goalML: settings.dailyGoalML)
    }

    /// Shows the undo bar for a few seconds. A second drink replaces the offer rather
    /// than stacking: only the most recent one can be taken back, which is the one the
    /// user is looking at.
    private func offerUndo(of entry: WaterEntry) {
        undoDismissal?.cancel()
        // The message is built now rather than read back off the model: the entry can
        // be gone before the toast is, and the bar should describe what was logged.
        let pending = PendingUndo(
            entry: entry,
            message: "Logged \(settings.measurementSystem.format(mL: entry.amountML))"
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

    /// Takes back the drink the toast is offering. A no-op if it has already gone,
    /// which is what a delete from the context menu in the same few seconds leaves.
    private func undo(_ entry: WaterEntry) {
        clearUndo()
        guard entry.modelContext != nil else { return }
        modelContext.delete(entry)
        afterLogChange()
    }

    /// Everything that has to catch up after the log changes in any way.
    private func afterLogChange() {
        mirrorToCompanions()
        ReminderManager.shared.refreshSchedule(entries: allEntries, goalML: settings.dailyGoalML)
    }

    /// Hands the current state to the two places that render it without the app being
    /// open: the watch and the widgets.
    private func mirrorToCompanions() {
        WatchSessionManager.shared.pushContext(
            totalML: todayTotal,
            goalML: settings.dailyGoalML,
            measurementSystem: settings.measurementSystem,
            quickAddPresetsML: settings.quickAddPresets
        )
        WidgetPublisher.publish(
            entries: allEntries,
            settings: settings,
            isShared: SharedModelContainer.isShared(modelContext.container)
        )
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
        mirrorToCompanions()
        applyStreakFreezeIfNeeded()
        ReminderManager.shared.refreshSchedule(entries: allEntries, goalML: settings.dailyGoalML)
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
        if pendingUndo?.entry.persistentModelID == entry.persistentModelID { clearUndo() }
        modelContext.delete(entry)
        afterLogChange()
    }

    /// A drink that can still be taken back, with the words to describe it.
    private struct PendingUndo {
        let entry: WaterEntry
        let message: String
    }


}

#Preview {
    HomeView()
        .environmentObject(AppSettings.shared)
        .modelContainer(for: WaterEntry.self, inMemory: true)
}
