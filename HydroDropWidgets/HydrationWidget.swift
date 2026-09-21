import AppIntents
import SwiftUI
import WidgetKit

/// The Home Screen widget: the mascot's mood, today's progress, and a button that
/// logs a drink without leaving the Home Screen.
struct HydrationWidget: Widget {
    static let kind = "HydrationWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HydrationProvider()) { entry in
            HydrationWidgetView(snapshot: entry.snapshot)
                .containerBackground(.fill.tertiary, for: .widget)
        }
        .configurationDisplayName("Hydration")
        .description("Your droplet, today's progress, and one tap to log a drink. Included with HydroDrop+.")
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

struct HydrationWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: HydrationSnapshot

    private var system: MeasurementSystem { snapshot.measurementSystem }

    var body: some View {
        if snapshot.isPlusActive {
            switch family {
            case .systemMedium: medium
            default: small
            }
        } else {
            locked
        }
    }

    // MARK: Locked

    /// What a non-subscriber sees. No progress and no log button: the whole widget is
    /// the HydroDrop+ feature, not just the button. Tapping it opens the app, which is
    /// where the upgrade lives.
    private var locked: some View {
        VStack(spacing: 6) {
            MascotView(
                progress: 0.5,
                size: family == .systemMedium ? 50 : 46,
                skin: .classic,
                isAnimated: false
            )
            .frame(height: family == .systemMedium ? 68 : 62)

            Label("HydroDrop+", systemImage: "lock.fill")
                .font(.caption.weight(.bold))
                .lineLimit(1)

            Text(family == .systemMedium
                 ? "Widgets are part of HydroDrop+. Open the app to upgrade."
                 : "Open the app to unlock widgets.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .minimumScaleFactor(0.8)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("HydroDrop widgets are part of HydroDrop+. Open the app to upgrade.")
    }

    // MARK: Small

    private var small: some View {
        VStack(spacing: 6) {
            MascotView(
                progress: snapshot.progress,
                size: 54,
                skin: snapshot.mascotSkin,
                isAnimated: false
            )
            .frame(height: 74)

            Text(system.format(mL: snapshot.todayTotalML))
                .font(.headline.weight(.bold))
                .minimumScaleFactor(0.7)
                .lineLimit(1)

            ProgressBar(progress: snapshot.progress)

            if let first = snapshot.quickAddPresetsML.first, snapshot.canLogFromExtensions {
                quickAddButton(amountML: first, compact: true)
            } else {
                Text("of \(system.format(mL: snapshot.dailyGoalML))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    // MARK: Medium

    private var medium: some View {
        HStack(spacing: 14) {
            VStack(spacing: 2) {
                MascotView(
                    progress: snapshot.progress,
                    size: 60,
                    skin: snapshot.mascotSkin,
                    isAnimated: false
                )
                .frame(height: 82)
                if snapshot.streak > 0 {
                    Label("\(snapshot.streak)", systemImage: "flame.fill")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .accessibilityLabel("\(snapshot.streak) day streak")
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(system.format(mL: snapshot.todayTotalML))
                        .font(.title2.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("of \(system.format(mL: snapshot.dailyGoalML)) goal")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                ProgressBar(progress: snapshot.progress)

                if snapshot.canLogFromExtensions {
                    HStack(spacing: 6) {
                        ForEach(Array(snapshot.quickAddPresetsML.prefix(3).enumerated()), id: \.offset) { _, amount in
                            quickAddButton(amountML: amount, compact: false)
                        }
                    }
                } else {
                    Text("Open HydroDrop to finish setting up.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: Pieces

    private func quickAddButton(amountML: Int, compact: Bool) -> some View {
        Button(intent: LogWaterIntent(amountML: amountML)) {
            HStack(spacing: 3) {
                Image(systemName: "plus")
                    .font(.caption2.weight(.bold))
                Text(system.formattedNumber(mL: amountML))
                    .font(.caption2.weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: compact ? .infinity : nil)
            .padding(.vertical, 5)
            .padding(.horizontal, compact ? 4 : 8)
        }
        .buttonStyle(.bordered)
        .tint(.blue)
        .accessibilityLabel("Log \(system.format(mL: amountML))")
    }
}

/// A flat capsule bar. Deliberately not the system `ProgressView`, whose tint and
/// height both change with the widget's rendering mode.
struct ProgressBar: View {
    let progress: Double

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.blue, .cyan],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * min(max(progress, 0), 1))
            }
        }
        .frame(height: 7)
        .accessibilityLabel("Progress")
        .accessibilityValue("\(Int((min(max(progress, 0), 1) * 100).rounded())) percent")
    }
}
