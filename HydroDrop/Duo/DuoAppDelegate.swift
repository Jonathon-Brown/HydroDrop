#if DUO_V2
import UIKit

/// The app delegate SwiftUI forwards to (`@UIApplicationDelegateAdaptor` in `HydroDropApp`), for
/// the push token and nothing else. The app had no delegate before Duo, and this one implements
/// only the two token callbacks.
///
/// It must never implement `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`:
/// SwiftData's CloudKit mirror of the water log is woken by silent pushes, which have to reach it
/// untouched, and Duo sends none (§9.7), so there is nothing here for one to do.
/// `DuoAppDelegateTests` holds it to that.
final class DuoAppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // Kept in memory by the push service, and uploaded only while a live duo exists (§3.1).
        // CloudKit's mirror asks for the token at every launch, so this runs for people with no
        // duo too, and for them it does nothing more.
        DuoStore.shared.pushTokenArrived(deviceToken, environment: DuoConfig.apnsEnvironment)
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected in a simulator without APNs and on a phone with no connection; the next request
        // for a token tries again. The domain and code say nothing about the person.
        let failure = error as NSError
        Diagnostics.log("no push token this time (\(failure.domain) \(failure.code))")
    }
}
#endif
