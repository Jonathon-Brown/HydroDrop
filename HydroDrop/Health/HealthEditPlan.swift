import Foundation

/// What an edit to a drink does to what HydroDrop wrote to Apple Health.
///
/// An edit used to clear the drink's sample identifiers and delete its samples straight
/// away, leaving the next reconcile to write it again. With sync off, Today then skipped
/// deleting the water sample, so it stayed in Health with nothing pointing at it, while the
/// caffeine sample went anyway. With sync on, a drink from before sync was last turned on
/// was deleted and never written again, because the reconcile only writes drinks from that
/// moment on. An edited drink's samples are now queued and replaced in one step (see
/// `HealthReplacementStep`): straight away with sync on, or when sync is next turned on,
/// with Health left exactly as it is until then.
enum HealthEditPlan: Equatable {
    /// Nothing Health recorded moved, or Health never had this drink.
    case leaveHealth
    /// Replace the drink's samples with its corrected figures.
    case replaceSamples

    init(isUnchanged: Bool, hasSamples: Bool) {
        self = !isUnchanged && hasSamples ? .replaceSamples : .leaveHealth
    }
}

/// Health samples waiting to be replaced with their drink's corrected figures.
///
/// Kept by sample identifier, which each drink already carries, so the synced model needed
/// no new field. The queue is device-local, like Health sync itself, but the identifiers
/// are whatever the synced drink carries, which another of the user's devices may have
/// written. So an edit made on a device with sync off is corrected when sync is turned on
/// on that device, not by another device that is already syncing. Doing better needs the
/// pending replacement on the synced model, which is a CloudKit schema change.
struct HealthReplacementQueue {
    static let key = "health.samplesToReplace"
    /// Samples this device may already have taken out of Health, whose replacement is still
    /// to be written. Finding nothing to delete for one of these means write the drink
    /// again, not let it go.
    static let awaitingWriteKey = "health.samplesAwaitingWrite"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var sampleIDs: Set<String> { read(Self.key) }
    var awaitingWrite: Set<String> { read(Self.awaitingWriteKey) }

    func add(_ ids: [String?]) {
        store(sampleIDs.union(ids.compactMap { $0 }), at: Self.key)
    }

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
        store(sampleIDs.subtracting([id]), at: Self.key)
        store(awaitingWrite.subtracting([id]), at: Self.awaitingWriteKey)
    }

    private func read(_ key: String) -> Set<String> {
        Set(defaults.stringArray(forKey: key) ?? [])
    }

    private func store(_ ids: Set<String>, at key: String) {
        defaults.set(ids.sorted(), forKey: key)
    }
}

/// What to do with one queued sample, once its delete has been tried.
///
/// The old sample is deleted first and the corrected one written second, so a pass cut
/// short, or a write that fails, never leaves both in Health. A sample is marked as
/// awaiting its write before the delete and stays queued until the write lands. A delete
/// that finds nothing, for a sample that isn't marked, means the sample
/// isn't in this device's Health: the user took it out, or only another device has it. It
/// is left as it is, and the drink keeps pointing at it, so it is never written twice.
///
/// One narrow exception is accepted. If the app is killed after the mark but before the
/// delete reports back, for a sample that isn't in this device's Health, the next pass sees
/// the mark and writes the drink again. The other way round, a drink whose sample was
/// already deleted would never be written back, which is the worse of the two.
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
