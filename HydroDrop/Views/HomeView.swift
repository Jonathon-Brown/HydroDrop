import SwiftUI
import SwiftData

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = StoreManager.shared
    @Query(sort: \WaterEntry.timestamp, order: .reverse) private var allEntries: [WaterEntry]

    @State private var showingAddSheet = false

    private var todayEntries: [WaterEntry] {
        allEntries.filter { Calendar.current.isDateInToday($0.timestamp) }
    }

    private var todayTotal: Int {
        todayEntries.reduce(0) { $0 + $1.amountML }
    }

    private var progress: Double {
        guard settings.dailyGoalML > 0 else { return 0 }
        return Double(todayTotal) / Double(settings.dailyGoalML)
    }

    private var streak: Int {
        StreakCalculator.currentStreak(
            entries: allEntries,
            goalML: settings.dailyGoalML,
            frozenDays: settings.frozenStreakDays
        )
    }

    /// True when a freeze is currently holding the streak together, i.e. yesterday
    /// was missed but protected.
    private var streakIsFrozen: Bool {
        guard let yesterday = Calendar.current.date(
            byAdding: .day,
            value: -1,
            to: Calendar.current.startOfDay(for: Date())
        ) else { return false }
        return settings.frozenStreakDays.contains(yesterday)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    streakBadge

                    VStack(spacing: 2) {
                        MascotView(progress: progress, size: 150, skin: settings.mascotSkin)
                        // The face carries the mood; naming it makes sure the signal
                        // still lands for anyone who reads the screen quickly.
                        Text(MascotMood.forProgress(progress).label)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .animation(.easeInOut, value: progress)
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
                }
                .padding()
            }
            .navigationTitle("Today")
            .sheet(isPresented: $showingAddSheet) {
                AddDrinkSheet { amount in
                    addEntry(amount: amount)
                }
            }
        }
        .onAppear {
            pushWatchContext()
            applyStreakFreezeIfNeeded()
        }
        .onChange(of: todayTotal) { _, _ in
            pushWatchContext()
        }
        .onChange(of: settings.dailyGoalML) { _, _ in
            pushWatchContext()
        }
        .onChange(of: settings.measurementSystem) { _, _ in
            pushWatchContext()
        }
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
                ForEach(settings.quickAddPresets, id: \.self) { amount in
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
                        HStack {
                            Image(systemName: "drop.fill")
                                .foregroundStyle(.blue)
                            Text(settings.measurementSystem.format(mL: entry.amountML))
                            Spacer()
                            Text(entry.timestamp, style: .time)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 10)
                        .contentShape(Rectangle())
                        .contextMenu {
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

    private func addEntry(amount: Int) {
        let entry = WaterEntry(amountML: amount)
        modelContext.insert(entry)
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
        // Logging changes today's pace, so the rest of the day's nudges are now stale.
        ReminderManager.shared.refreshSchedule(entries: allEntries + [entry], goalML: settings.dailyGoalML)
    }

    /// Spends a HydroDrop+ freeze on yesterday if it was missed and a streak is at stake.
    private func applyStreakFreezeIfNeeded() {
        guard let day = StreakFreeze.dayToProtect(
            entries: allEntries,
            goalML: settings.dailyGoalML,
            frozenDays: settings.frozenStreakDays,
            isSubscribed: store.isSubscribed
        ) else { return }
        settings.frozenStreakDays.append(day)
    }

    private func delete(_ entry: WaterEntry) {
        modelContext.delete(entry)
    }

    private func pushWatchContext() {
        WatchSessionManager.shared.pushContext(
            totalML: todayTotal,
            goalML: settings.dailyGoalML,
            measurementSystem: settings.measurementSystem
        )
    }
}

#Preview {
    HomeView()
        .environmentObject(AppSettings.shared)
        .modelContainer(for: WaterEntry.self, inMemory: true)
}
