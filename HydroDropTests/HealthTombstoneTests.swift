import SwiftData
import XCTest
@testable import HydroDrop

/// What a deleted drink leaves for the devices that hold its Health samples, and what each
/// device does with it. Run against a real on-disk store with the full schema, so the row
/// is the one CloudKit will carry.
@MainActor
final class HealthTombstoneTests: XCTestCase {
    private var storeDirectory: URL?
    private var context: ModelContext!
    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        try await super.setUp()
        let store = try TemporaryStore.make(for: SharedModelContainer.schema)
        storeDirectory = store.directory
        context = store.container.mainContext
    }

    override func tearDown() async throws {
        context = nil
        TemporaryStore.remove(storeDirectory)
        try await super.tearDown()
    }

    private func tombstones() throws -> [HealthTombstone] {
        try context.fetch(FetchDescriptor<HealthTombstone>(sortBy: [SortDescriptor(\.kindRawValue)]))
    }

    // MARK: - What a delete leaves

    /// One per sample kind the drink had, in the same context as the delete, carrying
    /// everything a delete on another device looks for.
    func testADeleteLeavesOneTombstonePerSampleKind() throws {
        let entry = WaterEntry(amountML: 250, timestamp: noon, drinkType: .coffee)
        entry.healthKitSampleUUID = "water-A"
        entry.caffeineSampleUUID = "caffeine-A"
        entry.healthWaterWritten = HealthWrittenRecord(
            state: .written, sampleUUID: "water-A", syncIdentifier: "old.water", syncVersion: 1,
            figures: HealthFigures(of: entry), owner: "PHONE"
        ).encoded
        context.insert(entry)
        try context.save()

        let samples = HealthSampleReference.all(of: entry)
        HealthTombstone.leave(for: samples, in: context, now: noon)
        context.delete(entry)
        try context.save()

        let left = try tombstones()
        XCTAssertEqual(left.map(\.kind), [.caffeine, .water])
        let caffeine = try XCTUnwrap(left.first)
        let water = try XCTUnwrap(left.last)
        XCTAssertEqual(water.reference, samples.first { $0.kind == .water })
        XCTAssertEqual(caffeine.reference, samples.first { $0.kind == .caffeine })
        XCTAssertEqual(water.sampleUUID, "water-A")
        XCTAssertEqual(Set(water.syncIdentifierList), ["old.water", "\(entry.healthSyncID!).water"])
        XCTAssertEqual(water.createdAt, noon)
        XCTAssertEqual(water.handledBy, "", "nobody has deleted anything yet")
    }

    /// A drink Health never had leaves nothing behind.
    func testADrinkHealthNeverHadLeavesNothing() throws {
        let entry = WaterEntry(amountML: 250, timestamp: noon)
        context.insert(entry)
        HealthTombstone.leave(for: HealthSampleReference.all(of: entry), in: context, now: noon)
        context.delete(entry)
        try context.save()
        XCTAssertEqual(try tombstones().count, 0)
    }

    // MARK: - Signing off

    func testEachDeviceSignsOffOnceAndTheListStaysSorted() {
        let tombstone = HealthTombstone(kindRawValue: "water", sampleUUID: "water-A", syncIdentifiers: [], createdAt: noon)
        tombstone.markHandled(by: "PHONE")
        tombstone.markHandled(by: "IPAD")
        tombstone.markHandled(by: "PHONE")
        XCTAssertEqual(tombstone.handledBy, "IPAD,PHONE")
        XCTAssertTrue(tombstone.isHandled(by: "PHONE"))
        XCTAssertTrue(tombstone.isHandled(by: "IPAD"))
        XCTAssertFalse(tombstone.isHandled(by: "WATCH"))
    }

    func testAnUnsignedTombstoneIsWorkAndASignedOneIsNot() {
        let signed = HealthTombstone(kindRawValue: "water", sampleUUID: "water-A", syncIdentifiers: [], createdAt: noon)
        signed.markHandled(by: "PHONE")
        let unsigned = HealthTombstone(kindRawValue: "caffeine", sampleUUID: "caffeine-A", syncIdentifiers: [], createdAt: noon)

        let plan = HealthTombstone.plan([signed, unsigned], device: "PHONE", now: noon.addingTimeInterval(60))

        XCTAssertEqual(plan.toHonour.map(\.sampleUUID), ["caffeine-A"])
        XCTAssertEqual(plan.toDrop.count, 0)
    }

    /// A month on, whatever is left on it: a device that has not deleted by then is not
    /// going to, and the row must not stay forever.
    func testAMonthOldTombstoneIsDroppedWhateverIsLeftOnIt() {
        let old = HealthTombstone(kindRawValue: "water", sampleUUID: "water-A", syncIdentifiers: [], createdAt: noon)
        let fresh = HealthTombstone(kindRawValue: "water", sampleUUID: "water-B", syncIdentifiers: [], createdAt: noon.addingTimeInterval(HealthTombstone.lifetime / 2))

        let plan = HealthTombstone.plan([old, fresh], device: "IPAD", now: noon.addingTimeInterval(HealthTombstone.lifetime))

        XCTAssertEqual(plan.toDrop.map(\.sampleUUID), ["water-A"])
        XCTAssertEqual(plan.toHonour.map(\.sampleUUID), ["water-B"])
    }

    /// A kind a later version writes is nothing this one can delete. It is left unsigned
    /// for a device that can, and expires like any other.
    func testAKindThisVersionDoesNotKnowIsLeftAlone() {
        let foreign = HealthTombstone(kindRawValue: "tea", sampleUUID: "tea-A", syncIdentifiers: ["x.tea"], createdAt: noon)
        XCTAssertNil(foreign.kind)
        XCTAssertNil(foreign.reference)
        XCTAssertEqual(HealthTombstone.plan([foreign], device: "PHONE", now: noon).toHonour.count, 1)
    }

    /// Identifiers survive the comma-separated string whatever spacing a hand edit left.
    func testIdentifiersRoundTripThroughTheStoredString() {
        let tombstone = HealthTombstone(kindRawValue: "water", sampleUUID: nil, syncIdentifiers: ["a.water", "b.water"], createdAt: noon)
        XCTAssertEqual(tombstone.syncIdentifierList, ["a.water", "b.water"])
        tombstone.syncIdentifiers = " a.water , ,b.water"
        XCTAssertEqual(tombstone.syncIdentifierList, ["a.water", "b.water"])
        XCTAssertEqual(tombstone.reference, HealthSampleReference(kind: .water, uuid: nil, syncIdentifiers: ["a.water", "b.water"]))
    }
}
