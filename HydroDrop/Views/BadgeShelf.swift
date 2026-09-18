import SwiftUI

/// Every milestone, earned or not, as a row of badges.
///
/// The unearned ones are shown rather than hidden: knowing that 100 days exists is
/// most of what makes reaching 30 feel like progress. They are drawn quietly enough
/// not to read as a list of failures.
struct BadgeShelf: View {
    let earnedDays: Set<Int>
    let currentStreak: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Milestones")
                    .font(.headline)
                Spacer()
                Text("\(earnedDays.count) of \(StreakMilestone.allCases.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(StreakMilestone.allCases) { milestone in
                        badge(milestone)
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 4)
            }
        }
    }

    private func badge(_ milestone: StreakMilestone) -> some View {
        let isEarned = earnedDays.contains(milestone.days)
        return VStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(isEarned ? milestone.tint.opacity(0.18) : Color(.tertiarySystemFill))
                    .frame(width: 54, height: 54)
                Image(systemName: isEarned ? milestone.icon : "lock.fill")
                    .font(isEarned ? .title3 : .footnote)
                    .foregroundStyle(isEarned ? milestone.tint : .secondary)
            }
            Text("\(milestone.days)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isEarned ? .primary : .secondary)
            Text(milestone.days == 1 ? "day" : "days")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(width: 62)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(milestone.title)
        .accessibilityValue(accessibilityValue(for: milestone, isEarned: isEarned))
    }

    private func accessibilityValue(for milestone: StreakMilestone, isEarned: Bool) -> String {
        if isEarned { return "Earned" }
        let remaining = max(0, milestone.days - currentStreak)
        return remaining > 0 ? "\(remaining) more days" : "Not earned yet"
    }
}

#Preview {
    BadgeShelf(earnedDays: [3, 7, 14], currentStreak: 18)
        .padding()
}
