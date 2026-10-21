import XCTest
@testable import BrowserCore

final class SearchSupportTests: XCTestCase {
    func testSearchTermsFromResultsPages() {
        XCTAssertEqual(
            SearchEngine.google.searchTerms(in: URL(string: "https://www.google.com/search?q=swift+ui%26more&ie=utf-8&oe=utf-8")!),
            "swift ui&more")
        XCTAssertEqual(SearchEngine.duckDuckGo.searchTerms(in: URL(string: "https://duckduckgo.com/?q=caf%C3%A9&t=h_")!), "café")
        XCTAssertEqual(
            SearchEngine.wikipedia.searchTerms(in: URL(string: "https://en.wikipedia.org/wiki/Special:Search?search=Paris")!), "Paris")
        XCTAssertNil(SearchEngine.google.searchTerms(in: URL(string: "https://www.google.com/maps?q=Paris")!))
        XCTAssertNil(SearchEngine.google.searchTerms(in: URL(string: "https://example.com/search?q=test")!))
    }

    func testTemplateValidation() {
        XCTAssertTrue(SearchEngine.isValidTemplate("https://search.example/?q=%s"))
        XCTAssertFalse(SearchEngine.isValidTemplate("https://search.example/?q="))
        XCTAssertFalse(SearchEngine.isValidTemplate("ftp://search.example/?q=%s"))
        XCTAssertFalse(SearchEngine.isValidTemplate("not a url %s"))
    }

    func testSuggestParsing() {
        XCTAssertEqual(SuggestParser.parse(Data(#"["sw",["swift","swiftui","swim"]]"#.utf8)), ["swift", "swiftui", "swim"])
        XCTAssertEqual(SuggestParser.parse(Data(#"["q",["a","b","c","d","e","f"],[],[]]"#.utf8)).count, 5)
        XCTAssertEqual(SuggestParser.parse(Data("{}".utf8)), [])
        XCTAssertEqual(SuggestParser.parse(Data("not json".utf8)), [])
    }

    func testDomainCompletion() {
        let completion = DomainCompletion(topDomains: ["google.com", "github.com", "www.wikipedia.org"], customDomains: ["gitlab.example.com"])
        XCTAssertEqual(completion.completion(for: "gi"), "tlab.example.com", "custom sites come first")
        XCTAssertEqual(completion.completion(for: "goo"), "gle.com")
        XCTAssertEqual(completion.completion(for: "www.goo"), "gle.com")
        XCTAssertEqual(completion.completion(for: "WIK"), "ipedia.org")
        XCTAssertNil(completion.completion(for: "com"), "never completes inside the top-level domain alone")
        XCTAssertNil(completion.completion(for: "google.com"), "nothing left to add")
        XCTAssertNil(completion.completion(for: "goo gle"))
        XCTAssertNil(completion.completion(for: "google.com/ma"))

        var topOnly = completion
        topOnly.usesCustomDomains = false
        XCTAssertEqual(topOnly.completion(for: "gi"), "thub.com")
    }

    func testNormalizedDomain() {
        XCTAssertEqual(DomainCompletion.normalizedDomain(" https://www.Example.com/ "), "example.com")
        XCTAssertEqual(DomainCompletion.normalizedDomain("news.site.org"), "news.site.org")
        XCTAssertNil(DomainCompletion.normalizedDomain("localhost"))
        XCTAssertNil(DomainCompletion.normalizedDomain("two words.com"))
    }
}
