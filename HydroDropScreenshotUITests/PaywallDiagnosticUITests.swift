import XCTest

/// Drives the paywall under the scheme's StoreKit configuration so the product-load
/// result can be observed from CI rather than by eye. The run action and the test action
/// both carry the configuration (see Scripts/patch_scheme_storekit.py), so a failure here
/// is a real StoreKit failure, not a missing-config artifact.
final class PaywallDiagnosticUITests: XCTestCase {
    func testPaywallLoadsSubscriptionOptions() throws {
        let app = XCUIApplication()
        app.launch()

        app.tabBars.buttons["Settings"].tap()
        let upgrade = app.buttons["Upgrade to HydroDrop+"]
        XCTAssertTrue(upgrade.waitForExistence(timeout: 15), "no upgrade row in Settings")
        upgrade.tap()

        // The fetch races a 15s timeout inside StoreManager, so allow more than that
        // before deciding nothing arrived.
        let unavailable = app.staticTexts["Subscription options unavailable"]
        let loaded = NSPredicate(format: "label CONTAINS[c] '$'")
        let price = app.staticTexts.containing(loaded).firstMatch

        let deadline = Date().addingTimeInterval(25)
        while Date() < deadline, !unavailable.exists, !price.exists {
            usleep(500_000)
        }

        let diagnostic = app.staticTexts["paywall-diagnostic"]
        let detail = diagnostic.exists ? diagnostic.label : "<no diagnostic rendered>"
        print("SKDIAG-UITEST >>> \(detail)")

        if let data = app.screenshot().image.pngData() {
            try? data.write(to: URL(fileURLWithPath: "/Users/jonathonbrown/Developer/HydroDrop/screenshots/paywall-diagnostic.png"))
        }

        XCTAssertFalse(
            unavailable.exists,
            "Paywall reported no subscription options. StoreManager says: \(detail)"
        )
    }
}
