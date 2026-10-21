import BrowserCore
import WebKit
import XCTest
@testable import Browser

@MainActor
final class SmokeTests: XCTestCase {
    func testDefaultFoldersAreCreated() throws {
        AppFolders.ensureDefaultFolders()
        for name in AppFolders.defaultFolderNames {
            var isDirectory: ObjCBool = false
            let path = AppFolders.documentsDirectory.appendingPathComponent(name).path
            XCTAssertTrue(FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), name)
            XCTAssertTrue(isDirectory.boolValue, name)
        }
    }

    func testPrivateTabsUseTheNonPersistentStore() {
        let privateConfiguration = WebViewFactory.makeConfiguration(isPrivate: true)
        XCTAssertFalse(privateConfiguration.websiteDataStore.isPersistent)
        XCTAssertTrue(privateConfiguration.websiteDataStore === AppServices.shared.privateSession.dataStore)
        XCTAssertTrue(WebViewFactory.makeConfiguration(isPrivate: false).websiteDataStore.isPersistent)
        XCTAssertFalse(WebViewFactory.makeConfiguration(isPrivate: false).preferences.javaScriptCanOpenWindowsAutomatically)
    }

    func testUserAgentNamesSafariVersion() {
        XCTAssertTrue(WebViewFactory.applicationNameForUserAgent.hasPrefix("Version/"))
        XCTAssertTrue(WebViewFactory.applicationNameForUserAgent.hasSuffix("Safari/605.1.15"))
    }

    func testBrowserWindowLoads() {
        let root = BrowserSplitViewController(model: BrowserWindowModel(services: TestServices.make(), restoringGroupID: nil))
        root.loadViewIfNeeded()
        root.browser.loadViewIfNeeded()
        XCTAssertTrue(root.browser.navigationItem.titleView is AddressField)
    }
}

@MainActor
final class TabModelTests: XCTestCase {
    func testNewWindowStartsWithABlankTab() {
        let model = BrowserWindowModel(services: TestServices.make(), restoringGroupID: nil)
        XCTAssertEqual(model.normalGroup.tabs.count, 1)
        XCTAssertEqual(model.selectedTab?.showsStartPage, true)
        XCTAssertFalse(model.isPrivate)
    }

    func testOpeningAndClosingTabs() {
        let model = BrowserWindowModel(services: TestServices.make(), restoringGroupID: nil)
        let first = model.normalGroup.tabs[0]
        let second = model.newTab(url: URL(string: "https://example.com"))
        XCTAssertTrue(model.selectedTab === second)
        let third = model.newTab(url: URL(string: "https://example.org"), after: first, select: false)
        XCTAssertEqual(model.normalGroup.tabs.map(\.id), [first.id, third.id, second.id])
        XCTAssertTrue(model.selectedTab === second)

        model.close(second)
        XCTAssertTrue(model.selectedTab === third)
        model.close(third)
        model.close(first)
        XCTAssertEqual(model.normalGroup.tabs.count, 1, "closing the last tab opens a new blank one")
        XCTAssertEqual(model.selectedTab?.showsStartPage, true)
    }

    func testPrivateTabsAreSeparate() {
        let model = BrowserWindowModel(services: TestServices.make(), restoringGroupID: nil)
        model.setPrivate(true)
        XCTAssertTrue(model.isPrivate)
        XCTAssertEqual(model.privateGroup.tabs.count, 1)
        XCTAssertEqual(model.selectedTab?.isPrivate, true)
        model.closeAllTabs(isPrivate: true)
        XCTAssertFalse(model.isPrivate)
        XCTAssertTrue(model.privateGroup.tabs.isEmpty)
    }

    func testTypedInputBecomesURLOrSearch() {
        let engine = SearchEngine.duckDuckGo
        XCTAssertEqual(BrowserWindowModel.url(for: "example.com", engine: engine)?.absoluteString, "https://example.com")
        XCTAssertEqual(BrowserWindowModel.url(for: "two words", engine: engine)?.absoluteString,
                       "https://duckduckgo.com/?q=two%20words")
    }

    func testTabsAreSavedAndRestored() throws {
        let file = TestServices.temporaryFile()
        let store = TabStore(file: file)
        let group = store.makeGroup()
        group.insert(TabModel(isPrivate: false, url: URL(string: "https://example.com/a")))
        group.insert(TabModel(isPrivate: false, url: URL(string: "https://example.com/b")))
        group.selectedTabID = group.tabs[1].id
        store.saveNow()

        let restored = TabStore(file: file)
        let restoredGroup = try XCTUnwrap(restored.group(withID: group.id))
        XCTAssertEqual(restoredGroup.tabs.map(\.url?.absoluteString), ["https://example.com/a", "https://example.com/b"])
        XCTAssertEqual(restoredGroup.selectedTabID, group.tabs[1].id)
    }
}

