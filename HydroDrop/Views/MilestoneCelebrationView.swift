import SwiftUI

/// Shown once, the moment a streak reaches a milestone.
///
/// Deliberately a dead end: it congratulates, offers to share, and closes. There is
/// nothing to upsell here and nothing to sign up for, because interrupting someone to
/// sell to them at the moment they succeeded is how a celebration turns into an advert.
///
/// It marks two kinds of moment: a streak reaching a milestone, and the droplet's world
/// growing a new stage. They often land on the same day, three goal days being a three
/// day streak as well, and when they do they are one celebration, not two in a row.
struct MilestoneCelebrationView: View {
    /// What is being marked. At least one of the two is always there.
    struct Occasion: Identifiable, Equatable {
        var milestone: StreakMilestone?
        var worldStage: WorldStage?

        var id: String { "\(milestone?.days ?? 0)|\(worldStage?.goalDays ?? 0)" }
    }

    let occasion: Occasion
    /// The world as it now stands, for the share card when the world is the news.
    var world: WorldCardContent?
    let streak: Int
    let skin: MascotSkin
    let todayTotalML: Int
    let goalML: Int
    let system: MeasurementSystem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    private var milestone: StreakMilestone? { occasion.milestone }
    private var worldStage: WorldStage? { occasion.worldStage }

    private var badgeTitle: String { milestone?.title ?? "Your world grew" }
    private var badgeIcon: String { milestone?.icon ?? worldStage?.icon ?? "leaf.fill" }
    private var badgeTint: Color { milestone?.tint ?? .green }
    private var blurb: String { milestone?.blurb ?? worldStage?.blurb ?? "" }

    private var headline: String {
        if milestone == nil, let worldStage { return worldStage.title }
        return streak == 1 ? "1 day streak" : "\(streak) day streak"
    }

    var body: some View {
        ZStack {
            ScrollView {
                VStack(spacing: 20) {
                    Spacer(minLength: 24)

                    MascotView(progress: 1.15, size: 140, skin: skin)
                        .scaleEffect(hasAppeared || reduceMotion ? 1 : 0.6)
                        .animation(
                            reduceMotion ? nil : .spring(response: 0.55, dampingFraction: 0.55),
                            value: hasAppeared
                        )

                    Label(badgeTitle, systemImage: badgeIcon)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(badgeTint))

                    Text(headline)
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)

                    Text(blurb)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    // Both on the same day: the streak leads, and the world gets its line.
                    if milestone != nil, let worldStage {
                        Label("Your world grew: \(worldStage.title)", systemImage: worldStage.icon)
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.green)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }

                    Spacer(minLength: 16)

                    VStack(spacing: 12) {
                        StreakShareButton(
                            streak: streak,
                            skin: skin,
                            milestone: milestone,
                            todayTotalML: todayTotalML,
                            goalML: goalML,
                            system: system,
                            label: "Share this",
                            // The world's own card when the world is the only news.
                            world: milestone == nil ? world : nil
                        )
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        Button("Done") { dismiss() }
                            .font(.subheadline.weight(.medium))
                    }
                    .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity)
            }

            ConfettiView()
        }
        .onAppear { hasAppeared = true }
        .accessibilityAction(named: "Close") { dismiss() }
    }
}

#Preview {
    MilestoneCelebrationView(
        occasion: .init(milestone: .oneMonth, worldStage: .flowers),
        streak: 30,
        skin: .classic,
        todayTotalML: 2_000,
        goalML: 2_000,
        system: .metric
    )
}
