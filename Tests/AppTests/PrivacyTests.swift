import BrowserCore
import WebKit
import XCTest
@testable import Browser

@MainActor
final class PrivacyTests: XCTestCase {
    /// Every bundled list, with a safelist rule appended, must compile in WebKit.
    func testBundledBlockListsCompile() async throws {
        let store = try XCTUnwrap(WKContentRuleListStore.default())
        for list in ContentBlocker.List.all {
            let url = try XCTUnwrap(Bundle.main.url(forResource: list.resourceName, withExtension: "json"), list.resourceName)
            let json = SafelistRules.appending(exceptions: ["example.com"], to: try String(contentsOf: url, encoding: .utf8))
            let identifier = "test-\(list.resourceName)"
            let compiled: WKContentRuleList? = await withCheckedContinuation { continuation in
                store.compileContentRuleList(forIdentifier: identifier, encodedContentRuleList: json) { ruleList, error in
                    XCTAssertNil(error, "\(list.resourceName): \(String(describing: error))")
                    continuation.resume(returning: ruleList)
                }
            }
            XCTAssertNotNil(compiled, list.resourceName)
            store.removeContentRuleList(forIdentifier: identifier) { _ in }
        }
    }

    func testBundledMatcherKnowsCommonTrackers() throws {
        var lists: [TrackerCategory: Data] = [:]
        for category in TrackerCategory.allCases {
            let url = try XCTUnwrap(Bundle.main.url(forResource: category.listName, withExtension: "json"))
            lists[category] = try Data(contentsOf: url)
        }
        let suffixURL = try XCTUnwrap(Bundle.main.url(forResource: "public_suffix_list", withExtension: "dat"))
        let matcher = TrackerMatcher(
            lists: lists, publicSuffixList: PublicSuffixList(text: try String(contentsOf: suffixURL, encoding: .utf8)))
        let page = URL(string: "https://news.example.co.uk/story")
        XCTAssertEqual(matcher.category(for: URL(string: "https://www.google-analytics.com/analytics.js")!, on: page), .analytics)
        XCTAssertEqual(matcher.category(for: URL(string: "https://securepubads.g.doubleclick.net/tag/js/gpt.js")!, on: page), .advertising)
        XCTAssertNil(matcher.category(for: URL(string: "https://static.example.co.uk/app.js")!, on: page))
    }

    func testTrackerCategoryPreferences() {
        let defaults = UserDefaults(suiteName: "PrivacyTests-\(UUID().uuidString)")!
        let preferences = Preferences(defaults: defaults)
        XCTAssertTrue(preferences.trackingProtectionEnabled)
        XCTAssertTrue(preferences.isBlocking(.advertising))
        XCTAssertFalse(preferences.isBlocking(.content), "content trackers are off by default, like Focus")
        preferences.setBlocking(.content, true)
        preferences.setBlocking(.social, false)
        XCTAssertTrue(preferences.isBlocking(.content))
        XCTAssertFalse(preferences.isBlocking(.social))
        preferences.addBlockedTrackers(3)
        XCTAssertEqual(preferences.lifetimeTrackersBlocked, 3)
    }

    func testEraseClosesPrivateTabsAndReplacesTheStore() {
        let services = TestServices.make()
        let window = BrowserWindowModel(services: services, restoringGroupID: nil)
        window.newTab(url: URL(string: "https://example.com/secret"), isPrivate: true)
        let oldStore = services.privateSession.dataStore
        EraseService.erasePrivateBrowsing(services: services)
        XCTAssertTrue(window.privateGroup.tabs.isEmpty)
        XCTAssertFalse(window.isPrivate)
        XCTAssertFalse(services.privateSession.dataStore === oldStore)
        XCTAssertTrue(window.recentlyClosed.allSatisfy { !$0.isPrivate })
    }
}
