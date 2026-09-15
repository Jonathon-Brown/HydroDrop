import Foundation

/// An on-device tally of how people move through the HydroDrop+ paywall.
///
/// Counts only — no timestamps per event, no identifiers, nothing about the user — and
/// nothing here ever leaves the device. It is read back solely through
/// `EventCountsView`, by whoever is holding the phone. That is what keeps the app under
/// "Data Not Collected": the numbers are never transmitted, so they are not collected.
///
/// Stored in plain `UserDefaults`, deliberately not in SwiftData or `CloudSettingsStore`:
/// both of those sync through iCloud, and these counts must stay on this device.
@MainActor
enum EventCounter {
    enum Event {
        case paywallShown(PaywallSource)
        case paywallDismissedWithoutPurchase
        case purchaseAttempted
        case purchaseSucceeded
        case purchaseCancelled
        case purchasePending
        case purchaseFailed
        case streakBreakMessageShown

        var key: String {
            switch self {
            case .paywallShown(let source): return "paywall.shown.\(source.rawValue)"
            case .paywallDismissedWithoutPurchase: return "paywall.dismissedWithoutPurchase"
            case .purchaseAttempted: return "purchase.attempted"
            case .purchaseSucceeded: return "purchase.succeeded"
            case .purchaseCancelled: return "purchase.cancelled"
            case .purchasePending: return "purchase.pending"
            case .purchaseFailed: return "purchase.failed"
            case .streakBreakMessageShown: return "streakBreakMessage.shown"
            }
        }
    }

    private static let countsKey = "localEvents.counts"
    private static let sinceKey = "localEvents.since"

    static func record(_ event: Event, defaults: UserDefaults = .standard) {
        var counts = self.counts(defaults: defaults)
        counts[event.key, default: 0] += 1
        defaults.set(counts, forKey: countsKey)
        if defaults.object(forKey: sinceKey) == nil {
            defaults.set(Date(), forKey: sinceKey)
        }
    }

    static func count(of event: Event, defaults: UserDefaults = .standard) -> Int {
        counts(defaults: defaults)[event.key] ?? 0
    }

    /// When the first event was recorded on this install, or nil if none has been.
    static func countingSince(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: sinceKey) as? Date
    }

    private static func counts(defaults: UserDefaults) -> [String: Int] {
        defaults.dictionary(forKey: countsKey) as? [String: Int] ?? [:]
    }
}
