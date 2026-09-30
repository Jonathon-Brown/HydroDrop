import SwiftData
import XCTest
@testable import HydroDrop

/// The synced side of 1.9's Health edits, run against real on-disk stores: how a drink gets
/// its Health identifier, what an edit and the move of 1.8.1's local queue write onto
/// drinks, which drinks a replacement pass looks at, and what a delete looks for.
@MainActor
final class HealthEditSyncTests: XCTestCase {
    private var suiteName = ""
    private var defaults: UserDefaults!
    private var storeDirectory: URL?
    private var container: ModelContainer!
    private var context: ModelContext!
    private let noon = Date(timeIntervalSince1970: 1_790_000_000)

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "HealthEditSyncTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
        let store = try TemporaryStore.make(for: SharedModelContainer.schema)
        storeDirectory = store.directory
        container = store.container
        context = store.container.mainContext
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        context = nil
        container = nil
        TemporaryStore.remove(storeDirectory)
        try await super.tearDown()
    }

    private func record(_ state: HealthWrittenRecord.State = .written, sample: String?, for entry: WaterEntry, syncIdentifier: String? = "drink.water", marked: Bool = false) -> HealthWrittenRecord {
        HealthWrittenRecord(
            state: state,
            sampleUUID: sample,
            syncIdentifier: syncIdentifier,
            syncVersion: 1_790_000_000_000,
            figures: state == .stale ? nil : HealthFigures(of: entry),
            owner: "PHONE",
            editedSince: marked
        )
    }

    // MARK: - The Health identifier

    /// Set in the initialiser, so every drink made by 1.9, in any process, has its own.
    func testEveryNewDrinkHasItsOwnHealthIdentifier() {
        let first = WaterEntry(amountML: 250)
        let second = WaterEntry(amountML: 250)
        XCTAssertNotNil(first.healthSyncID)
        XCTAssertNotNil(second.healthSyncID)
        XCTAssertNotEqual(first.healthSyncID, second.healthSyncID)
    }

    /// The pitfall the review found: a property default can become the schema's default,
    /// and every migrated row would then share one identifier, so a newer version of one
    /// drink's sample would replace another drink's. A row from before 1.9 must read nil.
    func testADrinkFromBefore19HasNoHealthIdentifierAfterTheMigration() throws {
        let directory = URL.temporaryDirectory.appending(path: "HealthEditSyncTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { TemporaryStore.remove(directory) }
        let url = directory.appending(path: "store.sqlite")
        do {
            let legacy = Schema([HealthEditLegacySchema.WaterEntry.self])
            let old = try ModelContainer(for: legacy, configurations: ModelConfiguration(schema: legacy, url: url, cloudKitDatabase: .none))
            let oldContext = ModelContext(old)
            oldContext.insert(HealthEditLegacySchema.WaterEntry(amountML: 250, timestamp: noon))
            oldContext.insert(HealthEditLegacySchema.WaterEntry(amountML: 300, timestamp: noon.addingTimeInterval(60)))
            try oldContext.save()
        }
        let schema = Schema([WaterEntry.self])
        let migrated = try ModelContainer(for: schema, configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none))
        let rows = try ModelContext(migrated).fetch(FetchDescriptor<WaterEntry>())
        XCTAssertEqual(rows.count, 2)
        for row in rows {
            XCTAssertNil(row.healthSyncID)
            XCTAssertNil(row.healthWaterWritten)
            XCTAssertNil(row.healthCaffeineWritten)
        }
    }

    /// Two devices converting the same drink at once see the same sample, so they agree.
    func testADrinkAlreadyInHealthIsNamedAfterItsSample() {
        let drink = WaterEntry(amountML: 250)
        drink.healthSyncID = nil
        drink.healthKitSampleUUID = "water-A"
        XCTAssertEqual(HealthKitManager.newHealthSyncID(for: drink), "legacy-water-A")
        drink.healthKitSampleUUID = nil
        drink.caffeineSampleUUID = "caffeine-B"
        XCTAssertEqual(HealthKitManager.newHealthSyncID(for: drink), "legacy-caffeine-B")
        drink.caffeineSampleUUID = nil
        XCTAssertNotNil(UUID(uuidString: HealthKitManager.newHealthSyncID(for: drink)))
    }

    // MARK: - An edit

    /// A sample written before 1.9 has no record, so the edit makes one from the figures the
    /// drink has before it changes, marked, and claimed by the editing device if it can
    /// write to Health, so it acts at once.
    func testAnEditToAnOlderSampleRecordsWhatHealthHasAndMarksIt() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        let before = HealthFigures(of: drink)
        drink.noteHealthEdit(claimedBy: "PHONE")
        drink.amountML = 400
        let written = try XCTUnwrap(drink.healthRecord(for: .water).record)
        XCTAssertEqual(written.state, .written)
        XCTAssertEqual(written.sampleUUID, "water-A")
        XCTAssertNil(written.syncIdentifier)
        XCTAssertEqual(written.syncVersion, 0)
        XCTAssertEqual(written.figures, before)
        XCTAssertEqual(written.owner, "PHONE", "claimed by the device that will replace it")
        XCTAssertTrue(written.editedSince)
        XCTAssertEqual(drink.healthRecord(for: .caffeine), .none, "no caffeine sample, nothing to note")
    }

    func testAnEditToA19SampleOnlyMarksItsRecord() {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        let original = record(sample: "water-A", for: drink)
        drink.setHealthRecord(original, for: .water)
        drink.noteHealthEdit(claimedBy: "IPAD")
        var expected = original
        expected.editedSince = true
        XCTAssertEqual(drink.healthRecord(for: .water).record, expected, "still owned by the device that wrote it")
    }

    func testAnEditLeavesARecordFromALaterVersionAlone() {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        drink.healthWaterWritten = "2|something newer"
        drink.noteHealthEdit(claimedBy: "PHONE")
        XCTAssertEqual(drink.healthWaterWritten, "2|something newer")
    }

    func testAnEditToADrinkHealthNeverHadNotesNothing() {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.noteHealthEdit(claimedBy: "PHONE")
        XCTAssertNil(drink.healthWaterWritten)
        XCTAssertNil(drink.healthCaffeineWritten)
    }

    /// A record voided by a 1.8.1 device's rewrite is replaced by one for the sample the
    /// drink points at now.
    func testAnEditAfterAnOlderDeviceRewroteTheSampleRecordsTheNewSample() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-B"
        drink.setHealthRecord(record(sample: "water-A", for: drink), for: .water)
        drink.noteHealthEdit(claimedBy: nil)
        let written = try XCTUnwrap(drink.healthRecord(for: .water).record)
        XCTAssertEqual(written.sampleUUID, "water-B")
        XCTAssertNil(written.owner, "edited on a device that can't write to Health: nobody claims it")
        XCTAssertEqual(written.syncVersion, 0)
        XCTAssertTrue(written.editedSince)
    }

    func testTheEditPlanCountsARecordAsSomethingHealthHas() {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        XCTAssertFalse(drink.hasHealthSamplesOrRecords)
        drink.setHealthRecord(HealthKitManager.nothingRecord(for: drink, after: .none, owner: "PHONE"), for: .water)
        XCTAssertTrue(drink.hasHealthSamplesOrRecords)
        XCTAssertEqual(HealthEditPlan(isUnchanged: false, hasSamples: drink.hasHealthSamplesOrRecords), .replaceSamples)
    }

    // MARK: - Moving 1.8.1's queue

    /// The step that repairs edits made before 1.9 on a device with sync off: once it runs
    /// 1.9, its queue reaches the synced drinks, where the device with sync on sees it.
    func testQueuedSamplesMoveOntoTheirDrinks() throws {
        let coffee = WaterEntry(amountML: 250, timestamp: noon, drinkType: .coffee)
        coffee.healthKitSampleUUID = "water-A"
        coffee.caffeineSampleUUID = "caffeine-B"
        context.insert(coffee)
        try context.save()
        let queue = HealthReplacementQueue(defaults: defaults)
        defaults.set(["water-A", "caffeine-B", "no-drink"], forKey: HealthReplacementQueue.key)
        defaults.set(["water-A"], forKey: HealthReplacementQueue.awaitingWriteKey)

        queue.moveQueuedSamplesOntoDrinks(in: context) { _ in nil }

        XCTAssertEqual(coffee.healthRecord(for: .water).record?.state, .stale)
        XCTAssertNil(coffee.healthRecord(for: .water).record?.owner, "moved on a device that can't write to Health: nobody claims it")
        XCTAssertEqual(coffee.healthRecord(for: .water).record?.sampleUUID, "water-A")
        XCTAssertEqual(coffee.healthRecord(for: .caffeine).record?.state, .stale)
        XCTAssertEqual(coffee.healthRecord(for: .caffeine).record?.sampleUUID, "caffeine-B")
        XCTAssertEqual(queue.sampleIDs, [], "every entry moved, and the one no drink carries dropped")
        XCTAssertEqual(queue.awaitingWrite, ["water-A"], "what this device did to its own Health stays here")
        XCTAssertFalse(context.hasChanges, "saved, so it syncs")
    }

    func testAQueuedSampleWhoseDrinkHasARecordIsOnlyMarked() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        drink.setHealthRecord(record(sample: "water-A", for: drink), for: .water)
        context.insert(drink)
        try context.save()
        defaults.set(["water-A"], forKey: HealthReplacementQueue.key)

        HealthReplacementQueue(defaults: defaults).moveQueuedSamplesOntoDrinks(in: context) { _ in "IPAD" }

        let written = try XCTUnwrap(drink.healthRecord(for: .water).record)
        XCTAssertEqual(written.state, .written)
        XCTAssertEqual(written.owner, "PHONE", "a record already claimed keeps its owner")
        XCTAssertTrue(written.editedSince)
    }

    func testAMovedSampleIsClaimedByADeviceWithSyncOn() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        context.insert(drink)
        try context.save()
        defaults.set(["water-A"], forKey: HealthReplacementQueue.key)
        HealthReplacementQueue(defaults: defaults).moveQueuedSamplesOntoDrinks(in: context) { $0 == .water ? "PHONE" : nil }
        XCTAssertEqual(drink.healthRecord(for: .water).record?.owner, "PHONE")
    }

    func testAnEmptyQueueChangesNothing() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        context.insert(drink)
        try context.save()
        HealthReplacementQueue(defaults: defaults).moveQueuedSamplesOntoDrinks(in: context) { _ in "PHONE" }
        XCTAssertNil(drink.healthWaterWritten)
    }

    // MARK: - Which drinks a pass looks at

    func testAScanFindsEveryDrinkWithARecordAndNoOthers() throws {
        let recorded = WaterEntry(amountML: 250, timestamp: noon)
        recorded.healthKitSampleUUID = "water-A"
        recorded.setHealthRecord(record(sample: "water-A", for: recorded), for: .water)
        let caffeineOnly = WaterEntry(amountML: 250, timestamp: noon.addingTimeInterval(60), drinkType: .coffee)
        caffeineOnly.caffeineSampleUUID = "caffeine-B"
        caffeineOnly.setHealthRecord(record(sample: "caffeine-B", for: caffeineOnly, syncIdentifier: "drink.caffeine"), for: .caffeine)
        let legacy = WaterEntry(amountML: 250, timestamp: noon.addingTimeInterval(120))
        legacy.healthKitSampleUUID = "water-C"
        [recorded, caffeineOnly, legacy].forEach(context.insert)
        try context.save()

        let queue = HealthReplacementQueue(defaults: defaults)
        let scanned = try HealthKitManager.replacementCandidates(scanning: true, queue: queue, in: context)
        XCTAssertEqual(scanned.map(\.healthSyncID), [recorded.healthSyncID, caffeineOnly.healthSyncID])
        XCTAssertEqual(try HealthKitManager.replacementCandidates(scanning: false, queue: queue, in: context).count, 0)
    }

    /// Without a scan, only what this device is part way through is looked at. A mark no
    /// drink carries any more belongs to a deleted drink and is dropped.
    func testWithoutAScanOnlyDrinksThisDeviceMarkedAreLookedAt() throws {
        let marked = WaterEntry(amountML: 250, timestamp: noon)
        marked.healthKitSampleUUID = "water-A"
        context.insert(marked)
        try context.save()
        let queue = HealthReplacementQueue(defaults: defaults)
        queue.markAwaitingWrite("water-A")
        queue.markAwaitingWrite("deleted-drink")

        let found = try HealthKitManager.replacementCandidates(scanning: false, queue: queue, in: context)
        XCTAssertEqual(found.count, 1)
        XCTAssertTrue(found.first === marked)
        XCTAssertEqual(queue.awaitingWrite, ["water-A"])
    }

    /// The scan runs at launch and on every return to the foreground, over every drink with
    /// a record, through the same plan the pass makes. Ten thousand drinks is years of heavy
    /// use. The design's budget is 100 ms; the bound here leaves room for a shared CI machine.
    func testScanningTenThousandDrinksStaysQuick() throws {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<10_000 {
            let drink = WaterEntry(amountML: 250, timestamp: start.addingTimeInterval(Double(index) * 600))
            drink.healthKitSampleUUID = UUID().uuidString
            drink.setHealthRecord(record(sample: drink.healthKitSampleUUID, for: drink), for: .water)
            context.insert(drink)
        }
        try context.save()
        let fresh = ModelContext(container)
        let queue = HealthReplacementQueue(defaults: defaults)
        let notes = HealthPendingNotes(defaults: defaults)
        var plan = HealthPendingPlan()
        let elapsed = try ContinuousClock().measure {
            let candidates = try HealthKitManager.replacementCandidates(scanning: true, queue: queue, in: fresh)
            plan = HealthPendingPlan.make(candidates: candidates, awaiting: queue.awaitingWrite, device: "PHONE", notes: notes, now: noon) { _, _, _ in true }
        }
        XCTAssertEqual(plan.due.count, 0)
        XCTAssertEqual(plan.stillPending.count, 0)
        print("Scanning 10,000 drinks for out-of-date Health samples took \(elapsed)")
        XCTAssertLessThan(elapsed, .seconds(1))
    }

    // MARK: - Who acts, and when

    private func editedDrink(owner: String?, marked: Bool = true) -> WaterEntry {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        var written = record(sample: "water-A", for: drink, marked: marked)
        written.owner = owner
        drink.setHealthRecord(written, for: .water)
        drink.amountML = 400
        context.insert(drink)
        return drink
    }

    private func plan(_ drinks: [WaterEntry], on device: String? = "PHONE", at now: Date? = nil, awaiting: Set<String> = [], mayChange: @escaping (HealthSampleKind, WaterEntry, Bool) -> Bool = { _, _, _ in true }) -> HealthPendingPlan {
        HealthPendingPlan.make(
            candidates: drinks,
            awaiting: awaiting,
            device: device,
            notes: HealthPendingNotes(defaults: defaults),
            now: now ?? noon,
            mayChange: mayChange
        )
    }

    func testTheOwnerActsOnAnEditAtOnce() {
        let drink = editedDrink(owner: "PHONE")
        let due = plan([drink]).due
        XCTAssertEqual(due.map(\.work), [.replace(sampleUUID: "water-A")])
        XCTAssertEqual(due.map(\.kind), [.water])
    }

    /// The whole point of the fallback: another device doesn't race the owner. It takes over
    /// only once the drink has been out of date for a week, as seen from here.
    func testAnotherDeviceTakesOverOnlyAfterAWeek() {
        let drink = editedDrink(owner: "IPAD")
        XCTAssertTrue(plan([drink]).due.isEmpty, "first seen now")
        XCTAssertTrue(plan([drink], at: noon.addingTimeInterval(6 * 24 * 3600)).due.isEmpty)
        XCTAssertEqual(plan([drink], at: noon.addingTimeInterval(7 * 24 * 3600)).due.map(\.work), [.replace(sampleUUID: "water-A")])
        XCTAssertEqual(plan([drink]).stillPending.count, 1, "still pending while it waits")
    }

    func testAnUnownedSampleWaitsAWeekForEveryone() {
        let drink = editedDrink(owner: nil)
        XCTAssertTrue(plan([drink]).due.isEmpty)
        XCTAssertEqual(plan([drink], at: noon.addingTimeInterval(7 * 24 * 3600)).due.count, 1)
    }

    func testALetGoStandsForAWeek() {
        let drink = editedDrink(owner: "PHONE")
        let key = HealthPendingNotes.key(kind: .water, currentUUID: "water-A", field: drink.healthWaterWritten)
        HealthPendingNotes(defaults: defaults).noteLetGo(key, now: noon)
        XCTAssertTrue(plan([drink], at: noon.addingTimeInterval(3600)).due.isEmpty)
        XCTAssertEqual(plan([drink], at: noon.addingTimeInterval(7 * 24 * 3600)).due.count, 1)
    }

    func testWorkThisDeviceMayNotDoIsLeftPending() {
        let drink = editedDrink(owner: "PHONE")
        let skipped = plan([drink]) { _, _, _ in false }
        XCTAssertTrue(skipped.due.isEmpty)
        XCTAssertEqual(skipped.stillPending.count, 1)
    }

    /// A sample this device already took out is put back whatever else holds, and the check
    /// on caffeine tracking is told so.
    func testASampleThisDeviceTookOutIsPutBack() {
        let drink = editedDrink(owner: "IPAD", marked: false)
        var toldPuttingBack: [Bool] = []
        let due = plan([drink], awaiting: ["water-A"]) { _, _, puttingBack in
            toldPuttingBack.append(puttingBack)
            return true
        }.due
        XCTAssertEqual(due.map(\.work), [.replace(sampleUUID: "water-A")])
        XCTAssertEqual(toldPuttingBack, [true])
    }

    func testADeletedDrinkIsNotPlanned() throws {
        let drink = editedDrink(owner: "PHONE")
        try context.save()
        context.delete(drink)
        XCTAssertTrue(plan([drink]).due.isEmpty)
    }

    // MARK: - Claiming

    /// Edited first on a device that can't write to Health, then again on one that can:
    /// that device claims it, and acts at once once its sync is on, as 1.8.1 did.
    func testALaterEditClaimsASampleNobodyOwns() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        drink.noteHealthEdit(claimedBy: nil)
        XCTAssertNil(drink.healthRecord(for: .water).record?.owner)
        drink.noteHealthEdit(claimedBy: "PHONE")
        XCTAssertEqual(drink.healthRecord(for: .water).record?.owner, "PHONE")
        drink.noteHealthEdit(claimedBy: "IPAD")
        XCTAssertEqual(drink.healthRecord(for: .water).record?.owner, "PHONE", "an owner, once there, stays")
    }

    func testMovingTheQueueClaimsAStaleSampleNobodyOwns() {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        drink.noteStaleHealthSample("water-A", kind: .water, claimedBy: nil)
        drink.noteStaleHealthSample("water-A", kind: .water, claimedBy: "PHONE")
        XCTAssertEqual(drink.healthRecord(for: .water).record?.state, .stale)
        XCTAssertEqual(drink.healthRecord(for: .water).record?.owner, "PHONE")
    }

    /// Cleared because it stopped counting: an edit marks the record, so the owner writes
    /// it again at once if it comes to count.
    func testAnEditToADrinkHealthHoldsNothingForMarksIt() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.setHealthRecord(HealthKitManager.nothingRecord(for: drink, after: .none, owner: "PHONE"), for: .water)
        drink.noteHealthEdit(claimedBy: "IPAD")
        let nothing = try XCTUnwrap(drink.healthRecord(for: .water).record)
        XCTAssertEqual(nothing.state, .nothing)
        XCTAssertTrue(nothing.editedSince)
        XCTAssertEqual(nothing.owner, "PHONE")
    }

    /// The ordinary pass writing it too, at once and on any device, is the race the owner
    /// rules exist to avoid, so a drink a replacement cleared is left to the replacement.
    func testADrinkAReplacementClearedIsLeftToTheReplacement() {
        let drink = WaterEntry(amountML: 250, timestamp: noon, drinkType: .coffee)
        XCTAssertTrue(HealthKitManager.isEligible(drink, since: .distantPast))
        XCTAssertTrue(HealthKitManager.isCaffeineEligible(drink, since: .distantPast))
        drink.setHealthRecord(HealthKitManager.nothingRecord(for: drink, after: .none, owner: "PHONE"), for: .water)
        drink.setHealthRecord(HealthKitManager.nothingRecord(for: drink, after: .none, owner: "PHONE"), for: .caffeine)
        XCTAssertFalse(HealthKitManager.isEligible(drink, since: .distantPast))
        XCTAssertFalse(HealthKitManager.isCaffeineEligible(drink, since: .distantPast))
    }

    /// Caffeine is claimed only by a device that may write caffeine.
    func testEachKindIsClaimedOnlyWhereItCanBeWritten() {
        let coffee = WaterEntry(amountML: 250, timestamp: noon, drinkType: .coffee)
        coffee.healthKitSampleUUID = "water-A"
        coffee.caffeineSampleUUID = "caffeine-B"
        coffee.noteHealthEdit { $0 == .water ? "PHONE" : nil }
        XCTAssertEqual(coffee.healthRecord(for: .water).record?.owner, "PHONE")
        XCTAssertNil(coffee.healthRecord(for: .caffeine).record?.owner)
    }

    /// Edited back to what Health already has: the mark goes, so a later change from a
    /// device still on 1.8.1 still gets the owner's day's wait.
    func testAnEditBackToWhatHealthHasTakesItsMarkBack() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        drink.setHealthRecord(record(sample: "water-A", for: drink), for: .water)
        drink.noteHealthEdit(claimedBy: "PHONE")
        drink.amountML = 400
        drink.settleHealthEdit(on: "PHONE")
        XCTAssertTrue(try XCTUnwrap(drink.healthRecord(for: .water).record).editedSince, "still edited")
        drink.noteHealthEdit(claimedBy: "PHONE")
        drink.amountML = 250
        drink.settleHealthEdit(on: "PHONE")
        XCTAssertFalse(try XCTUnwrap(drink.healthRecord(for: .water).record).editedSince, "back to what Health has")
    }

    /// Another device may be replacing the sample right now, so only its owner takes the
    /// mark back. The owner sees the edit back as a change and puts Health right.
    func testOnlyTheOwnerTakesAMarkBack() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        drink.setHealthRecord(record(sample: "water-A", for: drink, marked: true), for: .water)
        drink.settleHealthEdit(on: "IPAD")
        XCTAssertTrue(try XCTUnwrap(drink.healthRecord(for: .water).record).editedSince)
        drink.settleHealthEdit(on: nil)
        XCTAssertTrue(try XCTUnwrap(drink.healthRecord(for: .water).record).editedSince, "a device with no name owns nothing")
    }

    /// A mark is dropped only against what the store holds, never against a change that
    /// was never saved.
    func testAMarkIsNotDroppedAgainstUnsavedChanges() throws {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        drink.healthKitSampleUUID = "water-A"
        context.insert(drink)
        try context.save()
        let queue = HealthReplacementQueue(defaults: defaults)
        queue.markAwaitingWrite("water-A")
        drink.healthKitSampleUUID = nil
        XCTAssertTrue(context.hasChanges)
        _ = try HealthKitManager.replacementCandidates(scanning: false, queue: queue, in: context)
        XCTAssertEqual(queue.awaitingWrite, ["water-A"])
        try context.save()
        _ = try HealthKitManager.replacementCandidates(scanning: false, queue: queue, in: context)
        XCTAssertEqual(queue.awaitingWrite, [])
    }

    /// Kept on this device, the same every time it is asked.
    func testThisDeviceHasOneLastingName() throws {
        let first = try XCTUnwrap(HealthInstall.id)
        XCTAssertEqual(HealthInstall.id, first)
        XCTAssertNotNil(UUID(uuidString: first))
    }

    // MARK: - What a delete looks for

    /// By UUID and by every sync identifier the sample may carry, so a sample another
    /// device wrote before this one heard its UUID still goes.
    func testADeletedDrinksSamplesAreFoundByUUIDAndSyncIdentifier() {
        let coffee = WaterEntry(amountML: 250, timestamp: noon, drinkType: .coffee)
        coffee.healthSyncID = "drink"
        coffee.healthKitSampleUUID = "water-A"
        coffee.setHealthRecord(record(sample: "water-A", for: coffee, syncIdentifier: "legacy-water-Z.water"), for: .water)
        XCTAssertEqual(HealthSampleReference.all(of: coffee), [
            HealthSampleReference(kind: .water, uuid: "water-A", syncIdentifiers: ["legacy-water-Z.water", "drink.water"]),
            HealthSampleReference(kind: .caffeine, uuid: nil, syncIdentifiers: ["drink.caffeine"]),
        ])

        let before19 = WaterEntry(amountML: 250, timestamp: noon)
        before19.healthSyncID = nil
        XCTAssertEqual(HealthSampleReference.all(of: before19), [])
        before19.healthKitSampleUUID = "water-C"
        XCTAssertEqual(HealthSampleReference.all(of: before19), [
            HealthSampleReference(kind: .water, uuid: "water-C", syncIdentifiers: []),
        ])
    }

    // MARK: - Caffeine

    /// Tracking is set on each device. One without it must not delete what a tracking device
    /// wrote: only drinks since sync was turned on are written afresh, so an older coffee's
    /// caffeine would be gone for good.
    func testCaffeineIsLeftAloneWhereItIsNotTrackedOrNotAllowed() {
        let coffee = WaterEntry(amountML: 250, drinkType: .coffee)
        XCTAssertFalse(HealthKitManager.leavesCaffeineAlone(coffee, tracked: true, authorized: true))
        XCTAssertTrue(HealthKitManager.leavesCaffeineAlone(coffee, tracked: false, authorized: true))
        XCTAssertTrue(HealthKitManager.leavesCaffeineAlone(coffee, tracked: true, authorized: false))
        let water = WaterEntry(amountML: 250)
        XCTAssertFalse(HealthKitManager.leavesCaffeineAlone(water, tracked: false, authorized: true), "a drink with no caffeine left may lose its old figure")
    }

    func testWhatAReplacementStillHasToWrite() {
        let coffee = WaterEntry(amountML: 250, drinkType: .coffee)
        let water = WaterEntry(amountML: 250)
        XCTAssertTrue(HealthKitManager.replacementStillCounts(coffee, kind: .caffeine))
        XCTAssertFalse(HealthKitManager.replacementStillCounts(water, kind: .caffeine))
        XCTAssertTrue(HealthKitManager.replacementStillCounts(water, kind: .water))
    }

    /// Health holds nothing, as of the drink's figures now, under the identifier and version
    /// last used, so the next write goes above it.
    func testANothingRecordKeepsTheLastIdentifierAndVersion() {
        let drink = WaterEntry(amountML: 250, timestamp: noon)
        let before = record(sample: "water-A", for: drink)
        drink.amountML = 0
        let nothing = HealthKitManager.nothingRecord(for: drink, after: .record(before), owner: "IPAD")
        XCTAssertEqual(nothing.state, .nothing)
        XCTAssertNil(nothing.sampleUUID)
        XCTAssertEqual(nothing.syncIdentifier, "drink.water")
        XCTAssertEqual(nothing.syncVersion, before.syncVersion)
        XCTAssertEqual(nothing.figures, HealthFigures(of: drink))
        XCTAssertEqual(nothing.owner, "IPAD", "the device that cleared it writes it again if it comes to count")
    }
}

/// A drink as 1.8.1 stored it, before the three 1.9 fields existed.
enum HealthEditLegacySchema {
    @Model
    final class WaterEntry {
        var amountML: Int = 0
        var timestamp: Date = Date.distantPast
        var drinkTypeRawValue: String?
        var healthKitSampleUUID: String?
        var caffeineSampleUUID: String?

        init(amountML: Int, timestamp: Date) {
            self.amountML = amountML
            self.timestamp = timestamp
        }
    }
}