@MainActor
final class LibraryTests: XCTestCase {
    func testRecentlyClosedTabsReopen() {
        let model = BrowserWindowModel(services: TestServices.make(), restoringGroupID: nil)
        let tab = model.newTab(url: URL(string: "https://example.com/closed"))
        model.close(tab)
        XCTAssertEqual(model.recentlyClosed.first?.snapshot.url?.absoluteString, "https://example.com/closed")
        model.reopenLastClosedTab()
        XCTAssertEqual(model.selectedTab?.url?.absoluteString, "https://example.com/closed")
        XCTAssertTrue(model.recentlyClosed.isEmpty)
    }

    func testClosingPrivateTabsForgetsThem() {
        let model = BrowserWindowModel(services: TestServices.make(), restoringGroupID: nil)
        let privateTab = model.newTab(url: URL(string: "https://example.com/secret"), isPrivate: true)
        model.close(privateTab)
        XCTAssertEqual(model.recentlyClosed.count, 1)
        model.newTab(isPrivate: true)
        model.closeAllTabs(isPrivate: true)
        XCTAssertTrue(model.recentlyClosed.isEmpty)
    }

    func testBookmarksAndShortcuts() {
        let store = BookmarkStore(file: TestServices.temporaryStore("bookmarks.json"))
        let url = URL(string: "https://www.example.com/")!
        store.addBookmark(title: "Example", url: url)
        store.addBookmark(title: "Again", url: URL(string: "https://www.example.com")!)
        XCTAssertEqual(store.bookmarks.count, 1)
        XCTAssertTrue(store.isBookmarked(URL(string: "https://www.example.com#top")))
        store.addShortcut(title: "", url: url)
        XCTAssertEqual(store.shortcuts.first?.title, "example.com")
        store.removeShortcut(for: url)
        XCTAssertTrue(store.shortcuts.isEmpty)
    }

    func testSiteSettingsRememberZoomPerSite() {
        let sites = SiteSettingsStore(file: TestServices.temporaryStore("sites.json"))
        sites.update(URL(string: "https://www.example.com")) { $0.zoom = 1.5 }
        XCTAssertEqual(sites.settings(for: URL(string: "https://example.com/page")).zoom, 1.5)
        XCTAssertNil(sites.settings(for: URL(string: "https://other.example")).zoom)
    }

    func testHistoryStoreRecordsAndClears() {
        let history = HistoryStore(file: TestServices.temporaryStore("history.json"))
        history.recordVisit(to: URL(string: "https://example.com/a")!, title: "A")
        history.updateTitle("Alpha", for: URL(string: "https://example.com/a")!)
        XCTAssertEqual(history.index.search().first?.title, "Alpha")
        history.clear(since: nil)
        XCTAssertTrue(history.index.search().isEmpty)
    }
}

@MainActor
enum TestServices {
    static func temporaryFile() -> JSONFileStore<SessionSnapshot> {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("session.json")
        return JSONFileStore(url: url)
    }

    static func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    static func temporaryStore<Value: Codable>(_ name: String) -> JSONFileStore<Value> {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent(name)
        return JSONFileStore(url: url)
    }

    static func make() -> AppServices {
        let preferences = Preferences()
        let filesRoot = temporaryDirectory()
        return AppServices(
            preferences: preferences,
            tabStore: TabStore(file: temporaryFile()),
            history: HistoryStore(file: temporaryStore("history.json")),
            bookmarks: BookmarkStore(file: temporaryStore("bookmarks.json")),
            siteSettings: SiteSettingsStore(file: temporaryStore("sites.json")),
            searchEngines: SearchEngineStore(preferences: preferences, file: temporaryStore("engines.json")),
            downloads: DownloadManager(
                preferences: preferences, file: temporaryStore("downloads.json"), directory: temporaryDirectory()),
            files: FileStore(
                preferences: preferences, root: filesRoot,
                trash: TrashStore(root: filesRoot, directory: temporaryDirectory(), file: temporaryStore("trash.json"))),
            playlists: PlaylistStore(root: filesRoot, file: temporaryStore("playlists.json")))
    }
}
