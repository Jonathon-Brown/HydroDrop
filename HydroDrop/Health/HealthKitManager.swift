import Foundation
import HealthKit
import SwiftData
import UIKit

/// Mirrors HydroDrop's drinks into Apple Health, when the user asks for it.
///
/// One direction only: HydroDrop writes dietary water, plus dietary caffeine for anyone
/// tracking caffeine with HydroDrop+, and this class never reads anything back. That is
/// why its authorization request asks to read nothing at all, and why nothing here can
/// see what any other app has written. Insights reads through HealthInsightsReader.
///
/// The design is a reconciliation rather than a hook on every write. Drinks arrive
/// from the Today screen, a notification action, the watch, and an App Intent running
/// in a widget process that has no business holding a HealthKit entitlement. Rather
/// than teach every one of those about Health, an entry simply carries the identifier
/// of its Health sample or does not, and this class makes the two agree whenever it
/// gets the chance. Since 1.9 an entry also carries a record of the figures its sample
/// was written with and of its owner, the device that wrote or claimed it (see
/// `HealthWrittenRecord`), so an edit made on any device, with sync on there or not,
/// reaches the owner, which corrects it. Another device takes over after a week.
///
/// Every sample carries a sync identifier made from its drink's own `healthSyncID`. Health
/// replaces a lower version of the same identifier instead of adding a second sample, so
/// writing the same drink again on one device never leaves two.
///
/// Deletions are the exception and are handled at the moment they happen, because once
/// the entry is gone its sample identifier goes with it.
@MainActor
final class HealthKitManager {
    static let shared = HealthKitManager()

    private let store = HKHealthStore()
    private var reconcileInFlight = false
    /// Set by a request that arrives during a pass, which then goes round once more.
    private var reconcileAgain = false
    private var backgroundTime: UIBackgroundTaskIdentifier = .invalid
    /// Set when iOS takes that time back, so the pass stops starting writes it may not finish.
    private var backgroundTimeExpired = false
    /// Set when the next pass should read every drink for one whose Health record no longer
    /// matches it (see `replacePendingSamples`). Set at launch, and by anything that can
    /// leave a drink out of step with Health: an edit here, the app coming back with
    /// whatever iCloud brought while it was away, sync or caffeine tracking being turned on.
    /// Logging a drink doesn't set it, so an ordinary reconcile stays cheap.
    private var pendingScanRequested = true

    /// Whether this device has Health at all. False on a Mac running the iPhone app, in
    /// some regions, and on an iPad before iPadOS 17.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// What every drink is written as.
    private static let waterType = HKQuantityType(.dietaryWater)
    /// Written only for subscribers who have turned caffeine tracking on, and only once
    /// Health has said yes to caffeine specifically.
    private static let caffeineType = HKQuantityType(.dietaryCaffeine)

    /// How many samples are written per round trip during a backfill, so a long
    /// history does not become one enormous save.
    private static let batchSize = 200

    private init() {}

    enum AuthorizationOutcome: Equatable {
        case granted
        /// The user said no, or had already said no in the Health app.
        case denied
        case unavailable
        case failed(String)
    }

    /// Whether HydroDrop may currently write water to Health.
    ///
    /// Health deliberately never reveals whether *reading* was refused, but sharing
    /// status is readable, and sharing is all this needs.
    var isAuthorizedToWrite: Bool {
        guard Self.isAvailable else { return false }
        return store.authorizationStatus(for: Self.waterType) == .sharingAuthorized
    }

    /// Whether HydroDrop may write caffeine. Can be false while water is allowed: they
    /// are separate switches in Health, and someone who granted water long ago has never
    /// been asked about caffeine.
    var isAuthorizedToWriteCaffeine: Bool {
        guard Self.isAvailable else { return false }
        return store.authorizationStatus(for: Self.caffeineType) == .sharingAuthorized
    }

    /// Asks the next pass to look through every drink for one whose Health samples are out
    /// of date, rather than only the ones this device is part way through.
    func requestPendingScan() {
        pendingScanRequested = true
    }

