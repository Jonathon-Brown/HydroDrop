import Foundation
import SwiftData

/// A throwaway on-disk store for tests, and the directory it lives in.
///
/// These stores used to be `ModelConfiguration(isStoredInMemoryOnly: true)`. On iOS 27,
/// saving into an in-memory store raises `NSInternalInconsistencyException`, "No eligible
/// connection available", from CoreData's `NSSQLDefaultConnectionManager` inside
/// `ModelContext.save()`. It is an Objective-C exception, so no Swift `catch` can
/// intercept it and the whole test process dies — which is what took down Xcode Cloud
/// runs 37 and 38. An on-disk store is unaffected: measured at 2000 saves on iOS 26.5 and
/// iOS 27.0 alike, while the in-memory one failed on 27.0 every time.
///
/// So this is not a style preference. Please do not change these back to in-memory.
enum TemporaryStore {
    /// A fresh container in its own temporary directory. The caller owns the directory
    /// and should hand it to `remove(_:)` in teardown.
    static func make(for schema: Schema) throws -> (container: ModelContainer, directory: URL) {
        let directory = URL.temporaryDirectory.appending(path: "HydroDropTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let configuration = ModelConfiguration(
            schema: schema,
            url: directory.appending(path: "store.sqlite"),
            // Tests should never reach for an iCloud account, and on a machine without one
            // the mirroring delegate spends every test tearing itself down and retrying.
            cloudKitDatabase: .none
        )
        return (try ModelContainer(for: schema, configurations: configuration), directory)
    }

    /// Takes the sqlite file and its -wal/-shm siblings with it.
    static func remove(_ directory: URL?) {
        guard let directory else { return }
        try? FileManager.default.removeItem(at: directory)
    }
}
