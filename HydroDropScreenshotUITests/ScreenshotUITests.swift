import XCTest
import UIKit

final class ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    /// Where captures are written when running locally. CI has no such path, so the run
    /// there relies on the attachments instead of failing on a write it can't do.
    private var outputDirectory: String? {
        ProcessInfo.processInfo.environment["SCREENSHOT_OUTPUT_DIR"]
            ?? (ProcessInfo.processInfo.environment["CI"] == nil
                ? "/Users/jonathonbrown/Developer/HydroDrop/screenshots"
                : nil)
    }

    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedHistory"]
        app.launch()

        // These taps are the screenshot: if the buttons aren't there, the capture is of
        // an empty Today screen and the run should say so rather than quietly succeed.
        let button200 = app.buttons["200 mL"]
        XCTAssertTrue(button200.waitForExistence(timeout: 5), "no 200 mL quick-add button — is the app in imperial?")
        button200.tap()

        let button330 = app.buttons["330 mL"]
        XCTAssertTrue(button330.waitForExistence(timeout: 3), "no 330 mL quick-add button")
        button330.tap()

        // The seeded day plus both taps: the total on screen has to reflect them.
        XCTAssertTrue(
            app.staticTexts["530 mL"].waitForExistence(timeout: 3),
            "today's total didn't add up to the two quick adds"
        )
        save(app.screenshot(), name: "01-today")

        app.tabBars.buttons["History"].tap()
        XCTAssertTrue(app.staticTexts["Last 7 days"].waitForExistence(timeout: 5), "history chart didn't appear")
        save(app.screenshot(), name: "02-history")

        app.tabBars.buttons["Settings"].tap()
        XCTAssertTrue(app.buttons["Calculate for me"].waitForExistence(timeout: 5), "settings didn't appear")
        save(app.screenshot(), name: "03-settings")
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
