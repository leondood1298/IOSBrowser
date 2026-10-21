import XCTest

/// UI flows that double as visual checks: every `saveScreenshot` call is kept as a test
/// attachment and, when CI sets `TEST_RUNNER_SHOTS_DIR`, written straight to that folder.
/// Expects `scripts/testserver.py` serving `TestSite/` on port 8000.
final class ScreenshotTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchAndLoadTestPage() throws {
        let app = XCUIApplication()
        app.launch()

        let field = app.textFields["urlField"]
        XCTAssertTrue(field.waitForExistence(timeout: 20))
        saveScreenshot(of: app, named: "01-launch")

        field.tap()
        field.typeText("localhost:8000\n")
        let heading = app.webViews.staticTexts["Browser test page"]
        XCTAssertTrue(heading.waitForExistence(timeout: 30))
        saveScreenshot(of: app, named: "02-test-page")
    }

    @MainActor
    private func saveScreenshot(of app: XCUIApplication, named name: String) {
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
