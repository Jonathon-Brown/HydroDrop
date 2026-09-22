import SwiftUI
import SwiftData
import Charts

private struct DayTotal: Identifiable {
    let date: Date
    let totalML: Int
    var id: Date { date }
}

struct HistoryView: View {
    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = StoreManager.shared
    @ObservedObject private var router = AppRouter.shared
    @Query(sort: \WaterEntry.timestamp, order: .reverse) private var allEntries: [WaterEntry]
    @State private var showingPaywall = false
    @State private var showingWeeklyRecap = false

    private let freeDayCount = 7
    private let plusDayCount = 30

    private var calendar: Calendar { .current }

    private var dayCount: Int {
        store.isSubscribed ? plusDayCount : freeDayCount
    }

    private var displayedDays: [DayTotal] {
        let totals = StreakCalculator.totalsByDay(allEntries, calendar: calendar)
        return (0..<dayCount).reversed().compactMap { offset -> DayTotal? in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: Date())) else { return nil }
            return DayTotal(date: day, totalML: totals[DayKey.key(for: day, calendar: calendar)] ?? 0)
        }
    }

    private var streak: Int {
        StreakCalculator.currentStreak(
            entries: allEntries,
            goalML: settings.dailyGoalML,
            frozenDayKeys: settings.frozenStreakDayKeys
        )
    }

    private var average: Int {
        let total = displayedDays.reduce(0) { $0 + $1.totalML }
        return total / max(displayedDays.count, 1)
    }

    private var daysGoalMet: Int {
        displayedDays.filter { $0.totalML >= settings.dailyGoalML }.count
    }

    private static let insightsAnchor = "insights"

    private func showInsightsIfAsked(_ proxy: ScrollViewProxy) {
        guard router.pendingInsights else { return }
        router.pendingInsights = false
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(0.4))
            withAnimation { proxy.scrollTo(Self.insightsAnchor, anchor: .top) }
        }
    }

    private var worldCard: WorldCardContent {
        WorldCardContent(
            state: WorldEngine.state(
                totalsByDay: StreakCalculator.totalsByDay(allEntries),
                goalML: settings.dailyGoalML,
                frozenDayKeys: settings.frozenStreakDayKeys,
                recordedGoalDays: settings.worldGoalDaysRecord
            ),
            decorations: settings.activeWorldDecorations,
            timeOfDay: WorldTimeOfDay(date: Date())
        )
    }

    private var todayTotal: Int {
        let totals = StreakCalculator.totalsByDay(allEntries, calendar: calendar)
        return totals[DayKey.key(for: Date(), calendar: calendar)] ?? 0
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statsRow

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Last \(dayCount) days")
                            .font(.headline)

                        // Plotted in the display unit so the axis reads in the same
                        // unit as everything else on the screen.
                        Chart(displayedDays) { day in
                            BarMark(
                                x: .value("Day", day.date, unit: .day),
                                y: .value(settings.measurementSystem.unitLabel, settings.measurementSystem.displayVolume(fromML: day.totalML))
                            )
                            .foregroundStyle(day.totalML >= settings.dailyGoalML ? Color.blue : Color.blue.opacity(0.45))
                            .cornerRadius(dayCount > freeDayCount ? 2 : 6)

                            RuleMark(y: .value("Goal", settings.measurementSystem.displayVolume(fromML: settings.dailyGoalML)))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .foregroundStyle(.secondary)
                        }
                        .chartYAxisLabel(settings.measurementSystem.unitLabel)
                        .frame(height: 220)
                        .chartXAxis {
                            if dayCount > freeDayCount {
                                AxisMarks(values: .stride(by: .day, count: 5)) { value in
                                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                                }
                            } else {
                                AxisMarks(values: .stride(by: .day)) { value in
                                    AxisValueLabel(format: .dateTime.weekday(.abbreviated))
                                }
                            }
                        }
                    }
                    .padding()
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))

                    if !store.isSubscribed {
                        BannerAdView(adUnitID: AdManager.bannerAdUnitID)
                    }

                    if store.isSubscribed {
                        Button {
                            showingWeeklyRecap = true
                        } label: {
                            HStack {
                                Image(systemName: "calendar")
                                    .foregroundStyle(.blue)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Your week in water")
                                        .font(.subheadline.weight(.semibold))
                                    Text("Averages, your best day, and when you tend to fall behind.")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
                        }
                        .buttonStyle(.plain)
                    }

                    InsightsSection(
                        totalsByDay: StreakCalculator.totalsByDay(allEntries),
                        goalML: settings.dailyGoalML
                    )
                    .id(Self.insightsAnchor)

                    BadgeShelf(
                        earnedDays: Set(settings.celebratedMilestones),
                        currentStreak: streak
                    )

                    if !store.isSubscribed {
                        upsellBanner
                    }
                }
                .padding()
            }
            // The weekly recap's link lands here. Waits a beat so the tab has changed
            // and the recap has gone before anything moves.
            .onChange(of: router.pendingInsights) { _, _ in showInsightsIfAsked(proxy) }
            // This tab may not have existed yet when the link was tapped.
            .onAppear { showInsightsIfAsked(proxy) }
            }
            .navigationTitle("History")
            .toolbar {
                // Nothing worth sharing until there is a streak to share.
                if streak > 0 {
                    ToolbarItem(placement: .primaryAction) {
                        // Two cards to choose from: the streak on its own, or the droplet
                        // at home in its world.
                        Menu {
                            StreakShareButton(
                                streak: streak,
                                skin: settings.activeMascotSkin,
                                todayTotalML: todayTotal,
                                goalML: settings.dailyGoalML,
                                system: settings.measurementSystem
                            )
                            StreakShareButton(
                                streak: streak,
                                skin: settings.activeMascotSkin,
                                todayTotalML: todayTotal,
                                goalML: settings.dailyGoalML,
                                system: settings.measurementSystem,
                                label: "Share my world",
                                world: worldCard
                            )
                        } label: {
                            Label("Share", systemImage: "square.and.arrow.up")
                        }
                    }
                }
            }
            .sheet(isPresented: $showingPaywall) {
                PaywallView(source: .historyBanner)
            }
            .sheet(isPresented: $showingWeeklyRecap) {
                WeeklyRecapView()
                    .environmentObject(settings)
            }
        }
    }

    private var statsRow: some View {
        HStack(spacing: 12) {
            statCard(title: "Streak", value: "\(streak)", subtitle: streak == 1 ? "day" : "days", icon: "flame.fill", tint: .orange)
            statCard(title: "\(dayCount)-day avg", value: settings.measurementSystem.formattedNumber(mL: average), subtitle: settings.measurementSystem.unitLabel, icon: "chart.line.uptrend.xyaxis", tint: .blue)
            statCard(title: "Goal hit", value: "\(daysGoalMet)/\(dayCount)", subtitle: "days", icon: "checkmark.seal.fill", tint: .green)
        }
    }

    private func statCard(title: String, value: String, subtitle: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.bold))
            Text("\(title) · \(subtitle)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var upsellBanner: some View {
        Button {
            showingPaywall = true
        } label: {
            HStack {
                Image(systemName: "sparkles")
                    .foregroundStyle(.orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text("See your full history")
                        .font(.subheadline.weight(.semibold))
                    Text("HydroDrop+ unlocks 30-day trends and more.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.secondary)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    HistoryView()
        .environmentObject(AppSettings.shared)
        .modelContainer(for: WaterEntry.self, inMemory: true)
}
