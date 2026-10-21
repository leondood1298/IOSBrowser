import BrowserCore
import XCTest
@testable import Browser

@MainActor
final class TabGroupTests: XCTestCase {
    func testMakingSwitchingAndDeletingGroups() {
        let services = TestServices.make()
        let window = BrowserWindowModel(services: services, restoringGroupID: nil)
        window.newTab(url: URL(string: "https://example.com/1"))

        let work = window.makeGroup(named: "Work", movingCurrentTabs: true)
        XCTAssertTrue(window.normalGroup === work)
        XCTAssertEqual(work.title, "Work")
        XCTAssertEqual(work.tabs.count, 2)
        XCTAssertTrue(window.defaultGroup.tabs.isEmpty)
        XCTAssertEqual(services.tabStore.namedGroups.map(\.title), ["Work"])
        XCTAssertEqual(window.normalTabs.count, 2, "views see the shown group's tabs")

        window.show(window.defaultGroup)
        XCTAssertTrue(window.normalGroup === window.defaultGroup)
        XCTAssertEqual(window.normalTabs.count, 1, "an empty group gets a blank tab")

        let tab = window.newTab(url: URL(string: "https://example.com/2"))
        window.move(tab, to: work)
        XCTAssertTrue(work.tabs.contains { $0 === tab })
        XCTAssertFalse(window.normalGroup.tabs.contains { $0 === tab })

        window.delete(work)
        XCTAssertTrue(services.tabStore.namedGroups.isEmpty)
    }

    func testAGroupIsShownInOnlyOneWindow() {
        let services = TestServices.make()
        let first = BrowserWindowModel(services: services, restoringGroupID: nil)
        let shared = first.makeGroup(named: "Shared", movingCurrentTabs: false)
        let second = BrowserWindowModel(services: services, restoringGroupID: nil)
        XCTAssertFalse(second.show(shared))
        XCTAssertTrue(second.normalGroup === second.defaultGroup)
        XCTAssertTrue(services.tabStore.window(showing: shared) === first)
    }

    func testRestoringTheShownGroup() {
        let services = TestServices.make()
        let first = BrowserWindowModel(services: services, restoringGroupID: nil)
        let group = first.makeGroup(named: "Reading", movingCurrentTabs: false)
        let ownID = first.defaultGroup.id
        let restored = BrowserWindowModel(services: services, restoringGroupID: ownID, activeGroupID: group.id)
        // The group is still shown by the first window, so the restored one falls back to its own.
        XCTAssertTrue(restored.normalGroup === restored.defaultGroup)
    }

    func testDuplicateAndCloseOthers() {
        let window = BrowserWindowModel(services: TestServices.make(), restoringGroupID: nil)
        let tab = window.newTab(url: URL(string: "https://example.com/a"))
        window.duplicate(tab)
        XCTAssertEqual(window.normalGroup.tabs.count, 3)
        XCTAssertNotEqual(window.selectedTab?.id, tab.id)
        XCTAssertEqual(window.selectedTab?.url, tab.url)
        window.closeOtherTabs(than: tab)
        XCTAssertEqual(window.normalGroup.tabs.map(\.id), [tab.id])
    }

    func testRenameGroup() {
        let services = TestServices.make()
        let window = BrowserWindowModel(services: services, restoringGroupID: nil)
        let group = window.makeGroup(named: "Old", movingCurrentTabs: false)
        services.tabStore.rename(group, to: "  New name ")
        XCTAssertEqual(group.title, "New name")
        services.tabStore.rename(group, to: "   ")
        XCTAssertEqual(group.title, "New name", "blank names are ignored")
    }
}
