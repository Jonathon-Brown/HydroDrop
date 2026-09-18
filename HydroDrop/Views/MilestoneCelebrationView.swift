import SwiftUI

/// Shown once, the moment a streak reaches a milestone.
///
/// Deliberately a dead end: it congratulates, offers to share, and closes. There is
/// nothing to upsell here and nothing to sign up for, because interrupting someone to
/// sell to them at the moment they succeeded is how a celebration turns into an advert.
struct MilestoneCelebrationView: View {
    let milestone: StreakMilestone
    let streak: Int
    let skin: MascotSkin
    let todayTotalML: Int
    let goalML: Int
    let system: MeasurementSystem

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

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

                    Label(milestone.title, systemImage: milestone.icon)
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Capsule().fill(milestone.tint))

                    Text(streak == 1 ? "1 day streak" : "\(streak) day streak")
                        .font(.system(size: 38, weight: .heavy, design: .rounded))
                        .multilineTextAlignment(.center)

                    Text(milestone.blurb)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)

                    Spacer(minLength: 16)

                    VStack(spacing: 12) {
                        StreakShareButton(
                            streak: streak,
                            skin: skin,
                            milestone: milestone,
                            todayTotalML: todayTotalML,
                            goalML: goalML,
                            system: system,
                            label: "Share this"
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
        milestone: .oneMonth,
        streak: 30,
        skin: .classic,
        todayTotalML: 2_000,
        goalML: 2_000,
        system: .metric
    )
}
