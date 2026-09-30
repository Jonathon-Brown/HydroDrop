import SwiftData
import XCTest
@testable import HydroDrop

/// An edited drink's Health samples used to be deleted on the spot: with sync off the water
/// sample was stranded in Health, and with sync on a drink from before sync was turned on
/// was deleted and never written again. Edits now note on the synced drink that its samples
/// are out of date, and a reconcile replaces them in one step, deleting first and writing
/// second.
@MainActor
final class HealthEditPlanTests: XCTestCase {
    // MARK: - The plan

    func testAnUnchangedDrinkNeverTouchesHealth() {
        XCTAssertEqual(HealthEditPlan(isUnchanged: true, hasSamples: true), .leaveHealth)
        XCTAssertEqual(HealthEditPlan(isUnchanged: true, hasSamples: false), .leaveHealth)
    }

    func testAChangedDrinkWithSamplesIsReplaced() {
        XCTAssertEqual(HealthEditPlan(isUnchanged: false, hasSamples: true), .replaceSamples)
    }

    func testAChangedDrinkHealthNeverHadIsLeftToTheOrdinaryPass() {
        XCTAssertEqual(HealthEditPlan(isUnchanged: false, hasSamples: false), .leaveHealth)
    }

    // MARK: - One replacement step

    func testADeleteThatCouldNotBeDoneIsTriedAgainLater() {
        for awaiting in [true, false] {
            for counts in [true, false] {
                XCTAssertEqual(HealthReplacementStep(deletedCount: nil, wasAwaitingWrite: awaiting, stillCounts: counts), .retryLater)
            }
        }
    }

    func testADeletedSampleIsRewrittenOrCleared() {
        XCTAssertEqual(HealthReplacementStep(deletedCount: 1, wasAwaitingWrite: false, stillCounts: true), .rewrite)
        XCTAssertEqual(HealthReplacementStep(deletedCount: 1, wasAwaitingWrite: false, stillCounts: false), .clear)
    }

    /// Nothing to delete, and this device never deleted it: the sample isn't in this
    /// device's Health, because the user took it out or only another device has it.
    func testASampleNotInThisDevicesHealthIsLeftAlone() {
        XCTAssertEqual(HealthReplacementStep(deletedCount: 0, wasAwaitingWrite: false, stillCounts: true), .letGo)
        XCTAssertEqual(HealthReplacementStep(deletedCount: 0, wasAwaitingWrite: false, stillCounts: false), .letGo)
    }

    /// Nothing to delete because this device already deleted it in a pass whose write
    /// failed or was cut short: the replacement still has to be written.
    func testAReplacementWhoseWriteFailedIsWrittenNextTime() {
        XCTAssertEqual(HealthReplacementStep(deletedCount: 0, wasAwaitingWrite: true, stillCounts: true), .rewrite)
        XCTAssertEqual(HealthReplacementStep(deletedCount: 0, wasAwaitingWrite: true, stillCounts: false), .clear)
    }

    // MARK: - This device's marks

