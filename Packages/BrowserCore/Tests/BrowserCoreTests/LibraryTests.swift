import XCTest
@testable import BrowserCore

final class HistoryIndexTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    func testRecordingCountsVisitsAndKeepsLatestTitle() {
        var history = HistoryIndex()
        let url = URL(string: "https://example.com/a")!
        history.recordVisit(to: url, title: "First", at: base)
        history.recordVisit(to: url, title: "", at: base.addingTimeInterval(60))
        history.updateTitle("Second", for: url)
        let entry = history.search().first
        XCTAssertEqual(entry?.visitCount, 2)
        XCTAssertEqual(entry?.title, "Second")
        XCTAssertEqual(entry?.lastVisit, base.addingTimeInterval(60))
    }

    func testOnlyWebPagesAreRecorded() {
        var history = HistoryIndex()
        history.recordVisit(to: URL(string: "about:blank")!, title: "", at: base)
        history.recordVisit(to: URL(string: "data:text/html,x")!, title: "", at: base)
        XCTAssertTrue(history.search().isEmpty)
    }

    func testSearchOrderAndRemoval() {
        var history = HistoryIndex()
        history.recordVisit(to: URL(string: "https://swift.org")!, title: "Swift", at: base)
        history.recordVisit(to: URL(string: "https://example.com")!, title: "Example", at: base.addingTimeInterval(10))
        XCTAssertEqual(history.search().map(\.title), ["Example", "Swift"])
        XCTAssertEqual(history.search("swi").map(\.title), ["Swift"])
        history.removeVisits(since: base.addingTimeInterval(5))
        XCTAssertEqual(history.search().map(\.title), ["Swift"])
        history.removeVisits(since: nil)
        XCTAssertTrue(history.search().isEmpty)
    }

    func testCapsByCountAndAge() {
        var history = HistoryIndex(maximumEntries: 2, maximumAge: 100)
        history.recordVisit(to: URL(string: "https://a.example")!, title: "A", at: base)
        history.recordVisit(to: URL(string: "https://b.example")!, title: "B", at: base.addingTimeInterval(1))
        history.recordVisit(to: URL(string: "https://c.example")!, title: "C", at: base.addingTimeInterval(2))
        XCTAssertEqual(history.search().map(\.title), ["C", "B"])
        history.recordVisit(to: URL(string: "https://d.example")!, title: "D", at: base.addingTimeInterval(500))
        XCTAssertEqual(history.search().map(\.title), ["D"])
    }

    func testGroupedByDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var history = HistoryIndex()
        history.recordVisit(to: URL(string: "https://a.example")!, title: "A", at: base)
        history.recordVisit(to: URL(string: "https://b.example")!, title: "B", at: base.addingTimeInterval(86_400 * 2))
        let groups = history.groupedByDay(calendar: calendar)
        XCTAssertEqual(groups.count, 2)
        XCTAssertEqual(groups.first?.entries.map(\.title), ["B"])
    }
}

final class SiteSettingsTests: XCTestCase {
    func testKeyIgnoresWWWAndCase() {
        XCTAssertEqual(SiteSettingsIndex.key(for: URL(string: "https://WWW.Example.com/a")), "example.com")
        XCTAssertNil(SiteSettingsIndex.key(for: URL(string: "about:blank")))
    }

    func testUpdateAndClear() {
        var index = SiteSettingsIndex()
        let url = URL(string: "https://www.example.com/page")!
        index.update(url) { $0.zoom = 1.25 }
        index.update(URL(string: "https://example.com/other")!) { $0.layout = .desktop }
        XCTAssertEqual(index.settings(for: url), SiteSettings(zoom: 1.25, layout: .desktop))
        index.update(url) {
            $0.zoom = nil
            $0.layout = nil
        }
        XCTAssertTrue(index.sites.isEmpty)
    }

    func testZoomSteps() {
        XCTAssertEqual(ZoomLevels.next(after: 1.0), 1.15)
        XCTAssertEqual(ZoomLevels.previous(before: 1.0), 0.85)
        XCTAssertEqual(ZoomLevels.next(after: 3.0), 3.0)
        XCTAssertEqual(ZoomLevels.previous(before: 0.5), 0.5)
        XCTAssertEqual(ZoomLevels.percentText(1.15), "115%")
    }

    func testUserAgents() {
        XCTAssertNil(UserAgent.standard.string())
        XCTAssertTrue(UserAgent.chromeDesktop.string()?.contains("Chrome/") == true)
        XCTAssertEqual(UserAgent.custom.string(custom: "  MyAgent/1.0 "), "MyAgent/1.0")
        XCTAssertNil(UserAgent.custom.string(custom: "   "))
    }
}

final class BookmarkAndSuggestionTests: XCTestCase {
    func testSameURLIgnoresTrailingSlashAndFragment() {
        XCTAssertTrue(BookmarkLibrary.same(URL(string: "https://example.com/")!, URL(string: "https://example.com#top")!))
        XCTAssertFalse(BookmarkLibrary.same(URL(string: "https://example.com/a")!, URL(string: "https://example.com/b")!))
        let library = BookmarkLibrary(bookmarks: [Bookmark(title: "E", url: URL(string: "https://example.com/")!)])
        XCTAssertTrue(library.isBookmarked(URL(string: "https://example.com")!))
    }

    func testRankingPrefersHostPrefixAndDeduplicates() {
        let now = Date()
        let candidates: [SuggestionRanker.Candidate] = [
            .init(kind: .history, title: "Learn GitHub Actions", url: URL(string: "https://docs.example.com/github")!, lastUsed: now),
            .init(kind: .history, title: "GitHub", url: URL(string: "https://github.com/")!, lastUsed: now, useCount: 5),
            .init(kind: .bookmark, title: "GitHub", url: URL(string: "https://github.com")!),
            .init(kind: .history, title: "Unrelated", url: URL(string: "https://example.org")!),
        ]
        let results = SuggestionRanker.rank("git", candidates: candidates)
        XCTAssertEqual(results.first?.url.host, "github.com")
        XCTAssertEqual(results.first?.kind, .bookmark, "bookmarks rank above history at the same match level")
        XCTAssertEqual(results.count, 2, "github.com appears once; unrelated is dropped")
        XCTAssertTrue(SuggestionRanker.rank("   ", candidates: candidates).isEmpty)
    }
}
