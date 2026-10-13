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

    /// Leaves one tombstone per sample a drink about to be deleted has, in the same
    /// context as the delete, so the two land in one save and no device ever sees the
    /// drink gone without the tombstones that go with it. Nothing for a drink Health
    /// never had.
    static func leave(for samples: [HealthSampleReference], in context: ModelContext, now: Date = Date()) {
        for sample in samples {
            context.insert(HealthTombstone(sample, createdAt: now))
        }
    }
}
