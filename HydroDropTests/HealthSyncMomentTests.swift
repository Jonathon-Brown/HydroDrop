import SwiftData
import XCTest
@testable import HydroDrop

/// Drinks logged on Today used to reach Apple Health only on the next foreground. Every
/// change now goes as soon as it has settled. A write checks its drinks again once Health
/// has taken the samples, and these tests cover the pieces of that check: when a write
/// happens, what a drink's sample records, whether a written sample is kept, and the list
/// of samples still to take back.
@MainActor
final class HealthSyncMomentTests: XCTestCase {
    private let noon = Date(timeIntervalSinceReferenceDate: 800_000_000)
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var storeDirectory: URL?

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HealthSyncMomentTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        TemporaryStore.remove(storeDirectory)
        try await super.tearDown()
    }

    func testOnlyADrinkThatCanStillBeUndoneWaits() {
        XCTAssertFalse(HealthSyncMoment.loggedWithUndoOffer.writesToHealth)
        let settled = HealthSyncMoment.allCases.filter { $0 != .loggedWithUndoOffer }
        XCTAssertEqual(Set(settled), [
            .undoOfferEnded, .leftForegroundDuringUndoOffer, .arrivedFromWatch, .logChanged, .cameToForeground,
        ])
        for moment in settled {
            XCTAssertTrue(moment.writesToHealth, "\(moment)")
        }
    }

    // MARK: - What a sample records

    /// The write builds its sample from this and checks the drink against it afterwards,
    /// so a drift between the two would take back every sample it wrote.
    func testASnapshotRecordsWhatHealthIsGiven() throws {
        let store = try TemporaryStore.make(for: Schema([WaterEntry.self]))
        storeDirectory = store.directory
        let context = store.container.mainContext
        let water = WaterEntry(amountML: 300, timestamp: noon)
        let coffee = WaterEntry(amountML: 250, timestamp: noon, drinkType: .coffee)
        context.insert(water)
        context.insert(coffee)
        try context.save()

        XCTAssertEqual(HealthKitManager.snapshot(of: water, caffeine: false), HealthSampleSnapshot(timestamp: noon, amount: 300))
        // What counts towards the day, not what was poured.
        XCTAssertEqual(HealthKitManager.snapshot(of: coffee, caffeine: false), HealthSampleSnapshot(timestamp: noon, amount: 225))
        XCTAssertEqual(HealthKitManager.snapshot(of: coffee, caffeine: true), HealthSampleSnapshot(timestamp: noon, amount: 95))

        context.delete(coffee)
        XCTAssertNil(HealthKitManager.snapshot(of: coffee, caffeine: false))
        try context.save()
        XCTAssertNil(HealthKitManager.snapshot(of: coffee, caffeine: true))
    }

    // MARK: - Whether a written sample is kept

    func testASampleIsKeptWhenItsDrinkIsUnchanged() {
        let written = HealthSampleSnapshot(timestamp: noon, amount: 250)
        XCTAssertTrue(HealthSampleSnapshot.keepsWrittenSample(written, current: written))
    }

    /// Undone or deleted while Health was saving it.
    func testASampleForADrinkThatWentAwayIsNotKept() {
        XCTAssertFalse(HealthSampleSnapshot.keepsWrittenSample(HealthSampleSnapshot(timestamp: noon, amount: 250), current: nil))
    }

    /// Edited while Health was saving it: an amount or type change shows as a different
    /// amount, a time change as a different timestamp.
    func testASampleForADrinkThatChangedIsNotKept() {
        let written = HealthSampleSnapshot(timestamp: noon, amount: 250)
        XCTAssertFalse(HealthSampleSnapshot.keepsWrittenSample(written, current: HealthSampleSnapshot(timestamp: noon, amount: 500)))
        XCTAssertFalse(HealthSampleSnapshot.keepsWrittenSample(written, current: HealthSampleSnapshot(timestamp: noon.addingTimeInterval(-3600), amount: 250)))
    }

    // MARK: - Samples still to take back

    func testTheTakeBackListKeepsWaterAndCaffeineApart() {
        let list = HealthTakeBackList(defaults: defaults)
        list.add(["water-1", "water-2"], caffeine: false)
        list.add(["caffeine-1"], caffeine: true)
        list.add(["water-1"], caffeine: false)
        XCTAssertEqual(list.sampleIDs(caffeine: false), ["water-1", "water-2"])
        XCTAssertEqual(list.sampleIDs(caffeine: true), ["caffeine-1"])

        list.remove("water-1", caffeine: false)
        list.remove("water-2", caffeine: true)
        XCTAssertEqual(list.sampleIDs(caffeine: false), ["water-2"])
        XCTAssertEqual(list.sampleIDs(caffeine: true), ["caffeine-1"])
    }

    func testAddingNothingLeavesTheListUntouched() {
        let list = HealthTakeBackList(defaults: defaults)
        list.add([], caffeine: false)
        XCTAssertNil(defaults.object(forKey: HealthTakeBackList.waterKey))
    }

    /// A delete that couldn't be done keeps the sample listed; one that found nothing
    /// finishes it, or the list would never drain.
    func testASampleComesOffTheListOnceAnyDeleteGoesThrough() {
        XCTAssertFalse(HealthTakeBackList.isFinished(afterDeleting: nil))
        XCTAssertTrue(HealthTakeBackList.isFinished(afterDeleting: 0))
        XCTAssertTrue(HealthTakeBackList.isFinished(afterDeleting: 1))
    }

    /// Every sample is taken back, whatever happens to its drink's identifier. Only a drink
    /// that is still here is written again.
    func testAFailedTakeBackListsEverySampleAndReplacesOnlyLiveDrinks() {
        let failed = HealthFailedTakeBack([(id: "edited", drinkIsLive: true), (id: "undone", drinkIsLive: false)])
        XCTAssertEqual(failed.toTakeBack, ["edited", "undone"])
        XCTAssertEqual(failed.toReplace, ["edited"])
    }

    /// Its take-back may land first, so the replacement's own delete finds nothing. The mark
    /// makes that a rewrite rather than a let-go.
    func testAReplacedDrinkIsWrittenEvenAfterItsSampleIsTakenBack() {
        let queue = HealthReplacementQueue(defaults: defaults)
        queue.addAwaitingWrite(["edited"])
        XCTAssertEqual(queue.sampleIDs, ["edited"])
        XCTAssertEqual(queue.awaitingWrite, ["edited"])
        XCTAssertEqual(HealthReplacementStep(deletedCount: 0, wasAwaitingWrite: true, stillCounts: true), .rewrite)
    }
}
