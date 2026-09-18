import SwiftUI
import SwiftData

/// The week just gone, in four numbers and one observation.
struct WeeklyRecapView: View {
    @EnvironmentObject private var settings: AppSettings
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \WaterEntry.timestamp, order: .reverse) private var allEntries: [WaterEntry]

    private var recap: WeeklyRecap {
        WeeklyRecap.make(
            entries: allEntries,
            goalML: settings.dailyGoalML,
            windowStartMinutes: settings.quietStartMinutes,
            windowEndMinutes: settings.quietEndMinutes
        )
    }

    private var system: MeasurementSystem { settings.measurementSystem }

    var body: some View {
        NavigationStack {
            ScrollView {
                let recap = self.recap
                VStack(spacing: 20) {
                    if recap.hasAnyIntake {
                        statCards(recap)
                        weekChart(recap)
                        if let slip = slipSentence(recap) {
                            observation(slip)
                        }
                    } else {
                        emptyState
                    }
                }
                .padding()
            }
            .navigationTitle("Your week")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func statCards(_ recap: WeeklyRecap) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                card(
                    title: "Daily average",
                    value: system.formattedNumber(mL: recap.averageML),
                    unit: system.unitLabel,
                    icon: "chart.line.uptrend.xyaxis",
                    tint: .blue
                )
                card(
                    title: "Goal met",
                    value: "\(recap.daysGoalMet)/7",
                    unit: recap.daysGoalMet == 1 ? "day" : "days",
                    icon: "checkmark.seal.fill",
                    tint: .green
                )
            }
            if let best = recap.bestDay {
                card(
                    title: "Best day",
                    value: system.formattedNumber(mL: best.totalML),
                    unit: "\(system.unitLabel) on \(weekdayName(best.dayKey))",
                    icon: "trophy.fill",
                    tint: .orange
                )
                .frame(maxWidth: .infinity)
            }
        }
    }

    private func card(title: String, value: String, unit: String, icon: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(tint)
            Text(value)
                .font(.title2.weight(.bold))
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text("\(title) · \(unit)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    /// A plain bar per day. Deliberately not a Swift Charts chart: History already has
    /// one, and this screen is a summary rather than a second place to study the data.
    private func weekChart(_ recap: WeeklyRecap) -> some View {
        let peak = max(recap.goalML, recap.days.map(\.totalML).max() ?? 1)
        return VStack(alignment: .leading, spacing: 10) {
            Text("Day by day")
                .font(.headline)
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(recap.days) { day in
                    VStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(day.totalML >= recap.goalML ? Color.blue : Color.blue.opacity(0.4))
                            .frame(height: max(4, 110 * CGFloat(day.totalML) / CGFloat(max(peak, 1))))
                        Text(weekdayInitial(day.dayKey))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(weekdayName(day.dayKey))
                    .accessibilityValue(system.format(mL: day.totalML))
                }
            }
            .frame(height: 132, alignment: .bottom)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private func observation(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
            Text(text)
                .font(.subheadline)
            Spacer(minLength: 0)
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            MascotView(progress: 0, size: 110, skin: settings.activeMascotSkin)
            Text("Nothing logged this week")
                .font(.headline)
            Text("Log a few drinks and your recap will have something to say.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 40)
    }

    private func slipSentence(_ recap: WeeklyRecap) -> String? {
        guard let hour = recap.slipHour else { return nil }
        return "You tend to fall behind around \(hourLabel(hour)). A glass before then usually sets the rest of the day up."
    }

    private func hourLabel(_ hour: Int) -> String {
        MinuteOfDay.label(hour * 60)
    }

    private func weekdayName(_ dayKey: String) -> String {
        guard let date = DayKey.date(from: dayKey) else { return dayKey }
        return date.formatted(.dateTime.weekday(.wide))
    }

    private func weekdayInitial(_ dayKey: String) -> String {
        guard let date = DayKey.date(from: dayKey) else { return "" }
        return date.formatted(.dateTime.weekday(.narrow))
    }
}

#Preview {
    WeeklyRecapView()
        .environmentObject(AppSettings.shared)
        .modelContainer(for: WaterEntry.self, inMemory: true)
}
