import XCTest
@testable import HydroDrop

/// Lifetime and a subscription are counted independently, because someone holding both
/// is still being charged for the subscription and needs Settings to say so.
@MainActor
final class PlusEntitlementsTests: XCTestCase {
    private let monthly = StoreManager.PlusProductID.monthly.rawValue
    private let yearly = StoreManager.PlusProductID.yearly.rawValue
    private let lifetime = StoreManager.PlusProductID.lifetime.rawValue

    func testNothingOwnedGrantsNothing() {
        let entitlements = PlusEntitlements(productIDs: [String]())
        XCTAssertFalse(entitlements.hasLifetime)
        XCTAssertFalse(entitlements.hasActiveSubscription)
        XCTAssertFalse(entitlements.grantsPlus)
    }

    func testEitherSubscriptionAloneGrantsPlusWithoutLifetime() {
        for id in [monthly, yearly] {
            let entitlements = PlusEntitlements(productIDs: [id])
            XCTAssertTrue(entitlements.hasActiveSubscription, id)
            XCTAssertFalse(entitlements.hasLifetime, id)
            XCTAssertTrue(entitlements.grantsPlus, id)
        }
    }

    func testLifetimeAloneGrantsPlusWithoutASubscription() {
        let entitlements = PlusEntitlements(productIDs: [lifetime])
        XCTAssertTrue(entitlements.hasLifetime)
        XCTAssertFalse(entitlements.hasActiveSubscription)
        XCTAssertTrue(entitlements.grantsPlus)
    }

    /// The case the old single `ownedProductID` lost: the subscription is still there
    /// beside lifetime, so it must be reported whichever order StoreKit lists the two in.
    func testLifetimeAndASubscriptionAreBothReportedInEitherOrder() {
        for ids in [[lifetime, yearly], [yearly, lifetime], [monthly, lifetime]] {
            let entitlements = PlusEntitlements(productIDs: ids)
            XCTAssertTrue(entitlements.hasLifetime, "\(ids)")
            XCTAssertTrue(entitlements.hasActiveSubscription, "\(ids)")
            XCTAssertTrue(entitlements.grantsPlus, "\(ids)")
        }
    }

    func testProductsThatAreNotHydroDropPlusCountForNothing() {
        let entitlements = PlusEntitlements(productIDs: ["com.example.other", ""])
        XCTAssertEqual(entitlements, PlusEntitlements(productIDs: [String]()))
        XCTAssertFalse(entitlements.grantsPlus)
    }

    /// A new product added to `PlusProductID` has to land on one side or the other, or it
    /// would be sold without granting anything.
    func testEveryPlusProductGrantsPlus() {
        for product in StoreManager.PlusProductID.allCases {
            XCTAssertTrue(PlusEntitlements(productIDs: [product.rawValue]).grantsPlus, product.rawValue)
        }
    }
}

/// Settings tells a lifetime owner to cancel their subscription only while it can still
/// charge, which is a different question from whether it is still active.
final class SubscriptionRenewalTests: XCTestCase {
    private typealias Snapshot = SubscriptionRenewal.Snapshot

    func testNoSubscriptionHistoryCannotCharge() {
        XCTAssertFalse(SubscriptionRenewal.willCharge([]))
    }

    func testRenewingSubscriptionWillCharge() {
        XCTAssertTrue(SubscriptionRenewal.willCharge([Snapshot(state: .subscribed, willAutoRenew: true)]))
    }

    /// Cancelled but not yet ended: still active, but there is nothing left to cancel.
    func testCancelledSubscriptionThatIsStillActiveWillNotCharge() {
        XCTAssertFalse(SubscriptionRenewal.willCharge([Snapshot(state: .subscribed, willAutoRenew: false)]))
    }

    /// Billing retry drops out of the active list, but the payment can still go through.
    func testBillingRetryAndGracePeriodCanStillCharge() {
        XCTAssertTrue(SubscriptionRenewal.willCharge([Snapshot(state: .inBillingRetryPeriod, willAutoRenew: true)]))
        XCTAssertTrue(SubscriptionRenewal.willCharge([Snapshot(state: .inGracePeriod, willAutoRenew: true)]))
        XCTAssertFalse(SubscriptionRenewal.willCharge([Snapshot(state: .inBillingRetryPeriod, willAutoRenew: false)]))
    }

    func testEndedSubscriptionsCannotCharge() {
        XCTAssertFalse(SubscriptionRenewal.willCharge([
            Snapshot(state: .expired, willAutoRenew: true),
            Snapshot(state: .revoked, willAutoRenew: true),
        ]))
    }

    func testAnyChargeableStatusInTheGroupCounts() {
        XCTAssertTrue(SubscriptionRenewal.willCharge([
            Snapshot(state: .expired, willAutoRenew: false),
            Snapshot(state: .subscribed, willAutoRenew: true),
        ]))
    }
}