    /// Who claims a sample of this kind with no owner when its drink is edited, or when
    /// 1.8.1's queue is moved onto it: this device, if it may write that kind to Health, so
    /// it replaces the sample itself as soon as sync is on here, as 1.8.1 did.
    ///
    /// Claiming touches only the synced drink, so it needs the permission and not sync:
    /// a device with sync off still leaves Health alone. Requiring sync would make someone
    /// with one device, who edits with sync off and then turns it on, wait a week where
    /// 1.8.1 corrected it at once. The cost is rarer: a second device with sync on that
    /// edits the same drink afterwards waits a week for it too, and never gets it wrong. A
    /// device that can't write the kind claims nothing, and one with sync on takes it over
    /// after a week (see `HealthPendingWork.Wait`).
    func claimant(for kind: HealthSampleKind) -> String? {
        let allowed = kind == .water ? isAuthorizedToWrite : isAuthorizedToWriteCaffeine
        return allowed ? HealthInstall.id : nil
    }

    /// Asks Health for permission. Caffeine is only asked for when the person has
    /// caffeine tracking on, so nobody is shown a permission for a feature they do not
    /// use. Health only shows its sheet for types it has not asked about before, so an
    /// existing water user who turns caffeine on sees a sheet with caffeine alone.
    func requestAuthorization(includingCaffeine: Bool = false) async -> AuthorizationOutcome {
        guard Self.isAvailable else { return .unavailable }
        do {
            // Nothing to read. Asking for read access we would never use would put a
            // permission in front of the user that buys them nothing.
            var toShare: Set<HKSampleType> = [Self.waterType]
            if includingCaffeine { toShare.insert(Self.caffeineType) }
            try await store.requestAuthorization(toShare: toShare, read: [])
        } catch {
            Diagnostics.log("Health authorization failed: \(error)")
            return .failed(error.localizedDescription)
        }
        return isAuthorizedToWrite ? .granted : .denied
    }

    // MARK: - Writing

    /// Writes every drink that should be in Health and is not there yet.
    ///
    /// "Should be" means logged at or after the moment sync was switched on, unless the
    /// user has since asked for their history to be added, which moves that moment back.
    /// Nothing is ever written twice: an entry that already carries a sample identifier
    /// is skipped, including one that was written by another of the user's devices.
    func reconcile(context: ModelContext, settings: AppSettings = .shared) async {
        guard settings.healthKitSyncEnabled, isAuthorizedToWrite else { return }
        // A request that arrives mid-pass used to be dropped, so a drink saved after the
        // running pass had fetched waited for the next foreground. It now sends the running
        // pass round once more.
        guard !reconcileInFlight else {
            reconcileAgain = true
            // A pass that has run out of background time stops going round, so it would
            // drop this request. Fresh time lets it take this one too.
            if backgroundTimeExpired { beginBackgroundTime() }
            return
        }
        reconcileInFlight = true
        // A pass can start as the app leaves the foreground: an undo offer ending on the way
        // out, or a watch drink delivered in the background. Suspended between Health
        // accepting a sample and the drink recording it, then terminated, the next pass
        // would write that drink twice, so each pass asks for the time to finish.
        beginBackgroundTime()
        defer {
            reconcileInFlight = false
            endBackgroundTime()
        }
        repeat {
            reconcileAgain = false
            await runPass(context: context, settings: settings)
        } while reconcileAgain && mayKeepWriting(settings) && isAuthorizedToWrite
    }

