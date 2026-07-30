import XCTest
import UIKit

final class ScreenshotUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    func testCaptureScreenshots() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSeedHistory"]
        app.launch()

        let outputDir = "/Users/jonathonbrown/Developer/HydroDrop/screenshots"

        let button200 = app.buttons["200 mL"]
        if button200.waitForExistence(timeout: 5) {
            button200.tap()
        }
        let button330 = app.buttons["330 mL"]
        if button330.waitForExistence(timeout: 3) {
            button330.tap()
        }
        sleep(1)
        save(app.screenshot(), name: "01-today", to: outputDir)

        app.tabBars.buttons["History"].tap()
        sleep(1)
        save(app.screenshot(), name: "02-history", to: outputDir)

        app.tabBars.buttons["Settings"].tap()
        sleep(1)
        save(app.screenshot(), name: "03-settings", to: outputDir)
    }

    private func save(_ screenshot: XCUIScreenshot, name: String, to directory: String) {
        guard let data = screenshot.image.pngData() else { return }
        let url = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? data.write(to: url)
    }
}
