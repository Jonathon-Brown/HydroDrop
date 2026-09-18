import SwiftUI

/// A streak length worth stopping to mark.
///
/// The spacing is deliberate: close together at the start, where a habit is fragile
/// and any encouragement counts, and far apart later, where reaching one has to still
/// mean something. The raw value is the number of days, which is also what is stored,
/// so the list can grow without disturbing anything already earned.
enum StreakMilestone: Int, CaseIterable, Identifiable, Comparable {
    case threeDays = 3
    case oneWeek = 7
    case twoWeeks = 14
    case oneMonth = 30
    case twoMonths = 60
    case oneHundredDays = 100
    case oneYear = 365

    var id: Int { rawValue }
    var days: Int { rawValue }

    static func < (lhs: StreakMilestone, rhs: StreakMilestone) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    var title: String {
        switch self {
        case .threeDays: return "Three days"
        case .oneWeek: return "One week"
        case .twoWeeks: return "Two weeks"
        case .oneMonth: return "One month"
        case .twoMonths: return "Two months"
        case .oneHundredDays: return "100 days"
        case .oneYear: return "One year"
        }
    }

    /// Said to the user at the moment they reach it. Warm, and never a lecture about
    /// what they should do next.
    var blurb: String {
        switch self {
        case .threeDays: return "Three days in a row. That is how a habit starts."
        case .oneWeek: return "A full week of hitting your goal. Your droplet is thrilled."
        case .twoWeeks: return "Two weeks straight. This is looking like a routine."
        case .oneMonth: return "A whole month. Thirty days without missing once."
        case .twoMonths: return "Two months running. That is real staying power."
        case .oneHundredDays: return "One hundred days. Not many people get here."
        case .oneYear: return "A year of hitting your goal every single day. Remarkable."
        }
    }

    var icon: String {
        switch self {
        case .threeDays: return "drop.fill"
        case .oneWeek: return "flame.fill"
        case .twoWeeks: return "bolt.fill"
        case .oneMonth: return "star.fill"
        case .twoMonths: return "moon.stars.fill"
        case .oneHundredDays: return "crown.fill"
        case .oneYear: return "trophy.fill"
        }
    }

    var tint: Color {
        switch self {
        case .threeDays: return .cyan
        case .oneWeek: return .orange
        case .twoWeeks: return .yellow
        case .oneMonth: return .purple
        case .twoMonths: return .indigo
        case .oneHundredDays: return .pink
        case .oneYear: return .green
        }
    }

    /// Every milestone a streak of this length has passed.
    static func reached(by streak: Int) -> [StreakMilestone] {
        allCases.filter { $0.days <= streak }
    }

    /// The one to celebrate for a streak that just grew, or nil.
    ///
    /// Only the highest newly reached milestone is returned. A streak restored from
    /// another device can cross several at once, and seven celebrations in a row is a
    /// queue to dismiss rather than a moment.
    static func newlyReached(streak: Int, alreadyCelebrated: Set<Int>) -> StreakMilestone? {
        reached(by: streak)
            .filter { !alreadyCelebrated.contains($0.days) }
            .max()
    }
}
