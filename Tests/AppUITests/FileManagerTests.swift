import XCTest

/// M4 flows: the file manager's folders, a new folder, its menu and info, the icon view, and
/// deleting to the Trash.
final class FileManagerTests: UITestCase {
    @MainActor
    func testFolders() throws {
        launch()
        app.buttons["moreButton"].tap()
        tapMenuItem("Files")
        XCTAssertTrue(element("file-Downloads").waitForExistence(timeout: 15))
        saveScreenshot("33-files")

        app.buttons["filesMenuButton"].tap()
        tapMenuItem("New Folder")
        let alert = app.alerts["New Folder"]
        XCTAssertTrue(alert.waitForExistence(timeout: 10))
        alert.textFields.firstMatch.typeText("Projects")
        alert.buttons["Create"].tap()
        let folder = element("file-Projects")
        XCTAssertTrue(folder.waitForExistence(timeout: 10))

        folder.press(forDuration: 1.2)
        XCTAssertTrue(app.buttons["Get Info"].waitForExistence(timeout: 10))
        saveScreenshot("34-file-menu")
        app.buttons["Get Info"].tap()
        XCTAssertTrue(app.navigationBars["Info"].waitForExistence(timeout: 10))
        saveScreenshot("35-file-info")
        app.navigationBars["Info"].buttons["Done"].tap()

        app.buttons["filesMenuButton"].tap()
        tapMenuItem("Icons")
        XCTAssertTrue(folder.waitForExistence(timeout: 10))
        saveScreenshot("36-files-grid")

        folder.press(forDuration: 1.2)
        tapMenuItem("Delete")
        tapMenuItem("Delete")
        XCTAssertTrue(folder.waitForNonExistence(timeout: 10))
        app.buttons["filesMenuButton"].tap()
        tapMenuItem("Trash")
        XCTAssertTrue(app.staticTexts["Projects"].waitForExistence(timeout: 10))
        saveScreenshot("37-trash")
    }
}
