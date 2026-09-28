import XCTest
@testable import HydroDrop

/// Restore Purchases used to say nothing when it found nothing, which on a fresh account
/// reads as a broken button. Only a restore that found nothing new speaks; one that found
/// something closes the paywall by itself.
final class RestoreFindingTests: XCTestCase {
    private let none = PlusEntitlements(hasLifetime: false, hasActiveSubscription: false)
    private let subscribed = PlusEntitlements(hasLifetime: false, hasActiveSubscription: true)
    private let lifetime = PlusEntitlements(hasLifetime: true, hasActiveSubscription: false)
    private let both = PlusEntitlements(hasLifetime: true, hasActiveSubscription: true)

    func testAFreeUserWhoGetsAnythingBackHasRestored() {
        XCTAssertEqual(RestoreFinding(before: none, after: subscribed), .restored)
        XCTAssertEqual(RestoreFinding(before: none, after: lifetime), .restored)
        XCTAssertEqual(RestoreFinding(before: none, after: both), .restored)
        XCTAssertNil(RestoreFinding(before: none, after: subscribed).message)
    }

    func testAFreeUserWhoGetsNothingBackIsToldSo() {
        let finding = RestoreFinding(before: none, after: none)
        XCTAssertEqual(finding, .nothingToRestore)
        XCTAssertEqual(finding.message?.contains("different Apple Account"), true)
    }

    func testASubscriberWhoFindsLifetimeHasRestored() {
        XCTAssertEqual(RestoreFinding(before: subscribed, after: both), .restored)
    }

    /// On the Switch to Lifetime sheet: the subscription is already there, so the only
    /// thing a restore could add is Lifetime, and the message says it wasn't found.
    func testASubscriberWithNoLifetimeToFindIsToldTheirSubscriptionIsFine() {
        let finding = RestoreFinding(before: subscribed, after: subscribed)
        XCTAssertEqual(finding, .noLifetimeToRestore)
        XCTAssertEqual(finding.message?.contains("Your subscription isn't affected."), true)
    }

    /// A subscription that lapsed while the app stayed open still reads as active until
    /// something refreshes it, so the Switch to Lifetime sheet can be open when the
    /// restore finds it gone. That must not be described as unaffected.
    func testLosingAnEntitlementIsNeverDescribedAsUnaffected() {
        let lapsed = RestoreFinding(before: subscribed, after: none)
        XCTAssertEqual(lapsed, .nothingToRestore)
        XCTAssertEqual(lapsed.message?.contains("isn't affected"), false)
        XCTAssertEqual(RestoreFinding(before: lifetime, after: none), .nothingToRestore)
        XCTAssertEqual(RestoreFinding(before: both, after: subscribed), .noLifetimeToRestore)
        XCTAssertEqual(RestoreFinding(before: both, after: lifetime), .nothingMissing)
        // The same, the way the Switch to Lifetime sheet actually asks.
        XCTAssertEqual(RestoreFinding(before: subscribed, after: none, wantsLifetime: true), .nothingToRestore)
        XCTAssertEqual(RestoreFinding(before: both, after: subscribed, wantsLifetime: true), .noLifetimeToRestore)
    }

    /// The Switch to Lifetime sheet closes only for Lifetime, so a subscription coming
    /// back there hasn't finished anything and still needs a word.
    func testOnTheSwitchSheetOnlyLifetimeCountsAsRestored() {
        XCTAssertEqual(RestoreFinding(before: none, after: subscribed, wantsLifetime: true), .noLifetimeToRestore)
        XCTAssertEqual(RestoreFinding(before: subscribed, after: both, wantsLifetime: true), .restored)
        XCTAssertEqual(RestoreFinding(before: none, after: subscribed, wantsLifetime: false), .restored)
    }

    func testALifetimeOwnerHasNothingMissingAndNoMessage() {
        XCTAssertEqual(RestoreFinding(before: lifetime, after: lifetime), .nothingMissing)
        XCTAssertEqual(RestoreFinding(before: both, after: both), .nothingMissing)
        XCTAssertNil(RestoreFinding(before: lifetime, after: lifetime).message)
    }

    /// Health shows this text when HydroDrop asks to write. Caffeine is written too, for
    /// anyone tracking it, so the text has to say so.
    func testTheHealthWriteTextNamesEverythingHydroDropWrites() throws {
        let text = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "NSHealthUpdateUsageDescription") as? String)
        XCTAssertTrue(text.contains("dietary water"), text)
        XCTAssertTrue(text.contains("caffeine"), text)
    }
}
