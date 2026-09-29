import Foundation

/// When a change to the log is written to Apple Health.
///
/// A drink logged on Today used to reach Health only on the app's next foreground, or after
/// an edit, delete or undo, so a coffee logged just before closing the app stayed out of
/// Health until it was next opened. Every change is now written as soon as it has settled.
/// The one wait is the undo offer: there is no point writing a drink that may be taken back.
/// A write that does race an undo, a delete or an edit is still safe, because the write
/// checks its drink again once Health has taken the sample (see `HealthSampleSnapshot`).
enum HealthSyncMoment: CaseIterable {
    /// A drink logged on Today, while its undo offer is still showing.
    case loggedWithUndoOffer
    /// The undo offer ran out, so the drink is staying.
    case undoOfferEnded
    /// The app left the foreground while an undo offer was showing, which ends the offer.
    case leftForegroundDuringUndoOffer
    /// A drink logged on the watch. The phone shows no undo offer for those.
    case arrivedFromWatch
    /// An edit, a delete or an undo.
    case logChanged
    /// The app came back to the foreground.
    case cameToForeground

    var writesToHealth: Bool {
        self != .loggedWithUndoOffer
    }
}

/// A drink as a Health sample records it: when, and how much of that kind.
struct HealthSampleSnapshot: Equatable {
    let timestamp: Date
    let amount: Double

    /// Whether a sample written from `written` still matches its drink, which now looks
    /// like `current`, or is gone if that is nil.
    ///
    /// A write waits on Health, and in that time the drink can be undone, deleted or
    /// edited. Recording the sample anyway left it in Health with nothing pointing at it,
    /// or pointing at figures the drink no longer has. Such a sample is taken back out, and
    /// the next pass writes the drink as it is now, if it is still there.
    static func keepsWrittenSample(_ written: HealthSampleSnapshot, current: HealthSampleSnapshot?) -> Bool {
        current == written
    }
}

/// Samples a write had to take back out of Health but couldn't, kept by kind until a later
/// pass can delete them.
///
/// Health refuses deletes while the phone is locked. A drink's own identifier isn't enough
/// to find such a sample again: the drink may be gone, or a failed save and a rollback may
/// lose the identifier. Device-local, because only this device wrote these samples.
struct HealthTakeBackList {
    static let waterKey = "health.waterSamplesToTakeBack"
    static let caffeineKey = "health.caffeineSamplesToTakeBack"
    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func sampleIDs(caffeine: Bool) -> Set<String> {
        Set(defaults.stringArray(forKey: key(caffeine)) ?? [])
    }

    func add(_ ids: [String], caffeine: Bool) {
        guard !ids.isEmpty else { return }
        store(sampleIDs(caffeine: caffeine).union(ids), caffeine: caffeine)
    }

    func remove(_ id: String, caffeine: Bool) {
        store(sampleIDs(caffeine: caffeine).subtracting([id]), caffeine: caffeine)
    }

    /// Whether a sample can come off the list after a delete. Anything but "couldn't" will
    /// do: nothing to delete means it is already out of Health.
    static func isFinished(afterDeleting deleted: Int?) -> Bool {
        deleted != nil
    }

    private func key(_ caffeine: Bool) -> String {
        caffeine ? Self.caffeineKey : Self.waterKey
    }

    private func store(_ ids: Set<String>, caffeine: Bool) {
        defaults.set(ids.sorted(), forKey: key(caffeine))
    }
}

/// What a failed take-back leaves to do. Every sample goes on `HealthTakeBackList`, so it is
/// deleted even if its drink's identifier is lost. A drink that is still here is also
/// queued for replacement, so its current figures are written once the sample is out.
struct HealthFailedTakeBack: Equatable {
    let toTakeBack: [String]
    let toReplace: [String]

    init(_ samples: [(id: String, drinkIsLive: Bool)]) {
        toTakeBack = samples.map { $0.id }
        toReplace = samples.filter { $0.drinkIsLive }.map { $0.id }
    }
}

extension HealthReplacementQueue {
    /// Queues samples that may already be out of Health, so the replacement writes their
    /// drinks even when its own delete finds nothing.
    func addAwaitingWrite(_ ids: [String]) {
        add(ids)
        ids.forEach(markAwaitingWrite)
    }
}
