import Foundation
import SwiftData

/// The one place the SwiftData store is opened, whichever process is asking.
///
/// The app, the widget's quick-add button and the App Intents all have to end up on the
/// same file, so they all come through here. The preference order is the same
/// everywhere: the shared container with iCloud, then the shared container without it,
/// and only then SwiftData's own default location, which is where the app lived before
/// the App Group existed.
enum SharedModelContainer {
    /// Every model the store holds. A store made before `Bottle` existed, including the
    /// one `StoreMigration` builds with only `WaterEntry` in it, gains the new entity by
    /// lightweight migration the first time it is opened with this.
    static let schema = Schema([WaterEntry.self, Bottle.self])

    /// Builds the container the app should use, migrating the store into the App Group
    /// on the way if that has not happened yet.
    ///
    /// Never returns nil: an app that cannot reach iCloud, or cannot reach its own App
    /// Group, is still an app that has to let you log a glass of water.
    static func makeForApp() -> ModelContainer {
        if let url = StoreMigration.resolveStoreURL() {
            if let container = open(url: url, cloudKit: .automatic) {
                // The read-and-reinsert leaves duplicates once CloudKit mirrors the legacy
                // originals back down. Collapse them here, on the live synced container, so
                // the delete propagates — and every launch, because that sync can land late.
                StoreMigration.deduplicateIfNeeded(in: container)
                return container
            }
            Diagnostics.log("iCloud store unavailable in the App Group, falling back to local")
            if let container = open(url: url, cloudKit: .none) {
                return container
            }
        }

        // No App Group, or the shared file would not open at all. Back to exactly what
        // the app did before any of this existed.
        if let container = open(url: nil, cloudKit: .automatic) {
            return container
        }
        if let container = open(url: nil, cloudKit: .none) {
            return container
        }
        fatalError("Failed to create a ModelContainer at any location")
    }

    /// The container an extension should use, or nil when there is nothing shared to
    /// open. Callers must treat nil as "the app has not finished setting this up", not
    /// as an empty database: creating a store here instead would fork the user's data
    /// into a second file the app never reads.
    static func makeForExtension() -> ModelContainer? {
        guard let url = AppGroup.storeURL,
              FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else {
            Diagnostics.log("no shared store to open from this extension")
            return nil
        }
        // Same configuration the app uses, so a drink logged here is exported to iCloud
        // on the same terms as one logged in the app.
        if let container = open(url: url, cloudKit: .automatic) {
            return container
        }
        Diagnostics.log("shared store would not open with iCloud from an extension; saving locally")
        return open(url: url, cloudKit: .none)
    }

    private static func open(url: URL?, cloudKit: ModelConfiguration.CloudKitDatabase) -> ModelContainer? {
        do {
            let configuration: ModelConfiguration
            if let url {
                configuration = ModelConfiguration(schema: schema, url: url, cloudKitDatabase: cloudKit)
            } else {
                configuration = ModelConfiguration(schema: schema, cloudKitDatabase: cloudKit)
            }
            return try ModelContainer(for: schema, configurations: configuration)
        } catch {
            Diagnostics.log("could not open the store (\(url?.lastPathComponent ?? "default")): \(error)")
            return nil
        }
    }

    /// Whether the store the app is using is the shared one, which is what decides
    /// whether an extension can log a drink at all.
    static func isShared(_ container: ModelContainer) -> Bool {
        guard let shared = AppGroup.storeURL else { return false }
        return container.configurations.contains { $0.url.standardizedFileURL == shared.standardizedFileURL }
    }
}
