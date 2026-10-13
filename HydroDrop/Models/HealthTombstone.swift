import Foundation
import SwiftData

/// A Health sample whose drink is gone, left for whichever device holds the sample to
/// delete.
///
/// A drink's samples are taken out of Health at the moment the drink is deleted, on the
/// device that deleted it, and the drink takes the only record of which samples were its
/// with it. So a drink deleted where Health sync was off, or on a device that never wrote
/// the sample, stayed in Health on the device that did: nothing there ever learned the
/// sample's identifier again, and the privacy page's promise that a deleted drink's entry
/// is removed held on one device only. The identifiers are now written here in the same
/// save as the delete, synced like any other row, and every device that may write to
/// Health deletes what it holds and signs off (see `HealthKitManager.honourTombstones`).
/// A row is dropped a month after it was made; by then every device that was going to
/// see it has.
///
/// Same CloudKit rules as `WaterEntry`: every attribute carries a default or is optional,
/// nothing is unique, and there are no relationships. Kept to strings and dates, like
/// `Bottle.linkedTagIDs`, because that is the one shape CloudKit cannot get wrong, and
/// because the widget compiles this file too, to open the store with the full schema,
/// and must not need anything from Health.
@Model
final class HealthTombstone {
    /// The `HealthSampleKind` raw value: "water" or "caffeine".
    var kindRawValue: String = "water"
    /// The sample's UUID on the device that wrote it, or nil for a sample only its sync
    /// identifiers name.
    var sampleUUID: String?
    /// Every sync identifier the sample may carry, separated by commas.
    var syncIdentifiers: String = ""
    var createdAt: Date = Date.distantPast
    /// The `HealthInstall.id` of every device that has deleted what it holds, separated
    /// by commas.
    var handledBy: String = ""

    /// How long a tombstone stands: long enough for a device that is opened once a month.
    static let lifetime: TimeInterval = 30 * 24 * 60 * 60

    init(kindRawValue: String, sampleUUID: String?, syncIdentifiers: [String], createdAt: Date = Date()) {
        self.kindRawValue = kindRawValue
        self.sampleUUID = sampleUUID
        self.syncIdentifiers = syncIdentifiers.joined(separator: ",")
        self.createdAt = createdAt
    }

    var syncIdentifierList: [String] {
        Self.pieces(of: syncIdentifiers)
    }

    var handlers: Set<String> {
        Set(Self.pieces(of: handledBy))
    }

    func isHandled(by device: String) -> Bool {
        handlers.contains(device)
    }

    /// Signs off for `device`. Signing off twice changes nothing, and the list is kept
    /// sorted so two devices merging their signatures through iCloud agree on the text.
    func markHandled(by device: String) {
        guard !isHandled(by: device) else { return }
        handledBy = (Array(handlers) + [device]).sorted().joined(separator: ",")
    }

    func hasExpired(now: Date) -> Bool {
        now.timeIntervalSince(createdAt) >= Self.lifetime
    }

    /// What this device should do with the tombstones it holds: honour the ones it has
    /// not signed, and drop the ones a month old whatever is left on them. A device that
    /// has not deleted yet still sees an expired one go; a month is the agreed limit.
    static func plan(_ tombstones: [HealthTombstone], device: String, now: Date) -> (toHonour: [HealthTombstone], toDrop: [HealthTombstone]) {
        var toHonour: [HealthTombstone] = []
        var toDrop: [HealthTombstone] = []
        for tombstone in tombstones {
            if tombstone.hasExpired(now: now) {
                toDrop.append(tombstone)
            } else if !tombstone.isHandled(by: device) {
                toHonour.append(tombstone)
            }
        }
        return (toHonour, toDrop)
    }

    private static func pieces(of list: String) -> [String] {
        list.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}
