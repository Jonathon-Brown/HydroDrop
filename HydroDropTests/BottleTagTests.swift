import XCTest
import SwiftData
@testable import HydroDrop

/// A sticker can be written by anyone with a phone, a touch can be read twice, and one
/// bottle is free. These are the three places a bottle tag can go wrong without any
/// NFC hardware being involved, so they are the three that can be tested.
final class BottleTagTests: XCTestCase {
    private let bottleID = UUID(uuidString: "6B1E7F70-0000-4000-8000-00000000ABCD")!

    // MARK: - The address on the sticker

    func testTheWrittenAddressIsTheOneTheWebsiteAndTheAppAgreeOn() {
        XCTAssertEqual(
            BottleTag.url(for: bottleID).absoluteString,
            "https://hydrodrop.us/tap?b=6B1E7F70-0000-4000-8000-00000000ABCD"
        )
    }

    func testWhatIsWrittenCanBeReadBack() {
        XCTAssertEqual(BottleTag.tagID(from: BottleTag.url(for: bottleID)), bottleID)
    }

    func testTheFallbackPagesAddressIsAcceptedToo() throws {
        let page = try XCTUnwrap(URL(string: "https://hydrodrop.us/tap.html?b=\(bottleID.uuidString)"))
        XCTAssertEqual(BottleTag.tagID(from: page), bottleID)
    }

    func testCasingAndExtraParametersDoNotMatter() throws {
        let shouting = try XCTUnwrap(URL(string: "HTTPS://HydroDrop.US/tap?utm=x&b=\(bottleID.uuidString.lowercased())"))
        XCTAssertEqual(BottleTag.tagID(from: shouting), bottleID)
    }

    func testAnythingThatIsNotExactlyOurAddressIsSomeoneElsesTag() throws {
        let id = bottleID.uuidString
        let rejected = [
            "http://hydrodrop.us/tap?b=\(id)",            // not HTTPS
            "https://www.hydrodrop.us/tap?b=\(id)",       // a host we do not serve
            "https://hydrodrop.us.evil.example/tap?b=\(id)",
            "https://evil.example/tap?b=\(id)",
            "https://hydrodrop.us/privacy.html?b=\(id)",  // not the tap path
            "https://hydrodrop.us/tapestry?b=\(id)",
            "https://hydrodrop.us/tap",                    // no bottle
            "https://hydrodrop.us/tap?bottle=\(id)",       // wrong parameter
            "https://hydrodrop.us/tap?b=not-a-uuid",
            "https://hydrodrop.us/tap?b=",
            "hydrodrop://tap?b=\(id)",                     // a custom scheme is never ours
        ]
        for address in rejected {
            let url = try XCTUnwrap(URL(string: address), address)
            XCTAssertNil(BottleTag.tagID(from: url), address)
        }
    }

    // MARK: - One touch, one drink

    private let start = Date(timeIntervalSince1970: 1_700_000_000)

