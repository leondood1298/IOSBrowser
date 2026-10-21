import XCTest
@testable import BrowserCore

final class PublicSuffixListTests: XCTestCase {
    private let list = PublicSuffixList(text: """
        // Comment lines are ignored
        com
        uk
        co.uk
        *.ck
        !www.ck
        github.io
        """)

    func testRegistrableDomains() {
        XCTAssertEqual(list.registrableDomain(for: "www.example.com"), "example.com")
        XCTAssertEqual(list.registrableDomain(for: "a.b.example.com"), "example.com")
        XCTAssertEqual(list.registrableDomain(for: "news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(list.registrableDomain(for: "user.github.io"), "user.github.io")
        XCTAssertEqual(list.registrableDomain(for: "a.b.ck"), "a.b.ck", "*.ck makes b.ck a suffix")
        XCTAssertEqual(list.registrableDomain(for: "www.ck"), "www.ck", "!www.ck is an exception")
        XCTAssertEqual(list.registrableDomain(for: "example.unknowntld"), "example.unknowntld")
        XCTAssertNil(list.registrableDomain(for: "co.uk"))
        XCTAssertNil(list.registrableDomain(for: "localhost"))
        XCTAssertNil(list.registrableDomain(for: "192.168.1.1"))
    }
}

final class TrackerMatcherTests: XCTestCase {
    private func matcher() -> TrackerMatcher {
        let ads = """
            [
            {"action":{"type":"block"},"trigger":{"url-filter":"^https?://([^/]+\\\\.)?ads\\\\.example","load-type":["third-party"]}},
            {"action":{"type":"block"},"trigger":{"url-filter":"^https?://([^/]+\\\\.)?doubleclick\\\\.net","load-type":["third-party"],"unless-domain":["*google.com","*youtube.com"]}}
            ]
            """
        let social = """
            [{"action":{"type":"block"},"trigger":{"url-filter":"^https?://([^/]+\\\\.)?facebook\\\\.net","load-type":["third-party"],"unless-domain":["*facebook.com"]}}]
            """
        return TrackerMatcher(
            lists: [.advertising: Data(ads.utf8), .social: Data(social.utf8)],
            publicSuffixList: PublicSuffixList(text: "com\nnet\nexample\nco.uk"))
    }

    func testFilterParsing() {
        XCTAssertEqual(TrackerMatcher.domain(fromFilter: "^https?://([^/]+\\.)?doubleclick\\.net"), "doubleclick.net")
        XCTAssertNil(TrackerMatcher.domain(fromFilter: ".*"))
    }

    func testMatchesThirdPartyTrackersAndSubdomains() {
        let page = URL(string: "https://news.site.co.uk/article")
        XCTAssertEqual(matcher().category(for: URL(string: "https://stats.g.doubleclick.net/x.js")!, on: page), .advertising)
        XCTAssertEqual(matcher().category(for: URL(string: "https://connect.facebook.net/sdk.js")!, on: page), .social)
        XCTAssertNil(matcher().category(for: URL(string: "https://cdn.site.co.uk/app.js")!, on: page))
        XCTAssertNil(matcher().category(for: URL(string: "https://notdoubleclick.net/x")!, on: page))
    }

    func testOwnerSitesAreExempt() {
        XCTAssertNil(matcher().category(for: URL(string: "https://ad.doubleclick.net/x")!, on: URL(string: "https://www.youtube.com/watch")))
        XCTAssertNil(matcher().category(for: URL(string: "https://connect.facebook.net/sdk.js")!, on: URL(string: "https://m.facebook.com/")))
    }

    func testCounts() {
        var counts = TrackerCounts()
        counts.add(.advertising)
        counts.add(.advertising)
        counts.add(.social)
        XCTAssertEqual(counts.total, 3)
        XCTAssertEqual(counts[.advertising], 2)
        XCTAssertEqual(counts[.content], 0)
    }
}

final class SafelistRulesTests: XCTestCase {
    func testAppendsIgnoreRule() throws {
        let list = "[\n{\"action\":{\"type\":\"block\"},\"trigger\":{\"url-filter\":\"x\"}}\n]\n"
        let result = SafelistRules.appending(exceptions: ["Example.com", "news.site"], to: list)
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 2)
        let last = try XCTUnwrap(rules.last)
        XCTAssertEqual((last["action"] as? [String: String])?["type"], "ignore-previous-rules")
        XCTAssertEqual((last["trigger"] as? [String: Any])?["if-domain"] as? [String], ["*example.com", "*news.site"])
    }

    func testNoExceptionsLeavesListUnchanged() {
        let list = "[{\"a\":1}]"
        XCTAssertEqual(SafelistRules.appending(exceptions: [], to: list), list)
    }

    func testEmptyList() throws {
        let result = SafelistRules.appending(exceptions: ["a.com"], to: "[]")
        let rules = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(result.utf8)) as? [[String: Any]])
        XCTAssertEqual(rules.count, 1)
    }
}
