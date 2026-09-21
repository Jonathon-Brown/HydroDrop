import SwiftUI

/// Offers extra water on a hot day, for today only.
///
/// A suggestion with two answers and no default. Nothing here changes the saved goal:
/// accepting raises today's target and tomorrow it is gone, which is what makes it safe
/// to offer at all.
struct WeatherBumpCard: View {
    let bumpML: Int
    let system: MeasurementSystem
    /// Why the extra is being suggested. One card covers every reason there is today,
    /// so a hot morning after a Night Out is one question rather than two.
    var sources: [TodayBump.Source] = [.heat]
    let onAccept: () -> Void
    let onDismiss: () -> Void

    private var isOnlyHeat: Bool { sources == [.heat] }

    private var title: String {
        if isOnlyHeat { return "It is hot out there" }
        if sources == [.workout] { return InsightsCopy.workoutCardTitle }
        if sources == [.heat, .nightOut] { return "A hot day after a late night" }
        return "A little extra today?"
    }

    private var icon: String {
        if isOnlyHeat { return "sun.max.fill" }
        return sources == [.workout] ? "figure.run" : "drop.circle.fill"
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(isOnlyHeat ? .orange : (sources == [.workout] ? .green : .blue))

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                Text("Add \(system.format(mL: bumpML)) to today's goal? Your usual goal and your streak stay exactly as they are.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button("Add for today", action: onAccept)
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    Button("No thanks", action: onDismiss)
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
    }
}

/// Shown once a bump has been taken, so the raised number on screen is explained.
struct WeatherBumpBadge: View {
    let bumpML: Int
    let system: MeasurementSystem
    /// False once anything other than the heat is part of today's extra.
    var isOnlyHeat = true

    var body: some View {
        Label(
            isOnlyHeat
                ? "Includes \(system.format(mL: bumpML)) for the heat today"
                : "Includes \(system.format(mL: bumpML)) extra, for today only",
            systemImage: isOnlyHeat ? "sun.max.fill" : "drop.circle.fill"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .accessibilityLabel("Today's goal includes \(system.format(mL: bumpML)) extra, for today only")
    }
}

#Preview {
    VStack(spacing: 16) {
        WeatherBumpCard(bumpML: 500, system: .metric, onAccept: {}, onDismiss: {})
        WeatherBumpBadge(bumpML: 500, system: .metric)
    }
    .padding()
}
