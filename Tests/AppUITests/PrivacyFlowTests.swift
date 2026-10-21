import XCTest

/// M2 flows: the tracking protection shield, Erase, and Clear Browsing Data.
final class PrivacyFlowTests: UITestCase {
    @MainActor
    func testShieldCountsBlockedTrackers() throws {
        launch()
        open("localhost:8000/trackers.html")
        waitForText("Trackers test page")
        sleep(2)
        app.buttons["shieldButton"].tap()
        XCTAssertTrue(app.switches["trackingProtectionToggle"].waitForExistence(timeout: 10))
        let analytics = app.descendants(matching: .any)["category-analytics"]
        XCTAssertTrue(analytics.waitForExistence(timeout: 5))
        XCTAssertTrue(analytics.label.contains("1 blocked"), analytics.label)
        saveScreenshot("21-shield")
    }

    @MainActor
    func testEraseClearsPrivateTabs() throws {
        launch()
        app.typeKey("n", modifierFlags: [.command, .shift])
        open("localhost:8000", tapField: false)
        waitForText("Browser test page")
        let erase = app.buttons["eraseButton"]
        XCTAssertTrue(erase.waitForExistence(timeout: 10))
        saveScreenshot("22-private-before-erase")
        erase.tap()
        XCTAssertTrue(app.otherElements["toast"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["newTabPage"].waitForExistence(timeout: 10))
        saveScreenshot("23-after-erase")
    }

    @MainActor
    func testClearBrowsingDataSheet() throws {
        launch()
        open("localhost:8000")
        waitForText("Browser test page")
        app.buttons["moreButton"].tap()
        tapMenuItem("Clear Browsing Data…")
        XCTAssertTrue(app.buttons["confirmClearDataButton"].waitForExistence(timeout: 10))
        saveScreenshot("24-clear-data")
        app.buttons["confirmClearDataButton"].tap()
        XCTAssertTrue(app.otherElements["toast"].waitForExistence(timeout: 10))
    }
}
