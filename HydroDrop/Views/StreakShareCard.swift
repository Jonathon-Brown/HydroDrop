import SwiftUI

/// The image a streak gets shared as.
///
/// Sized and laid out for being rendered by `ImageRenderer` rather than for being put
/// on screen, so everything is in fixed points and nothing depends on the environment
/// it is rendered from. It carries the app name and the site, because a card that
/// travels without saying where it came from is just a picture of a droplet.
/// What the world version of the card is drawn from. When a card has one, the droplet
/// stands in its world and the card says how far the world has come.
struct WorldCardContent: Equatable {
    var state: WorldState
    var decorations: [WorldDecoration]
    var timeOfDay: WorldTimeOfDay

    var key: String {
        "\(state.goalDays)|\(Int(state.vitality * 100))|\(decorations.map(\.rawValue).joined(separator: ","))|\(timeOfDay.rawValue)"
    }
}

struct StreakShareCard: View {
    let streak: Int
    let skin: MascotSkin
    let milestone: StreakMilestone?
    let todayTotalML: Int
    let goalML: Int
    let system: MeasurementSystem
    var world: WorldCardContent?

    static let size = CGSize(width: 420, height: 540)

    private var headline: String {
        streak == 1 ? "1 day streak" : "\(streak) day streak"
    }

    var body: some View {
        if let world {
            worldCard(world)
        } else {
            classicCard
        }
    }

    /// The droplet at home. The scene is a still: a share card is a picture.
    private func worldCard(_ world: WorldCardContent) -> some View {
        ZStack(alignment: .bottom) {
            WorldSceneView(
                state: world.state,
                decorations: world.decorations,
                timeOfDay: world.timeOfDay,
                isAnimated: false
            )
            MascotView(progress: max(0.2, world.state.vitality), size: 96, skin: skin, isAnimated: false)
                .padding(.bottom, 92)

            // Shade behind the words, so they read over a bright noon sky and a dark pond alike.
            VStack(spacing: 0) {
                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                    .frame(height: 170)
                Spacer()
                LinearGradient(colors: [.clear, .black.opacity(0.5)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 90)
            }

            VStack(spacing: 6) {
                Text(world.state.stage.title)
                    .font(.system(size: 34, weight: .heavy, design: .rounded))
                Text("\(world.state.goalDays) goal \(world.state.goalDays == 1 ? "day" : "days")" + (streak > 0 ? "  ·  \(headline)" : ""))
                    .font(.system(size: 17, weight: .medium))
                    .opacity(0.9)
                Spacer()
                brandLine
            }
            .foregroundStyle(.white)
            .padding(.top, 30)
        }
        .frame(width: Self.size.width, height: Self.size.height)
    }

    private var brandLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "drop.fill")
                .font(.system(size: 16, weight: .bold))
            Text("HydroDrop")
                .font(.system(size: 19, weight: .bold, design: .rounded))
            Text("hydrodrop.us")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.bottom, 26)
    }

    private var classicCard: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 26)

            MascotView(progress: 1.1, size: 168, skin: skin, isAnimated: false)
                .frame(height: 228)

            VStack(spacing: 8) {
                if let milestone {
                    Label(milestone.title, systemImage: milestone.icon)
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 7)
                        .background(Capsule().fill(milestone.tint.opacity(0.95)))
                }

                Text(headline)
                    .font(.system(size: 42, weight: .heavy, design: .rounded))
                    .foregroundStyle(.white)

                Text("\(system.format(mL: todayTotalML)) of \(system.format(mL: goalML)) today")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(.white.opacity(0.85))
            }

            Spacer(minLength: 26)

            brandLine
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background(
            LinearGradient(
                colors: [
                    Color(red: 0.10, green: 0.42, blue: 0.85),
                    Color(red: 0.16, green: 0.62, blue: 0.92),
                    Color(red: 0.30, green: 0.78, blue: 0.94),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

/// Renders the card and offers it to the share sheet.
///
/// The render happens once, off the main render loop, and the button stays disabled
/// until it is ready rather than handing `ShareLink` a placeholder it would then share.
struct StreakShareButton: View {
    let streak: Int
    let skin: MascotSkin
    var milestone: StreakMilestone?
    let todayTotalML: Int
    let goalML: Int
    let system: MeasurementSystem
    var label: String = "Share streak"
    /// Set to share the world version of the card.
    var world: WorldCardContent?

    @State private var rendered: Image?

    var body: some View {
        Group {
            if let rendered {
                ShareLink(
                    item: rendered,
                    preview: SharePreview(shareTitle, image: rendered)
                ) {
                    Label(label, systemImage: "square.and.arrow.up")
                }
            } else {
                Label(label, systemImage: "square.and.arrow.up")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: renderKey) {
            rendered = await renderCard()
        }
    }

    private var shareTitle: String {
        if world != nil { return "My HydroDrop world" }
        return streak == 1 ? "My 1 day HydroDrop streak" : "My \(streak) day HydroDrop streak"
    }

    /// Everything the card draws from. A change to any of it means the cached image is
    /// stale and has to be drawn again.
    private var renderKey: String {
        "\(streak)|\(skin.rawValue)|\(milestone?.days ?? 0)|\(todayTotalML)|\(goalML)|\(system.rawValue)|\(world?.key ?? "")"
    }

    @MainActor
    private func renderCard() async -> Image? {
        let renderer = ImageRenderer(
            content: StreakShareCard(
                streak: streak,
                skin: skin,
                milestone: milestone,
                todayTotalML: todayTotalML,
                goalML: goalML,
                system: system,
                world: world
            )
        )
        renderer.scale = 3
        renderer.proposedSize = ProposedViewSize(StreakShareCard.size)
        guard let image = renderer.uiImage else {
            Diagnostics.log("could not render the streak share card")
            return nil
        }
        return Image(uiImage: image)
    }
}

#Preview {
    StreakShareCard(
        streak: 30,
        skin: .classic,
        milestone: .oneMonth,
        todayTotalML: 2_000,
        goalML: 2_000,
        system: .metric
    )
}
