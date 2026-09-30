import XCTest

/// Drives the paywall under the scheme's StoreKit configuration so the product-load
/// result can be observed from CI rather than by eye. The run action and the test action
/// both carry the configuration (see Scripts/patch_scheme_storekit.py), so a failure here
/// is a real StoreKit failure, not a missing-config artifact.
final class PaywallDiagnosticUITests: XCTestCase {
    func testPaywallLoadsSubscriptionOptions() throws {
        let app = XCUIApplication()
        // A fresh simulator has no history, and first-launch onboarding would sit on top
        // of the Settings button these tests drive. Only a free user has the upgrade row,
        // so purchases the simulator holds are ignored.
        app.launchArguments = ["-UITestSkipOnboarding", "-UITestIgnorePurchases"]
        app.launch()

        // The first query after launch also waits out the launch itself, which a busy
        // Xcode Cloud machine can stretch well past what the tap allows on its own.
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "no Settings gear after launch")
        settings.tap()
        let upgrade = try upgradeRow(in: app)
        upgrade.tap()

        // The fetch races a 15s timeout inside StoreManager, so allow more than that
        // before deciding nothing arrived.
        let unavailable = app.staticTexts["Subscription options unavailable"]
        let price = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] '$'")).firstMatch

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, !unavailable.exists, !price.exists {
            usleep(500_000)
        }

        let diagnostic = app.staticTexts["paywall-diagnostic"]
        let detail = diagnostic.exists ? diagnostic.label : "<no diagnostic rendered>"
        print("SKDIAG-UITEST >>> \(detail)")

        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "paywall"
        screenshot.lifetime = .keepAlways
        add(screenshot)

        // Guideline 2.1(b) is about a paywall that never resolves, so the spinner is the
        // failure this test exists to catch. Asserting only that the "unavailable" copy
        // is absent passed while the spinner was still turning — which is exactly the
        // state the app was rejected for.
        XCTAssertTrue(
            unavailable.exists || price.exists,
            "Paywall never left its loading state within 25s. StoreManager says: \(detail)"
        )
        XCTAssertTrue(
            price.exists,
            "Paywall reported no subscription options. StoreManager says: \(detail)"
        )
        XCTAssertFalse(
            unavailable.exists,
            "Paywall showed the unavailable state. StoreManager says: \(detail)"
        )
    }

    /// The paywall has to stay dismissible whatever the load did, so a user can never be
    /// trapped behind it.
    func testPaywallCanAlwaysBeClosed() throws {
        let app = XCUIApplication()
        // A fresh simulator has no history, and first-launch onboarding would sit on top
        // of the Settings button these tests drive. Only a free user has the upgrade row,
        // so purchases the simulator holds are ignored.
        app.launchArguments = ["-UITestSkipOnboarding", "-UITestIgnorePurchases"]
        app.launch()

        // The first query after launch also waits out the launch itself, which a busy
        // Xcode Cloud machine can stretch well past what the tap allows on its own.
        let settings = app.buttons["Settings"].firstMatch
        XCTAssertTrue(settings.waitForExistence(timeout: 30), "no Settings gear after launch")
        settings.tap()
        let upgrade = try upgradeRow(in: app)
        upgrade.tap()

        let close = app.buttons["Close"]
        XCTAssertTrue(close.waitForExistence(timeout: 10), "the paywall has no visible Close button")
        close.tap()
        XCTAssertTrue(upgrade.waitForExistence(timeout: 10), "the paywall did not dismiss")
    }

    /// Settings' upgrade row, which only a free user has. A HydroDrop+ user has an "is
    /// active" row in its place, so the wait ends on whichever turns up first, and a
    /// subscriber stops the test at once, with that said, instead of tapping a row that
    /// isn't there after the full timeout.
    private func upgradeRow(in app: XCUIApplication) throws -> XCUIElement {
        let upgrade = app.buttons["Upgrade to HydroDrop+"]
        let active = app.descendants(matching: .any)
            .matching(NSPredicate(format: "label BEGINSWITH 'HydroDrop+' AND label CONTAINS 'is active'"))
            .firstMatch
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !upgrade.exists, !active.exists {
            usleep(250_000)
        }
        if active.exists {
            XCTFail(
                "The app launched as a HydroDrop+ user, not a free one. -UITestIgnorePurchases "
                    + "should hide the simulator's StoreKit test purchases: check that StoreManager still reads it."
            )
        }
        return try XCTUnwrap(upgrade.exists ? upgrade : nil, "no upgrade row in Settings")
    }
}
