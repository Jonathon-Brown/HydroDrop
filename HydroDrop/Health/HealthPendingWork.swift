import Foundation

/// What the replacement pass does about one kind of one drink, read from the drink's
/// record of what Health holds (see `HealthWrittenRecord`).
enum HealthPendingWork: Equatable {
    /// Nothing: Health has what the drink says, or nothing is known about it.
    case none
    /// Take the drink's current sample out and write the drink again.
    case replace(sampleUUID: String)
    /// Health holds nothing of this kind for the drink. Write it if it counts now.
    case writeIfCounts

    /// How soon this device may do the work, counted from when it first saw it.
    enum Wait: Equatable {
        /// This device owns the sample and a 1.9 edit marked the change, or this device took
        /// the sample out of its own Health and must put the drink back.
        case none
        /// This device owns the sample, but no 1.9 edit marked the change, so a device still
        /// on 1.8.1 made it. With sync on there, that device replaces the sample itself,
        /// with one that has no sync identifier, and its new UUID voids the record. Acting
        /// sooner would race it and leave two samples.
        case aDay
        /// Another device owns the sample, or nobody does. Two devices replacing the same
        /// sample at once might leave two samples, so this one waits long enough for the
        /// owner to have done it, and takes over only if it hasn't: the owner is gone, or
        /// has sync off.
        case aWeek

        var interval: TimeInterval {
            switch self {
            case .none: return 0
            case .aDay: return 24 * 60 * 60
            case .aWeek: return 7 * 24 * 60 * 60
            }
        }
    }

    /// - Parameters:
    ///   - reading: the drink's record for this kind.
    ///   - currentUUID: the drink's own identifier for this kind's sample.
    ///   - current: the drink's figures now.
    ///   - isAwaitingWrite: this device marked `currentUUID` before deleting it, so it may
    ///     already have taken it out of its own Health and must write it back.
    ///   - device: this device (`HealthInstall.id`), to tell its own samples from others'.
    static func decide(
        reading: HealthRecordReading,
        currentUUID: String?,
        current: HealthFigures,
        isAwaitingWrite: Bool,
        device: String?
    ) -> (work: HealthPendingWork, wait: Wait) {
        if let currentUUID, isAwaitingWrite {
            return (.replace(sampleUUID: currentUUID), .none)
        }
        guard let record = reading.record else { return (.none, .none) }
        let owned = device != nil && record.owner == device
        if record.isVoid(currentUUID: currentUUID) {
            // A 1.9 edit happened, and something that doesn't write records changed the
            // sample since, so whatever the drink points at now is out of date. Nobody owns
            // that sample.
            if record.editedSince, let currentUUID {
                return (.replace(sampleUUID: currentUUID), .aWeek)
            }
            return (.none, .none)
        }
        switch record.state {
        case .stale:
            return (.replace(sampleUUID: currentUUID ?? ""), owned ? .none : .aWeek)
        case .written:
            guard let written = record.figures, let currentUUID, !written.matches(current) else { return (.none, .none) }
            return (.replace(sampleUUID: currentUUID), wait(owned: owned, marked: record.editedSince))
        case .nothing:
            guard let written = record.figures, !written.matches(current) else { return (.none, .none) }
            return (.writeIfCounts, wait(owned: owned, marked: record.editedSince))
        }
    }

    private static func wait(owned: Bool, marked: Bool) -> Wait {
        guard owned else { return .aWeek }
        return marked ? .none : .aDay
    }

    /// Whether work first seen at `firstSeen` may be done at `now`.
    static func isDue(_ wait: Wait, firstSeen: Date, now: Date) -> Bool {
        now.timeIntervalSince(firstSeen) >= wait.interval
    }
}

extension HealthWrittenRecord {
    /// Whether something that doesn't write records (1.8.1) changed the drink's sample of
    /// this kind since this was written. A void record describes nothing Health holds.
    func isVoid(currentUUID: String?) -> Bool {
        switch state {
        case .written, .stale:
            return sampleUUID != currentUUID
        case .nothing:
            return currentUUID != nil
        }
    }
}

/// What this device remembers about pending replacements, kept in its own defaults because
/// both notes are about this device's Health store and this device's own view.
struct HealthPendingNotes {
    /// When this device first saw each change it has to wait on (see `HealthPendingWork.Wait`).
    static let firstSeenKey = "health.pendingFirstSeen"
    /// When this device last found nothing to delete for a pending drink and let it go.
    static let letGoKey = "health.replacementsLetGo"
    /// How long a let-go stands before this device looks again. Health sync may only have
    /// been late in bringing the sample, and looking again is safe: finding nothing still
    /// writes nothing.
    static let letGoLasts: TimeInterval = 7 * 24 * 60 * 60

