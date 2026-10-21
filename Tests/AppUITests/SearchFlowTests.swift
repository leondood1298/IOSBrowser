import XCTest

/// M2b flows: inline URL autocomplete, the search suggestions prompt, Find on Page from the
/// address bar, and the Search settings.
final class SearchFlowTests: UITestCase {
    @MainActor
    func testInlineAutocomplete() throws {
        launch()
        let field = app.textFields["urlField"]
        field.tap()
        field.typeText("wikip")
        XCTAssertEqual(field.value as? String, "wikipedia.org")
        saveScreenshot("25-autocomplete")
    }

    @MainActor
    func testSuggestionsPromptAndFindOnPage() throws {
        launch()
        open("localhost:8000")
        waitForText("Browser test page")

        let field = app.textFields["urlField"]
        field.tap()
        field.typeText("fixtures")
        let no = app.buttons["suggestionsPromptNo"]
        XCTAssertTrue(no.waitForExistence(timeout: 10))
        let find = app.buttons["findOnPageSuggestion"]
        XCTAssertTrue(find.exists)
        saveScreenshot("26-search-prompt")

        no.tap()
        XCTAssertTrue(no.waitForNonExistence(timeout: 10))
        find.tap()
        let findText = app.descendants(matching: .any).matching(NSPredicate(format: "value == 'fixtures'")).firstMatch
        XCTAssertTrue(findText.waitForExistence(timeout: 10))
        saveScreenshot("27-find-on-page")
    }

    @MainActor
    func testSearchSettings() throws {
        launch()
        app.buttons["moreButton"].tap()
        tapMenuItem("Settings")
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 10))
        let link = element("searchSettingsLink")
        // Rows below the visible part of the form aren't created until scrolled to.
        for _ in 0..<4 where !link.waitForExistence(timeout: 2) {
            app.swipeUp()
        }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
        link.tap()
        XCTAssertTrue(app.navigationBars["Search"].waitForExistence(timeout: 10))
        saveScreenshot("28-search-settings")
    }
}