    private func runPass(context: ModelContext, settings: AppSettings) async {
        await takeBackLeftovers(settings: settings)
        // First, so the drinks it rewrites carry their new identifiers before the pass
        // below looks for anything unwritten.
        await replacePendingSamples(context: context, settings: settings)
        // Turned off mid-pass: nothing more is written until sync is back on.
        guard mayKeepWriting(settings), isAuthorizedToWrite else { return }

        let start = settings.healthSyncStartDate
        let descriptor = FetchDescriptor<WaterEntry>(
            predicate: #Predicate { $0.healthKitSampleUUID == nil && $0.timestamp >= start },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        // The fetch narrows; this decides. Keeping the rule in one testable place
        // stops the predicate and the intent drifting apart.
        let pending = (try? context.fetch(descriptor))?.filter { Self.isEligible($0, since: start) } ?? []
        for batch in stride(from: 0, to: pending.count, by: Self.batchSize) {
            guard mayKeepWriting(settings) else { return }
            // Checked again after the last batch's wait on Health, in which a drink can be
            // deleted or edited.
            let slice = pending[batch..<min(batch + Self.batchSize, pending.count)]
                .filter { Self.isLive($0) && Self.isEligible($0, since: start) }
            await write(Array(slice), kind: .water, context: context)
        }

        guard mayKeepWriting(settings) else { return }
        await reconcileCaffeine(context: context, settings: settings, since: start)
    }

    /// Whether the pass may start another write to Health. Not once sync is turned off,
    /// and not once the background time has run out: suspended between Health taking a
    /// sample and the drink recording it, then terminated, the next pass would write that
    /// drink twice. The one exception is a replacement whose delete has already landed
    /// (see `replace`).
    private func mayKeepWriting(_ settings: AppSettings) -> Bool {
        settings.healthKitSyncEnabled && !backgroundTimeExpired
    }

    private func beginBackgroundTime() {
        backgroundTimeExpired = false
        guard backgroundTime == .invalid else { return }
        backgroundTime = UIApplication.shared.beginBackgroundTask(withName: "Apple Health sync") { [weak self] in
            MainActor.assumeIsolated {
                self?.backgroundTimeExpired = true
                self?.endBackgroundTime()
            }
        }
    }

    private func endBackgroundTime() {
        guard backgroundTime != .invalid else { return }
        UIApplication.shared.endBackgroundTask(backgroundTime)
        backgroundTime = .invalid
    }

    /// A drink as its sample records it, or nil once the drink has been deleted. Both the
    /// sample a write builds and the check after it come from here, so they can't disagree.
    ///
    /// Water is what HydroDrop counts, not what was poured: a 200 mL coffee contributes
    /// 180 mL to the day here and in Health alike, so the two never disagree.
    static func snapshot(of entry: WaterEntry, caffeine: Bool) -> HealthSampleSnapshot? {
        guard isLive(entry) else { return nil }
        return HealthSampleSnapshot(
            timestamp: entry.timestamp,
            amount: caffeine ? entry.drinkType.caffeineMg(in: entry.amountML) : Double(entry.hydratedML)
        )
    }

    /// A sample on its way to Health, with everything needed to record it on its drink.
    private struct PendingWrite {
        let entry: WaterEntry
        let sample: HKQuantitySample
        /// The drink as the sample records it, to check against once Health has it.
        let written: HealthSampleSnapshot
        /// What the drink's record says once the sample is in, made from the drink's own
        /// figures at the moment the sample was built.
        let record: HealthWrittenRecord
    }

    /// Takes back out of Health the samples written for drinks that were undone, deleted
    /// or edited while the write was waiting on Health.
    ///
    /// Health refuses deletes while the phone is locked, which is when a watch drink is
    /// usually written. Every such sample then goes on `HealthTakeBackList` for a later
    /// pass to delete. A drink that is still here is also pointed at its sample, with a
    /// record of the figures the sample holds, which the drink no longer has, and marked as
    /// awaiting its write, so a later pass writes its current figures once the sample is
    /// out. If the user removes the sample in Health first, the drink is still written back:
    /// the accepted cost of never leaving it out.
    private func takeBackStaleWrites(_ stale: [PendingWrite], kind: HealthSampleKind, context: ModelContext) async {
        guard !stale.isEmpty else { return }
        do {
            try await store.delete(stale.map(\.sample))
        } catch {
            let samples = stale.map { (id: $0.sample.uuid.uuidString, drinkIsLive: Self.isLive($0.entry)) }
            let failed = HealthFailedTakeBack(samples)
            for (pending, sample) in zip(stale, samples) where sample.drinkIsLive {
                pending.entry.setHealthSampleUUID(sample.id, for: kind)
                // Marked, and owned by this device like any sample it writes, so it acts on
                // it at once: the drink changed while it was being written.
                var record = pending.record
                record.editedSince = true
                pending.entry.setHealthRecord(record, for: kind)
            }
            HealthReplacementQueue().addAwaitingWrite(failed.toReplace)
            HealthTakeBackList().add(failed.toTakeBack, caffeine: kind == .caffeine)
            try? context.save()
            Diagnostics.log("could not take back \(stale.count) Health \(kind.rawValue) samples for drinks that changed, \(stale.count - failed.toReplace.count) with no drink left; trying again later: \(error)")
        }
    }

    /// Deletes the samples `takeBackStaleWrites` couldn't. Waits while the phone is locked,
    /// as replacements do, and keeps any it still can't delete. By UUID alone: by sync
    /// identifier it could take out another device's correct sample of the same drink.
    private func takeBackLeftovers(
        settings: AppSettings,
        list: HealthTakeBackList = HealthTakeBackList()
    ) async {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        for kind in HealthSampleKind.allCases {
            let caffeine = kind == .caffeine
            for sampleID in list.sampleIDs(caffeine: caffeine).sorted() {
                guard settings.healthKitSyncEnabled else { return }
                let deleted = await deleteSamples(kind, uuid: sampleID)
                if HealthTakeBackList.isFinished(afterDeleting: deleted) {
                    list.remove(sampleID, caffeine: caffeine)
                }
            }
        }
    }

    /// Replaces the samples of drinks whose figures no longer match what Health was given
    /// (see `HealthWrittenRecord`, `HealthPendingWork` and `HealthReplacementStep`).
    ///
    /// The drinks come from the records on the synced drinks, so an edit made on any device
    /// is found here, including one made where sync is off, and this device acts on the
    /// samples it owns (see `HealthPendingWork.Wait`). These ignore
    /// `healthSyncStartDate`: the drinks were already in Health, so correcting them hands
    /// Health nothing it did not have. A drink deleted since its edit is let go without
    /// touching Health, the same as a delete with sync off. Waits while the phone is locked,
    /// since Health can't delete then and every replacement starts with one, and stops
    /// between drinks if sync is turned off, leaving the rest for the next pass.
    private func replacePendingSamples(
        context: ModelContext,
        settings: AppSettings,
        queue: HealthReplacementQueue = HealthReplacementQueue(),
        notes: HealthPendingNotes = HealthPendingNotes()
    ) async {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        let scanning = pendingScanRequested
        guard scanning || !queue.awaitingWrite.isEmpty else { return }
        pendingScanRequested = false
        let candidates: [WaterEntry]
        do {
            candidates = try Self.replacementCandidates(scanning: scanning, queue: queue, in: context)
        } catch {
            // A lookup that failed is not a drink that was deleted: keep everything.
            Diagnostics.log("could not look for drinks whose Health samples are out of date: \(error)")
            if scanning { pendingScanRequested = true }
            return
        }
        let now = Date()
        let device = HealthInstall.id
        let plan = HealthPendingPlan.make(
            candidates: candidates,
            awaiting: queue.awaitingWrite,
            device: device,
            notes: notes,
            now: now
        ) { kind, entry, puttingBack in
            mayChange(kind, of: entry, puttingBack: puttingBack, settings: settings)
        }
        var finished = true
        for item in plan.due {
            guard mayKeepWriting(settings) else {
                finished = false
                break
            }
            // The drink may have been deleted or changed while an earlier one waited on
            // Health. Only work that still stands is done.
            guard Self.isLive(item.entry),
                  HealthPendingPlan.decide(item.entry, kind: item.kind, awaiting: queue.awaitingWrite, device: device).work == item.work else { continue }
            let carriesOn: Bool
            switch item.work {
            case .none:
                continue
            case .replace(let sampleID):
                carriesOn = await replace(sampleID, kind: item.kind, of: item.entry, reading: item.reading, noteKey: item.noteKey, now: now, queue: queue, notes: notes, context: context)
            case .writeIfCounts:
                carriesOn = await writeIfCounts(item.kind, of: item.entry, reading: item.reading, context: context)
            }
            guard carriesOn else {
                finished = false
                break
            }
        }
        if !finished {
            // Cut short: the next pass looks again rather than waiting for the next reason to.
            if scanning { pendingScanRequested = true }
        } else if scanning {
            notes.prune(keeping: plan.stillPending)
        }
    }

    /// Whether this device may touch a drink's samples of this kind at all. Caffeine is
    /// left alone where it isn't allowed, and, for a drink that still has caffeine, where it
    /// isn't tracked: tracking is set on each device, and a device without it deleting what
    /// a tracking device wrote would leave an older drink's caffeine out of Health for good,
    /// because only drinks since sync was turned on are written afresh. The exception is
    /// putting back a sample this device already took out, which goes ahead whatever
    /// tracking says, as a rewrite carries on after sync is turned off: otherwise the drink's
    /// caffeine would stay out of Health for good.
    private func mayChange(_ kind: HealthSampleKind, of entry: WaterEntry, puttingBack: Bool, settings: AppSettings) -> Bool {
        switch kind {
        case .water:
            return isAuthorizedToWrite
        case .caffeine:
            if puttingBack { return isAuthorizedToWriteCaffeine }
            return !Self.leavesCaffeineAlone(entry, tracked: settings.caffeineTrackingActive, authorized: isAuthorizedToWriteCaffeine)
        }
    }

    /// One replacement: marked, deleted, then written again or cleared, or let go (see
    /// `HealthReplacementStep`). Returns false when the pass has to stop.
    private func replace(
        _ sampleID: String,
        kind: HealthSampleKind,
        of entry: WaterEntry,
        reading: HealthRecordReading,
        noteKey: String,
        now: Date,
        queue: HealthReplacementQueue,
        notes: HealthPendingNotes,
        context: ModelContext
    ) async -> Bool {
        let wasAwaiting = queue.awaitingWrite.contains(sampleID)
        // Marked before the delete, so a pass cut short after Health has deleted the
        // sample isn't read next time as the user having removed it.
        queue.markAwaitingWrite(sampleID)
        let deleted = await deleteSamples(kind, uuid: sampleID, syncIdentifiers: entry.healthSyncIdentifiers(for: kind))
        // Deleted while Health was busy: that delete retired what it pointed at, and a
        // deleted drink can't be read.
        guard Self.isLive(entry) else {
            queue.remove(sampleID)
            return true
        }
        let step = HealthReplacementStep(
            deletedCount: deleted,
            wasAwaitingWrite: wasAwaiting,
            stillCounts: Self.replacementStillCounts(entry, kind: kind)
        )
        switch step {
        case .retryLater:
            queue.abandonAttempt(sampleID, wasAwaiting: wasAwaiting)
        case .letGo:
            // Left pointing at the sample, with its record as it is: the ordinary pass
            // doesn't put the drink back, a sample only another device can see is never
            // written a second time from here, and that device can still replace it.
            queue.remove(sampleID)
            notes.noteLetGo(noteKey, now: now)
        case .clear:
            let pointed = entry.healthSampleUUID(for: kind)
            let recorded = entry.healthRecordField(for: kind)
            entry.setHealthSampleUUID(nil, for: kind)
            entry.setHealthRecord(Self.nothingRecord(for: entry, after: reading, owner: HealthInstall.id), for: kind)
            do {
                try context.save()
                queue.remove(sampleID)
            } catch {
                // Put back as the store has it, and still marked, so the next pass finds the
                // drink by its sample, finds nothing to delete, sees the mark, and clears it
                // again, rather than letting go a drink that may come to count.
                entry.setHealthSampleUUID(pointed, for: kind)
                entry.setHealthRecordField(recorded, for: kind)
                Diagnostics.log("could not record a cleared Health \(kind.rawValue) sample: \(error)")
            }
        case .rewrite:
            // Out of time since the delete: left marked, the next pass writes it. Sync
            // turned off since the delete doesn't stop it. The old sample is already gone,
            // and finishing puts the drink back as it is rather than leaving it out.
            guard !backgroundTimeExpired else { return false }
            await write([entry], kind: kind, context: context)
            // Still pointing at the old sample: the write failed, and the next pass writes
            // it. Gone, or pointing elsewhere: nothing more to do for this one. If recording
            // the new identifier failed, it stays on the drink in memory for the next save,
            // unless a kill or a rollback of the context loses it. The sync identifier then
            // makes the next write replace the sample Health kept rather than add a second.
            // Crossed off only once that is saved: a mark dropped against a change the store
            // never got would leave a sample already out of Health read as let go.
            let current = Self.isLive(entry) ? entry.healthSampleUUID(for: kind) : nil
            if current != sampleID && !context.hasChanges { queue.remove(sampleID) }
        }
        return true
    }

    /// For a drink Health holds nothing of this kind for, as of figures it no longer has:
    /// written if it counts now, whatever `healthSyncStartDate` says, because Health had it
    /// once. Returns false when the pass has to stop.
    private func writeIfCounts(
        _ kind: HealthSampleKind,
        of entry: WaterEntry,
        reading: HealthRecordReading,
        context: ModelContext
    ) async -> Bool {
        if Self.replacementStillCounts(entry, kind: kind) {
            guard !backgroundTimeExpired else { return false }
            await write([entry], kind: kind, context: context)
        } else {
            entry.setHealthRecord(Self.nothingRecord(for: entry, after: reading, owner: HealthInstall.id), for: kind)
            try? context.save()
        }
        return true
    }

    /// What a drink's record says once Health holds nothing of this kind for it: its figures
    /// now, the sync identifier and version last used, so the next write goes above it, and
    /// the device that cleared it, which writes it again if it comes to count.
    static func nothingRecord(for entry: WaterEntry, after reading: HealthRecordReading, owner: String?) -> HealthWrittenRecord {
        HealthWrittenRecord(
            state: .nothing,
            sampleUUID: nil,
            syncIdentifier: reading.record?.syncIdentifier,
            syncVersion: reading.record?.syncVersion ?? 0,
            figures: HealthFigures(of: entry),
            owner: owner
        )
    }

    /// The drinks a replacement pass looks at: every drink with a record, when it has been
    /// asked to scan, and any drink carrying a sample this device marked before deleting it.
    /// A mark no drink carries any more, in a context with nothing unsaved, is dropped: its
    /// drink was deleted, and nothing is left to write back. Separate so a test can run the
    /// very predicate the pass uses.
    static func replacementCandidates(
        scanning: Bool,
        queue: HealthReplacementQueue,
        in context: ModelContext
    ) throws -> [WaterEntry] {
        var drinks: [WaterEntry] = []
        var seen = Set<PersistentIdentifier>()
        func add(_ entry: WaterEntry?) {
            guard let entry, seen.insert(entry.persistentModelID).inserted else { return }
            drinks.append(entry)
        }
        if scanning {
            let descriptor = FetchDescriptor<WaterEntry>(
                predicate: #Predicate { $0.healthWaterWritten != nil || $0.healthCaffeineWritten != nil },
                sortBy: [SortDescriptor(\.timestamp)]
            )
            try context.fetch(descriptor).forEach(add)
        }
        for sampleID in queue.awaitingWrite.sorted() {
            let found = try entries(carrying: sampleID, in: context)
            // Only against what the store holds: unsaved changes may never land.
            if found.water == nil && found.caffeine == nil && !context.hasChanges {
                queue.remove(sampleID)
            }
            add(found.water)
            add(found.caffeine)
        }
        return drinks
    }

    /// Whether an edited drink has anything of this kind to write in place of its old sample.
    ///
    /// Deliberately blind to `healthSyncStartDate`, unlike `isEligible`: a drink from before
    /// sync was turned on is corrected like any other, because Health already had it.
    /// Whether this device writes caffeine at all is decided before this is asked (see
    /// `leavesCaffeineAlone`).
    static func replacementStillCounts(_ entry: WaterEntry, kind: HealthSampleKind) -> Bool {
        switch kind {
        case .water: return entry.hydratedML > 0
        case .caffeine: return hasCaffeine(entry)
        }
    }

    static func hasCaffeine(_ entry: WaterEntry) -> Bool {
        entry.drinkType.caffeineMg(in: entry.amountML) > 0
    }

    /// Whether this device must leave a drink's caffeine sample exactly as it is: always
    /// without permission, and for a drink that still has caffeine, while caffeine isn't
    /// tracked here. A drink that no longer has any may still have its caffeine taken out.
    static func leavesCaffeineAlone(_ entry: WaterEntry, tracked: Bool, authorized: Bool) -> Bool {
        !authorized || (hasCaffeine(entry) && !tracked)
    }

    /// A Health identifier for a drink logged before 1.9, or on a device still on 1.8.1.
    /// One already in Health is named after its sample, which every device sees the same,
    /// so two devices converting it at once agree.
    static func newHealthSyncID(for entry: WaterEntry) -> String {
        if let existing = entry.healthKitSampleUUID ?? entry.caffeineSampleUUID {
            return "legacy-\(existing)"
        }
        return UUID().uuidString
    }

    /// Whether a drink can still be read. One deleted while a pass waits on Health can't be.
    static func isLive(_ entry: WaterEntry) -> Bool {
        entry.modelContext != nil && !entry.isDeleted
    }

    /// The drinks whose water or caffeine sample has this identifier. Separate so a test
    /// can run the very predicates the replacement uses.
    static func entries(
        carrying sampleID: String,
        in context: ModelContext
    ) throws -> (water: WaterEntry?, caffeine: WaterEntry?) {
        let target: String? = sampleID
        var byWater = FetchDescriptor<WaterEntry>(predicate: #Predicate { $0.healthKitSampleUUID == target })
        byWater.fetchLimit = 1
        var byCaffeine = FetchDescriptor<WaterEntry>(predicate: #Predicate { $0.caffeineSampleUUID == target })
        byCaffeine.fetchLimit = 1
        return (try context.fetch(byWater).first, try context.fetch(byCaffeine).first)
    }

    /// The same pass, for caffeine. Never asks for permission: a reconcile runs in the
    /// background of ordinary use, and a Health sheet appearing because a coffee was
    /// logged would be the wrong moment. Permission is asked for in Settings, when
    /// caffeine tracking is turned on.
    private func reconcileCaffeine(context: ModelContext, settings: AppSettings, since start: Date) async {
        guard settings.caffeineTrackingActive, isAuthorizedToWriteCaffeine else { return }
        let descriptor = FetchDescriptor<WaterEntry>(
            predicate: #Predicate { $0.caffeineSampleUUID == nil && $0.timestamp >= start },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        let pending = (try? context.fetch(descriptor))?.filter { Self.isCaffeineEligible($0, since: start) } ?? []
        for batch in stride(from: 0, to: pending.count, by: Self.batchSize) {
            guard mayKeepWriting(settings) else { return }
            let slice = pending[batch..<min(batch + Self.batchSize, pending.count)]
                .filter { Self.isLive($0) && Self.isCaffeineEligible($0, since: start) }
            await write(Array(slice), kind: .caffeine, context: context)
        }
    }

    /// Whether a drink's caffeine belongs in Health and is not there yet.
    static func isCaffeineEligible(_ entry: WaterEntry, since start: Date) -> Bool {
        entry.caffeineSampleUUID == nil
            && entry.timestamp >= start
            && entry.drinkType.caffeineMg(in: entry.amountML) > 0
            && !isLeftToReplacement(entry, kind: .caffeine)
    }

    /// Whether a drink belongs in Health and is not there yet.
    ///
    /// A drink logged before the user turned sync on is not eligible, which is what
    /// keeps "on" from meaning "and hand over everything that came before". Asking for
    /// the backfill moves `start` to the distant past, which makes everything eligible.
    static func isEligible(_ entry: WaterEntry, since start: Date) -> Bool {
        entry.healthKitSampleUUID == nil
            && entry.timestamp >= start
            && entry.hydratedML > 0
            && !isLeftToReplacement(entry, kind: .water)
    }

    /// Whether a drink a replacement cleared is left to the replacement to write again.
    ///
    /// Its record says Health holds nothing of this kind as of figures it no longer has,
    /// which is how the replacement finds it, and the replacement writes it under the
    /// owner's rules. The ordinary pass writing it too, at once and on any device, is the
    /// race between two devices those rules exist to avoid.
    static func isLeftToReplacement(_ entry: WaterEntry, kind: HealthSampleKind) -> Bool {
        guard let record = entry.healthRecord(for: kind).record else { return false }
        return record.state == .nothing && !record.isVoid(currentUUID: entry.healthSampleUUID(for: kind))
    }

    /// Writes drinks' samples of one kind, each under its drink's sync identifier, and
    /// records on each drink the sample and the figures Health was given.
    ///
    /// A drink without a Health identifier gets one first, saved before Health sees a
    /// sample carrying it: an identifier lost to a kill after Health took the sample would
    /// give the next write a different one, and Health two samples.
    private func write(_ entries: [WaterEntry], kind: HealthSampleKind, context: ModelContext) async {
        let assigned = entries.filter { Self.isLive($0) && $0.healthSyncID == nil }
        for entry in assigned {
            entry.healthSyncID = Self.newHealthSyncID(for: entry)
        }
        if !assigned.isEmpty {
            do {
                try context.save()
            } catch {
                // Taken back, so no later write goes under an identifier the store never got.
                assigned.forEach { $0.healthSyncID = nil }
                Diagnostics.log("could not record new Health identifiers, so nothing is written this pass: \(error)")
                return
            }
        }

        // Each sample's identifier exists as soon as it is constructed, so the entries
        // can be matched to their samples before the save rather than searched for after.
        var pending: [PendingWrite] = []
        let device = HealthInstall.id
        for entry in entries {
            guard let written = Self.snapshot(of: entry, caffeine: kind == .caffeine),
                  let base = entry.healthSyncID else { continue }
            let identifier = WaterEntry.healthSyncIdentifier(base: base, kind: kind)
            let version = HealthWrittenRecord.nextVersion(after: entry.healthRecord(for: kind).record?.syncVersion ?? 0)
            let sample = HKQuantitySample(
                type: Self.sampleType(kind),
                quantity: HKQuantity(unit: Self.unit(kind), doubleValue: written.amount),
                start: written.timestamp,
                end: written.timestamp,
                metadata: [
                    HKMetadataKeySyncIdentifier: identifier,
                    HKMetadataKeySyncVersion: NSNumber(value: version),
                ]
            )
            let record = HealthWrittenRecord(
                state: .written,
                sampleUUID: sample.uuid.uuidString,
                syncIdentifier: identifier,
                syncVersion: version,
                figures: HealthFigures(of: entry),
                owner: device
            )
            pending.append(PendingWrite(entry: entry, sample: sample, written: written, record: record))
        }
        guard !pending.isEmpty else { return }

        do {
            try await store.save(pending.map(\.sample))
        } catch {
            // Left unmarked on purpose, so the next reconcile tries again rather than
            // quietly dropping the drink from Health for good.
            Diagnostics.log("could not write \(kind.rawValue) for \(pending.count) drinks to Health: \(error)")
            return
        }

        var stale: [PendingWrite] = []
        for write in pending {
            if HealthSampleSnapshot.keepsWrittenSample(write.written, current: Self.snapshot(of: write.entry, caffeine: kind == .caffeine)) {
                write.entry.setHealthSampleUUID(write.sample.uuid.uuidString, for: kind)
                write.entry.setHealthRecord(write.record, for: kind)
            } else {
                stale.append(write)
            }
        }
        do {
            try context.save()
        } catch {
            Diagnostics.log("could not record Health \(kind.rawValue) sample identifiers: \(error)")
        }
        // After the identifiers are saved, so nothing waits on Health while they aren't.
        await takeBackStaleWrites(stale, kind: kind, context: context)
    }

    private static func sampleType(_ kind: HealthSampleKind) -> HKQuantityType {
        switch kind {
        case .water: return waterType
        case .caffeine: return caffeineType
        }
    }

    private static func unit(_ kind: HealthSampleKind) -> HKUnit {
        switch kind {
        case .water: return .literUnit(with: .milli)
        case .caffeine: return .gramUnit(with: .milli)
        }
    }

    // MARK: - Deleting

    /// Removes a sample HydroDrop wrote, found by its UUID or by any of the sync
    /// identifiers given.
    ///
    /// Only ever deletes samples this app saved, so nothing another app or the user put in
    /// Health can be touched by it. A sample that is not there any more, on a device that
    /// never had it, simply deletes nothing. The sync identifiers find the sample under
    /// whatever UUID it has here: another device's copy, or the one Health kept when it
    /// dropped a save of a lower version while still reporting success, which leaves a
    /// drink pointing at a UUID Health never kept.
    /// Returns how many samples it deleted, or nil if the delete couldn't be done.
    @discardableResult
    func deleteSamples(_ kind: HealthSampleKind, uuid: String?, syncIdentifiers: [String] = []) async -> Int? {
        let allowed = kind == .water ? isAuthorizedToWrite : isAuthorizedToWriteCaffeine
        guard Self.isAvailable, allowed else { return nil }
        var predicates: [NSPredicate] = []
        if let uuid, let parsed = UUID(uuidString: uuid) {
            predicates.append(HKQuery.predicateForObjects(with: [parsed]))
        }
        if !syncIdentifiers.isEmpty {
            predicates.append(HKQuery.predicateForObjects(
                withMetadataKey: HKMetadataKeySyncIdentifier,
                allowedValues: syncIdentifiers
            ))
        }
        guard let first = predicates.first else { return nil }
        let predicate = predicates.count == 1 ? first : NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        return await withCheckedContinuation { continuation in
            store.deleteObjects(of: Self.sampleType(kind), predicate: predicate) { success, count, error in
                if let error {
                    Diagnostics.log("could not delete a Health \(kind.rawValue) sample: \(error)")
                }
                continuation.resume(returning: success && error == nil ? count : nil)
            }
        }
    }
}
