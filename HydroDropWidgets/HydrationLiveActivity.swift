import ActivityKit
import SwiftUI
import WidgetKit

/// Today's progress on the Lock Screen and in the Dynamic Island.
///
/// The mascot carries the mood on the lock screen, where there is room for it. The
/// Dynamic Island's compact forms get a droplet and a number instead: a face drawn at
/// twenty points is a smudge, and the point of the compact view is to be readable at a
/// glance rather than charming.
struct HydrationLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HydrationActivityAttributes.self) { context in
            lockScreen(context.state)
                .activityBackgroundTint(Color.black.opacity(0.35))
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    MascotView(
                        progress: context.state.progress,
                        size: 34,
                        skin: context.state.mascotSkin,
                        isAnimated: false
                    )
                    .frame(width: 48, height: 52)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    if context.state.streak > 0 {
                        Label("\(context.state.streak)", systemImage: "flame.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.orange)
                            .accessibilityLabel("\(context.state.streak) day streak")
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(summary(context.state))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        ProgressBar(progress: context.state.progress)
                    }
                }
            } compactLeading: {
                Image(systemName: "drop.fill")
                    .foregroundStyle(.cyan)
            } compactTrailing: {
                Text(percent(context.state))
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
            } minimal: {
                Image(systemName: "drop.fill")
                    .foregroundStyle(.cyan)
            }
            .keylineTint(.cyan)
        }
    }

    private func lockScreen(_ state: HydrationActivityAttributes.ContentState) -> some View {
        HStack(spacing: 14) {
            MascotView(
                progress: state.progress,
                size: 44,
                skin: state.mascotSkin,
                isAnimated: false
            )
            .frame(width: 60, height: 66)

            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(state.measurementSystem.format(mL: state.todayTotalML))
                        .font(.headline)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Spacer(minLength: 6)
                    Text(percent(state))
                        .font(.subheadline.weight(.semibold))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                ProgressBar(progress: state.progress)
                Text(summary(state))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func percent(_ state: HydrationActivityAttributes.ContentState) -> String {
        "\(Int((state.clampedProgress * 100).rounded()))%"
    }

    private func summary(_ state: HydrationActivityAttributes.ContentState) -> String {
        let system = state.measurementSystem
        guard state.remainingML > 0 else {
            return "Goal reached. Nicely done."
        }
        return "\(system.format(mL: state.remainingML)) to go, of \(system.format(mL: state.goalML))"
    }
}
