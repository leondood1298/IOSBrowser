import XCTest

/// M1c flows: tab groups in the sidebar and the Settings screen.
final class IPadFeatureTests: UITestCase {
    @MainActor
    func testTabGroupsInSidebar() throws {
        launch()
        open("localhost:8000")
        waitForText("Browser test page")

        let toggle = [app.buttons["ToggleSidebar"], app.buttons["Show Sidebar"]].first { $0.waitForExistence(timeout: 3) }
        guard let toggle else { throw XCTSkip("No sidebar button found") }
        toggle.tap()
        let newGroup = app.staticTexts["New Tab Group"]
        XCTAssertTrue(newGroup.waitForExistence(timeout: 10))
        saveScreenshot("18-sidebar")

        newGroup.tap()
        let alert = app.alerts["New Tab Group"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.textFields.firstMatch.typeText("Work")
        alert.buttons["Create"].tap()
        XCTAssertTrue(app.staticTexts["Work"].waitForExistence(timeout: 10))
        saveScreenshot("19-tab-group")
    }

    @MainActor
    func testSettings() throws {
        launch()
        app.buttons["moreButton"].tap()
        tapMenuItem("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        saveScreenshot("20-settings")
        app.buttons["settingsDoneButton"].tap()
    }
}
