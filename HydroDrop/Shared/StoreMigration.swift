import Foundation
import SwiftData

/// Moves the SwiftData store into the App Group container, once, so the widget and the
/// App Intents can read and write the same data the app does.
///
/// The rule throughout is that the user's existing store is sacred. It is read, never
/// moved, and never deleted by this release: if anything at all goes wrong the app
/// carries on from the original file exactly as it did before, and the only casualty is
/// that the widget has nothing to show. The move is a read-and-reinsert — the legacy
/// rows are fetched and written afresh into the group store — rather than a file copy,
/// because copying a live CloudKit-mirrored SQLite store carries its mirroring metadata
/// and its uncheckpointed `-wal`/`-shm` sidecars along with it, and both go wrong in
/// ways that only surface later.
///
/// The reinserted rows are brand-new objects, so SwiftData mints new CloudKit record
/// names for them. The legacy originals are still in the user's private database and
/// sync back down on top of the copies, doubling every entry. `deduplicateIfNeeded`
/// cleans that up on launch — it has to be on launch, not once, because the duplicates
/// can arrive long after the migration itself finished.
enum StoreMigration {
    /// Set once the legacy rows have been reinserted and verified. Its presence is what
    /// stops the read-and-reinsert re-running. Only a *success* sets it — a failure never
    /// does, so a transient error does not lock the user out of the shared store forever.
    static let migrationCompleteKey = "store.migrationComplete"

    /// Counts failed read-and-reinsert attempts. After `maxMigrationAttempts` the app
    /// gives up and stays on the legacy store — the same outcome as a hard failure, but
    /// reached only after genuine retries rather than on the first stumble.
    static let migrationAttemptsKey = "store.migrationAttempts"
    static let maxMigrationAttempts = 3

    /// The row count the last dedupe pass saw. The pass is skipped whenever the count is
    /// unchanged, so a launch with no new sync does no work.
    static let lastDedupeCountKey = "store.lastDedupeCount"

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

        // The completion flag is the authority on whether the move is done, not the file
        // existing on its own: a half-written group store from an interrupted run must
        // never be mistaken for a finished one.
        if AppGroup.defaults?.bool(forKey: migrationCompleteKey) == true {
            return target
        }

        // Out of retries. Stay on the legacy store rather than attempt the reinsert a
        // fourth time; a future build can reset the counter and try a different approach.
        if (AppGroup.defaults?.integer(forKey: migrationAttemptsKey) ?? 0) >= maxMigrationAttempts {
            Diagnostics.log("store migration has failed \(maxMigrationAttempts) times; staying on the original store")
            return nil
        }

        let legacy = AppGroup.legacyStoreURL
        guard fileManager.fileExists(atPath: legacy.path(percentEncoded: false)) else {
            // A fresh install has nothing to move, so the shared location is simply
            // where its store gets created — and that is already the finished state.
            AppGroup.defaults?.set(true, forKey: migrationCompleteKey)
            return target
        }

