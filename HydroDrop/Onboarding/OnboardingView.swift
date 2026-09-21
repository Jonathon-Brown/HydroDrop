import SwiftUI
import SwiftData

/// First-launch onboarding, and the same flow replayed from Settings.
///
/// Five stops: meet the mascot, pick a goal, pick units, set up reminders (with the
/// system permission asked for only after the value has been explained), and log a
/// first real drink. Everything the user chooses is written to `AppSettings` at the
/// moment they confirm it, so closing the app halfway keeps whatever was already
/// decided, and the flow itself holds no state that has to be saved.
struct OnboardingView: View {
    enum Mode {
        case firstLaunch
        /// Opened from Settings. Adds a Close button and never re-marks completion.
        case replay
    }

    let mode: Mode
    let onFinish: () -> Void

    @EnvironmentObject private var settings: AppSettings
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private enum Step: Int, CaseIterable {
        case intro, goal, units, reminderSchedule, reminderPrimer, firstSip
    }

    @State private var step: Step = .intro

    // Goal
    @State private var weightText = ""
    @State private var activity: OnboardingActivity = .moderate
    @State private var goalML: Int

    // Reminders
    @State private var startMinutes: Int
    @State private var endMinutes: Int
    @State private var intervalMinutes: Int
    @State private var notificationsDenied = false
    @State private var isRequestingPermission = false

    // First sip
    @State private var hasLoggedFirstSip = false

    /// Longest sensible weight entry, e.g. "1234.5". Same backstop as the calculator.
    private static let maxWeightCharacters = 6
    /// Where the mascot lands after the first sip: visibly happier than "parched",
    /// whatever fraction of the goal one glass actually is.
    private static let firstSipMoodProgress = 0.8