    private var suiteName = ""
    private var defaults: UserDefaults!
    private var storeDirectory: URL?

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HealthEditPlanTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        TemporaryStore.remove(storeDirectory)
        try await super.tearDown()
    }

    /// 1.8.1's list is only ever read, to move it onto the drinks.
    func testTheListFrom181IsReadFromItsOldKey() {
        defaults.set(["water-1", "caffeine-1"], forKey: "health.samplesToReplace")
        XCTAssertEqual(HealthReplacementQueue(defaults: defaults).sampleIDs, ["water-1", "caffeine-1"])
    }

    /// A delete that couldn't be done takes back the mark this pass made. The drink's record
    /// still says it is out of date, so the next pass tries again.
    func testAFailedFirstAttemptTakesBackItsOwnMark() {
        let queue = HealthReplacementQueue(defaults: defaults)
        queue.markAwaitingWrite("water-1")
        queue.abandonAttempt("water-1", wasAwaiting: false)
        XCTAssertEqual(queue.awaitingWrite, [])
    }

    /// An earlier pass's delete worked, so the sample is already out of Health. Losing its
    /// mark to a later failed delete would turn the next "nothing to delete" into `.letGo`,
    /// and the edited drink would never be written back.
    func testAFailedRetryKeepsAnEarlierPassesMark() {
        let queue = HealthReplacementQueue(defaults: defaults)
        queue.markAwaitingWrite("water-1")
        queue.abandonAttempt("water-1", wasAwaiting: true)
        XCTAssertEqual(queue.awaitingWrite, ["water-1"])
        XCTAssertEqual(HealthReplacementStep(deletedCount: 0, wasAwaitingWrite: true, stillCounts: true), .rewrite)
    }

    func testCrossingOffClearsOnlyThatMark() {
        let queue = HealthReplacementQueue(defaults: defaults)
        queue.markAwaitingWrite("water-1")
        queue.markAwaitingWrite("water-2")
        queue.remove("water-1")
        XCTAssertEqual(queue.awaitingWrite, ["water-2"])
    }

    // MARK: - What an edited drink still has to write

    /// The bug this fixes: with sync on, an edited drink from before sync was turned on was
    /// deleted from Health and never written again, because the ordinary pass skips it.
    func testADrinkFromBeforeSyncWasTurnedOnIsStillReplaced() {
        let syncTurnedOn = Date(timeIntervalSinceReferenceDate: 800_000_000)
        let olderDrink = WaterEntry(amountML: 300, timestamp: syncTurnedOn.addingTimeInterval(-86_400))
        XCTAssertFalse(HealthKitManager.isEligible(olderDrink, since: syncTurnedOn))
        XCTAssertTrue(HealthKitManager.replacementStillCounts(olderDrink, kind: .water))
    }

    /// Whether this device touches caffeine at all is decided first (see
    /// `HealthKitManager.leavesCaffeineAlone`). Once it does, a drink with caffeine is written
    /// again, and one edited to have none has its caffeine sample taken out.
    func testCaffeineIsWrittenAgainOnlyWhileTheDrinkHasSome() {
        let coffee = WaterEntry(amountML: 250, drinkType: .coffee)
        XCTAssertTrue(HealthKitManager.replacementStillCounts(coffee, kind: .caffeine))
        let water = WaterEntry(amountML: 250)
        XCTAssertFalse(HealthKitManager.replacementStillCounts(water, kind: .caffeine))
        XCTAssertTrue(HealthKitManager.replacementStillCounts(water, kind: .water))
    }

    // MARK: - Finding the drink behind a queued sample

    /// Runs the replacement's own predicates against a real store.
    func testAQueuedSampleFindsItsDrinkByWaterOrCaffeine() throws {
        let store = try TemporaryStore.make(for: Schema([WaterEntry.self]))
        storeDirectory = store.directory
        let context = store.container.mainContext
        let coffee = WaterEntry(amountML: 250, drinkType: .coffee)
        coffee.healthKitSampleUUID = "water-A"
        coffee.caffeineSampleUUID = "caffeine-B"
        context.insert(coffee)
        context.insert(WaterEntry(amountML: 300))
        try context.save()

        let byWater = try HealthKitManager.entries(carrying: "water-A", in: context)
        XCTAssertTrue(byWater.water === coffee)
        XCTAssertNil(byWater.caffeine)

        let byCaffeine = try HealthKitManager.entries(carrying: "caffeine-B", in: context)
        XCTAssertNil(byCaffeine.water)
        XCTAssertTrue(byCaffeine.caffeine === coffee)

        let unknown = try HealthKitManager.entries(carrying: "not-a-sample", in: context)
        XCTAssertNil(unknown.water)
        XCTAssertNil(unknown.caffeine)
    }

    /// A pass that waits on Health reads its drinks again only if they are still there. A
    /// drink deleted in the meantime, saved or not, must read as gone rather than be read.
    func testADeletedDrinkReadsAsGoneBeforeAndAfterTheSave() throws {
        let store = try TemporaryStore.make(for: Schema([WaterEntry.self]))
        storeDirectory = store.directory
        let context = store.container.mainContext
        let drink = WaterEntry(amountML: 250)
        context.insert(drink)
        try context.save()
        XCTAssertTrue(HealthKitManager.isLive(drink))

        context.delete(drink)
        XCTAssertFalse(HealthKitManager.isLive(drink), "deleted, not yet saved")
        try context.save()
        XCTAssertFalse(HealthKitManager.isLive(drink), "deleted and saved")
    }
}
