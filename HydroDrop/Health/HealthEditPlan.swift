import Foundation
import SwiftData

/// What an edit to a drink does to what HydroDrop wrote to Apple Health.
///
/// An edit used to clear the drink's sample identifiers and delete its samples straight
/// away, leaving the next reconcile to write it again. With sync off, Today then skipped
/// deleting the water sample, so it stayed in Health with nothing pointing at it, while the
/// caffeine sample went anyway. With sync on, a drink from before sync was last turned on
/// was deleted and never written again, because the reconcile only writes drinks from that
/// moment on. An edited drink's samples are now replaced in one step (see
/// `HealthReplacementStep`) by their owner, the device that wrote or claimed them, whichever
/// device the edit was made on, with Health left exactly as it is until then (see
/// `WaterEntry.noteHealthEdit`). Another device takes over after a week.
enum HealthEditPlan: Equatable {
    /// Nothing Health recorded moved, or Health never had this drink.
    case leaveHealth
    /// Replace the drink's samples with its corrected figures.
    case replaceSamples

    init(isUnchanged: Bool, hasSamples: Bool) {
        self = !isUnchanged && hasSamples ? .replaceSamples : .leaveHealth
    }
}

/// This device's own part in replacing edited drinks' Health samples.
///
/// 1.8.1 kept the whole queue here, by sample identifier, so an edit made on a device with
/// sync off was corrected only when sync was turned on on that device, never by another
/// device that already synced. The work list is now each synced drink's record of what
/// Health holds (see `HealthWrittenRecord`). What stays here is what only this device can
/// know: which samples it may already have taken out of its own Health. The old list is
/// moved onto the drinks once (see `moveQueuedSamplesOntoDrinks`).
struct HealthReplacementQueue {
    /// The list 1.8.1 kept. Read only to move it onto the drinks.
    static let key = "health.samplesToReplace"
    /// Samples this device may already have taken out of Health, whose replacement is still
    /// to be written. Finding nothing to delete for one of these means write the drink
    /// again, not let it go.
    static let awaitingWriteKey = "health.samplesAwaitingWrite"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// What is left of the list 1.8.1 kept.
    var sampleIDs: Set<String> { read(Self.key) }
    var awaitingWrite: Set<String> { read(Self.awaitingWriteKey) }

    func markAwaitingWrite(_ id: String) {
        store(awaitingWrite.union([id]), at: Self.awaitingWriteKey)
    }

    /// Undoes this pass's mark after a delete that couldn't be done. A mark made earlier
    /// stays: that sample may already be out of Health, and without the mark the next pass
    /// would read "nothing to delete" as the user having removed it and never write the
    /// drink back.
    func abandonAttempt(_ id: String, wasAwaiting: Bool) {
        guard !wasAwaiting else { return }
        store(awaitingWrite.subtracting([id]), at: Self.awaitingWriteKey)
    }

    /// Crosses a sample off once it has been replaced, or let go.
    func remove(_ id: String) {
        store(awaitingWrite.subtracting([id]), at: Self.awaitingWriteKey)
    }

    /// Moves the list 1.8.1 kept on this device onto the synced drinks, where every device
    /// can see it. Runs at every launch until the list is empty, with sync on here or not.
    ///
    /// A queued sample no drink carries any more is dropped, as 1.8.1 did. One whose drink
    /// has no record of it is marked out of date with its figures unknown, since the list
    /// never kept them, and claimed by `claimant` for its kind: this device if it may write
    /// that kind to Health, since it would have replaced the sample itself once sync was
    /// on. Otherwise a device with sync on takes it over after a week. A lookup that fails
    /// keeps the rest for the next launch.
    @MainActor
    func moveQueuedSamplesOntoDrinks(in context: ModelContext, claimedBy claimant: (HealthSampleKind) -> String?) {
        let queued = sampleIDs
        guard !queued.isEmpty else { return }
        var moved: [String] = []
        for sampleID in queued.sorted() {
            let found: (water: WaterEntry?, caffeine: WaterEntry?)
            do {
                found = try HealthKitManager.entries(carrying: sampleID, in: context)
            } catch {
                Diagnostics.log("could not look up a queued Health sample's drink; trying again next launch: \(error)")
                break
            }
            found.water?.noteStaleHealthSample(sampleID, kind: .water, claimedBy: claimant(.water))
            found.caffeine?.noteStaleHealthSample(sampleID, kind: .caffeine, claimedBy: claimant(.caffeine))
            moved.append(sampleID)
        }
        guard !moved.isEmpty else { return }
        do {
            try context.save()
        } catch {
            // Left on the list, so the next launch moves them again. Doing it twice only
            // marks the same drinks twice.
            Diagnostics.log("could not save the queued Health samples onto their drinks: \(error)")
            return
        }
        store(sampleIDs.subtracting(moved), at: Self.key)
        Diagnostics.log("moved \(moved.count) queued Health samples onto their drinks")
    }

    private func read(_ key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func store(_ ids: Set<String>, at key: String) {
        if ids.isEmpty {
            defaults.removeObject(forKey: key)
        } else {
            defaults.set(ids.sorted(), forKey: key)
        }
    }
}

/// What to do with one sample being replaced, once its delete has been tried.
///
/// The old sample is deleted first and the corrected one written second, so a pass cut
/// short, or a write that fails, never leaves both in Health. A sample is marked as
/// awaiting its write before the delete and stays marked until the write lands. A delete
/// that finds nothing, for a sample that isn't marked, means the sample
/// isn't in this device's Health: the user took it out, or only another device has it. It
/// is left as it is, and the drink keeps pointing at it, so it is never written twice.
///
/// One narrow exception is accepted. If the app is killed after the mark but before the
/// delete reports back, for a sample that isn't in this device's Health, the next pass sees
/// the mark and writes the drink again. The other way round, a drink whose sample was
/// already deleted would never be written back, which is the worse of the two. The sync
/// identifier each sample now carries turns that second write into a replacement, where
/// the other copy is in this device's Health.
enum HealthReplacementStep: Equatable {
    /// The delete couldn't be done (not allowed, or the phone is locked): try again later.
    case retryLater
    /// Not in this device's Health: leave it, and the drink's record of it, alone.
    case letGo
    /// Out of Health, and the edited drink has nothing of this kind to write.
    case clear
    /// Out of Health: write the corrected drink.
    case rewrite

    /// - Parameters:
    ///   - deletedCount: what the delete removed, or nil if it could not be done.
    ///   - wasAwaitingWrite: the sample was marked before this pass, so this device may
    ///     already have taken it out.
    ///   - stillCounts: the edited drink has something of this kind to write.
    init(deletedCount: Int?, wasAwaitingWrite: Bool, stillCounts: Bool) {
        guard let deletedCount else {
            self = .retryLater
            return
        }
        if deletedCount == 0 && !wasAwaitingWrite {
            self = .letGo
        } else {
            self = stillCounts ? .rewrite : .clear
        }
    }
}
