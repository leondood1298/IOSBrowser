import XCTest

/// Shared setup for the UI flows. Each test launches the app with --reset-state, so saved tabs,
/// history and settings from earlier tests don't leak in. Every `saveScreenshot` is kept as a test
/// attachment and, when CI sets `TEST_RUNNER_SHOTS_DIR`, written to that folder as a PNG. A failing
/// test also saves a `FAIL-<test>` screenshot of the moment it failed.
/// Expects `scripts/testserver.py` serving `TestSite/` on port 8000.
class UITestCase: XCTestCase {
    var app: XCUIApplication!
    private var savingFailureShot = false

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    override func record(_ issue: XCTIssue) {
        var issue = issue
        if Thread.isMainThread, !savingFailureShot {
            savingFailureShot = true
            let shotName = "FAIL-" + (name.split(separator: " ").last.map { String($0.dropLast()) } ?? "test")
            MainActor.assumeIsolated {
                let screenshot = XCUIScreen.main.screenshot()
                let attachment = XCTAttachment(screenshot: screenshot)
                attachment.name = shotName
                attachment.lifetime = .keepAlways
                issue.add(attachment)
                writeToShotsFolder(screenshot, name: shotName)
            }
            savingFailureShot = false
        }
        super.record(issue)
    }

    /// Launches with clean state. The first launch on a fresh CI simulator can take a while.
    @MainActor
    func launch() {
        app = XCUIApplication()
        app.launchArguments = ["--reset-state", "--ui-testing"]
        app.launch()
        XCTAssertTrue(app.textFields["urlField"].waitForExistence(timeout: 60))
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

    /// Waits for text in the page. The first page load on a cold simulator can take over 30 s.
    @MainActor
    func waitForText(_ text: String, timeout: TimeInterval = 60) {
        XCTAssertTrue(app.webViews.staticTexts[text].waitForExistence(timeout: timeout), "\(text) didn't appear")
    }

    /// Opens a private tab from the New Tab button's menu. (Typing ⇧⌘N isn't reliable in UI
    /// tests: with the on-screen keyboard up, the simulator types the letter into the field.)
    @MainActor
    func openPrivateTab() {
        app.buttons["newTabButton"].press(forDuration: 1.2)
        tapMenuItem("New Private Tab")
    }

    /// The element with an accessibility identifier, whatever its type (SwiftUI decides whether a
    /// view shows up as an "other" element, a scroll view, a cell…).
    @MainActor
    func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
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

    /// Dismisses a menu or popover by tapping an empty spot in the lower right of the page.
    /// (A tap right at the bottom edge didn't close long-press menus.)
    @MainActor
    func tapOutside() {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.85)).tap()
    }

    /// Closes the open long-press menu, identified by one of its items, and waits until it's gone.
    @MainActor
    func dismissMenu(containing item: String) {
        tapOutside()
        XCTAssertTrue(app.buttons[item].waitForNonExistence(timeout: 15), "The menu with \(item) didn't close")
    }

    @MainActor
    func saveScreenshot(_ name: String) {
        let screenshot = app.screenshot()
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        writeToShotsFolder(screenshot, name: name)
    }

    @MainActor
    private func writeToShotsFolder(_ screenshot: XCUIScreenshot, name: String) {
        guard let directory = ProcessInfo.processInfo.environment["SHOTS_DIR"], !directory.isEmpty else { return }
        let file = URL(fileURLWithPath: directory).appendingPathComponent("\(name).png")
        try? screenshot.pngRepresentation.write(to: file)
    }
}
