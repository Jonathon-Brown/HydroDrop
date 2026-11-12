import Foundation
import SwiftData

/// The Health side of `HealthTombstone`. Kept out of the model's own file, which the
/// widget compiles and which must not need anything from Health.
extension HealthTombstone {
    convenience init(_ reference: HealthSampleReference, createdAt: Date = Date()) {
        self.init(
            kindRawValue: reference.kind.rawValue,
            sampleUUID: reference.uuid,
            syncIdentifiers: reference.syncIdentifiers,
            createdAt: createdAt
        )
    }

    /// Nil for a kind this version does not know, written by a later one. Such a tombstone
    /// is left for a device that does, and expires like any other.
    var kind: HealthSampleKind? {
        HealthSampleKind(rawValue: kindRawValue)
    }

    /// What a delete looks for, as `HealthKitManager.deleteSamples` wants it.
    var reference: HealthSampleReference? {
        kind.map { HealthSampleReference(kind: $0, uuid: sampleUUID, syncIdentifiers: syncIdentifierList) }
    }

    /// Leaves one tombstone per kind (water, caffeine) for each drink about to be deleted
    /// that Health has or had, in the same context as the delete, so the two land in one
    /// save and no device ever sees the drink gone without the tombstones that go with it.
    /// Nothing for a drink Health never had: every drink carries a sync identifier from the
    /// start, so this used to leave two tombstones for every delete, and with Health off on
    /// every device nothing ever swept them out of iCloud. The cost, accepted: a sample
    /// another device wrote moments before this device deletes the drink, before that
    /// device's record arrives, gets no tombstone and stays in that device's Health.
    static func leave(for entries: [WaterEntry], in context: ModelContext, now: Date = Date()) {
        for sample in entries.filter(\.hasHealthSamplesOrRecords).flatMap(HealthSampleReference.all(of:)) {
            context.insert(HealthTombstone(sample, createdAt: now))
        }
    }
}