        return migrate(from: legacy, to: target)
    }

    /// Reads every row out of the legacy store and writes it afresh into the group store,
    /// then records the completion flag. Returns the group URL on success, or nil to keep
    /// the app on its original store. A failure records an attempt and returns nil without
    /// touching the completion flag, so the next launch retries until the attempt cap.
    static func migrate(from legacy: URL, to target: URL) -> URL? {
        let legacyRows: [WaterEntry]
        do {
            legacyRows = try readRows(at: legacy)
        } catch {
            recordFailedAttempt("could not read the existing store; leaving it in place: \(error)")
            return nil
        }

        do {
            let migrated = try reinsert(legacyRows, into: target)
            guard migrated == legacyRows.count else {
                recordFailedAttempt("the migrated store has \(migrated) entries, expected \(legacyRows.count); leaving the app on its original store")
                return nil
            }
        } catch {
            recordFailedAttempt("could not write entries into the App Group store; leaving the app on its original store: \(error)")
            return nil
        }

        AppGroup.defaults?.set(true, forKey: migrationCompleteKey)
        Diagnostics.log("moved \(legacyRows.count) entries into the App Group container")
        return target
    }

    /// Opens the legacy store *with saving allowed*, so SwiftData can replay any pending
    /// internal migration it needs before the fetch — an open with `allowsSave: false`
    /// fails with SQLITE_READONLY the moment that replay tries to write. No CloudKit: a
    /// one-off read must not start a sync or wait on the network. Throws so the caller
    /// can tell "the store would not open" from "the store is genuinely empty".
    static func readRows(at url: URL) throws -> [WaterEntry] {
        let configuration = ModelConfiguration(
            schema: Schema([WaterEntry.self]),
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: WaterEntry.self, configurations: configuration)
        let context = ModelContext(container)
        return try context.fetch(FetchDescriptor<WaterEntry>())
    }

    /// Writes the given rows into a freshly opened group store and returns the count it
    /// holds afterwards, so the caller can confirm nothing was dropped. Opened without
    /// CloudKit so the reinsert does not race a sync mid-write; the app's own container
    /// re-opens the same file with CloudKit straight afterwards and mirrors it then.
    static func reinsert(_ rows: [WaterEntry], into target: URL) throws -> Int {
        let configuration = ModelConfiguration(
            schema: Schema([WaterEntry.self]),
            url: target,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: WaterEntry.self, configurations: configuration)
        let context = ModelContext(container)
        for row in rows {
            // A fresh WaterEntry, not the fetched object: a managed object belongs to the
            // context it was fetched from and cannot simply be inserted into another.
            let copy = WaterEntry(amountML: row.amountML, timestamp: row.timestamp)
            copy.drinkTypeRawValue = row.drinkTypeRawValue
            copy.healthKitSampleUUID = row.healthKitSampleUUID
            context.insert(copy)
        }
        try context.save()
        return try context.fetchCount(FetchDescriptor<WaterEntry>())
    }

    /// Removes the duplicate rows the CloudKit round-trip leaves behind after a
    /// read-and-reinsert: the reinserted copies and the originals mirrored back down are
    /// distinct objects with identical field values. Groups by the fields that define a
    /// drink — `timestamp`, `amountML`, `drinkTypeRawValue` — and keeps one of each.
    ///
    /// Runs on the live, CloudKit-backed app container so the delete propagates, and runs
    /// every launch because the duplicates can arrive on a sync that lands well after the
    /// migration finished. It skips itself when the row count is unchanged since the last
    /// pass, so a launch with no new sync costs a single `fetchCount`.
    static func deduplicateIfNeeded(in container: ModelContainer) {
        let context = ModelContext(container)
        let currentCount: Int
        do {
            currentCount = try context.fetchCount(FetchDescriptor<WaterEntry>())
        } catch {
            Diagnostics.log("could not count entries for the dedupe pass: \(error)")
            return
        }

        // Nothing has landed since the last pass, so there is nothing new to collapse.
        if let last = AppGroup.defaults?.object(forKey: lastDedupeCountKey) as? Int, last == currentCount {
            return
        }

        do {
            let rows = try context.fetch(FetchDescriptor<WaterEntry>())
            var seen = Set<String>()
            var removed = 0
            for row in rows {
                let key = "\(row.timestamp.timeIntervalSinceReferenceDate)|\(row.amountML)|\(row.drinkTypeRawValue ?? "")"
                if seen.contains(key) {
                    context.delete(row)
                    removed += 1
                } else {
                    seen.insert(key)
                }
            }
            if removed > 0 {
                try context.save()
                Diagnostics.log("dedupe pass removed \(removed) duplicate entries")
            }
            // Record the post-dedupe count so the next launch measures against what the
            // store actually holds now, not the inflated figure we just corrected.
            let settledCount = try context.fetchCount(FetchDescriptor<WaterEntry>())
            AppGroup.defaults?.set(settledCount, forKey: lastDedupeCountKey)
        } catch {
            Diagnostics.log("dedupe pass could not complete: \(error)")
        }
    }

    /// Logs the failure and bumps the attempt counter, leaving the completion flag alone
    /// so the next launch retries. Deliberately does *not* set completion on failure: one
    /// transient error must not permanently deny the user the shared-store widget.
    private static func recordFailedAttempt(_ message: String) {
        let attempts = (AppGroup.defaults?.integer(forKey: migrationAttemptsKey) ?? 0) + 1
        AppGroup.defaults?.set(attempts, forKey: migrationAttemptsKey)
        Diagnostics.log("\(message) (attempt \(attempts) of \(maxMigrationAttempts))")
    }
}
