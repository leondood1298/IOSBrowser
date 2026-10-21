import XCTest
@testable import BrowserCore

final class URLDisplayTests: XCTestCase {
    func testHostDropsWWWAndUserInfo() {
        XCTAssertEqual(URLDisplay.host(for: URL(string: "https://www.example.com/a?b=c")), "example.com")
        XCTAssertEqual(URLDisplay.host(for: URL(string: "https://google.com@evil.example/login")), "evil.example")
        XCTAssertEqual(URLDisplay.host(for: URL(string: "http://Sub.Example.org:8080/")), "sub.example.org")
        XCTAssertNil(URLDisplay.host(for: URL(string: "about:blank")))
        XCTAssertNil(URLDisplay.host(for: nil))
    }

    func testEditableTextRemovesUserInfo() {
        XCTAssertEqual(
            URLDisplay.editableText(for: URL(string: "https://user:pass@example.com/path")),
            "https://example.com/path")
        XCTAssertEqual(URLDisplay.editableText(for: URL(string: "https://example.com/a?b=1")), "https://example.com/a?b=1")
        XCTAssertNil(URLDisplay.editableText(for: URL(string: "about:blank")))
        XCTAssertNil(URLDisplay.editableText(for: URL(string: "data:text/html,hi")))
    }

    func testTabTitle() {
        XCTAssertEqual(URLDisplay.tabTitle(pageTitle: "  Hello  ", url: nil), "Hello")
        XCTAssertEqual(URLDisplay.tabTitle(pageTitle: "", url: URL(string: "https://www.swift.org/blog")), "swift.org")
        XCTAssertEqual(URLDisplay.tabTitle(pageTitle: nil, url: nil), "New Tab")
    }
}

final class ExternalLinkPolicyTests: XCTestCase {
    private func action(_ string: String) -> LinkAction {
        ExternalLinkPolicy.action(for: URL(string: string)!)
    }

    func testWebLinksLoad() {
        XCTAssertEqual(action("https://example.com"), .load)
        XCTAssertEqual(action("about:blank"), .load)
        XCTAssertEqual(action("blob:https://example.com/uuid"), .load)
    }

    func testAppLinks() {
        XCTAssertEqual(action("tel:+15551234"), .openDirectly)
        XCTAssertEqual(action("mailto:a@example.com"), .askToOpen(.mail))
        XCTAssertEqual(action("facetime-audio:a@example.com"), .askToOpen(.facetime))
        XCTAssertEqual(action("itms-apps://apps.apple.com/app/id1"), .askToOpen(.appStore))
        XCTAssertEqual(action("spotify:track:123"), .askToOpen(.other(scheme: "spotify")))
        XCTAssertEqual(action("https://apps.apple.com/us/app/id1105317682"), .offerApp(.appStore))
        XCTAssertEqual(action("https://maps.apple.com/?q=Paris"), .offerApp(.maps))
        XCTAssertEqual(action("file:///etc/hosts"), .block)
    }
}

final class ErrorPageTests: XCTestCase {
    func testIgnoredErrors() {
        XCTAssertTrue(ErrorPage.shouldIgnore(domain: NSURLErrorDomain, code: NSURLErrorCancelled))
        XCTAssertTrue(ErrorPage.shouldIgnore(domain: "WebKitErrorDomain", code: 102))
        XCTAssertFalse(ErrorPage.shouldIgnore(domain: NSURLErrorDomain, code: NSURLErrorTimedOut))
    }

    func testFriendlyContentAndEscaping() {
        let offline = ErrorPage.content(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet, description: "x")
        XCTAssertEqual(offline.title, "You're offline")
        let html = ErrorPage.html(
            ErrorPage.Content(title: "<b>T</b>", message: "a & b"), failingURL: URL(string: "https://e.com/?q=\"x\""))
        XCTAssertTrue(html.contains("&lt;b&gt;T&lt;/b&gt;"))
        XCTAssertTrue(html.contains("a &amp; b"))
        XCTAssertFalse(html.contains("<b>T</b>"))
        XCTAssertTrue(html.contains("location.reload()"))
    }
}

final class JSONFileStoreTests: XCTestCase {
    func testSessionRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = JSONFileStore<SessionSnapshot>(url: directory.appendingPathComponent("session.json"))
        XCTAssertNil(store.load())

        let tab = TabSnapshot(
            id: UUID(), url: URL(string: "https://example.com"), title: "Example",
            interactionState: Data([1, 2, 3]), lastActive: Date(timeIntervalSince1970: 1_700_000_000))
        let group = TabGroupSnapshot(
            id: UUID(), title: nil, tabs: [tab], selectedTabID: tab.id, created: Date(timeIntervalSince1970: 1_600_000_000))
        let session = SessionSnapshot(groups: [group])
        try store.save(session)
        XCTAssertEqual(store.load(), session)

        store.delete()
        XCTAssertNil(store.load())
    }
}
