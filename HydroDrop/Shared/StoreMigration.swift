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
/// collapses the copies onto their originals as they arrive — on this device only, and
/// only the rows this device's reinsert made, which it remembers by their Health
/// identifiers. It has to run on every launch, and after every sync, because the
/// originals can arrive long after the migration itself finished.
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

    /// The Health identifiers of the copies this device's read-and-reinsert made, and
    /// when it made them. Only this device can tell a copy from the original it was taken
    /// from, so only this device collapses them, and only these rows.
    ///
    /// The pass used to run on every device and collapse any rows that matched on
    /// timestamp, amount and type, keeping whichever came first in the store. That was
    /// the copy on the device that had migrated, where the reinsert put the copies in
    /// before the originals synced down, and the original everywhere else, where the
    /// copies arrived by sync. Each device deleted the row the other had kept, and once
    /// the deletes synced the drink was gone everywhere. The same rule also took two real
    /// drinks logged to the same minute, which the time picker produces when a lunch is
    /// backfilled, for one drink synced twice, and deleted one of them.
    static let migrationCopyIDsKey = "store.migrationCopyIDs"
    static let migrationMomentKey = "store.migrationMoment"

    /// How long the originals are waited for. With iCloud off on this device they never
    /// come back down, and a list that never emptied would have the pass reading every
    /// row on every launch for good. After this the copies simply are the user's log.
    static let copyListLifetime: TimeInterval = 30 * 24 * 60 * 60

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
    static func migrate(from legacy: URL, to target: URL, now: Date = Date()) -> URL? {
        let legacyRows: [WaterEntry]
        do {
            legacyRows = try readRows(at: legacy)
        } catch {
            recordFailedAttempt("could not read the existing store; leaving it in place: \(error)")
            return nil
        }

        let reinserted: Reinsertion
        do {
            reinserted = try reinsertRecordingCopies(legacyRows, into: target)
            guard reinserted.count == legacyRows.count else {
                recordFailedAttempt("the migrated store has \(reinserted.count) entries, expected \(legacyRows.count); leaving the app on its original store")
                return nil
            }
        } catch {
            recordFailedAttempt("could not write entries into the App Group store; leaving the app on its original store: \(error)")
            return nil
        }

        AppGroup.defaults?.set(true, forKey: migrationCompleteKey)
        // Recorded before the group store is opened with CloudKit, so the very first
        // dedupe pass already knows which rows are the copies.
        AppGroup.defaults?.set(reinserted.copyIDs, forKey: migrationCopyIDsKey)
        AppGroup.defaults?.set(now.timeIntervalSinceReferenceDate, forKey: migrationMomentKey)
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

    /// What a read-and-reinsert produced: how many rows the target holds afterwards, and
    /// the Health identifiers minted for the copies, which is how the dedupe pass knows
    /// them from the originals once those sync down.
    struct Reinsertion {
        let count: Int
        let copyIDs: [String]
    }

    /// Writes the given rows into a freshly opened group store and returns the count it
    /// holds afterwards, so the caller can confirm nothing was dropped.
    static func reinsert(_ rows: [WaterEntry], into target: URL) throws -> Int {
        try reinsertRecordingCopies(rows, into: target).count
    }

    /// The same, also reporting the identifiers of the copies it made. Opened without
    /// CloudKit so the reinsert does not race a sync mid-write; the app's own container
    /// re-opens the same file with CloudKit straight afterwards and mirrors it then.
    static func reinsertRecordingCopies(_ rows: [WaterEntry], into target: URL) throws -> Reinsertion {
        let configuration = ModelConfiguration(
            schema: Schema([WaterEntry.self]),
            url: target,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        let container = try ModelContainer(for: WaterEntry.self, configurations: configuration)
        let context = ModelContext(container)
        var copyIDs: [String] = []
        for row in rows {
            // A fresh WaterEntry, not the fetched object: a managed object belongs to the
            // context it was fetched from and cannot simply be inserted into another. The
            // initialiser mints it a Health identifier of its own, which is what marks it
            // as a copy; everything else Health knows about the drink comes across, so a
            // copy that outlives its original, where iCloud is off, is still the drink
            // Health has.
            let copy = WaterEntry(amountML: row.amountML, timestamp: row.timestamp)
            copy.drinkTypeRawValue = row.drinkTypeRawValue
            copy.healthKitSampleUUID = row.healthKitSampleUUID
            copy.caffeineSampleUUID = row.caffeineSampleUUID
            copy.healthWaterWritten = row.healthWaterWritten
            copy.healthCaffeineWritten = row.healthCaffeineWritten
            if let id = copy.healthSyncID { copyIDs.append(id) }
            context.insert(copy)
        }
        try context.save()
        return Reinsertion(count: try context.fetchCount(FetchDescriptor<WaterEntry>()), copyIDs: copyIDs)
    }

    /// Samples a dedupe pass found on the copies it deleted that the original doesn't point
    /// at, because the original already has a sample of that kind. Each is a second copy of
    /// the drink in Health, for the app to take back out.
    struct HealthLeftovers: Equatable {
        var water: [String] = []
        var caffeine: [String] = []

        var isEmpty: Bool { water.isEmpty && caffeine.isEmpty }
    }

    /// Removes the copies this device's read-and-reinsert made, once the originals they
    /// were taken from have synced back down: a copy and its original are distinct objects
    /// with identical `timestamp`, `amountML` and `drinkTypeRawValue`, and the copy is the
    /// one whose Health identifier is on this device's list. A copy whose original has not
    /// arrived is the only row the user has for that drink, and stays. Rows that are not
    /// on the list are never touched, however alike they are: two real drinks logged to
    /// the same minute are two real drinks.
    ///
    /// A deleted copy's samples move onto the original where it has none of that kind, and
    /// any left over are handed to `retire`, which the app points at `HealthTakeBackList`.
    ///
    /// Runs on the live, CloudKit-backed app container so the delete propagates, on every
    /// launch and after every sync, because the originals can arrive on a sync that lands
    /// well after the migration finished. Costs nothing once the list is empty.
    static func deduplicateIfNeeded(
        in container: ModelContainer,
        retire: (HealthLeftovers) -> Void = { _ in },
        now: Date = Date()
    ) {
        guard let defaults = AppGroup.defaults,
              let copyIDs = defaults.stringArray(forKey: migrationCopyIDsKey),
              !copyIDs.isEmpty else { return }
        if let moment = defaults.object(forKey: migrationMomentKey) as? Double,
           now.timeIntervalSinceReferenceDate - moment > copyListLifetime {
            // The originals are not coming. The copies are the user's log now.
            forgetCopies(in: defaults)
            Diagnostics.log("dedupe pass stopped waiting for originals that never synced")
            return
        }

        let context = ModelContext(container)
        do {
            let rows = try context.fetch(FetchDescriptor<WaterEntry>())
            let copies = Set(copyIDs)
            func isCopy(_ row: WaterEntry) -> Bool {
                row.healthSyncID.map(copies.contains) ?? false
            }
            // What is still to collapse, worked out before anything moves: a copy the user
            // has already deleted is off the list, and so is each one deleted below.
            var remaining = Set(rows.compactMap(\.healthSyncID)).intersection(copies)

            var groups: [String: [WaterEntry]] = [:]
            var order: [String] = []
            for row in rows {
                let key = "\(row.timestamp.timeIntervalSinceReferenceDate)|\(row.amountML)|\(row.drinkTypeRawValue ?? "")"
                if groups[key] == nil { order.append(key) }
                groups[key, default: []].append(row)
            }
            var removed = 0
            var leftovers = HealthLeftovers()
            for key in order {
                guard let group = groups[key], group.count > 1 else { continue }
                // Only once the original is here. Two copies of one drink, from this
                // device's migration and another's, are still both copies.
                guard let original = group.first(where: { !isCopy($0) }) else { continue }
                for copy in group where isCopy(copy) {
                    if let id = copy.healthSyncID { remaining.remove(id) }
                    adoptHealth(of: copy, into: original, leftovers: &leftovers)
                    context.delete(copy)
                    removed += 1
                }
            }
            if removed > 0 {
                try context.save()
                Diagnostics.log("dedupe pass removed \(removed) copies the migration made")
            }
            // Only once the deletes are saved: a sample handed over is taken out of Health.
            if !leftovers.isEmpty {
                retire(leftovers)
                Diagnostics.log("dedupe pass left \(leftovers.water.count + leftovers.caffeine.count) second copies in Health to take back")
            }
            if remaining.isEmpty {
                forgetCopies(in: defaults)
            } else if remaining.count != copyIDs.count {
                defaults.set(remaining.sorted(), forKey: migrationCopyIDsKey)
            }
        } catch {
            Diagnostics.log("dedupe pass could not complete: \(error)")
        }
    }

    private static func forgetCopies(in defaults: UserDefaults) {
        defaults.removeObject(forKey: migrationCopyIDsKey)
        defaults.removeObject(forKey: migrationMomentKey)
    }

    /// Moves a copy's samples, and the records that go with them, onto the original where
    /// it has none of that kind. A different sample where it has one of its own is a second
    /// copy of the drink in Health, and goes on `leftovers`. An original with no Health
    /// identifier of its own takes the copy's, so a sample the copy was written under is
    /// still the original's to replace.
    static func adoptHealth(of row: WaterEntry, into kept: WaterEntry, leftovers: inout HealthLeftovers) {
        if let sample = row.healthKitSampleUUID, sample != kept.healthKitSampleUUID {
            if kept.healthKitSampleUUID == nil {
                kept.healthKitSampleUUID = sample
                kept.healthWaterWritten = row.healthWaterWritten
            } else {
                leftovers.water.append(sample)
            }
        }
        if let sample = row.caffeineSampleUUID, sample != kept.caffeineSampleUUID {
            if kept.caffeineSampleUUID == nil {
                kept.caffeineSampleUUID = sample
                kept.healthCaffeineWritten = row.healthCaffeineWritten
            } else {
                leftovers.caffeine.append(sample)
            }
        }
        if kept.healthSyncID == nil {
            kept.healthSyncID = row.healthSyncID
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
