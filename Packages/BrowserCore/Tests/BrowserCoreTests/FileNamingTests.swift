import XCTest
@testable import BrowserCore

final class FileNamingTests: XCTestCase {
    func testSanitize() {
        XCTAssertEqual(FileNaming.sanitize("a/b\\c:d?.txt"), "a-b-c-d-.txt")
        XCTAssertEqual(FileNaming.sanitize("  ..hidden. "), "hidden")
        XCTAssertEqual(FileNaming.sanitize("   "), "download")
        let long = String(repeating: "x", count: 300) + ".mp4"
        let cleaned = FileNaming.sanitize(long)
        XCTAssertEqual(cleaned.count, 180)
        XCTAssertTrue(cleaned.hasSuffix(".mp4"))
    }

    func testUnique() {
        let taken: Set<String> = ["photo.jpg", "photo (2).jpg", "notes"]
        XCTAssertEqual(FileNaming.unique("new.jpg") { taken.contains($0) }, "new.jpg")
        XCTAssertEqual(FileNaming.unique("photo.jpg") { taken.contains($0) }, "photo (3).jpg")
        XCTAssertEqual(FileNaming.unique("photo (2).jpg") { taken.contains($0) }, "photo (3).jpg")
        XCTAssertEqual(FileNaming.unique("notes") { taken.contains($0) }, "notes (2)")
    }

    func testUniqueURL() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("a.txt"))
        XCTAssertEqual(FileNaming.uniqueURL(in: directory, for: "a.txt").lastPathComponent, "a (2).txt")
        XCTAssertEqual(FileNaming.uniqueURL(in: directory, for: "b.txt").lastPathComponent, "b.txt")
    }

    func testPageFileName() {
        XCTAssertEqual(FileNaming.pageFileName(title: "News: Today", url: nil, extension: "pdf"), "News- Today.pdf")
        XCTAssertEqual(FileNaming.pageFileName(title: nil, url: URL(string: "https://www.example.com/x"), extension: "pdf"), "example.com.pdf")
    }
}
