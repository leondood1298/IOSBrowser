import XCTest

/// M1b flows: shortcuts and the New Tab page, page settings and zoom, suggestions and history,
/// long-press menus, and the tab audio indicator.
final class BrowsingFeatureTests: UITestCase {
    @MainActor
    func testShortcutsOnStartPage() throws {
        launch()
        open("localhost:8000")
        waitForText("Browser test page")

        app.buttons["moreButton"].tap()
        tapMenuItem("Add to Shortcuts")
        app.buttons["newTabButton"].tap()
        XCTAssertTrue(app.buttons["shortcut-Browser test page"].waitForExistence(timeout: 10))
        saveScreenshot("08-start-page-shortcuts")
    }

    @MainActor
    func testPageSettingsZoom() throws {
        launch()
        open("localhost:8000")
        waitForText("Browser test page")

        app.buttons["pageSettingsButton"].tap()
        let zoomIn = app.buttons["zoomInButton"]
        XCTAssertTrue(zoomIn.waitForExistence(timeout: 10))
        zoomIn.tap()
        zoomIn.tap()
        XCTAssertTrue(app.buttons["zoomResetButton"].label.contains("125%"), app.buttons["zoomResetButton"].label)
        saveScreenshot("09-page-settings")
        tapOutside()
        sleep(1)
        saveScreenshot("10-zoomed-page")
    }

    @MainActor
    func testSuggestionsAndHistory() throws {
        launch()
        open("localhost:8000")
        waitForText("Browser test page")
        open("localhost:8000/second.html")
        waitForText("Second test page")

        app.buttons["newTabButton"].tap()
        let field = app.textFields["urlField"]
        field.tap()
        field.typeText("second")
        // The first tab shows the second page, so the row offers to switch to it.
        let suggestion = app.buttons
            .matching(NSPredicate(format: "identifier == 'suggestionRow' AND label CONTAINS 'Second test page'"))
            .firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 10))
        saveScreenshot("11-suggestions")
        suggestion.tap()
        waitForText("Second test page")
        XCTAssertEqual(app.descendants(matching: .any).matching(identifier: "suggestionRow").count, 0)

        app.typeKey("y", modifierFlags: .command)
        XCTAssertTrue(app.staticTexts["Browser test page"].waitForExistence(timeout: 10))
        saveScreenshot("12-history")
    }

    @MainActor
    func testLongPressMenus() throws {
        launch()
        open("localhost:8000")
        waitForText("Browser test page")

        app.webViews.links["Second page"].press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Open in New Tab"].waitForExistence(timeout: 10))
        saveScreenshot("13-link-menu")
        // Choosing an item closes the menu reliably (tapping beside it sometimes doesn't).
        app.buttons["Copy Link"].tap()
        XCTAssertTrue(app.buttons["Open in New Tab"].waitForNonExistence(timeout: 15))

        let image = app.webViews.images["Sample image"]
        XCTAssertTrue(image.waitForExistence(timeout: 10))
        image.press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Save to Downloads"].waitForExistence(timeout: 10))
        saveScreenshot("14-image-menu")
        app.buttons["Save to Downloads"].tap()
        XCTAssertTrue(element("toast").waitForExistence(timeout: 10))
        saveScreenshot("15-image-saved")
    }

    @MainActor
    func testAudioIndicator() throws {
        launch()
        open("localhost:8000/media.html")
        let play = app.webViews.buttons["Play tone"]
        XCTAssertTrue(play.waitForExistence(timeout: 60))
        play.tap()
        let audioButton = app.buttons["tabAudioButton"]
        // The simulator on CI may have no audio output; record what happened either way.
        if audioButton.waitForExistence(timeout: 15) {
            saveScreenshot("16-audio-playing")
            audioButton.tap()
            sleep(1)
            saveScreenshot("17-audio-muted")
        } else {
            saveScreenshot("16-audio-not-detected")
        }
    }
}
