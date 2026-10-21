import XCTest

/// M3 flows: downloading a file link through the confirm sheet, the Downloads list, and pausing
/// and resuming a slow download.
final class DownloadFlowTests: UITestCase {
    @MainActor
    func testDownloadFileLink() throws {
        launch()
        open("localhost:8000")
        waitForText("Browser test page")

        app.webViews.links["Download sample.txt"].tap()
        let confirm = app.buttons["confirmDownloadButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        saveScreenshot("29-download-confirm")
        confirm.tap()

        let downloads = element("downloadsButton")
        XCTAssertTrue(downloads.waitForExistence(timeout: 20))
        downloads.tap()
        XCTAssertTrue(element("download-sample.txt").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 20))
        saveScreenshot("30-downloads-list")
    }

    @MainActor
    func testPauseAndResume() throws {
        launch()
        open("localhost:8000")
        waitForText("Browser test page")

        app.webViews.links["Download an 8 MB file slowly"].tap()
        let confirm = app.buttons["confirmDownloadButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        confirm.tap()

        let downloads = element("downloadsButton")
        XCTAssertTrue(downloads.waitForExistence(timeout: 20))
        downloads.tap()
        let pause = app.buttons["Pause"]
        XCTAssertTrue(pause.waitForExistence(timeout: 20))
        sleep(3)
        saveScreenshot("31-download-running")
        pause.tap()
        let resume = app.buttons["Resume"]
        XCTAssertTrue(resume.waitForExistence(timeout: 20))
        saveScreenshot("32-download-paused")
        resume.tap()
        XCTAssertTrue(app.buttons["Pause"].waitForExistence(timeout: 20))
    }
}
