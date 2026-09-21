import Charts
import SwiftUI

/// Insights, in History: what hitting the goal lines up with in the person's own
/// Health data. One card for each thing compared.
///
/// Nothing is read until a subscriber taps Connect and has seen what will be read and
/// why. What is read is held by this view and nowhere else, and is gone when it is.
struct InsightsSection: View {
    /// Hydrating mL per day from the log, as `StreakCalculator.totalsByDay` groups it.
    let totalsByDay: [String: Int]
    let goalML: Int

    @ObservedObject private var store = StoreManager.shared
    @State private var isConnected = HealthInsightsReader.isConnected
    @State private var results: [InsightResult]?
    @State private var showingPrimer = false
    @State private var paywallSource: PaywallSource?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Insights")
                    .font(.headline)
                Spacer()
                if !store.isSubscribed {
                    Image(systemName: "lock.fill")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if let preview = Self.previewResults {
                ForEach(preview, id: \.metric) { result in
                    InsightCard(result: result)
                }
                Text(InsightsEngine.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !store.isSubscribed {
                locked
            } else if !HealthInsightsReader.isAvailable {
                note(InsightsCopy.unavailable)
            } else if !isConnected {
                connectCard
            } else if let results {
                ForEach(results, id: \.metric) { result in
                    InsightCard(result: result)
                }
                Text(InsightsEngine.footer)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .frame(maxWidth: .infinity, minHeight: 80)
            }
        }
        .task(id: loadKey) { await load() }
        .sheet(isPresented: $showingPrimer) {
            InsightsPrimerSheet {
                showingPrimer = false
                Task {
                    isConnected = await HealthInsightsReader.shared.connect()
                    await load()
                }
            }
        }
        .sheet(item: $paywallSource) { source in
            PaywallView(source: source)
        }
    }

    /// `-InsightsPreview` draws one finding, one "no clear difference" and one "keep
    /// logging", for looking at the cards where there is no Health data to read, which is
    /// every simulator. Compiled out of Release.
    private static var previewResults: [InsightResult]? {
        #if DEBUG
        guard ProcessInfo.processInfo.arguments.contains("-InsightsPreview") else { return nil }
        return [
            .finding(InsightFinding(metric: .sleep, metMean: 452, missedMean: 428, metDays: 19, missedDays: 14)),
            .noClearPattern(metric: .restingHeartRate),
            .needsMoreData(metric: .activeEnergy, goalDaysNeeded: 3, otherDaysNeeded: 0),
        ]
        #else
        return nil
        #endif
    }

    /// Everything a reload depends on. The log changing, the goal changing, a purchase,
    /// and Connect being tapped.
    private var loadKey: String {
        "\(store.isSubscribed)|\(isConnected)|\(goalML)|\(totalsByDay.count)|\(totalsByDay.values.reduce(0, +))"
    }

    private func load() async {
        guard store.isSubscribed, isConnected, HealthInsightsReader.isAvailable else { return }
        let health = await HealthInsightsReader.shared.dailyHealth()
        let met = Set(totalsByDay.filter { goalML > 0 && $0.value >= goalML }.keys)
        results = InsightsEngine.analyse(
            metDays: met,
            firstLoggedDay: totalsByDay.keys.min(),
            health: health,
            today: DayKey.key(for: Date())
        )
    }

    private var locked: some View {
        Button {
            paywallSource = .lockedInsights
        } label: {
            card {
                Label(InsightsCopy.cardTitle, systemImage: "chart.bar.xaxis")
                    .font(.subheadline.weight(.semibold))
                Text(InsightsCopy.lockedBody)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }

    private var connectCard: some View {
        card {
            Label(InsightsCopy.cardTitle, systemImage: "chart.bar.xaxis")
                .font(.subheadline.weight(.semibold))
            Text(InsightsCopy.connectBody)
                .font(.caption)
                .foregroundStyle(.secondary)
            Button("Connect") { showingPrimer = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func card<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8, content: content)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

/// One thing compared: the sentence, and the two averages it came from, side by side.
private struct InsightCard: View {
    let result: InsightResult

    private var metric: InsightMetric { result.metric }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(metric.title, systemImage: metric.icon)
                .font(.subheadline.weight(.semibold))

            if case .finding(let finding) = result {
                Text(finding.sentence)
                    .font(.subheadline)
                    .fixedSize(horizontal: false, vertical: true)
                chart(finding)
                Text("\(metric.alignmentNote). \(finding.metDays) goal days and \(finding.missedDays) other days, from the last \(InsightsEngine.windowDays).")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = result.waitingMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }

    /// Two bars from zero. Starting the axis anywhere else would make a small difference
    /// look like a big one, and the numbers are printed on the bars for anyone who wants
    /// to see exactly how small it is. Two plain colours, neither of them the app's own
    /// blue: the chart compares two kinds of day and does not mark one as the good one.
    private func chart(_ finding: InsightFinding) -> some View {
        let bars: [(label: String, value: Double, color: Color)] = [
            ("Goal met", finding.metMean, .teal),
            ("Goal not met", finding.missedMean, .indigo),
        ]
        return Chart {
            ForEach(bars, id: \.label) { bar in
                BarMark(x: .value("Days", bar.label), y: .value(metric.title, bar.value), width: .ratio(0.5))
                    .foregroundStyle(bar.color)
                    .cornerRadius(6)
                    .annotation(position: .top) {
                        Text(metric.format(bar.value))
                            .font(.caption2.weight(.semibold))
                    }
            }
        }
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...(max(finding.metMean, finding.missedMean) * 1.2))
        .frame(height: 130)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(metric.title) comparison")
        .accessibilityValue("Goal met: \(metric.format(finding.metMean)). Goal not met: \(metric.format(finding.missedMean)).")
    }
}

/// What is said before the system's Health sheet appears: exactly what will be read,
/// what it is for, and that saying no changes nothing else.
struct InsightsPrimerSheet: View {
    let onContinue: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Image(systemName: "chart.bar.xaxis")
                        .font(.system(size: 44))
                        .foregroundStyle(.blue)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)

                    Text(InsightsCopy.primerIntro)
                        .font(.subheadline)

                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(Array(zip(InsightsCopy.primerReads, ["bed.double.fill", "heart.fill", "flame.fill", "figure.run"])), id: \.0) { line, icon in
                            Label(line, systemImage: icon)
                        }
                    }
                    .font(.subheadline)

                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(zip(InsightsCopy.primerPromises, ["lock.fill", "drop.fill", "hand.raised.fill", "checkmark.circle.fill", "nosign"])), id: \.0) { line, icon in
                            Label(line, systemImage: icon)
                        }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                    Text(InsightsEngine.footer)
                        .font(.footnote)
                        .foregroundStyle(.secondary)

                    Button(action: onContinue) {
                        Text("Continue").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                .padding()
            }
            .navigationTitle("Connect Apple Health")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Not now") { dismiss() }
                }
            }
        }
    }
}
