import CloudKit
import UIKit

/// Exists for the two things a duo needs that SwiftUI has no modifier for: naming the
/// scene delegate that receives an opened invite, and receiving the silent push that
/// says something in a duo changed. SwiftUI still owns the app and its windows.
final class DuoAppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // Silent pushes need no permission and show nothing. SwiftData's own sync relies
        // on the same registration, so this asks for nothing the app did not already have.
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        // Expected in the simulator. A duo still refreshes on foreground without it.
        Diagnostics.log("could not register for remote notifications: \(error)")
    }

    /// Every silent push comes through here, SwiftData's included. Only the two duo
    /// subscriptions are acted on; anything else is answered "nothing new" and left to
    /// whoever it was for.
    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any],
        fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
    ) {
        guard DuoStore.isDuoPush(userInfo) else {
            completionHandler(.noData)
            return
        }
        Task { @MainActor in
            let changed = await DuoStore.shared.backgroundRefresh()
            completionHandler(changed ? .newData : .noData)
        }
    }

    func application(
        _ application: UIApplication,
        configurationForConnecting connectingSceneSession: UISceneSession,
        options: UIScene.ConnectionOptions
    ) -> UISceneConfiguration {
        let configuration = UISceneConfiguration(name: nil, sessionRole: connectingSceneSession.role)
        configuration.delegateClass = DuoSceneDelegate.self
        return configuration
    }
}

/// Where an opened duo invite arrives. iOS hands a CloudKit share to the scene, not to
/// the app, and SwiftUI has no modifier for it, so this is the one piece of UIKit
/// lifecycle in HydroDrop.
///
/// Both ways in lead to the same place. Nothing is accepted here: `DuoStore` checks the
/// invite and asks for a first name before saying yes.
final class DuoSceneDelegate: NSObject, UIWindowSceneDelegate {
    /// The app was not running when the invite was opened.
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Said once a launch, because a scene restored from before this delegate existed
        // is the one way an invite could arrive and find nobody listening.
        Diagnostics.log("scene connected; duo invites are being listened for")
        guard let metadata = connectionOptions.cloudKitShareMetadata else { return }
        Task { @MainActor in DuoStore.shared.received(metadata) }
    }

    /// The app was already running.
    func windowScene(_ windowScene: UIWindowScene, userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata) {
        Task { @MainActor in DuoStore.shared.received(cloudKitShareMetadata) }
    }
}
