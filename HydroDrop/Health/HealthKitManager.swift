import Foundation
import HealthKit
import SwiftData

/// Mirrors HydroDrop's drinks into Apple Health, when the user asks for it.
///
/// One direction only, and one type only: HydroDrop writes dietary water and never
/// reads anything back. That is why the authorization request asks to share and to
/// read nothing at all, and why nothing here can see what any other app has written.
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

    /// Whether this device has Health at all. False on iPad and in some regions.
    static var isAvailable: Bool { HKHealthStore.isHealthDataAvailable() }

    /// The only type HydroDrop touches.
    private static let waterType = HKQuantityType(.dietaryWater)

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

    func requestAuthorization() async -> AuthorizationOutcome {
        guard Self.isAvailable else { return .unavailable }
        do {
            // Nothing to read. Asking for read access we would never use would put a
            // permission in front of the user that buys them nothing.
            try await store.requestAuthorization(toShare: [Self.waterType], read: [])
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
        guard !reconcileInFlight else { return }
        reconcileInFlight = true
        defer { reconcileInFlight = false }

        let start = settings.healthSyncStartDate
        let descriptor = FetchDescriptor<WaterEntry>(
            predicate: #Predicate { $0.healthKitSampleUUID == nil && $0.timestamp >= start },
            sortBy: [SortDescriptor(\.timestamp)]
        )
        // The fetch narrows; this decides. Keeping the rule in one testable place
        // stops the predicate and the intent drifting apart.
        let pending = (try? context.fetch(descriptor))?.filter { Self.isEligible($0, since: start) } ?? []
        guard !pending.isEmpty else { return }

        for batch in stride(from: 0, to: pending.count, by: Self.batchSize) {
            let slice = Array(pending[batch..<min(batch + Self.batchSize, pending.count)])
            await write(slice, context: context)
        }
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
        var samplesByEntry: [(entry: WaterEntry, sample: HKQuantitySample)] = []
        for entry in entries {
            // What HydroDrop counts, not what was poured: a 200 mL coffee contributes
            // 180 mL to the day here and in Health alike, so the two never disagree.
            let hydrated = entry.hydratedML
            let quantity = HKQuantity(unit: .literUnit(with: .milli), doubleValue: Double(hydrated))
            let sample = HKQuantitySample(
                type: Self.waterType,
                quantity: quantity,
                start: entry.timestamp,
                end: entry.timestamp
            )
            samplesByEntry.append((entry, sample))
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

        for pair in samplesByEntry {
            pair.entry.healthKitSampleUUID = pair.sample.uuid.uuidString
        }
        do {
            try context.save()
        } catch {
            Diagnostics.log("could not record Health sample identifiers: \(error)")
        }
    }

    // MARK: - Deleting

    /// Removes a sample HydroDrop wrote.
    ///
    /// Only ever deletes by the identifier of a sample this app saved, so nothing
    /// another app or the user put in Health can be touched by it. A sample that is not
    /// there any more, on a device that never had it, simply deletes nothing.
    func deleteSample(uuidString: String?) async {
        guard let uuidString, let uuid = UUID(uuidString: uuidString) else { return }
        guard Self.isAvailable, isAuthorizedToWrite else { return }

        let predicate = HKQuery.predicateForObjects(with: [uuid])
        await withCheckedContinuation { continuation in
            store.deleteObjects(of: Self.waterType, predicate: predicate) { _, _, error in
                if let error {
                    Diagnostics.log("could not delete a Health sample: \(error)")
                }
                continuation.resume()
            }
        }
    }
}
