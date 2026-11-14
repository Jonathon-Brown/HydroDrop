import XCTest

/// Opt in explicitly so a flag-on binary with missing Duo UI fails rather than quietly skipping.
/// These previews have no services. No Create, Join, Reconnect or destructive confirmation is sent.
final class DuoUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    private var expectsDuo: Bool {
        get throws {
            let value = ProcessInfo.processInfo.environment["DUO_EXPECT"]
                ?? ProcessInfo.processInfo.environment["TEST_RUNNER_DUO_EXPECT"]
            guard let value else { throw XCTSkip("Set TEST_RUNNER_DUO_EXPECT=YES or NO for an explicit flag smoke run") }
            guard value == "YES" || value == "NO" else {
                XCTFail("DUO_EXPECT must be YES or NO")
                throw XCTSkip("Invalid smoke configuration")
            }
            return value == "YES"
        }
    }

    private func element(_ app: XCUIApplication, _ id: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: id).firstMatch
    }

    private func show(_ target: XCUIElement, in app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) {
        for _ in 0..<8 {
            if target.exists && target.isHittable { return }
            app.swipeUp()
        }
        XCTAssertTrue(target.exists && target.isHittable, "Cannot reach \(target.identifier)", file: file, line: line)
    }

    private func launch(_ scenario: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestSkipOnboarding", "-UITestForceSubscribed", "-AdRegion", "GBR", "-DuoPreview", scenario]
        app.launch()
        return app
    }

    private func openSettings(_ app: XCUIApplication) {
        let gear = app.buttons["Settings"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 15))
        gear.tap()
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
    }

    private func openDuo(_ app: XCUIApplication) {
        let row = element(app, "settings.duo")
        show(row, in: app)
        row.tap()
        XCTAssertTrue(element(app, "duo.screen").waitForExistence(timeout: 10))
    }

    func testSettingsFlagAndSampleConfirmationSmoke() throws {
        let enabled = try expectsDuo
        let app = launch("sample")
        defer { app.terminate() }
        openSettings(app)
        if !enabled {
            XCTAssertFalse(element(app, "settings.duo").exists)
            XCTAssertFalse(element(app, "duo.screen").exists)
            return
        }
        openDuo(app)
        XCTAssertTrue(element(app, "duo.card").exists)
        for (id, title, destructive) in [("duo.leave", "Leave this duo?", "Leave duo"), ("duo.block", "Block this partner?", "Block")] {
            let row = app.buttons[id].firstMatch
            show(row, in: app)
            row.tap()
            let dialog = app.sheets.firstMatch
            XCTAssertTrue(dialog.waitForExistence(timeout: 5), "\(id) must ask before acting")
            // The exact Block title includes the partner's name; the destructive button and
            // dismissal establish that this is the confirmation, without accepting it.
            if id == "duo.leave" { XCTAssertTrue(dialog.staticTexts[title].exists) }
            XCTAssertTrue(dialog.buttons[destructive].exists)
            let cancel = dialog.buttons["Cancel"]
            if cancel.exists {
                cancel.tap()
            } else {
                // iOS 27 presents this as an anchored popover. Its cancellation control
                // is the accessible dismiss region outside the confirmation sheet.
                let dismissRegions = app.otherElements.matching(identifier: "PopoverDismissRegion")
                XCTAssertEqual(dismissRegions.count, 1)
                let dismiss = dismissRegions.firstMatch
                XCTAssertTrue(dismiss.isHittable)
                dismiss.tap()
            }
            XCTAssertTrue(dialog.waitForNonExistence(timeout: 5))
            XCTAssertTrue(element(app, "duo.card").exists)
        }
    }

    func testEmptyStartsWithAnUnansweredAgeGate() throws {
        guard try expectsDuo else { return }
        let app = launch("empty")
        defer { app.terminate() }
        openSettings(app)
        openDuo(app)
        XCTAssertTrue(element(app, "duo.haveCode").exists)
        let start = app.buttons["duo.start"]
        show(start, in: app)
        start.tap()
        XCTAssertTrue(element(app, "duo.agegate.year").waitForExistence(timeout: 5))
        XCTAssertFalse(element(app, "duo.setup.create").exists)
        XCTAssertFalse(app.buttons["duo.agegate.continue"].isEnabled)
    }

    func testPreviewScenariosExposeTheirRequiredRows() throws {
        guard try expectsDuo else { return }
        for scenario in ["waiting", "justjoined", "silent", "full", "maintenance", "disconnected", "restore"] {
            let app = launch(scenario)
            openSettings(app)
            openDuo(app)
            switch scenario {
            case "waiting": XCTAssertTrue(element(app, "duo.invite.show").exists)
            case "full": show(element(app, "duo.start.full"), in: app)
            case "maintenance":
                XCTAssertTrue(app.staticTexts["HydroDrop's duo service is not available right now. Your duo will catch up when it is."].exists)
            case "disconnected":
                XCTAssertTrue(element(app, "duo.notice.disconnected.reconnect").exists)
                XCTAssertTrue(element(app, "duo.notice.disconnected.fresh").exists)
            case "restore":
                XCTAssertTrue(element(app, "duo.notice.restore.continue").exists)
                XCTAssertTrue(element(app, "duo.notice.restore.fresh").exists)
            case "justjoined", "silent":
                // These offers belong to Today. Close Settings completely before finding them.
                app.navigationBars["Duo Streaks"].buttons.firstMatch.tap()
                XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
                app.buttons["Done"].tap()
                let offer = element(app, scenario == "justjoined" ? "duo.notthem" : "duo.reconnectoffer")
                show(offer, in: app)
            default: XCTFail("Uncovered scenario")
            }
            app.terminate()
        }
    }
}
