import XCTest
@testable import BrowserCore

final class AppLinkTests: XCTestCase {
    func testRoundTrips() throws {
        let page = try XCTUnwrap(URL(string: "https://example.com/search?q=a+b&lang=en#top"))
        let links: [AppLink] = [
            .open(page, isPrivate: false),
            .open(page, isPrivate: true),
            .openText("swift & ipad", isPrivate: false),
            .download(try XCTUnwrap(URL(string: "https://cdn.example.com/files/My%20File.zip?token=1+2"))),
        ]
        for link in links {
            let url = try XCTUnwrap(link.url, "\(link)")
            XCTAssertEqual(url.scheme, "iosbrowser")
            XCTAssertEqual(AppLink(url: url), link, url.absoluteString)
        }
    }

    func testParsesLinksFromOtherApps() throws {
        XCTAssertEqual(
            AppLink(url: try XCTUnwrap(URL(string: "iosbrowser://open-url?url=https%3A%2F%2Fexample.com&private=1"))),
            .open(try XCTUnwrap(URL(string: "https://example.com")), isPrivate: true))
        XCTAssertEqual(
            AppLink(url: try XCTUnwrap(URL(string: "IOSBROWSER://Open-Text?text=hello"))),
            .openText("hello", isPrivate: false))
    }

    func testRejectsWhatItCantUse() throws {
        XCTAssertNil(AppLink(url: try XCTUnwrap(URL(string: "https://example.com/open-url?url=x"))))
        XCTAssertNil(AppLink(url: try XCTUnwrap(URL(string: "iosbrowser://open-url"))))
        XCTAssertNil(AppLink(url: try XCTUnwrap(URL(string: "iosbrowser://open-text?text=%20%20"))))
        XCTAssertNil(AppLink(url: try XCTUnwrap(URL(string: "iosbrowser://download?url=file%3A%2F%2F%2Fetc%2Fhosts"))))
        XCTAssertNil(AppLink(url: try XCTUnwrap(URL(string: "iosbrowser://settings"))))
    }
}
