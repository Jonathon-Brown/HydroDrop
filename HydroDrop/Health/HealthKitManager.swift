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
/// gets the chance.
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

    /// Whether this device has Health at all. False on iPad and in some regions.
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
        await replaceQueuedSamples(context: context, settings: settings)
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
            await write(Array(slice), context: context)
        }

        guard mayKeepWriting(settings) else { return }
        await reconcileCaffeine(context: context, settings: settings, since: start)
    }

    /// Whether the pass may start another write to Health. Not once sync is turned off,
    /// and not once the background time has run out: suspended between Health taking a
    /// sample and the drink recording it, then terminated, the next pass would write that
    /// drink twice. The one exception is a replacement whose delete has already landed
    /// (see `replaceQueuedSamples`).
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

    /// Takes back out of Health the samples written for drinks that were undone, deleted
    /// or edited while the write was waiting on Health.
    ///
    /// Health refuses deletes while the phone is locked, which is when a watch drink is
    /// usually written. Every such sample then goes on `HealthTakeBackList` for a later
    /// pass to delete. A drink that is still here is also pointed at its sample and queued
    /// for replacement, marked as awaiting its write, so that pass writes its current
    /// figures once the sample is out. If the user removes the sample in Health first, the
    /// drink is still written back: the accepted cost of never leaving it out.
    private func takeBackStaleWrites(
        _ stale: [(entry: WaterEntry, sample: HKQuantitySample)],
        caffeine: Bool,
        context: ModelContext
    ) async {
        guard !stale.isEmpty else { return }
        do {
            try await store.delete(stale.map(\.sample))
        } catch {
            let samples = stale.map { (id: $0.sample.uuid.uuidString, drinkIsLive: Self.isLive($0.entry)) }
            let failed = HealthFailedTakeBack(samples)
            for (pair, sample) in zip(stale, samples) where sample.drinkIsLive {
                if caffeine { pair.entry.caffeineSampleUUID = sample.id } else { pair.entry.healthKitSampleUUID = sample.id }
            }
            HealthReplacementQueue().addAwaitingWrite(failed.toReplace)
            HealthTakeBackList().add(failed.toTakeBack, caffeine: caffeine)
            try? context.save()
            Diagnostics.log("could not take back \(stale.count) Health samples for drinks that changed, \(stale.count - failed.toReplace.count) with no drink left; trying again later: \(error)")
        }
    }

    /// Deletes the samples `takeBackStaleWrites` couldn't. Waits while the phone is locked,
    /// as replacements do, and keeps any it still can't delete.
    private func takeBackLeftovers(
        settings: AppSettings,
        list: HealthTakeBackList = HealthTakeBackList()
    ) async {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        for caffeine in [false, true] {
            for sampleID in list.sampleIDs(caffeine: caffeine).sorted() {
                guard settings.healthKitSyncEnabled else { return }
                let deleted = caffeine
                    ? await deleteCaffeineSample(uuidString: sampleID)
                    : await deleteSample(uuidString: sampleID)
                if HealthTakeBackList.isFinished(afterDeleting: deleted) {
                    list.remove(sampleID, caffeine: caffeine)
                }
            }
        }
    }

    /// Replaces the samples of edited drinks with their corrected figures (see
    /// `HealthEditPlan` and `HealthReplacementStep`).
    ///
    /// These ignore `healthSyncStartDate`: the drinks were already in Health, so correcting
    /// them hands Health nothing it did not have. A drink deleted since its edit is let go
    /// without touching Health, the same as a delete with sync off. Waits while the phone
    /// is locked, since Health can't delete then and every replacement starts with one, and
    /// stops between drinks if sync is turned off, leaving the rest queued.
    private func replaceQueuedSamples(
        context: ModelContext,
        settings: AppSettings,
        queue: HealthReplacementQueue = HealthReplacementQueue()
    ) async {
        guard UIApplication.shared.isProtectedDataAvailable else { return }
        for sampleID in queue.sampleIDs.sorted() {
            guard mayKeepWriting(settings) else { return }
            let found: (water: WaterEntry?, caffeine: WaterEntry?)
            do {
                found = try Self.entries(carrying: sampleID, in: context)
            } catch {
                // A lookup that failed is not a drink that was deleted: keep the queue.
                Diagnostics.log("could not look up an edited drink's Health sample: \(error)")
                return
            }
            guard let entry = found.water ?? found.caffeine else {
                queue.remove(sampleID)
                continue
            }
            let isWater = found.water != nil
            let wasAwaiting = queue.awaitingWrite.contains(sampleID)
            // Marked before the delete, so a pass cut short after Health has deleted the
            // sample isn't read next time as the user having removed it.
            queue.markAwaitingWrite(sampleID)
            let deleted = isWater
                ? await deleteSample(uuidString: sampleID)
                : await deleteCaffeineSample(uuidString: sampleID)
            // Deleted while Health was busy: that delete retired what it pointed at, and a
            // deleted drink can't be read.
            guard Self.isLive(entry) else {
                queue.remove(sampleID)
                continue
            }
            let step = HealthReplacementStep(
                deletedCount: deleted,
                wasAwaitingWrite: wasAwaiting,
                stillCounts: Self.replacementStillCounts(
                    entry, water: isWater, caffeineTracked: settings.caffeineTrackingActive
                )
            )
            switch step {
            case .retryLater:
                queue.abandonAttempt(sampleID, wasAwaiting: wasAwaiting)
            case .letGo:
                // Left pointing at the sample the user removed, so the ordinary pass doesn't
                // put the drink back, and a sample only another device can see is never
                // written a second time.
                queue.remove(sampleID)
            case .clear:
                if isWater { entry.healthKitSampleUUID = nil } else { entry.caffeineSampleUUID = nil }
                try? context.save()
                queue.remove(sampleID)
            case .rewrite:
                // Out of time since the delete: left queued and marked, the next pass writes it.
                // Sync turned off since the delete doesn't stop it. The old sample is already
                // gone, and finishing puts the drink back as it is rather than leaving it out.
                guard !backgroundTimeExpired else { return }
                if isWater {
                    await write([entry], context: context)
                } else {
                    await writeCaffeine([entry], context: context)
                }
                // Still pointing at the old sample: the write failed, and the next pass
                // writes it. Gone, or pointing elsewhere: nothing more to do for this one. If
                // recording the new identifier failed, it stays on the drink in memory for the
                // next save, unless a kill or a rollback of the context loses it. Health then
                // keeps the corrected sample with nothing pointing at it, which is still better
                // than queueing again and writing the drink a second time.
                let current = Self.isLive(entry) ? (isWater ? entry.healthKitSampleUUID : entry.caffeineSampleUUID) : nil
                if current != sampleID { queue.remove(sampleID) }
            }
        }
    }

    /// Whether an edited drink has anything of this kind to write in place of its old sample.
    ///
    /// Deliberately blind to `healthSyncStartDate`, unlike `isEligible`: a drink from before
    /// sync was turned on is corrected like any other, because Health already had it.
    /// Caffeine is written again only while it is tracked. Otherwise the old, now wrong
    /// figure still goes, as it does when a drink is deleted.
    static func replacementStillCounts(_ entry: WaterEntry, water: Bool, caffeineTracked: Bool) -> Bool {
        water
            ? entry.hydratedML > 0
            : caffeineTracked && entry.drinkType.caffeineMg(in: entry.amountML) > 0
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
            await writeCaffeine(Array(slice), context: context)
        }
    }

    /// Whether a drink's caffeine belongs in Health and is not there yet.
    static func isCaffeineEligible(_ entry: WaterEntry, since start: Date) -> Bool {
        entry.caffeineSampleUUID == nil
            && entry.timestamp >= start
            && entry.drinkType.caffeineMg(in: entry.amountML) > 0
    }

    private func writeCaffeine(_ entries: [WaterEntry], context: ModelContext) async {
        var samplesByEntry: [(entry: WaterEntry, sample: HKQuantitySample, written: HealthSampleSnapshot)] = []
        for entry in entries {
            guard let written = Self.snapshot(of: entry, caffeine: true) else { continue }
            let quantity = HKQuantity(unit: .gramUnit(with: .milli), doubleValue: written.amount)
            let sample = HKQuantitySample(
                type: Self.caffeineType,
                quantity: quantity,
                start: written.timestamp,
                end: written.timestamp
            )
            samplesByEntry.append((entry, sample, written))
        }
        guard !samplesByEntry.isEmpty else { return }

        do {
            try await store.save(samplesByEntry.map(\.sample))
        } catch {
            Diagnostics.log("could not write caffeine for \(samplesByEntry.count) drinks to Health: \(error)")
            return
        }
        var stale: [(entry: WaterEntry, sample: HKQuantitySample)] = []
        for pair in samplesByEntry {
            if HealthSampleSnapshot.keepsWrittenSample(pair.written, current: Self.snapshot(of: pair.entry, caffeine: true)) {
                pair.entry.caffeineSampleUUID = pair.sample.uuid.uuidString
            } else {
                stale.append((pair.entry, pair.sample))
            }
        }
        do {
            try context.save()
        } catch {
            Diagnostics.log("could not record Health caffeine sample identifiers: \(error)")
        }
        // After the identifiers are saved, so nothing waits on Health while they aren't.
        await takeBackStaleWrites(stale, caffeine: true, context: context)
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
    }

    private func write(_ entries: [WaterEntry], context: ModelContext) async {
        // Each sample's identifier exists as soon as it is constructed, so the entries
        // can be matched to their samples before the save rather than searched for after.
        var samplesByEntry: [(entry: WaterEntry, sample: HKQuantitySample, written: HealthSampleSnapshot)] = []
        for entry in entries {
            guard let written = Self.snapshot(of: entry, caffeine: false) else { continue }
            let quantity = HKQuantity(unit: .literUnit(with: .milli), doubleValue: written.amount)
            let sample = HKQuantitySample(
                type: Self.waterType,
                quantity: quantity,
                start: written.timestamp,
                end: written.timestamp
            )
            samplesByEntry.append((entry, sample, written))
        }
        guard !samplesByEntry.isEmpty else { return }

        do {
            try await store.save(samplesByEntry.map(\.sample))
        } catch {
            // Left unmarked on purpose, so the next reconcile tries again rather than
            // quietly dropping the drink from Health for good.
            Diagnostics.log("could not write \(samplesByEntry.count) drinks to Health: \(error)")
            return
        }

        var stale: [(entry: WaterEntry, sample: HKQuantitySample)] = []
        for pair in samplesByEntry {
            if HealthSampleSnapshot.keepsWrittenSample(pair.written, current: Self.snapshot(of: pair.entry, caffeine: false)) {
                pair.entry.healthKitSampleUUID = pair.sample.uuid.uuidString
            } else {
                stale.append((pair.entry, pair.sample))
            }
        }
        do {
            try context.save()
        } catch {
            Diagnostics.log("could not record Health sample identifiers: \(error)")
        }
        await takeBackStaleWrites(stale, caffeine: false, context: context)
    }

    // MARK: - Deleting

    /// Removes a sample HydroDrop wrote.
    ///
    /// Only ever deletes by the identifier of a sample this app saved, so nothing
    /// another app or the user put in Health can be touched by it. A sample that is not
    /// there any more, on a device that never had it, simply deletes nothing.
    /// The same, for a caffeine sample. A drink that is deleted takes its caffeine out of
    /// Health with it.
    /// Both return how many samples they deleted, or nil if the delete couldn't be done.
    @discardableResult
    func deleteCaffeineSample(uuidString: String?) async -> Int? {
        guard let uuidString, let uuid = UUID(uuidString: uuidString) else { return nil }
        guard Self.isAvailable, isAuthorizedToWriteCaffeine else { return nil }
        let predicate = HKQuery.predicateForObjects(with: [uuid])
        return await withCheckedContinuation { continuation in
            store.deleteObjects(of: Self.caffeineType, predicate: predicate) { success, count, error in
                if let error {
                    Diagnostics.log("could not delete a Health caffeine sample: \(error)")
                }
                continuation.resume(returning: success && error == nil ? count : nil)
            }
        }
    }

    @discardableResult
    func deleteSample(uuidString: String?) async -> Int? {
        guard let uuidString, let uuid = UUID(uuidString: uuidString) else { return nil }
        guard Self.isAvailable, isAuthorizedToWrite else { return nil }

        let predicate = HKQuery.predicateForObjects(with: [uuid])
        return await withCheckedContinuation { continuation in
            store.deleteObjects(of: Self.waterType, predicate: predicate) { success, count, error in
                if let error {
                    Diagnostics.log("could not delete a Health sample: \(error)")
                }
                continuation.resume(returning: success && error == nil ? count : nil)
            }
        }
    }
}