    let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Everything a note depends on, so a changed record or a new sample is looked at
    /// afresh rather than under an old note.
    static func key(kind: HealthSampleKind, currentUUID: String?, field: String?) -> String {
        [kind.rawValue, currentUUID ?? "", field ?? ""].joined(separator: "#")
    }

    /// When a change was first seen, noting now if it is new.
    func firstSeen(_ key: String, now: Date) -> Date {
        var notes = read(Self.firstSeenKey)
        if let seen = notes[key] { return seen }
        notes[key] = now
        defaults.set(notes, forKey: Self.firstSeenKey)
        return now
    }

    func hasLetGo(_ key: String, now: Date) -> Bool {
        guard let when = read(Self.letGoKey)[key] else { return false }
        return now.timeIntervalSince(when) < Self.letGoLasts
    }

    func noteLetGo(_ key: String, now: Date) {
        var notes = read(Self.letGoKey)
        notes[key] = now
        defaults.set(notes, forKey: Self.letGoKey)
    }

    /// Forgets notes about anything no longer pending, after a pass that looked at every
    /// drink, so the notes never outgrow the work.
    func prune(keeping keys: Set<String>) {
        for storeKey in [Self.firstSeenKey, Self.letGoKey] {
            let notes = read(storeKey)
            let kept = notes.filter { keys.contains($0.key) }
            if kept.count != notes.count {
                defaults.set(kept, forKey: storeKey)
            }
        }
    }

    private func read(_ storeKey: String) -> [String: Date] {
        (defaults.dictionary(forKey: storeKey) as? [String: Date]) ?? [:]
    }
}

/// One piece of work the replacement pass may do now.
struct HealthPendingItem {
    let entry: WaterEntry
    let kind: HealthSampleKind
    let work: HealthPendingWork
    let reading: HealthRecordReading
    /// This change's key in `HealthPendingNotes`.
    let noteKey: String
}

/// What the replacement pass will do, decided in one go before it touches Health.
///
/// Separate from the pass, which has to wait on Health, so the rules that decide who
/// replaces what, and when, can be tested as they run: the owner acts at once, anyone else
/// only after a week, a let-go stands for a week, and caffeine is left alone where this
/// device may not touch it.
struct HealthPendingPlan {
    /// The work that may be done now, in order.
    var due: [HealthPendingItem] = []
    /// Every change still pending here, due or not, so notes about anything else can go.
    var stillPending: Set<String> = []

    /// - Parameters:
    ///   - candidates: the drinks to look at (see `HealthKitManager.replacementCandidates`).
    ///   - awaiting: the samples this device marked before deleting them, read once.
    ///   - device: this device (`HealthInstall.id`).
    ///   - mayChange: whether this device may touch this kind of this drink at all, given
    ///     whether the work only puts back a sample this device already took out.
    @MainActor
    static func make(
        candidates: [WaterEntry],
        awaiting: Set<String>,
        device: String?,
        notes: HealthPendingNotes,
        now: Date,
        mayChange: (HealthSampleKind, WaterEntry, _ puttingBack: Bool) -> Bool
    ) -> HealthPendingPlan {
        var plan = HealthPendingPlan()
        for entry in candidates where HealthKitManager.isLive(entry) {
            for kind in HealthSampleKind.allCases {
                let decision = decide(entry, kind: kind, awaiting: awaiting, device: device)
                guard decision.work != .none else { continue }
                let key = HealthPendingNotes.key(kind: kind, currentUUID: entry.healthSampleUUID(for: kind), field: entry.healthRecordField(for: kind))
                plan.stillPending.insert(key)
                let puttingBack = entry.healthSampleUUID(for: kind).map(awaiting.contains) ?? false
                guard !notes.hasLetGo(key, now: now),
                      decision.wait == .none || HealthPendingWork.isDue(decision.wait, firstSeen: notes.firstSeen(key, now: now), now: now),
                      mayChange(kind, entry, puttingBack) else { continue }
                plan.due.append(HealthPendingItem(
                    entry: entry,
                    kind: kind,
                    work: decision.work,
                    reading: entry.healthRecord(for: kind),
                    noteKey: key
                ))
            }
        }
        return plan
    }

    /// What one kind of one drink needs now. The pass asks again just before acting, since
    /// the drink may have changed while it waited on Health for another.
    static func decide(
        _ entry: WaterEntry,
        kind: HealthSampleKind,
        awaiting: Set<String>,
        device: String?
    ) -> (work: HealthPendingWork, wait: HealthPendingWork.Wait) {
        let sampleID = entry.healthSampleUUID(for: kind)
        return HealthPendingWork.decide(
            reading: entry.healthRecord(for: kind),
            currentUUID: sampleID,
            current: HealthFigures(of: entry),
            isAwaitingWrite: sampleID.map(awaiting.contains) ?? false,
            device: device
        )
    }
}
