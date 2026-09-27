import BackgroundTasks
import CloudKit
import Foundation
import UserNotifications

/// TestFlight builds 29 to 31 had a version of Duo Streaks built on iCloud sharing. It
/// never reached the App Store, and was taken out in favour of a design that can also
/// work on Android. This clears, once, what it left on a tester's phone, and does nothing
/// on a phone that never ran those builds.
///
/// The duo zones and their shares in a tester's iCloud are left alone: deleting someone's
/// iCloud data unasked is not this code's call. Leaving the duo in build 31 before
/// updating is the clean way out, since that build deletes them properly.
///
/// Known gap, accepted because it only touches a handful of testers and costs no more than
/// some extra silent pushes: the iCloud subscriptions belong to the account, but the sign
/// that Duo was used lives on the phone. A tester who deleted the app before updating, or
/// used Duo on another device, has no sign here, so their subscriptions stay.
enum LegacyDuoCleanup {
    /// The background refresh those builds scheduled. It stays declared in project.yml
    /// with an empty handler in `HydroDropApp`, because iOS can launch the app for a
    /// request scheduled before the update, and a launch for a task nobody handles is a
    /// crash. Keep both even once no tester is left on those builds: the Duo redesign is
    /// to take this identifier over for its own background fetch rather than retire it.
    static var refreshIdentifier: String {
        "\(Bundle.main.bundleIdentifier ?? "com.jonathonbrown.HydroDrop").duo.refresh"
    }

    private static let doneKey = "legacyDuoCleanup.v1.done"
    /// Set the moment a sign of Duo is found, before the signs themselves are cleared, so
    /// the iCloud half stays owed across launches until it actually succeeds.
    private static let iCloudOwedKey = "legacyDuoCleanup.v1.iCloudOwed"
    /// Set by those builds once they saved their iCloud change subscriptions. An account
    /// change cleared it, so on its own it can miss a phone that used Duo.
    private static let subscriptionsSavedKey = "duo.subscriptionsSaved"
    /// The duo cache. Written the first time a duo was started or joined, and kept, empty,
    /// after leaving it, so it marks a phone that used Duo even when the flag is gone.
    private static let statesKey = "duo.states.v1"
    private static let localKeys = [
        statesKey,
        "duo.myDisplayName",
        "duo.ledger.v1",
        "duo.notificationsOff",
        "duoInviteMoment.dismissed",
    ]
    private static let notificationPrefix = "hydrodrop.duo."
    /// Saved in the private and the shared database respectively.
    private static let privateSubscriptionID = "duo-private-changes"
    private static let sharedSubscriptionID = "duo-shared-changes"

    static func runOnce() {
        let own = UserDefaults.standard
        guard !own.bool(forKey: doneKey) else { return }
        // Those builds kept Duo in the App Group, or in the app's own defaults when the
        // build had no group, so both are looked at and cleared.
        let stores = [AppGroup.defaults, own].compactMap { $0 }
        if stores.contains(where: { $0.bool(forKey: subscriptionsSavedKey) || $0.object(forKey: statesKey) != nil }) {
            own.set(true, forKey: iCloudOwedKey)
        }
        for store in stores {
            for key in localKeys { store.removeObject(forKey: key) }
        }
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: refreshIdentifier)
        withdrawNotifications()
        guard own.bool(forKey: iCloudOwedKey) else {
            own.set(true, forKey: doneKey)
            return
        }
        // Anywhere else, the subscriptions TestFlight builds saved do not exist, and finding
        // nothing must not count as done: the iCloud half waits for a build that can see them.
        guard reachesProductionCloudKit else { return }
        Task { await deleteSubscriptions(clearingFlagIn: stores) }
    }

    /// Whether this build talks to CloudKit's Production environment, where TestFlight
    /// builds saved the subscriptions. That follows the signing, not the configuration: a
    /// Release build run or profiled from Xcode is signed for development and talks to
    /// Development. TestFlight and App Store builds are the ones with no
    /// embedded.mobileprovision; an Ad Hoc build has one and merely leaves this for later.
    private static var reachesProductionCloudKit: Bool {
        #if DEBUG || targetEnvironment(simulator)
        return false
        #else
        return Bundle.main.path(forResource: "embedded", ofType: "mobileprovision") == nil
        #endif
    }

    /// Nudges and goal-met notices, waiting or already on screen, all named with one prefix.
    private static func withdrawNotifications() {
        let center = UNUserNotificationCenter.current()
        center.getPendingNotificationRequests { requests in
            let ids = requests.map(\.identifier).filter { $0.hasPrefix(notificationPrefix) }
            center.removePendingNotificationRequests(withIdentifiers: ids)
        }
        center.getDeliveredNotifications { notifications in
            let ids = notifications.map(\.request.identifier).filter { $0.hasPrefix(notificationPrefix) }
            center.removeDeliveredNotifications(withIdentifiers: ids)
        }
    }

    /// Left in place, the private one would keep waking the app with a silent push for every
    /// change in the private database. Only gone, or an account that can never reach iCloud,
    /// settles it: signed out, offline or busy is tried again on the next launch.
    private static func deleteSubscriptions(clearingFlagIn stores: [UserDefaults]) async {
        let container = CKContainer.default()
        let targets = [
            (container.privateCloudDatabase, privateSubscriptionID),
            (container.sharedCloudDatabase, sharedSubscriptionID),
        ]
        for (database, id) in targets {
            do {
                _ = try await database.deleteSubscription(withID: id)
            } catch let error as CKError where error.code == .unknownItem {
                // Already gone, or never saved for this account.
            } catch let error as CKError where error.code == .managedAccountRestricted {
                // This account can never reach CloudKit, so there is nothing it could delete.
            } catch {
                Diagnostics.log("could not remove a legacy duo subscription, will retry next launch: \(error)")
                return
            }
        }
        for store in stores { store.removeObject(forKey: subscriptionsSavedKey) }
        UserDefaults.standard.removeObject(forKey: iCloudOwedKey)
        UserDefaults.standard.set(true, forKey: doneKey)
    }
}
