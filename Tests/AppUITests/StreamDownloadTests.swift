import XCTest

/// M7 flow: saving an HLS stream from the media picker, in a chosen quality, as one MP4.
final class StreamDownloadTests: UITestCase {
    @MainActor
    func testSavesHLSStreamAsMP4() throws {
        launch()
        open("localhost:8000/hls.html")
        waitForText("HLS test page")

        let mediaButton = app.buttons["mediaButton"]
        XCTAssertTrue(mediaButton.waitForExistence(timeout: 20))
        mediaButton.tap()
        XCTAssertTrue(element("media-HLS test page.mp4").waitForExistence(timeout: 10))
        saveScreenshot("47-stream-in-picker")
        app.buttons.matching(identifier: "mediaDownload-HLS test page.mp4").firstMatch.tap()

        let quality = app.buttons.matching(NSPredicate(format: "label BEGINSWITH '360p'")).firstMatch
        XCTAssertTrue(quality.waitForExistence(timeout: 20))
        XCTAssertTrue(app.buttons.matching(NSPredicate(format: "label BEGINSWITH '180p'")).firstMatch.exists)
        saveScreenshot("48-stream-quality")
        quality.tap()

        let confirm = app.buttons["confirmDownloadButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        confirm.tap()
        let downloads = element("downloadsButton")
        XCTAssertTrue(downloads.waitForExistence(timeout: 20))
        downloads.tap()
        XCTAssertTrue(element("download-HLS test page.mp4").waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 60))
        saveScreenshot("49-stream-downloaded")
    }
}
