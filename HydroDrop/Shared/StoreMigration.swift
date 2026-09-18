import Foundation
import SwiftData

/// Moves the SwiftData store into the App Group container, once, so the widget and the
/// App Intents can read and write the same data the app does.
///
/// The rule throughout is that the user's existing store is sacred. It is copied, never
/// moved, and never deleted by this release: if anything at all goes wrong the app
/// carries on from the original file exactly as it did before, and the only casualty is
/// that the widget has nothing to show. A half-migrated copy is removed so the next
/// launch starts the attempt from a clean slate rather than opening a store that is
/// missing rows.
enum StoreMigration {
    /// The URL the app should open, or nil to stay on SwiftData's default location.
    ///
    /// Returning nil is the "something went wrong" answer, and it is deliberately the
    /// same answer as "this build has no App Group": both mean the app runs alone.
    static func resolveStoreURL(fileManager: FileManager = .default) -> URL? {
        guard let target = AppGroup.storeURL else {
            Diagnostics.log("no App Group container; keeping the store where it is")
            return nil
        }

        do {
            try fileManager.createDirectory(
                at: target.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        } catch {
            Diagnostics.log("could not create the shared store directory: \(error)")
            return nil
        }

        // Already migrated, or created there in the first place.
        if fileManager.fileExists(atPath: target.path(percentEncoded: false)) {
            return target
        }

        let legacy = AppGroup.legacyStoreURL
        guard fileManager.fileExists(atPath: legacy.path(percentEncoded: false)) else {
            // A fresh install has nothing to move, so the shared location is simply
            // where its store gets created.
            return target
        }

        return migrate(from: legacy, to: target, fileManager: fileManager)
    }

    static func migrate(from legacy: URL, to target: URL, fileManager: FileManager = .default) -> URL? {
        guard let expected = entryCount(at: legacy) else {
            Diagnostics.log("could not read the existing store; leaving it in place")
            return nil
        }

        do {
            for suffix in AppGroup.storeSidecarSuffixes {
                let source = sidecar(of: legacy, suffix: suffix)
                guard fileManager.fileExists(atPath: source.path(percentEncoded: false)) else { continue }
                try fileManager.copyItem(at: source, to: sidecar(of: target, suffix: suffix))
            }
        } catch {
            Diagnostics.log("could not copy the store into the App Group: \(error)")
            removePartialCopy(at: target, fileManager: fileManager)
            return nil
        }

        guard let migrated = entryCount(at: target) else {
            Diagnostics.log("the copied store would not open; falling back to the original")
            removePartialCopy(at: target, fileManager: fileManager)
            return nil
        }

        guard migrated == expected else {
            Diagnostics.log("the copied store has \(migrated) entries, expected \(expected); falling back")
            removePartialCopy(at: target, fileManager: fileManager)
            return nil
        }

        Diagnostics.log("moved \(expected) entries into the App Group container")
        return target
    }

    /// Opens a store on its own, purely to count what is in it.
    ///
    /// Deliberately without CloudKit and without saving: this is a measurement, and it
    /// must not start a sync, write anything, or wait on the network.
    static func entryCount(at url: URL) -> Int? {
        do {
            let configuration = ModelConfiguration(
                schema: Schema([WaterEntry.self]),
                url: url,
                allowsSave: false,
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: WaterEntry.self, configurations: configuration)
            let context = ModelContext(container)
            return try context.fetchCount(FetchDescriptor<WaterEntry>())
        } catch {
            Diagnostics.log("could not count entries at \(url.lastPathComponent): \(error)")
            return nil
        }
    }

    /// Clears away a copy that cannot be trusted, so the next launch tries again from
    /// the original rather than opening a store that is missing rows.
    static func removePartialCopy(at target: URL, fileManager: FileManager = .default) {
        for suffix in AppGroup.storeSidecarSuffixes {
            let file = sidecar(of: target, suffix: suffix)
            guard fileManager.fileExists(atPath: file.path(percentEncoded: false)) else { continue }
            do {
                try fileManager.removeItem(at: file)
            } catch {
                Diagnostics.log("could not remove the failed copy \(file.lastPathComponent): \(error)")
            }
        }
    }

    static func sidecar(of url: URL, suffix: String) -> URL {
        guard !suffix.isEmpty else { return url }
        return url.deletingLastPathComponent()
            .appending(path: url.lastPathComponent + suffix, directoryHint: .notDirectory)
    }
}
