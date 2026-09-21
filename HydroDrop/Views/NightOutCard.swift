import SwiftUI

/// Night Out on the Today screen: a quiet way in when it is off, and the tally with a
/// way out when it is on.
///
/// The tally is about water. It says how many waters are still to go and nothing about
/// whether the number of drinks is a lot or a little. There are no badges for any of
/// this, and none of it appears on anything that can be shared.
struct NightOutSection: View {
    @ObservedObject var nightOut: NightOutCoordinator
    /// Everything logged, newest first or not. Only what falls inside the Night Out counts.
    let entries: [WaterEntry]

    var body: some View {
        // Read through a timeline so a Night Out that runs out while the screen is open
        // closes by itself rather than sitting there until the next tap.
        TimelineView(.periodic(from: .now, by: 60)) { context in
            if let startedAt = nightOut.startedAt, nightOut.isActive(now: context.date) {
                active(tally: NightOut.tally(of: entries, since: startedAt))
            } else {
                Button {
                    nightOut.start()
                } label: {
                    Label("Night Out", systemImage: "moon.stars.fill")
                        .font(.subheadline.weight(.medium))
                }
                .buttonStyle(.borderless)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityHint("Reminds you to drink water between drinks for the next six hours")
            }
        }
    }

    private func active(tally: NightOut.Tally) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "moon.stars.fill")
                .font(.title3)
                .foregroundStyle(.indigo)
            VStack(alignment: .leading, spacing: 6) {
                Text("Night Out")
                    .font(.subheadline.weight(.semibold))
                Text(NightOut.line(for: tally))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("End") { nightOut.end() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .accessibilityLabel("End Night Out")
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
        .accessibilityElement(children: .contain)
    }
}

/// The same switch, for the add-drink sheet, so it can be turned on at the moment the
/// first drink of the evening is being logged.
struct NightOutToggleRow: View {
    @ObservedObject var nightOut: NightOutCoordinator

    var body: some View {
        Toggle(isOn: Binding(
            get: { nightOut.isActive() },
            set: { $0 ? nightOut.start() : nightOut.end() }
        )) {
            Label("Night Out", systemImage: "moon.stars.fill")
        }
    }
}

/// Today's caffeine, for subscribers who asked to see it, with a gentle note when the
/// last of it came after their cutoff. A note, not an alert: it is information the
/// person asked for, not a telling off.
struct CaffeineTodayLine: View {
    let entries: [WaterEntry]
    let cutoffMinutes: Int
    let wakingStartMinutes: Int

    private var cutoffLabel: String {
        let date = Calendar.current.date(bySettingHour: cutoffMinutes / 60, minute: cutoffMinutes % 60, second: 0, of: Date()) ?? Date()
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        let now = Date()
        let total = Int(CaffeineCutoff.totalMg(of: entries, on: now).rounded())
        let late = CaffeineCutoff.lateDrink(
            in: entries,
            on: now,
            cutoffMinutes: cutoffMinutes,
            wakingStartMinutes: wakingStartMinutes
        )
        VStack(spacing: 2) {
            Label("\(total) mg caffeine today", systemImage: "bolt.heart")
                .font(.caption)
                .foregroundStyle(.secondary)
            if late != nil {
                Text("Your last one was after your \(cutoffLabel) cutoff.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
