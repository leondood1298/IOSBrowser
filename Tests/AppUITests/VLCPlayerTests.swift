import XCTest

/// M8 flow: a format the system player can't open (MKV) plays in the VLC player.
final class VLCPlayerTests: UITestCase {
    @MainActor
    func testPlaysMKVWithVLC() throws {
        launch()
        open("localhost:8000/video.html")
        waitForText("Video test page")

        app.webViews.links["Download sample.mkv"].tap()
        let confirm = app.buttons["confirmDownloadButton"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 20))
        confirm.tap()
        let downloads = element("downloadsButton")
        XCTAssertTrue(downloads.waitForExistence(timeout: 20))
        downloads.tap()
        let row = element("download-sample.mkv")
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        XCTAssertTrue(app.staticTexts["Downloaded"].waitForExistence(timeout: 30))
        row.tap()

        XCTAssertTrue(element("vlcPlayer").waitForExistence(timeout: 20))
        let time = app.staticTexts["vlcTime"]
        XCTAssertTrue(time.waitForExistence(timeout: 10))
        // The clock moves once VLC plays the file.
        let moving = expectation(
            for: NSPredicate(format: "NOT (label BEGINSWITH %@) AND NOT (label BEGINSWITH %@)", "0:00", "00:00"),
            evaluatedWith: time)
        wait(for: [moving], timeout: 20)
        saveScreenshot("51-vlc-player")
        app.buttons["vlcDoneButton"].tap()
        XCTAssertTrue(element("vlcPlayer").waitForNonExistence(timeout: 10))
    }
}
