import XCTest
@testable import HydroDrop

/// Runs against a throwaway defaults suite so the tests never touch the app's own counts.
@MainActor
final class EventCounterTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suiteName = "EventCounterTests"

    override func setUp() {
        super.setUp()
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        UserDefaults().removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    func testStartsEmpty() {
        XCTAssertEqual(EventCounter.count(of: .purchaseAttempted, defaults: defaults), 0)
        XCTAssertNil(EventCounter.countingSince(defaults: defaults))
    }

    func testCountsAccumulate() {
        EventCounter.record(.purchaseAttempted, defaults: defaults)
        EventCounter.record(.purchaseAttempted, defaults: defaults)
        XCTAssertEqual(EventCounter.count(of: .purchaseAttempted, defaults: defaults), 2)
        XCTAssertNotNil(EventCounter.countingSince(defaults: defaults))
    }

    func testPaywallImpressionsAreCountedPerSource() {
        EventCounter.record(.paywallShown(.todayEntryPoint), defaults: defaults)
        EventCounter.record(.paywallShown(.todayEntryPoint), defaults: defaults)
        EventCounter.record(.paywallShown(.historyBanner), defaults: defaults)
        XCTAssertEqual(EventCounter.count(of: .paywallShown(.todayEntryPoint), defaults: defaults), 2)
        XCTAssertEqual(EventCounter.count(of: .paywallShown(.historyBanner), defaults: defaults), 1)
        XCTAssertEqual(EventCounter.count(of: .paywallShown(.settingsRow), defaults: defaults), 0)
    }

    /// Every source needs its own bucket, or two trigger points would silently share a count.
    func testEverySourceHasADistinctKey() {
        let keys = PaywallSource.allCases.map { EventCounter.Event.paywallShown($0).key }
        XCTAssertEqual(Set(keys).count, PaywallSource.allCases.count)
    }
}
