import CloudKit
import UIKit

/// Exists to name the scene delegate. SwiftUI still owns the app and its windows; this
/// only asks for `DuoSceneDelegate` to be told what the scene is told.
final class DuoAppDelegate: NSObject, UIApplicationDelegate {
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
