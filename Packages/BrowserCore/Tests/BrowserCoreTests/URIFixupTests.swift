import XCTest
@testable import BrowserCore

final class URIFixupTests: XCTestCase {
    private func url(_ text: String) -> String? {
        URIFixup.url(from: text)?.absoluteString
    }

    func testDomainsGetHTTPS() {
        XCTAssertEqual(url("example.com"), "https://example.com")
        XCTAssertEqual(url("www.example.co.uk/path?q=1#top"), "https://www.example.co.uk/path?q=1#top")
        XCTAssertEqual(url("  Example.com/Path  "), "https://Example.com/Path")
        XCTAssertEqual(url("example.com."), "https://example.com.")
        XCTAssertEqual(url("xn--bcher-kva.example"), "https://xn--bcher-kva.example")
        XCTAssertEqual(url("example.com:8443/admin"), "https://example.com:8443/admin")
    }

    func testLocalHostsGetHTTP() {
        XCTAssertEqual(url("localhost"), "http://localhost")
        XCTAssertEqual(url("localhost:8000"), "http://localhost:8000")
        XCTAssertEqual(url("localhost:8000/files/a.txt"), "http://localhost:8000/files/a.txt")
        XCTAssertEqual(url("192.168.1.10"), "http://192.168.1.10")
        XCTAssertEqual(url("192.168.1.10:8080/x"), "http://192.168.1.10:8080/x")
        XCTAssertEqual(url("[::1]:8080"), "http://[::1]:8080")
    }

    func testExplicitSchemesAreKept() {
        XCTAssertEqual(url("http://example.com"), "http://example.com")
        XCTAssertEqual(URIFixup.url(from: "HTTPS://example.com/a")?.host, "example.com")
        XCTAssertEqual(url("https://example.com/a b"), "https://example.com/a%20b")
        XCTAssertEqual(url("about:blank"), "about:blank")
        XCTAssertEqual(url("mailto:someone@example.com"), "mailto:someone@example.com")
        XCTAssertEqual(url("tel:5551234"), "tel:5551234")
        XCTAssertEqual(url("spotify://track/123"), "spotify://track/123")
    }

    func testDangerousSchemesAreNeverLoaded() {
        XCTAssertNil(url("javascript:alert(1)"))
        XCTAssertNil(url("JavaScript:alert(1)"))
        XCTAssertNil(url("file:///etc/passwd"))
        XCTAssertEqual(URIFixup.classify("javascript:alert(1)"), .search("javascript:alert(1)"))
    }

    func testSearches() {
        XCTAssertEqual(URIFixup.classify("hello world"), .search("hello world"))
        XCTAssertEqual(URIFixup.classify("hello"), .search("hello"))
        XCTAssertEqual(URIFixup.classify("1.5"), .search("1.5"))
        XCTAssertEqual(URIFixup.classify("what is 2.5 km in miles"), .search("what is 2.5 km in miles"))
        XCTAssertEqual(URIFixup.classify("user@example.com"), .search("user@example.com"))
        XCTAssertEqual(URIFixup.classify("example."), .search("example."))
        XCTAssertEqual(URIFixup.classify(".com"), .search(".com"))
        XCTAssertEqual(URIFixup.classify("-bad.com"), .search("-bad.com"))
        XCTAssertEqual(URIFixup.classify("example.com:notaport"), .search("example.com:notaport"))
        XCTAssertNil(URIFixup.classify("   "))
    }
}
