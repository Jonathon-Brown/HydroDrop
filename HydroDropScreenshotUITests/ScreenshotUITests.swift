import XCTest
import UIKit

final class ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Where captures are written when running locally. CI has no such path, so the run
    /// there relies on the attachments instead of failing on a write it can't do.
    ///
    /// Without `SCREENSHOT_OUTPUT_DIR` this used to be the main checkout's `screenshots/`,
    /// spelled out in full, so a test run in any worktree rewrote that checkout's tracked
    /// captures, where another session may be working. It is now the `screenshots/` of the
    /// checkout these tests were built from.
    private var outputDirectory: String? {
        ProcessInfo.processInfo.environment["SCREENSHOT_OUTPUT_DIR"]
            ?? (ProcessInfo.processInfo.environment["CI"] == nil
                ? URL(fileURLWithPath: #filePath)
                    .deletingLastPathComponent()
                    .deletingLastPathComponent()
                    .appendingPathComponent("screenshots").path
                : nil)
    }

    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        // As a US user: in the EEA, the UK and Switzerland the app shows no ads, so the
        // Settings upgrade card and the paywall leave out "No ads", and the App Store
        // captures would change with whatever region the simulator happens to be set to.
        app.launchArguments = ["-UITestSeedHistory", "-AdRegion", "USA"]
        app.launch()

        logTodaysDrinks(app)

        // The quick adds sit below the world, so tapping them scrolled Today down past
        // its title, streak and Settings gear. Back to the top before the capture.
        let settingsButton = app.buttons["Settings"].firstMatch
        var swipes = 0
        while swipes < 4, !(settingsButton.exists && settingsButton.isHittable) {
            app.scrollViews.firstMatch.swipeDown()
            swipes += 1
        }
        XCTAssertTrue(settingsButton.isHittable, "Today didn't scroll back up to its header")
        // Scrolling brings up the scroll indicator down the right edge, which takes a
        // moment to fade and otherwise ends up in the capture.
        if swipes > 0 { sleep(2) }
        save(app.screenshot(), name: "01-today")

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Last 7 days"].waitForExistence(timeout: 10), "history chart didn't appear")
        save(app.screenshot(), name: "02-history")

        // Settings is a sheet now, opened from the gear in the corner of each tab.
        app.buttons["Settings"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10), "settings didn't appear")
        save(app.screenshot(), name: "03-settings")

        // The paywall, for the mascots image, opened the way a free user meets it: from
        // "More looks" under the droplet on Today.
        app.buttons["Done"].tap()
        app.tabBars.buttons["Today"].tap()
        let moreLooks = app.buttons["More looks"]
        XCTAssertTrue(moreLooks.waitForExistence(timeout: 10), "no More looks link on Today")
        moreLooks.tap()
        // The plans load after the sheet appears. Waiting for a price means the capture
        // is the finished paywall, not the spinner it starts with.
        let price = app.staticTexts.containing(NSPredicate(format: "label CONTAINS[c] '$'")).firstMatch
        XCTAssertTrue(price.waitForExistence(timeout: 25), "the paywall's plans never loaded")
        XCTAssertTrue(app.staticTexts["No ads, ever"].exists, "the paywall was captured as a user in a country without ads")
        save(app.screenshot(), name: "04-paywall")
    }

    /// History as a HydroDrop+ subscriber sees it: thirty days rather than seven, and no
    /// ads. The App Store image for History promises 30-day trends, so it uses this one.
    /// Runs after `testCaptureScreenshots` (tests run in name order), and every seeded
    /// launch starts from no entitlement, so the forced one doesn't carry over.
    func testCaptureSubscriberScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedHistory", "-UITestForceSubscribed", "-AdRegion", "USA"]
        app.launch()

        // The same day as the free captures, so today's bar matches across the set.
        logTodaysDrinks(app)

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(
            app.staticTexts["Last 30 days"].waitForExistence(timeout: 10),
            "History isn't showing a subscriber's 30 days"
        )
        save(app.screenshot(), name: "05-history-plus")
    }

    /// Today's two quick adds, on top of the seeded week. Both tests call this straight
    /// after `app.launch()`, so its first wait is also the wait for the launch.
    private func logTodaysDrinks(_ app: XCUIApplication) {
        // A seeded launch rebuilds the store, starts the ad SDK and draws the World from
        // its first frame, and the subscriber launch then re-lays out Today as HydroDrop+
        // turns on. This used to be one 5-second wait for the 200 mL button, which Xcode
        // Cloud run 54 missed on a docs-only merge, blaming imperial units that a seeded
        // launch can't have. Waiting for the launch first, with room to spare, keeps a
        // slow launch apart from a missing button, and costs a passing run nothing.
        XCTAssertTrue(
            app.tabBars.buttons["Today"].waitForExistence(timeout: 30),
            "the app never showed its tab bar after launch"
        )

        // These taps are the screenshot: if the buttons aren't there, the capture is of
        // an empty Today screen and the run should say so rather than quietly succeed.
        let button200 = app.buttons["200 mL"]
        XCTAssertTrue(button200.waitForExistence(timeout: 10), "no 200 mL quick-add button")
        button200.tap()

        let button330 = app.buttons["330 mL"]
        XCTAssertTrue(button330.waitForExistence(timeout: 10), "no 330 mL quick-add button")
        button330.tap()

        // The seeded day plus both taps: the total on screen has to reflect them.
        XCTAssertTrue(
            app.staticTexts["530 mL"].waitForExistence(timeout: 10),
            "today's total didn't add up to the two quick adds"
        )

        // A quick add offers a few seconds of undo. That bar is transient and has no
        // business in an App Store screenshot, so wait it out rather than capture it.
        let undo = app.buttons["Undo"]
        if undo.exists {
            XCTAssertTrue(undo.waitForNonExistence(timeout: 10), "the undo toast never went away")
        }
    }

    private func save(_ screenshot: XCUIScreenshot, name: String) {
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let directory = outputDirectory, let data = screenshot.image.pngData() else { return }
        let url = URL(fileURLWithPath: directory)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        do {
            try data.write(to: url.appendingPathComponent("\(name).png"))
        } catch {
            XCTFail("could not write \(name).png to \(directory): \(error)")
        }
    }
}
