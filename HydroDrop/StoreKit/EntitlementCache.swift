import Foundation

/// The last known HydroDrop+ entitlement, cached across launches.
///
/// `StoreManager.isSubscribed` starts as `false` and only becomes true once
/// `Transaction.currentEntitlements` has been read, which on a cold launch is a
/// network-dependent round trip. Treating that startup gap as "not subscribed"
/// locked paying users out of the Watch app for as long as the fetch took, and made
/// the streak-freeze check — which runs once, on appear — decide a subscriber wasn't
/// entitled to the freeze it was about to spend.
///
/// Seeding from the last known answer removes that window. Being wrong here can only
/// over-grant, and only until the real entitlement lands moments later, which is the
/// safe direction to be wrong in: a lapsed subscriber keeps Plus for another second,
/// rather than a paying one losing a streak permanently.
///
/// This is also the one entitlement read that is safe off the main actor, which is
/// what lets `ReminderManager` gate Plus-only scheduling without hopping actors.
enum EntitlementCache {
    private static let key = "plus.entitlementActive"

    static var isPlusActive: Bool {
        get { UserDefaults.standard.bool(forKey: key) }
        set { UserDefaults.standard.set(newValue, forKey: key) }
    }
}
