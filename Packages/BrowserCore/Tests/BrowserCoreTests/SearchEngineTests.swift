import XCTest
@testable import BrowserCore

final class SearchEngineTests: XCTestCase {
    func testQueryIsPercentEncoded() {
        XCTAssertEqual(
            SearchEngine.google.searchURL(for: "a b&c=d")?.absoluteString,
            "https://www.google.com/search?q=a%20b%26c%3Dd&ie=utf-8&oe=utf-8")
        XCTAssertEqual(
            SearchEngine.duckDuckGo.searchURL(for: "café")?.absoluteString,
            "https://duckduckgo.com/?q=caf%C3%A9")
    }

    func testSearchTermsPlaceholder() {
        let engine = SearchEngine(id: "x", name: "X", searchTemplate: "https://x.example/?q={searchTerms}&l=en")
        XCTAssertEqual(engine.searchURL(for: "100%")?.absoluteString, "https://x.example/?q=100%25&l=en")
    }

    func testEmptyQueryAndMissingPlaceholder() {
        XCTAssertNil(SearchEngine.google.searchURL(for: "   "))
        let broken = SearchEngine(id: "y", name: "Y", searchTemplate: "https://y.example/search")
        XCTAssertNil(broken.searchURL(for: "test"))
    }

    func testSuggestURL() {
        XCTAssertEqual(
            SearchEngine.google.suggestURL(for: "swift")?.absoluteString,
            "https://www.google.com/complete/search?client=firefox&ie=utf-8&oe=utf-8&q=swift")
        XCTAssertNil(SearchEngine.startpage.suggestURL(for: "swift"))
    }

    func testBuiltInEnginesHaveUniqueIDs() {
        let ids = SearchEngine.builtIn.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
        for engine in SearchEngine.builtIn {
            XCTAssertNotNil(engine.searchURL(for: "test"), engine.name)
        }
    }
}
