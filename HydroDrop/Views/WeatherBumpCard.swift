import SwiftUI

/// Offers extra water on a hot day, for today only.
///
/// A suggestion with two answers and no default. Nothing here changes the saved goal:
/// accepting raises today's target and tomorrow it is gone, which is what makes it safe
/// to offer at all.
struct WeatherBumpCard: View {
    let bumpML: Int
    let system: MeasurementSystem
    let onAccept: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "sun.max.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 8) {
                Text("It is hot out there")
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

    var body: some View {
        Label("Includes \(system.format(mL: bumpML)) for the heat today", systemImage: "sun.max.fill")
            .font(.caption)
            .foregroundStyle(.secondary)
            .accessibilityLabel("Today's goal includes \(system.format(mL: bumpML)) extra for the heat")
    }
}

#Preview {
    VStack(spacing: 16) {
        WeatherBumpCard(bumpML: 500, system: .metric, onAccept: {}, onDismiss: {})
        WeatherBumpBadge(bumpML: 500, system: .metric)
    }
    .padding()
}
