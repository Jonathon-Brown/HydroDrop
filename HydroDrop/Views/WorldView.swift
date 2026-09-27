import SwiftUI

/// The droplet's world, up close: what has grown, what comes next, and what to put in it.
///
/// The streak milestones live here too, on the same shelf History shows, because they
/// are the same story told two ways: the streak is what is happening now, and the world
/// is everything that has happened.
struct WorldView: View {
    let state: WorldState
    let streak: Int
    let todayTotalML: Int

    @EnvironmentObject private var settings: AppSettings
    @ObservedObject private var store = StoreManager.shared
    @State private var paywallSource: PaywallSource?

    private var timeOfDay: WorldTimeOfDay { WorldTimeOfDay(date: Date()) }
    private var weather: WorldWeather? { WorldWeather.current(isFeatureActive: settings.weatherGoalActive) }

    private var cardContent: WorldCardContent {
        WorldCardContent(state: state, decorations: settings.activeWorldDecorations, timeOfDay: timeOfDay)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                ZStack(alignment: .bottom) {
                    WorldSceneView(
                        state: state,
                        decorations: settings.activeWorldDecorations,
                        timeOfDay: timeOfDay,
                        weather: weather
                    )
                    MascotView(progress: max(0.2, state.vitality), size: 84, skin: settings.activeMascotSkin)
                        .padding(.bottom, 58)
                        .accessibilityHidden(true)
                }
                .frame(height: 340)
                .clipShape(RoundedRectangle(cornerRadius: 24))
                // Under cloud, rain or snow the painter draws no sun, moon or stars, so the
                // corner the chip covers holds only cloud and whatever is falling, and the
                // leading side stays clear of where the sun and moon go should a clear sky
                // ever carry the mark. After the clip, so neither the chip nor its tap area
                // is cut, and an overlay, so nothing below moves when a reading arrives.
                .overlay(alignment: .topLeading) {
                    if weather?.isOvercast == true {
                        // Darker than the Today chip: this corner is often pale cloud, and
                        // plain frost over it left the white mark near 3:1 by day. This much
                        // black kept it at 5.2:1 or better in cloud, rain and snow.
                        WorldWeatherAttribution(shade: 0.3)
                            .padding(.leading, 12)
                            .padding(.top, 6)
                    }
                }

                summary
                nextUnlock
                grownSoFar
                decorations

                BadgeShelf(earnedDays: Set(settings.celebratedMilestones), currentStreak: streak)

                StreakShareButton(
                    streak: streak,
                    skin: settings.activeMascotSkin,
                    todayTotalML: todayTotalML,
                    goalML: settings.dailyGoalML,
                    system: settings.measurementSystem,
                    label: "Share my world",
                    world: cardContent
                )
                .buttonStyle(.bordered)
                .frame(maxWidth: .infinity)
            }
            .padding()
        }
        .navigationTitle("Your World")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $paywallSource) { source in
            PaywallView(source: source)
        }
    }

    private var summary: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(state.stage.title)
                .font(.title2.weight(.bold))
            Text("\(state.goalDays) goal \(state.goalDays == 1 ? "day" : "days") so far. \(state.mood.words).")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if state.mood == .thirsty || state.mood == .wilting {
                Text("A few goal days bring the colour back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var nextUnlock: some View {
        if let next = state.stage.next, let days = state.daysToNext {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Label("Next: \(next.title)", systemImage: next.icon)
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Text("\(days) more \(days == 1 ? "day" : "days")")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ProgressView(value: state.progressToNext)
                    .tint(.green)
            }
            .padding()
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(.secondarySystemBackground)))
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Next: \(next.title)")
            .accessibilityValue("\(days) more goal \(days == 1 ? "day" : "days"), at \(next.goalDays)")
        } else {
            Label("Everything has grown. It is all yours to look after now.", systemImage: "checkmark.seal.fill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var grownSoFar: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What grows here")
                .font(.headline)
            ForEach(WorldStage.allCases.filter { $0 != .pond }) { stage in
                let isHere = state.stage >= stage
                HStack(spacing: 12) {
                    Image(systemName: isHere ? stage.icon : "lock.fill")
                        .frame(width: 26)
                        .foregroundStyle(isHere ? Color.green : .secondary)
                    Text(stage.title)
                        .foregroundStyle(isHere ? .primary : .secondary)
                    Spacer()
                    Text("\(stage.goalDays) days")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(stage.title)
                .accessibilityValue(isHere ? "Grown" : "At \(stage.goalDays) goal days")
            }
        }
    }

    private var decorations: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Decorations")
                .font(.headline)
            Text("Just for looks. Put in as many as you like.")
                .font(.caption)
                .foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                ForEach(WorldDecoration.allCases) { decoration in
                    decorationButton(decoration)
                }
            }
        }
    }

    private func decorationButton(_ decoration: WorldDecoration) -> some View {
        let isLocked = decoration.requiresPlus && !store.isSubscribed
        let isOn = !isLocked && settings.worldDecorations.contains(decoration.rawValue)
        return Button {
            if isLocked {
                paywallSource = .lockedWorldDecoration
            } else {
                settings.toggle(decoration)
            }
        } label: {
            VStack(spacing: 6) {
                Image(systemName: isLocked ? "lock.fill" : decoration.icon)
                    .font(.title3)
                    .foregroundStyle(isOn ? Color.white : (isLocked ? .secondary : .accentColor))
                Text(decoration.label)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isOn ? Color.white : .primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 64)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 14).fill(isOn ? Color.accentColor : Color(.secondarySystemBackground)))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(decoration.label)
        .accessibilityValue(isLocked ? "Part of HydroDrop Plus" : (isOn ? "In your world" : "Not in your world"))
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
