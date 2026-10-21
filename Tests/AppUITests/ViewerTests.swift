import XCTest

/// M5 flows: the image and PDF viewers change pages at once when you tap an edge, press an arrow
/// key, swipe or use the ‹ › buttons. The app writes sample files with --seed-viewer-files.
final class ViewerTests: UITestCase {
    @MainActor
    func testImagesTurnInstantly() throws {
        launch(extraArguments: ["--seed-viewer-files"])
        openFilesFolder("Viewer Test")
        let first = element("file-Image 1.png")
        XCTAssertTrue(first.waitForExistence(timeout: 15))
        first.tap()

        let counter = app.staticTexts["viewerCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 15))
        XCTAssertEqual(counter.label, "1 / 5")
        saveScreenshot("38-image-viewer")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(counter.label, "2 / 5")
        app.typeKey(.rightArrow, modifierFlags: [])
        XCTAssertEqual(counter.label, "3 / 5")
        app.swipeUp()
        XCTAssertEqual(counter.label, "4 / 5")
        saveScreenshot("39-image-viewer-page-4")
        app.buttons["viewerPrevious"].tap()
        XCTAssertEqual(counter.label, "3 / 5")
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        XCTAssertEqual(counter.label, "2 / 5")
        app.buttons["viewerDoneButton"].tap()
    }

    @MainActor
    func testMusicPlayer() throws {
        launch(extraArguments: ["--seed-viewer-files"])
        openFilesFolder("Viewer Test")
        let tone = element("file-Tone.wav")
        XCTAssertTrue(tone.waitForExistence(timeout: 15))
        tone.tap()
        let title = app.staticTexts["audioTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 15))
        XCTAssertEqual(title.label, "Tone")
        saveScreenshot("42-music-player")
        app.buttons["audioDoneButton"].tap()
        app.buttons["filesDoneButton"].tap()
        XCTAssertTrue(element("miniPlayer").waitForExistence(timeout: 10))
        saveScreenshot("43-mini-player")
    }

    @MainActor
    func testPDFPagesTurnInstantly() throws {
        launch(extraArguments: ["--seed-viewer-files"])
        openFilesFolder("Viewer Test")
        let pdf = element("file-Sample.pdf")
        XCTAssertTrue(pdf.waitForExistence(timeout: 15))
        pdf.tap()

        let page = app.buttons["pdfPageButton"]
        XCTAssertTrue(page.waitForExistence(timeout: 15))
        XCTAssertEqual(page.label, "1 / 5")
        saveScreenshot("40-pdf-viewer")

        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(page.label, "2 / 5")
        app.typeKey(.downArrow, modifierFlags: [])
        XCTAssertEqual(page.label, "3 / 5")
        app.swipeLeft()
        XCTAssertEqual(page.label, "4 / 5")
        saveScreenshot("41-pdf-page-4")
        app.buttons["pdfPrevious"].tap()
        XCTAssertEqual(page.label, "3 / 5")
    }
}
