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
    @Query(sort: \WaterEntry.timestamp, order: .reverse) private var allEntries: [WaterEntry]
    @State private var showingPaywall = false

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
            return DayTotal(date: day, totalML: totals[day] ?? 0)
        }
    }

    private var streak: Int {
        StreakCalculator.currentStreak(
            entries: allEntries,
            goalML: settings.dailyGoalML,
            frozenDays: settings.frozenStreakDays
        )
    }

    private var average: Int {
        let total = displayedDays.reduce(0) { $0 + $1.totalML }
        return total / max(displayedDays.count, 1)
    }

    private var daysGoalMet: Int {
        displayedDays.filter { $0.totalML >= settings.dailyGoalML }.count
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    statsRow

                    VStack(alignment: .leading, spacing: 12) {
                        Text("Last \(dayCount) days")
                            .font(.headline)

                        Chart(displayedDays) { day in
                            BarMark(
                                x: .value("Day", day.date, unit: .day),
                                y: .value("mL", day.totalML)
                            )
                            .foregroundStyle(day.totalML >= settings.dailyGoalML ? Color.blue : Color.blue.opacity(0.45))
                            .cornerRadius(dayCount > freeDayCount ? 2 : 6)

                            RuleMark(y: .value("Goal", settings.dailyGoalML))
                                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                                .foregroundStyle(.secondary)
                        }
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
                        upsellBanner
                    }
                }
                .padding()
            }
            .navigationTitle("History")
            .sheet(isPresented: $showingPaywall) {
                PaywallView()
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
