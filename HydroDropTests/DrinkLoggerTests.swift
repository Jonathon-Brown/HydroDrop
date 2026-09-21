import XCTest
import SwiftData
@testable import HydroDrop

/// Every way of logging a drink now writes through `DrinkLogger`, so a mistake here is
/// a mistake in all five of them at once. These drive the real thing against a real
/// in-memory store rather than a stand-in.
///
/// Only the core is covered. `logInApp` reaches straight into `WidgetPublisher`,
/// `ReminderManager` and `WatchSessionManager`, all three of which are singletons with
/// real side effects, and pretending otherwise would test the mocks instead.
@MainActor
final class DrinkLoggerTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    override func setUpWithError() throws {
        try super.setUpWithError()
        container = try ModelContainer(
            for: WaterEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDownWithError() throws {
        context = nil
        container = nil
        try super.tearDownWithError()
    }

    private func storedEntries() throws -> [WaterEntry] {
        try context.fetch(FetchDescriptor<WaterEntry>())
    }

    // MARK: - Writing

    func testTheDrinkLandsInTheStoreWithWhatItWasGiven() throws {
        let logged = try DrinkLogger.log(
            amountML: 330,
            drinkType: .coffee,
            timestamp: now,
            in: context,
            loggedBy: "a test",
            now: now
        )

        XCTAssertEqual(logged.entry.amountML, 330)
        XCTAssertEqual(logged.entry.drinkType, .coffee)
        XCTAssertEqual(logged.entry.timestamp, now)
        XCTAssertEqual(try storedEntries().count, 1)
    }

    func testAnUnspecifiedDrinkIsWater() throws {
        let logged = try DrinkLogger.log(amountML: 250, in: context, loggedBy: "a test", now: now)
        XCTAssertEqual(logged.entry.drinkType, .water)
    }

    /// The Today screen leaves the write to autosave, so nothing should be committed
    /// underneath it — but the entry still has to be visible to everything downstream.
    func testAnUnsavedDrinkIsStillVisibleInTheContext() throws {
        let logged = try DrinkLogger.log(
            amountML: 500,
            timestamp: now,
            in: context,
            savesImmediately: false,
            loggedBy: "a test",
            now: now
        )

        XCTAssertEqual(logged.allEntries.count, 1)
        XCTAssertEqual(logged.todayTotalML, 500)
        XCTAssertTrue(context.hasChanges, "the write should still be pending")
    }

    // MARK: - Totals

    /// The total is what the goal is measured against, so it has to count the drink
    /// that was just logged rather than the state from before it.
    func testTodaysTotalIncludesTheDrinkJustLogged() throws {
        context.insert(WaterEntry(amountML: 400, timestamp: now))
        try context.save()

        let logged = try DrinkLogger.log(
            amountML: 250,
            timestamp: now,
            in: context,
            loggedBy: "a test",
            now: now
        )

        XCTAssertEqual(logged.todayTotalML, 650)
        XCTAssertEqual(logged.allEntries.count, 2)
    }

    /// A juice counts for less than what was poured, and the reminder schedule and the
    /// widget both read this number.
    func testTheTotalCountsHydrationRatherThanVolume() throws {
        let logged = try DrinkLogger.log(
            amountML: 1_000,
            drinkType: .juice,
            timestamp: now,
            in: context,
            loggedBy: "a test",
            now: now
        )
        XCTAssertEqual(logged.todayTotalML, 850, "juice hydrates at 0.85")
    }

    func testYesterdaysDrinksAreNotInTodaysTotal() throws {
        let yesterday = now.addingTimeInterval(-86_400)
        context.insert(WaterEntry(amountML: 900, timestamp: yesterday))
        try context.save()

        let logged = try DrinkLogger.log(
            amountML: 250,
            timestamp: now,
            in: context,
            loggedBy: "a test",
            now: now
        )

        XCTAssertEqual(logged.todayTotalML, 250)
        XCTAssertEqual(logged.allEntries.count, 2, "yesterday's drink is still in the store")
    }

    /// A drink backdated to earlier today still counts towards today.
    func testADrinkBackdatedWithinTodayStillCounts() throws {
        let earlier = now.addingTimeInterval(-6 * 3_600)
        let logged = try DrinkLogger.log(
            amountML: 300,
            timestamp: earlier,
            in: context,
            loggedBy: "a test",
            now: now
        )
        XCTAssertEqual(logged.todayTotalML, 300)
    }

    // MARK: - Totals on their own

    func testTheTotalHelperAgreesWithWhatLoggingReports() {
        let entries = [
            WaterEntry(amountML: 250, timestamp: now),
            WaterEntry(amountML: 250, timestamp: now.addingTimeInterval(-86_400)),
            WaterEntry(amountML: 100, timestamp: now, drinkType: .coffee),
        ]
        XCTAssertEqual(DrinkLogger.todayTotalML(of: entries, now: now), 250 + 90)
    }

    func testAnEmptyLogHasNoTotal() {
        XCTAssertEqual(DrinkLogger.todayTotalML(of: [], now: now), 0)
    }
}
