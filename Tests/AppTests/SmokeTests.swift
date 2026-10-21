import BrowserCore
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

    func testBrowserCoreIsLinked() {
        XCTAssertEqual(URIFixup.classify("localhost:8000"), .url(URL(string: "http://localhost:8000")!))
    }

    func testBrowserViewControllerLoads() {
        let controller = BrowserViewController()
        controller.loadViewIfNeeded()
        XCTAssertNotNil(controller.navigationItem.titleView)
    }
}
