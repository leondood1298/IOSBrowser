import XCTest

/// M1a flows: tabs, the tab overview, private tabs, page dialogs and pop-ups.
final class ScreenshotTests: UITestCase {
    @MainActor
    func testTabsFlow() throws {
        launch()
        saveScreenshot("01-new-tab-page")

        open("localhost:8000")
        waitForText("Browser test page")
        saveScreenshot("02-test-page")

        app.buttons["newTabButton"].tap()
        open("localhost:8000/second.html", tapField: false)
        waitForText("Second test page")
        saveScreenshot("03-two-tabs")

        app.buttons["tabOverviewButton"].tap()
        XCTAssertTrue(app.collectionViews["tabOverview"].waitForExistence(timeout: 10))
        sleep(1)
        saveScreenshot("04-tab-overview")
        app.buttons["overviewDoneButton"].tap()

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(element("newTabPage").waitForExistence(timeout: 10))
        saveScreenshot("05-private-tab")
    }

    @MainActor
    func testDialogsAndPopups() throws {
        launch()
        open("localhost:8000/dialogs.html")
        let alertButton = app.webViews.buttons["Show alert"]
        XCTAssertTrue(alertButton.waitForExistence(timeout: 60))
        alertButton.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        saveScreenshot("06-js-alert")
        alert.buttons["OK"].tap()

        app.webViews.buttons["Show confirm"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.firstMatch.buttons["OK"].tap()
        waitForText("confirmed", timeout: 10)

        app.webViews.links["Open second page in a new tab"].tap()
        waitForText("Second test page")
        saveScreenshot("07-popup-in-new-tab")
    }
}
