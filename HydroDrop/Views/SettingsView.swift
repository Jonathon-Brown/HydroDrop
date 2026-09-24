import SwiftUI
import SwiftData
import UIKit
import StoreKit

/// Settings, opened as a sheet from the gear at the top of Today and History.
///
/// One short page of one-line rows, each showing where it currently stands, with the
/// detail a tap away. Everything used to sit on this page at once: every mascot, every
/// reminder control and a paragraph under each group, which made the few things people
/// come here to change hard to find.
struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var router = AppRouter.shared
    @ObservedObject private var duoStore = DuoStore.shared
    @State private var paywallSource: PaywallSource?
    @State private var showingEventCounts = false
    @State private var showingBugReport = false
    @State private var showingIntroReplay = false

    var body: some View {
        NavigationStack {
            List {
                plusSection

                Section {
                    NavigationLink {
                        GoalSettingsView()
                    } label: {
                        SettingsRowLabel("Daily goal", systemImage: "target", color: .blue,
                                         value: settings.measurementSystem.format(mL: settings.dailyGoalML))
                    }
                    NavigationLink {
                        ReminderSettingsView()
                    } label: {
                        SettingsRowLabel("Reminders", systemImage: "bell.fill", color: .red, value: reminderSummary)
                    }
                    NavigationLink {
                        QuickAddSettingsView()
                    } label: {
                        SettingsRowLabel("Quick add", systemImage: "drop.fill", color: .cyan, value: quickAddSummary)
                    }
                    Picker(selection: $settings.measurementSystem) {
                        ForEach(MeasurementSystem.allCases) { system in
                            Text(system.label).tag(system)
                        }
                    } label: {
                        SettingsRowLabel("Units", systemImage: "ruler.fill", color: .gray)
                    }
                    .pickerStyle(.menu)
                }

                Section {
                    NavigationLink {
                        MascotSettingsView()
                    } label: {
                        LabeledContent {
                            Text(settings.activeMascotSkin.label)
                        } label: {
                            Label {
                                Text("Mascot")
                            } icon: {
                                // The droplet itself rather than a tile: it is the setting.
                                MascotView(progress: 1.0, size: 20, skin: settings.activeMascotSkin, isAnimated: false)
                                    .frame(width: 29, height: 29)
                                    .accessibilityHidden(true)
                            }
                        }
                    }
                    NavigationLink {
                        SmartFeaturesSettingsView()
                    } label: {
                        SettingsRowLabel("Smart features", systemImage: "sparkles", color: .purple,
                                         value: store.isSubscribed ? smartFeaturesSummary : nil,
                                         isLocked: !store.isSubscribed)
                    }
                }

                Section {
                    if HealthKitManager.isAvailable {
                        NavigationLink {
                            HealthSettingsView()
                        } label: {
                            SettingsRowLabel("Apple Health", systemImage: "heart.fill", color: .pink,
                                             value: settings.healthKitSyncEnabled ? "On" : "Off")
                        }
                    }
                    NavigationLink {
                        DuoView()
                    } label: {
                        SettingsRowLabel("Duo Streaks", systemImage: "person.2.fill", color: .green)
                    }
                    if BottleTagSession.showsInterface {
                        NavigationLink {
                            BottlesView()
                        } label: {
                            SettingsRowLabel("My Bottles", systemImage: "waterbottle.fill", color: .teal)
                        }
                    }
                }

                Section {
                    Button {
                        showingBugReport = true
                    } label: {
                        SettingsRowLabel("Report a Bug", systemImage: "ladybug.fill", color: .orange)
                    }
                    Button {
                        showingIntroReplay = true
                    } label: {
                        SettingsRowLabel("Replay intro", systemImage: "play.fill", color: .indigo)
                    }
                    NavigationLink {
                        WeatherDataSourcesView()
                    } label: {
                        SettingsRowLabel("Apple Weather", systemImage: "cloud.sun.fill", color: .cyan)
                    }
                } footer: {
                    versionFooter
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .task {
                // Permission can be taken away in iOS Settings while the app is
                // backgrounded, and granted back the same way. Rebuilding here means the
                // schedule matches the permission the user actually left us with.
                ReminderManager.shared.refreshSchedule()
            }
            .sheet(item: $paywallSource) { source in
                PaywallView(source: source)
            }
            .sheet(isPresented: $showingEventCounts) {
                EventCountsView()
            }
            .sheet(isPresented: $showingBugReport) {
                BugReportView()
            }
            .fullScreenCover(isPresented: $showingIntroReplay) {
                OnboardingView(mode: .replay) {
                    showingIntroReplay = false
                }
                .environmentObject(settings)
            }
            // Same alert the paywall shows for purchase and restore failures. Gated on
            // the entitlement because only the subscribed branch of this screen can set
            // the message (Manage Subscription); the paywall sheet presents its own copy
            // for the unsubscribed flows, and two views presenting the same error at
            // once is one too many.
            .alert(
                "Something went wrong",
                isPresented: Binding(
                    get: { store.isSubscribed && store.lastErrorMessage != nil },
                    set: { if !$0 { store.lastErrorMessage = nil } }
                )
            ) {
                Button("OK", role: .cancel) { store.lastErrorMessage = nil }
            } message: {
                Text(store.lastErrorMessage ?? "")
            }
            // Duo Streaks lives in here, and what goes wrong there (a nudge or an invite
            // that didn't send, a duo that couldn't be left) arrives as a notice. The
            // root shows those too, but not while this sheet is covering it. Once the
            // sheet is on its way out, the root takes over.
            .alert(
                "Duo Streaks",
                isPresented: Binding(
                    get: { duoStore.notice != nil && router.showingSettings },
                    set: { if !$0 { duoStore.notice = nil } }
                )
            ) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(duoStore.notice ?? "")
            }
        }
        // The daily goal, the unit system and the quick-add sizes all appear on the
        // widget, and none of them flow through a store write that would republish
        // on their own. Republish whenever one changes so the widget matches Settings
        // immediately rather than at the next logged drink or foreground. Out here,
        // around the whole stack, so a change made on a page pushed from this one is
        // caught too.
        .onChange(of: settings.dailyGoalML) { _, _ in republishWidget() }
        .onChange(of: settings.measurementSystem) { _, _ in republishWidget() }
        .onChange(of: settings.quickAddPresets) { _, _ in republishWidget() }
    }

    /// Recomputes the widget snapshot from the store after a settings change the widget
    /// renders. The totals come straight back out of the store rather than being carried
    /// in, so a goal or unit change never disturbs today's count.
    private func republishWidget() {
        WidgetPublisher.publish(
            context: modelContext,
            isShared: SharedModelContainer.isShared(modelContext.container)
        )
    }

    // MARK: - HydroDrop+

    @ViewBuilder
    private var plusSection: some View {
        if store.isSubscribed {
            Section {
                HStack(spacing: 12) {
                    SettingsIcon(systemName: "checkmark.seal.fill", color: .green)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("HydroDrop+ is active")
                        Text("\(freezesRemaining) of \(StreakFreeze.monthlyAllowance) streak freezes left this month")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                Button("Manage Subscription") {
                    Task { await presentManageSubscriptions() }
                }
            } footer: {
                Text("If you miss a day, a freeze is spent automatically to keep your streak alive.")
            }
        } else {
            Section {
                Button {
                    paywallSource = .settingsRow
                } label: {
                    upgradeCard
                }
                .accessibilityLabel("Upgrade to HydroDrop+")
                .accessibilityHint("No ads, every mascot, smart reminders and more.")
                .listRowBackground(
                    LinearGradient(
                        colors: [Color(red: 0.18, green: 0.56, blue: 0.93), Color(red: 0.12, green: 0.74, blue: 0.86)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
        }
    }

    /// The paid skins, fanned out, on the app's own blue: the most visible thing Plus
    /// changes is the droplet, so the way in shows it.
    private var upgradeCard: some View {
        HStack(spacing: 14) {
            HStack(spacing: -12) {
                ForEach(MascotSkin.allCases.filter(\.requiresPlus).prefix(3)) { skin in
                    MascotView(progress: 1.0, size: 26, skin: skin, isAnimated: false)
                }
            }
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("Upgrade to HydroDrop+")
                    .font(.headline)
                Text("No ads, every mascot, smart reminders and more.")
                    .font(.subheadline)
                    .opacity(0.85)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.footnote.weight(.semibold))
                .opacity(0.7)
        }
        .foregroundStyle(.white)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    // MARK: - Row summaries

    private var reminderSummary: String {
        settings.remindersEnabled ? "Every \(DurationLabel.label(minutes: settings.reminderIntervalMinutes))" : "Off"
    }

    /// "200 · 330 · 500 mL": the three sizes, with the unit said once.
    private var quickAddSummary: String {
        let system = settings.measurementSystem
        let sizes = settings.quickAddPresets.map { system.formattedNumber(mL: $0) }
        return sizes.joined(separator: " · ") + " " + system.unitLabel
    }

    /// How many of the Plus switches are actually doing something.
    private var smartFeaturesSummary: String {
        let on = [
            settings.weeklyRecapActive,
            settings.weatherGoalActive,
            settings.workoutGoalActive,
            settings.liveActivityActive,
            settings.caffeineTrackingActive,
        ].filter { $0 }.count
        return on == 0 ? "Off" : "\(on) on"
    }

    private var freezesRemaining: Int {
        StreakFreeze.freezesRemaining(frozenDayKeys: settings.frozenStreakDayKeys)
    }

    // MARK: - About

    private var versionFooter: some View {
        VStack(spacing: 6) {
            MascotView(progress: 1.0, size: 28, skin: settings.activeMascotSkin, isAnimated: false)
                .accessibilityHidden(true)
            Text("HydroDrop \(appVersionLabel)")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 28)
        .contentShape(Rectangle())
        // Hidden way into the on-device paywall counts. Does nothing in App Store
        // builds; see `EventCountsView.isAvailable`.
        .onLongPressGesture(minimumDuration: 1.5) {
            Task {
                if await EventCountsView.isAvailable {
                    showingEventCounts = true
                }
            }
        }
    }

    private var appVersionLabel: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(version) (\(build))"
    }

    // MARK: - Manage subscription

    /// Presents the App Store's manage-subscriptions sheet. Both ways this used to fail
    /// were silent: `try?` dropped whatever the sheet threw, and a missing window scene
    /// returned without a word — the "button does nothing" reported against 1.0 and
    /// 1.0.1. Errors now surface through `store.lastErrorMessage`, the alert path the
    /// paywall already uses, and with no scene to host the sheet the same page opens in
    /// the App Store app instead.
    @MainActor
    private func presentManageSubscriptions() async {
        guard let scene = activeWindowScene else {
            await openSubscriptionsInAppStore()
            return
        }
        do {
            try await AppStore.showManageSubscriptions(in: scene)
        } catch {
            store.lastErrorMessage = error.localizedDescription
        }
    }

    /// The foreground scene when there is one, otherwise any connected window scene.
    private var activeWindowScene: UIWindowScene? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        return scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    }

    /// Fallback for when no window scene can host the sheet: the same subscriptions
    /// page, opened in the App Store app.
    @MainActor
    private func openSubscriptionsInAppStore() async {
        if let url = URL(string: "https://apps.apple.com/account/subscriptions"),
           await UIApplication.shared.open(url) {
            return
        }
        store.lastErrorMessage = "Couldn't open your subscriptions. "
            + "You can manage them in Settings > Apple Account > Subscriptions."
    }
}

// MARK: - Rows

/// The rounded, coloured square each row leads with, as in the iOS Settings app.
struct SettingsIcon: View {
    let systemName: String
    let color: Color

    @ScaledMetric(relativeTo: .body) private var side: CGFloat = 29

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: side * 0.52, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: side, height: side)
            .background(RoundedRectangle(cornerRadius: side * 0.24, style: .continuous).fill(color.gradient))
            .accessibilityHidden(true)
    }
}

/// One row of Settings: icon and name, with where it stands on the trailing side.
struct SettingsRowLabel: View {
    let title: String
    let systemImage: String
    let color: Color
    var value: String?
    /// A HydroDrop+ row seen without HydroDrop+: a lock where the value would be.
    var isLocked = false

    init(_ title: String, systemImage: String, color: Color, value: String? = nil, isLocked: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.color = color
        self.value = value
        self.isLocked = isLocked
    }

    var body: some View {
        if isLocked {
            LabeledContent {
                Image(systemName: "lock.fill")
                    .font(.footnote)
                    .accessibilityLabel("HydroDrop+")
            } label: {
                titleLabel
            }
        } else if let value {
            LabeledContent {
                Text(value)
            } label: {
                titleLabel
            }
        } else {
            // Bare, so it also works as a picker's label, which brings its own value.
            titleLabel
        }
    }

    private var titleLabel: some View {
        Label {
            // Primary even inside a Button, which would otherwise tint it like a link.
            Text(title)
                .foregroundStyle(Color.primary)
        } icon: {
            SettingsIcon(systemName: systemImage, color: color)
        }
    }
}

#Preview {
    SettingsView()
        .environmentObject(AppSettings.shared)
}
