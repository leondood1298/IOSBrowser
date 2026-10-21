import XCTest

/// M6 flows: the address bar's media button lists the page's video and audio, and a long-pressed
/// video offers to download it.
final class MediaDetectionTests: UITestCase {
    @MainActor
    func testMediaButtonListsAndDownloadsVideo() throws {
        launch()
        open("localhost:8000/video.html")
        waitForText("Video test page")

        let mediaButton = app.buttons["mediaButton"]
        XCTAssertTrue(mediaButton.waitForExistence(timeout: 20))
        mediaButton.tap()
        XCTAssertTrue(element("media-sample.mp4").waitForExistence(timeout: 10))
        XCTAssertTrue(element("media-tone.wav").waitForExistence(timeout: 10))
        sleep(1)
        saveScreenshot("44-media-picker")

        app.buttons["mediaDownload-sample.mp4"].tap()
        let confirm = app.buttons["confirmDownloadButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        confirm.tap()
        let downloads = element("downloadsButton")
        XCTAssertTrue(downloads.waitForExistence(timeout: 20))
        downloads.tap()
        XCTAssertTrue(element("download-sample.mp4").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 30))
        saveScreenshot("46-media-downloaded")
    }

    @MainActor
    func testLongPressVideoOffersDownload() throws {
        launch()
        open("localhost:8000/video.html")
        waitForText("Video test page")
        XCTAssertTrue(app.buttons["mediaButton"].waitForExistence(timeout: 20))

        // The first video sits right under the heading: 480 × 270 points.
        let heading = app.webViews.staticTexts["Video test page"]
        heading.coordinate(withNormalizedOffset: CGVector(dx: 0, dy: 1))
            .withOffset(CGVector(dx: 200, dy: 140))
            .press(forDuration: 1.5)
        XCTAssertTrue(app.buttons["Download Video"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["Play in Player"].exists)
        saveScreenshot("45-video-menu")
        app.buttons["Copy Video Address"].tap()
        XCTAssertTrue(element("toast").waitForExistence(timeout: 10))
    }
}
