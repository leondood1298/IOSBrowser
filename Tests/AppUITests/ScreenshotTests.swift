import XCTest

/// UI flows that double as visual checks: every `saveScreenshot` call is kept as a test
/// attachment and, when CI sets `TEST_RUNNER_SHOTS_DIR`, written straight to that folder.
/// Expects `scripts/testserver.py` serving `TestSite/` on port 8000.
final class ScreenshotTests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testTabsFlow() throws {
        app = XCUIApplication()
        app.launch()

        let field = app.textFields["urlField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        saveScreenshot("01-new-tab-page")

        open("localhost:8000")
        XCTAssertTrue(app.webViews.staticTexts["Browser test page"].waitForExistence(timeout: 30))
        saveScreenshot("02-test-page")

        app.buttons["newTabButton"].tap()
        open("localhost:8000/second.html", tapField: false)
        XCTAssertTrue(app.webViews.staticTexts["Second test page"].waitForExistence(timeout: 30))
        saveScreenshot("03-two-tabs")

        app.buttons["tabOverviewButton"].tap()
        XCTAssertTrue(app.collectionViews["tabOverview"].waitForExistence(timeout: 10))
        sleep(1)
        saveScreenshot("04-tab-overview")
        app.buttons["overviewDoneButton"].tap()

        app.typeKey("n", modifierFlags: [.command, .shift])
        XCTAssertTrue(app.otherElements["newTabPage"].waitForExistence(timeout: 10))
        saveScreenshot("05-private-tab")
    }

    @MainActor
    func testDialogsAndPopups() throws {
        app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.textFields["urlField"].waitForExistence(timeout: 20))

        open("localhost:8000/dialogs.html")
        let alertButton = app.webViews.buttons["Show alert"]
        XCTAssertTrue(alertButton.waitForExistence(timeout: 30))
        alertButton.tap()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        saveScreenshot("06-js-alert")
        alert.buttons["OK"].tap()

        app.webViews.buttons["Show confirm"].tap()
        XCTAssertTrue(app.alerts.firstMatch.waitForExistence(timeout: 10))
        app.alerts.firstMatch.buttons["OK"].tap()
        XCTAssertTrue(app.webViews.staticTexts["confirmed"].waitForExistence(timeout: 10))

        app.webViews.links["Open second page in a new tab"].tap()
        XCTAssertTrue(app.webViews.staticTexts["Second test page"].waitForExistence(timeout: 30))
        saveScreenshot("07-popup-in-new-tab")
    }

    @MainActor
    private func open(_ address: String, tapField: Bool = true) {
        let field = app.textFields["urlField"]
        if tapField {
            field.tap()
        }
        field.typeText(address + "\n")
    }

    @MainActor
    private func saveScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)

        guard let directory = ProcessInfo.processInfo.environment["SHOTS_DIR"], !directory.isEmpty else { return }
        let file = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: file)
    }
}