    func testASecondTapInsideTheWindowIsIgnored() {
        var debouncer = BottleTapDebouncer()
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start))
        XCTAssertFalse(debouncer.shouldAccept(bottleID, at: start.addingTimeInterval(1)))
        XCTAssertFalse(debouncer.shouldAccept(bottleID, at: start.addingTimeInterval(29.9)))
    }

    func testTheSameBottleLogsAgainOnceTheWindowHasPassed() {
        var debouncer = BottleTapDebouncer()
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start))
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start.addingTimeInterval(30)))
    }

    func testADifferentBottleIsNotHeldUp() {
        var debouncer = BottleTapDebouncer()
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start))
        XCTAssertTrue(debouncer.shouldAccept(UUID(), at: start.addingTimeInterval(1)))
    }

    /// A phone left resting on the sticker reads it over and over. Those reads must not
    /// keep pushing the window out, or the bottle would never log again.
    func testIgnoredTapsDoNotExtendTheWindow() {
        var debouncer = BottleTapDebouncer()
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start))
        for second in stride(from: 5.0, to: 30.0, by: 5.0) {
            XCTAssertFalse(debouncer.shouldAccept(bottleID, at: start.addingTimeInterval(second)))
        }
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start.addingTimeInterval(30)))
    }

    func testAClockThatWentBackwardsIsNotARepeat() {
        var debouncer = BottleTapDebouncer()
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start))
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start.addingTimeInterval(-3_600)))
    }

    /// Undoing a bottle lifts the guard, so the same bottle can be tapped again at once.
    func testForgettingABottleLetsItBeTappedAgain() {
        var debouncer = BottleTapDebouncer()
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start))
        debouncer.forget(bottleID)
        XCTAssertTrue(debouncer.shouldAccept(bottleID, at: start.addingTimeInterval(2)))
    }

    /// The second read of one touch can be the one that launches the app.
    func testTheWindowSurvivesARelaunch() throws {
        let suiteName = "BottleTagTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        var first = BottleTapDebouncer.load(from: defaults)
        XCTAssertTrue(first.shouldAccept(bottleID, at: start))
        first.save(to: defaults)

        var afterRelaunch = BottleTapDebouncer.load(from: defaults)
        XCTAssertFalse(afterRelaunch.shouldAccept(bottleID, at: start.addingTimeInterval(3)))
    }

    // MARK: - One bottle is free

    func testTheFirstBottleIsFree() {
        XCTAssertTrue(BottleLimit.canAddBottle(existingCount: 0, isSubscribed: false))
    }

    func testASecondBottleNeedsPlus() {
        XCTAssertFalse(BottleLimit.canAddBottle(existingCount: 1, isSubscribed: false))
        XCTAssertFalse(BottleLimit.canAddBottle(existingCount: 4, isSubscribed: false))
    }

    func testPlusHasNoLimit() {
        XCTAssertTrue(BottleLimit.canAddBottle(existingCount: 1, isSubscribed: true))
        XCTAssertTrue(BottleLimit.canAddBottle(existingCount: 50, isSubscribed: true))
    }

    // MARK: - Bottles and their tags

    func testABottleAnswersToItsOwnTag() {
        let bottle = Bottle(name: "Desk bottle", capacityML: 750)
        XCTAssertEqual(bottle.allTagIDs, [bottle.id])
        XCTAssertTrue(BottleTag.bottle(for: bottle.id, in: [bottle]) === bottle)
    }

    func testALinkedTagMeansTheSameBottle() {
        let bottle = Bottle(name: "Desk bottle", capacityML: 750)
        let other = Bottle(name: "Gym bottle", capacityML: 1_000)
        let strangerTag = UUID()
        XCTAssertNil(BottleTag.bottle(for: strangerTag, in: [bottle, other]))

        other.link(tagID: strangerTag)

        XCTAssertTrue(BottleTag.bottle(for: strangerTag, in: [bottle, other]) === other)
        XCTAssertTrue(BottleTag.bottle(for: other.id, in: [bottle, other]) === other, "its own tag still works")
    }

    func testLinkingTheSameTagTwiceChangesNothing() {
        let bottle = Bottle(name: "Desk bottle", capacityML: 750)
        let tag = UUID()
        bottle.link(tagID: tag)
        let once = bottle.linkedTagIDs
        bottle.link(tagID: tag)
        bottle.link(tagID: bottle.id)
        XCTAssertEqual(bottle.linkedTagIDs, once)
        XCTAssertEqual(bottle.allTagIDs, [bottle.id, tag])
    }

    func testABottleHoldsWaterUnlessToldOtherwise() {
        let bottle = Bottle(name: "Desk bottle", capacityML: 750)
        XCTAssertEqual(bottle.drinkType, .water)
        bottle.drinkTypeRawValue = "something-from-a-newer-version"
        XCTAssertEqual(bottle.drinkType, .water)
        bottle.drinkTypeRawValue = nil
        XCTAssertEqual(bottle.drinkType, .water)
    }
}

