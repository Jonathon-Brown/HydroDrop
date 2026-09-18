import SwiftUI
import WidgetKit

/// The Lock Screen widgets: a progress ring and a line of text.
///
/// Kept separate from the Home Screen widget so each appears in the gallery under a
/// name that describes what it is, rather than one entry that behaves differently
/// depending on where it is placed. Neither carries a log button: accessory widgets
/// are a glance, and the Lock Screen already has the Action Button for logging.
struct HydrationAccessoryWidget: Widget {
    static let kind = "HydrationAccessoryWidget"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: HydrationProvider()) { entry in
            HydrationAccessoryView(snapshot: entry.snapshot)
                .containerBackground(.clear, for: .widget)
        }
        .configurationDisplayName("Hydration Progress")
        .description("Today's progress towards your goal, on the Lock Screen.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular])
    }
}

struct HydrationAccessoryView: View {
    @Environment(\.widgetFamily) private var family
    let snapshot: HydrationSnapshot

    private var system: MeasurementSystem { snapshot.measurementSystem }
    private var clampedProgress: Double { min(max(snapshot.progress, 0), 1) }
    private var percentLabel: String { "\(Int((clampedProgress * 100).rounded()))%" }

    var body: some View {
        switch family {
        case .accessoryRectangular: rectangular
        default: circular
        }
    }

    private var circular: some View {
        Gauge(value: clampedProgress) {
            Image(systemName: "drop.fill")
        } currentValueLabel: {
            Text(percentLabel)
                .minimumScaleFactor(0.6)
        }
        .gaugeStyle(.accessoryCircularCapacity)
        .accessibilityLabel("Hydration")
        .accessibilityValue("\(percentLabel) of your daily goal")
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label {
                Text(system.format(mL: snapshot.todayTotalML))
                    .font(.headline)
            } icon: {
                Image(systemName: "drop.fill")
            }
            .lineLimit(1)

            Text("of \(system.format(mL: snapshot.dailyGoalML))")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Gauge(value: clampedProgress) { EmptyView() }
                .gaugeStyle(.accessoryLinearCapacity)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Hydration")
        .accessibilityValue("\(system.format(mL: snapshot.todayTotalML)) of \(system.format(mL: snapshot.dailyGoalML)), \(percentLabel)")
    }
}
