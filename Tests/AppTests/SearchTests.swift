import BrowserCore
import XCTest
@testable import Browser

@MainActor
final class SearchTests: XCTestCase {
    private func makeStore() -> (SearchEngineStore, Preferences) {
        let preferences = Preferences(defaults: UserDefaults(suiteName: "SearchTests-\(UUID().uuidString)")!)
        return (SearchEngineStore(preferences: preferences, file: TestServices.temporaryStore("engines.json")), preferences)
    }

    func testAddingAnEngineMakesItTheDefault() throws {
        let (store, _) = makeStore()
        XCTAssertEqual(store.defaultEngine.id, SearchEngine.google.id)
        try store.addEngine(name: "My Search", template: "https://search.example/?q=%s")
        XCTAssertEqual(store.defaultEngine.name, "My Search")
        XCTAssertEqual(store.defaultEngine.searchURL(for: "a b")?.absoluteString, "https://search.example/?q=a%20b")
    }

    func testInvalidEnginesAreRejected() {
        let (store, _) = makeStore()
        XCTAssertThrowsError(try store.addEngine(name: "", template: "https://x.example/?q=%s"))
        XCTAssertThrowsError(try store.addEngine(name: "No placeholder", template: "https://x.example/?q="))
        XCTAssertThrowsError(try store.addEngine(name: "google", template: "https://x.example/?q=%s"), "names are unique")
    }

    func testRemovingAndRestoringBuiltInEngines() {
        let (store, _) = makeStore()
        store.remove(SearchEngine.google)
        XCTAssertTrue(store.engines.contains { $0.id == SearchEngine.google.id }, "the default engine can't be removed")
        store.remove(SearchEngine.bing)
        XCTAssertFalse(store.engines.contains { $0.id == SearchEngine.bing.id })
        XCTAssertTrue(store.hasRemovedBuiltIns)
        store.restoreDefaults()
        XCTAssertTrue(store.engines.contains { $0.id == SearchEngine.bing.id })
    }
}
