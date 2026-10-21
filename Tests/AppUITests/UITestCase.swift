import XCTest

/// Shared setup for the UI flows. Each test launches the app with --reset-state, so saved tabs,
/// history and settings from earlier tests don't leak in. Every `saveScreenshot` is kept as a test
/// attachment and, when CI sets `TEST_RUNNER_SHOTS_DIR`, written to that folder as a PNG.
/// Expects `scripts/testserver.py` serving `TestSite/` on port 8000.
class UITestCase: XCTestCase {
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func launch() {
        app = XCUIApplication()
        app.launchArguments = ["--reset-state"]
        app.launch()
        XCTAssertTrue(app.textFields["urlField"].waitForExistence(timeout: 20))
    }

    /// Types an address into the address bar and presses Return.
    @MainActor
    func open(_ address: String, tapField: Bool = true) {
        let field = app.textFields["urlField"]
        if tapField {
            field.tap()
        }
        field.typeText(address + "\n")
    }

    @MainActor
    func waitForText(_ text: String, timeout: TimeInterval = 30) {
        XCTAssertTrue(app.webViews.staticTexts[text].waitForExistence(timeout: timeout), "\(text) didn't appear")
    }

    /// Taps a menu item, which XCUITest may expose as a button or a menu item.
    @MainActor
    func tapMenuItem(_ title: String) {
        for candidate in [app.buttons[title], app.menuItems[title], app.staticTexts[title]] {
            if candidate.waitForExistence(timeout: 3) {
                candidate.tap()
                return
            }
        }
        XCTFail("Menu item \(title) not found")
    }

    /// Dismisses a menu or popover by tapping near the bottom edge.
    @MainActor
    func tapOutside() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
    }

    @MainActor
    func saveScreenshot(_ name: String) {
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
