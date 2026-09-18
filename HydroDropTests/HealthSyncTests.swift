import XCTest
@testable import HydroDrop

/// HealthKit itself cannot be exercised without a device and a granted permission, so
/// these cover the rule that decides what is offered to it, which is where the
/// judgement calls live.
final class HealthEligibilityTests: XCTestCase {
    private let syncStart = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(
        offsetFromStart: TimeInterval,
        amountML: Int = 500,
        drinkType: DrinkType = .water,
        sampleUUID: String? = nil
    ) -> WaterEntry {
        let entry = WaterEntry(
            amountML: amountML,
            timestamp: syncStart.addingTimeInterval(offsetFromStart),
            drinkType: drinkType
        )
        entry.healthKitSampleUUID = sampleUUID
        return entry
    }

    func testADrinkLoggedAfterSyncWasTurnedOnIsEligible() {
        XCTAssertTrue(HealthKitManager.isEligible(entry(offsetFromStart: 60), since: syncStart))
    }

    /// Turning sync on is not a request to hand Health everything that came before.
    func testADrinkLoggedBeforeSyncWasTurnedOnIsNot() {
        XCTAssertFalse(HealthKitManager.isEligible(entry(offsetFromStart: -60), since: syncStart))
    }

    func testADrinkLoggedAtTheExactMomentSyncStartedIsEligible() {
        XCTAssertTrue(HealthKitManager.isEligible(entry(offsetFromStart: 0), since: syncStart))
    }

    /// Asking for the backfill is what makes the whole history eligible.
    func testTheBackfillMakesEverythingEligible() {
        XCTAssertTrue(HealthKitManager.isEligible(entry(offsetFromStart: -86_400 * 365), since: .distantPast))
    }

    /// The identifier doubles as the record of what is already in Health, so its
    /// presence is what stops a drink being written twice.
    func testADrinkAlreadyInHealthIsNotWrittenAgain() {
        let synced = entry(offsetFromStart: 60, sampleUUID: UUID().uuidString)
        XCTAssertFalse(HealthKitManager.isEligible(synced, since: syncStart))
    }

    func testAZeroAmountIsNotOfferedToHealth() {
        XCTAssertFalse(HealthKitManager.isEligible(entry(offsetFromStart: 60, amountML: 0), since: syncStart))
    }

    /// Health is given what HydroDrop counts, so the two never disagree about the day.
    func testTheHydratedAmountIsWhatCounts() {
        let coffee = entry(offsetFromStart: 60, amountML: 200, drinkType: .coffee)
        XCTAssertEqual(coffee.hydratedML, 180)
        XCTAssertTrue(HealthKitManager.isEligible(coffee, since: syncStart))
    }
}

final class HealthSettingsTests: XCTestCase {
    private var settings: AppSettings { AppSettings.shared }
    private var originalEnabled = false
    private var originalStart = Date()

    override func setUp() {
        super.setUp()
        originalEnabled = settings.healthKitSyncEnabled
        originalStart = settings.healthSyncStartDate
    }

    override func tearDown() {
        settings.healthKitSyncEnabled = originalEnabled
        settings.healthSyncStartDate = originalStart
        super.tearDown()
    }

    /// Nobody's health data is touched until they ask for it.
    func testSyncIsOffUntilTurnedOn() {
        XCTAssertFalse(
            UserDefaults.standard.object(forKey: "healthKitSyncEnabled") as? Bool ?? false,
            "Apple Health sync must default to off"
        )
    }

    func testTheBackfillFlagFollowsTheStartDate() {
        settings.healthSyncStartDate = Date()
        XCTAssertFalse(settings.hasBackfilledHealth)
        settings.healthSyncStartDate = .distantPast
        XCTAssertTrue(settings.hasBackfilledHealth)
    }
}

final class WaterEntryHealthFieldTests: XCTestCase {
    /// A drink that predates Health sync carries no sample, and a record already in
    /// CloudKit has no such field at all.
    func testANewEntryHasNoHealthSample() {
        XCTAssertNil(WaterEntry(amountML: 250).healthKitSampleUUID)
    }

    func testTheSampleIdentifierRoundTrips() {
        let entry = WaterEntry(amountML: 250)
        let uuid = UUID().uuidString
        entry.healthKitSampleUUID = uuid
        XCTAssertEqual(entry.healthKitSampleUUID, uuid)
    }
}
