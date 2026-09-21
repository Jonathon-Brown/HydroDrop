import Foundation
import SwiftData

/// A bottle the user owns, which an NFC sticker can stand for.
///
/// Tapping the phone to the sticker logs one full bottle, so everything a tap needs is
/// here: how much it holds and what is usually in it.
///
/// Same CloudKit rules as `WaterEntry`: every attribute carries a default or is
/// optional, nothing is unique, and there are no relationships. The defaults exist to
/// satisfy that, not because a nameless, empty bottle means anything.
@Model
final class Bottle {
    /// What the sticker carries. Generated once and never changed, so a tag written
    /// today still means this bottle after a rename or a new capacity.
    var id: UUID = UUID()
    var name: String = ""
    var capacityML: Int = 0

    /// The `DrinkType` raw value. Optional for the same reason as on `WaterEntry`: a
    /// value written by a newer version must never cost an older one the record.
    var drinkTypeRawValue: String?

    var createdAt: Date = Date.distantPast

    /// Other stickers that also mean this bottle, as UUID strings separated by commas.
    ///
    /// A tag this device has never seen can be linked to a bottle rather than thrown
    /// away: the sticker a partner wrote, or one left over from a bottle that was
    /// deleted. A plain string because it is the one shape CloudKit cannot get wrong.
    var linkedTagIDs: String?

    var drinkType: DrinkType {
        get { drinkTypeRawValue.flatMap(DrinkType.init(rawValue:)) ?? .water }
        set { drinkTypeRawValue = newValue.rawValue }
    }

    /// Every tag id that should log this bottle: its own, and any linked to it later.
    var allTagIDs: Set<UUID> {
        var ids: Set<UUID> = [id]
        for piece in (linkedTagIDs ?? "").split(separator: ",") {
            if let linked = UUID(uuidString: piece.trimmingCharacters(in: .whitespaces)) {
                ids.insert(linked)
            }
        }
        return ids
    }

    /// Makes `tagID` mean this bottle too. Linking the same tag twice changes nothing.
    func link(tagID: UUID) {
        guard !allTagIDs.contains(tagID) else { return }
        let existing = (linkedTagIDs ?? "").split(separator: ",").map(String.init)
        linkedTagIDs = (existing + [tagID.uuidString]).joined(separator: ",")
    }

    init(name: String, capacityML: Int, drinkType: DrinkType = .water, createdAt: Date = Date()) {
        self.id = UUID()
        self.name = name
        self.capacityML = capacityML
        self.drinkTypeRawValue = drinkType.rawValue
        self.createdAt = createdAt
    }
}