/// `StoreMigration` builds the shared store with only `WaterEntry` in its schema, and it
/// is not allowed to change. The app then opens that same file with `Bottle` in the
/// schema too, so the new entity has to arrive by lightweight migration without costing
/// anyone a drink.
final class BottleSchemaMigrationTests: XCTestCase {
    private var workingDirectory: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        workingDirectory = URL.temporaryDirectory.appending(path: "HydroDropBottleSchema-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workingDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: workingDirectory)
        try super.tearDownWithError()
    }

    private func openWithFullSchema(_ url: URL) throws -> ModelContainer {
        let configuration = ModelConfiguration(
            schema: SharedModelContainer.schema,
            url: url,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: SharedModelContainer.schema, configurations: configuration)
    }

    func testAStoreMadeByTheMigrationOpensWithBottlesInTheSchemaAndKeepsEveryDrink() throws {
        let url = workingDirectory.appending(path: "HydroDrop.store")
        let rows = (0..<7).map { index in
            WaterEntry(
                amountML: 200 + index,
                timestamp: Date(timeIntervalSince1970: 1_700_000_000 - Double(index * 3_600)),
                drinkType: index.isMultiple(of: 2) ? .water : .coffee
            )
        }
        // Exactly how the shared store comes to exist on an upgrading user's phone.
        XCTAssertEqual(try StoreMigration.reinsert(rows, into: url), 7)

        let container = try openWithFullSchema(url)
        let context = ModelContext(container)

        let drinks = try context.fetch(FetchDescriptor<WaterEntry>())
        XCTAssertEqual(drinks.count, 7, "no drink may be lost to the schema change")
        XCTAssertEqual(drinks.filter { $0.drinkType == .coffee }.count, 3)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bottle>()), 0)

        context.insert(Bottle(name: "Desk bottle", capacityML: 750))
        try context.save()
    }

    func testBottlesAndDrinksAreBothThereOnTheNextLaunch() throws {
        let url = workingDirectory.appending(path: "HydroDrop.store")
        _ = try StoreMigration.reinsert([WaterEntry(amountML: 250, timestamp: Date(timeIntervalSince1970: 1_700_000_000))], into: url)

        do {
            let context = ModelContext(try openWithFullSchema(url))
            let bottle = Bottle(name: "Gym bottle", capacityML: 1_000, drinkType: .sparkling)
            bottle.link(tagID: UUID())
            context.insert(bottle)
            try context.save()
        }

        let context = ModelContext(try openWithFullSchema(url))
        let bottles = try context.fetch(FetchDescriptor<Bottle>())
        XCTAssertEqual(bottles.count, 1)
        XCTAssertEqual(bottles.first?.name, "Gym bottle")
        XCTAssertEqual(bottles.first?.capacityML, 1_000)
        XCTAssertEqual(bottles.first?.drinkType, .sparkling)
        XCTAssertEqual(bottles.first?.allTagIDs.count, 2)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<WaterEntry>()), 1)
    }

    /// The old reader still has to work on the new file: `StoreMigration.readRows` opens
    /// with only `WaterEntry`, and a user can end up back on it if the shared store
    /// cannot be reached.
    func testTheMigrationsOwnReaderStillReadsAStoreThatHasBottlesInIt() throws {
        let url = workingDirectory.appending(path: "HydroDrop.store")
        _ = try StoreMigration.reinsert([WaterEntry(amountML: 250, timestamp: Date(timeIntervalSince1970: 1_700_000_000))], into: url)
        do {
            let context = ModelContext(try openWithFullSchema(url))
            context.insert(Bottle(name: "Desk bottle", capacityML: 750))
            try context.save()
        }
        XCTAssertEqual(try StoreMigration.readRows(at: url).count, 1)
    }
}