    init(mode: Mode, onFinish: @escaping () -> Void) {
        self.mode = mode
        self.onFinish = onFinish
        let settings = AppSettings.shared
        _goalML = State(initialValue: settings.dailyGoalML)
        _startMinutes = State(initialValue: settings.quietStartMinutes)
        _endMinutes = State(initialValue: settings.quietEndMinutes)
        _intervalMinutes = State(initialValue: settings.reminderIntervalMinutes)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    content
                        .transition(stepTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: step)

                stepDots
                    .padding(.bottom, 8)
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if step != .intro {
                    ToolbarItem(placement: .navigation) {
                        Button {
                            back()
                        } label: {
                            Label("Back", systemImage: "chevron.left")
                        }
                    }
                }
                if mode == .replay {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close") { finish(markComplete: false) }
                    }
                }
            }
        }
        .interactiveDismissDisabled(mode == .firstLaunch)
    }

    private var stepTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            )
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .intro: intro
        case .goal: goal
        case .units: units
        case .reminderSchedule: reminderSchedule
        case .reminderPrimer: reminderPrimer
        case .firstSip: firstSip
        }
    }

    private var stepDots: some View {
        HStack(spacing: 6) {
            ForEach(Step.allCases, id: \.rawValue) { candidate in
                Capsule()
                    .fill(candidate == step ? Color.accentColor : Color(.tertiarySystemFill))
                    .frame(width: candidate == step ? 18 : 6, height: 6)
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: step)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Step \(step.rawValue + 1) of \(Step.allCases.count)")
    }

    // MARK: - 1. Intro

    private var intro: some View {
        page(
            title: "Meet your droplet",
            subtitle: "It gets parched when you forget to drink. Log your water and it perks right up."
        ) {
            MascotView(progress: 0, size: 150, skin: settings.activeMascotSkin)
                .padding(.top, 24)
            Text(MascotMood.parched.label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        } footer: {
            primaryButton("Get started") { advance(to: .goal) }
        }
    }

    // MARK: - 2. Goal

    private var weightKG: Double? {
        guard let value = Double(weightText), value > 0, value.isFinite else { return nil }
        return settings.measurementSystem.weightInKG(fromDisplayValue: value)
    }

    private var suggestedGoalML: Int? {
        weightKG.map { OnboardingGoal.suggestedGoalML(weightKG: $0, activity: activity) }
    }

    private var goal: some View {
        page(
            title: "Set a daily goal",
            subtitle: "Two quick questions and we'll suggest one. Your weight is only used for the sum and is not saved."
        ) {
            GroupBox {
                HStack {
                    Text("Weight")
                    Spacer()
                    TextField("Weight", text: $weightText)
                        .keyboardType(.decimalPad)
                        .multilineTextAlignment(.trailing)
                        .frame(width: 90)
                        .onChange(of: weightText) { _, newValue in
                            if newValue.count > Self.maxWeightCharacters {
                                weightText = String(newValue.prefix(Self.maxWeightCharacters))
                            }
                            applySuggestion()
                        }
                    Text(settings.measurementSystem.weightUnitLabel)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Activity level")
                    .font(.headline)
                Picker("Activity level", selection: $activity) {
                    ForEach(OnboardingActivity.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: activity) { _, _ in applySuggestion() }
                Text(activity.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            GroupBox {
                GoalStepper(
                    goalML: $goalML,
                    system: settings.measurementSystem,
                    title: suggestedGoalML == nil ? "Daily goal" : "Suggested goal"
                )
            }

            Text("A general estimate based on common hydration guidelines, not medical advice. Adjust it to suit you.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        } footer: {
            primaryButton("Use this goal") {
                settings.dailyGoalML = goalML
                settings.activityLevel = activity.activityLevel
                advance(to: .units)
            }
        }
    }

    private func applySuggestion() {
        if let suggestedGoalML {
            goalML = suggestedGoalML
        }
    }

    // MARK: - 3. Units

    private var units: some View {
        page(
            title: "Pick your units",
            subtitle: "You can change this any time in Settings."
        ) {
            VStack(spacing: 12) {
                ForEach(MeasurementSystem.allCases) { system in
                    unitCard(system)
                }
            }
            .padding(.top, 8)
        } footer: {
            primaryButton("Continue") { advance(to: .reminderSchedule) }
        }
    }

    private func unitCard(_ system: MeasurementSystem) -> some View {
        let isSelected = settings.measurementSystem == system
        return Button {
            settings.measurementSystem = system
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "drop.fill")
                    .font(.title2)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(system == .metric ? "Milliliters" : "Fluid ounces")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("A glass is \(system.format(mL: system.defaultQuickAddPresetsML[0]))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.title3)
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? Color.accentColor : .clear, lineWidth: 2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    // MARK: - 4a. Reminder schedule

    private var wakingWindowIsEmpty: Bool { startMinutes == endMinutes }

    private var reminderSchedule: some View {
        page(
            title: "When are you awake?",
            subtitle: "Reminders only arrive between these times, and never overnight."
        ) {
            GroupBox {
                DatePicker(
                    "From",
                    selection: MinuteOfDay.dateBinding($startMinutes),
                    displayedComponents: .hourAndMinute
                )
                Divider()
                DatePicker(
                    "Until",
                    selection: MinuteOfDay.dateBinding($endMinutes),
                    displayedComponents: .hourAndMinute
                )
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Remind me every")
                    .font(.headline)
                DurationWheelPicker(
                    totalMinutes: $intervalMinutes,
                    range: AppSettings.reminderIntervalRange
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if wakingWindowIsEmpty {
                Label(
                    "Pick an end time that differs from the start time.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } footer: {
            primaryButton("Continue") { advance(to: .reminderPrimer) }
                .disabled(wakingWindowIsEmpty)
        }
    }

    // MARK: - 4b. Reminder primer

    private var reminderPrimer: some View {
        page(title: "A nudge at the right moment") {
            Image(systemName: "bell.badge.fill")
                .font(.system(size: 56))
                .foregroundStyle(Color.accentColor)
                .padding(.vertical, 12)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 16) {
                primerRow(
                    icon: "clock",
                    text: "One reminder every \(DurationLabel.label(minutes: intervalMinutes)), between \(MinuteOfDay.label(startMinutes)) and \(MinuteOfDay.label(endMinutes))."
                )
                primerRow(
                    icon: "hand.tap",
                    text: "Log a glass or snooze straight from the notification. No need to open the app."
                )
                primerRow(
                    icon: "slider.horizontal.3",
                    text: "Change the schedule or switch reminders off any time in Settings."
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if notificationsDenied {
                Label(
                    "Notifications are off for HydroDrop in iOS Settings. Turn them on there whenever you like and reminders will start.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.footnote)
                .foregroundStyle(.orange)
            }
        } footer: {
            if notificationsDenied {
                primaryButton("Continue") { advance(to: .firstSip) }
            } else {
                primaryButton("Turn on reminders") { enableReminders() }
                    .disabled(isRequestingPermission)
                Button("Not now") {
                    applyReminderSchedule()
                    settings.remindersEnabled = false
                    advance(to: .firstSip)
                }
                .font(.subheadline.weight(.medium))
            }
        }
    }

    private func primerRow(icon: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .frame(width: 24)
                .foregroundStyle(Color.accentColor)
            Text(text)
                .font(.subheadline)
        }
    }

    /// The window and interval are the user's choice whether or not they let us notify,
    /// so they are kept either way and Settings shows what was picked.
    private func applyReminderSchedule() {
        settings.quietStartMinutes = startMinutes
        settings.quietEndMinutes = endMinutes
        settings.reminderIntervalMinutes = intervalMinutes
    }

    /// The system prompt, asked for only now, after the primer has made the case.
    private func enableReminders() {
        applyReminderSchedule()
        settings.remindersEnabled = true
        isRequestingPermission = true
        ReminderManager.shared.requestAuthorizationIfNeeded { granted in
            isRequestingPermission = false
            if granted {
                advance(to: .firstSip)
            } else {
                notificationsDenied = true
            }
        }
    }

    // MARK: - 5. First sip

    private var firstSipAmountML: Int {
        settings.quickAddPresets.first ?? 250
    }

    private var firstSipProgress: Double {
        hasLoggedFirstSip ? Self.firstSipMoodProgress : 0
    }

    private var firstSip: some View {
        page(
            title: hasLoggedFirstSip ? "That's the idea" : "Log your first sip",
            subtitle: hasLoggedFirstSip
                ? "Your droplet is already happier. Keep it that way through the day."
                : "Tap the glass whenever you drink. Your droplet reacts right away."
        ) {
            MascotView(progress: firstSipProgress, size: 150, skin: settings.activeMascotSkin)
                .padding(.top, 12)
            Text(MascotMood.forProgress(firstSipProgress).label)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .animation(.easeInOut, value: hasLoggedFirstSip)

            if !hasLoggedFirstSip {
                Button {
                    logFirstSip()
                } label: {
                    VStack(spacing: 4) {
                        Image(systemName: "drop.fill")
                            .font(.title2)
                        Text(settings.measurementSystem.format(mL: firstSipAmountML))
                            .font(.subheadline.weight(.semibold))
                    }
                    .frame(maxWidth: 160)
                    .padding(.vertical, 16)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
                }
                .buttonStyle(.plain)
                .padding(.top, 8)
            }
        } footer: {
            if hasLoggedFirstSip {
                primaryButton("Start tracking") { finish(markComplete: true) }
            } else {
                Button("Skip for now") { finish(markComplete: true) }
                    .font(.subheadline.weight(.medium))
            }
        }
    }

    /// A real entry, exactly what a quick-add button on Today would write.
    private func logFirstSip() {
        // A save failure has never stopped onboarding: the first sip is a nicety, and
        // holding up the intro over it would cost more than losing it. `DrinkLogger`
        // names the reason in Console, so the drink is not lost silently.
        _ = try? DrinkLogger.logInApp(
            amountML: firstSipAmountML,
            in: modelContext,
            loggedBy: "onboarding",
            followUp: .init(reminderGoalML: settings.dailyGoalML),
            settings: settings
        )
        // Outside the logger, so the intro still acknowledges the tap even on the rare
        // occasion the write did not land.
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(reduceMotion ? nil : .spring(response: 0.5, dampingFraction: 0.7)) {
            hasLoggedFirstSip = true
        }
    }

    // MARK: - Navigation

    private func advance(to next: Step) {
        step = next
    }

    private func back() {
        guard let previous = Step(rawValue: step.rawValue - 1) else { return }
        step = previous
    }

    private func finish(markComplete: Bool) {
        if markComplete {
            settings.hasCompletedOnboarding = true
        }
        onFinish()
    }

    // MARK: - Layout

    private func page<Content: View, Footer: View>(
        title: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content,
        @ViewBuilder footer: () -> Footer
    ) -> some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    Text(title)
                        .font(.title.weight(.bold))
                        .multilineTextAlignment(.center)
                    if let subtitle {
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    content()
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .scrollDismissesKeyboard(.interactively)

            VStack(spacing: 12) {
                footer()
            }
            .padding(.horizontal)
            .padding(.vertical, 12)
        }
    }

    private func primaryButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.headline)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

#Preview {
    OnboardingView(mode: .replay) {}
        .environmentObject(AppSettings.shared)
        .modelContainer(for: WaterEntry.self, inMemory: true)
}
