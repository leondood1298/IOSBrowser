import XCTest
@testable import BrowserCore

final class FilesTests: XCTestCase {
    private func entry(
        _ name: String, folder: Bool = false, size: Int64 = 0, modified: TimeInterval = 0, kind: String = "",
        duration: Double? = nil
    ) -> FileEntry {
        FileEntry(
            name: name, isDirectory: folder, size: size, modified: Date(timeIntervalSince1970: modified), kind: kind,
            duration: duration)
    }

    func testFoldersFirstThenNaturalNameOrder() {
        let entries = [entry("file 10"), entry("file 2"), entry("B", folder: true), entry("a", folder: true)]
        XCTAssertEqual(FileSort.name.sorted(entries).map(\.name), ["a", "B", "file 2", "file 10"])
        XCTAssertEqual(FileSort.name.sorted(entries, reversed: true).map(\.name), ["B", "a", "file 10", "file 2"])
    }

    func testSortBySizeDateAndKind() {
        let entries = [
            entry("small", size: 10, modified: 300, kind: "Text"),
            entry("big", size: 900, modified: 100, kind: "Movie"),
            entry("medium", size: 500, modified: 200, kind: "Image"),
        ]
        XCTAssertEqual(FileSort.size.sorted(entries).map(\.name), ["big", "medium", "small"])
        XCTAssertEqual(FileSort.size.sorted(entries, reversed: true).map(\.name), ["small", "medium", "big"])
        XCTAssertEqual(FileSort.date.sorted(entries).map(\.name), ["small", "medium", "big"])
        XCTAssertEqual(FileSort.kind.sorted(entries).map(\.name), ["medium", "big", "small"])
    }

    func testSortByDurationPutsUnknownLast() {
        let entries = [entry("doc"), entry("short", duration: 30), entry("long", duration: 600)]
        XCTAssertEqual(FileSort.duration.sorted(entries).map(\.name), ["long", "short", "doc"])
    }

    func testEqualValuesFallBackToName() {
        let entries = [entry("b", size: 5), entry("a", size: 5)]
        XCTAssertEqual(FileSort.size.sorted(entries).map(\.name), ["a", "b"])
    }

    func testTrashExpiry() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let deleted = Date(timeIntervalSince1970: 1_800_000_000)
        let record = TrashRecord(originalPath: "Downloads/report.pdf", deleted: deleted, isDirectory: false, size: 10)
        XCTAssertEqual(record.name, "report.pdf")
        XCTAssertEqual(record.daysLeft(now: deleted, calendar: calendar), 30)
        XCTAssertFalse(record.isExpired(now: deleted.addingTimeInterval(29 * 86_400), calendar: calendar))
        XCTAssertEqual(record.daysLeft(now: deleted.addingTimeInterval(29.5 * 86_400), calendar: calendar), 0)
        XCTAssertTrue(record.isExpired(now: deleted.addingTimeInterval(30 * 86_400), calendar: calendar))
        XCTAssertEqual(record.daysLeft(now: deleted.addingTimeInterval(40 * 86_400), calendar: calendar), 0)
    }

    func testArchiveDetection() {
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x.bin", header: Data([0x50, 0x4B, 0x03, 0x04, 0])), .zip)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x", header: Data([0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C])), .sevenZip)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x", header: Data([0x52, 0x61, 0x72, 0x21, 0x1A, 0x07, 0x01, 0x00])), .rar)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x", header: Data([0x1F, 0x8B, 0x08])), .gzip)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x", header: Data([0x42, 0x5A, 0x68, 0x39])), .bzip2)
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x", header: Data([0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00])), .xz)
        var tar = Data(count: 262)
        tar.replaceSubrange(257..<262, with: Array("ustar".utf8))
        XCTAssertEqual(ArchiveFormat.detect(fileName: "x", header: tar), .tar)
        // Falls back to the extension when the header says nothing.
        XCTAssertEqual(ArchiveFormat.detect(fileName: "Backup.TGZ", header: Data()), .gzip)
        XCTAssertNil(ArchiveFormat.detect(fileName: "notes.txt", header: Data("hello".utf8)))
    }

    func testSafeRelativePaths() {
        XCTAssertEqual(ArchivePaths.safeRelativePath("../../etc/passwd"), "etc/passwd")
        XCTAssertEqual(ArchivePaths.safeRelativePath("/absolute/file.txt"), "absolute/file.txt")
        XCTAssertEqual(ArchivePaths.safeRelativePath("folder\\sub\\file.txt"), "folder/sub/file.txt")
        XCTAssertEqual(ArchivePaths.safeRelativePath("a/./b//c.txt"), "a/b/c.txt")
        XCTAssertNil(ArchivePaths.safeRelativePath("./"))
        XCTAssertNil(ArchivePaths.safeRelativePath("../.."))
    }

    func testArchiveNames() {
        XCTAssertEqual(ArchivePaths.folderName(forArchive: "Photos.zip"), "Photos")
        XCTAssertEqual(ArchivePaths.folderName(forArchive: "data.tar.gz"), "data")
        XCTAssertEqual(ArchivePaths.decompressedName(for: "notes.txt.gz"), "notes.txt")
        XCTAssertEqual(ArchivePaths.decompressedName(for: "backup.tgz"), "backup.tar")
        XCTAssertEqual(ArchivePaths.decompressedName(for: "file.xz"), "file")
    }
}
