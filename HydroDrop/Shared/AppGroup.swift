import Foundation

/// The container the app, the widget and the App Intents all share.
///
/// Everything an extension needs to read lives behind this: the SwiftData store and
/// the small snapshot of settings the widget renders from. Each accessor is optional
/// because a build signed without the App Groups entitlement has no container at all,
/// and that has to degrade to an app that still works on its own rather than a crash.
enum AppGroup {
    static let identifier = "group.com.jonathonbrown.HydroDrop"

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }

    static var defaults: UserDefaults? {
        UserDefaults(suiteName: identifier)
    }

    /// Where the shared SwiftData store lives. Under Library/Application Support inside
    /// the group container, which is where a database belongs and what the system
    /// excludes from iCloud document backup on our behalf.
    static var storeURL: URL? {
        containerURL?
            .appending(path: "Library/Application Support", directoryHint: .isDirectory)
            .appending(path: "HydroDrop.store", directoryHint: .notDirectory)
    }

    /// The store SwiftData created for us before the App Group existed: the default
    /// location inside the app's own sandbox.
    static var legacyStoreURL: URL {
        URL.applicationSupportDirectory.appending(path: "default.store", directoryHint: .notDirectory)
    }

    /// SQLite writes alongside the main file, and a copy that leaves these behind is a
    /// copy that silently loses whatever had not been checkpointed yet.
    static let storeSidecarSuffixes = ["", "-wal", "-shm"]
}
