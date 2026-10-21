import BrowserCore
import XCTest
@testable import Browser

@MainActor
final class DownloadTests: XCTestCase {
    private var folderName = ""
    private var folder: URL {
        AppFolders.documentsDirectory.appendingPathComponent(folderName, isDirectory: true)
    }

    /// A folder of its own under Documents for each test, removed afterwards.
    private func prepareFolder() throws {
        folderName = "UnitTestDownloads-\(UUID().uuidString)"
        let url = folder
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
    }

    private func makeManager(
        file: JSONFileStore<[DownloadRecord]> = TestServices.temporaryStore("downloads.json"),
        directory: URL = TestServices.temporaryDirectory()
    ) -> DownloadManager {
        DownloadManager(preferences: Preferences(), file: file, directory: directory)
    }

    private func savedFile(named name: String, contents: String = "hello") throws -> URL {
        let url = folder.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    func testRelaunchPausesResumableDownloadsAndFailsTheRest() throws {
        try prepareFolder()
        let directory = TestServices.temporaryDirectory()
        let file: JSONFileStore<[DownloadRecord]> = TestServices.temporaryStore("downloads.json")
        let resumable = DownloadRecord(
            sourceURL: URL(string: "https://example.com/a.zip"), pageURL: nil, fileName: "a.zip",
            folder: folderName, state: .running)
        let lost = DownloadRecord(
            sourceURL: URL(string: "https://example.com/b.zip"), pageURL: nil, fileName: "b.zip",
            folder: folderName, state: .running)
        try file.save([resumable, lost])
        let resumeData = directory.appendingPathComponent("ResumeData", isDirectory: true)
        try FileManager.default.createDirectory(at: resumeData, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: resumeData.appendingPathComponent("\(resumable.id.uuidString).data"))

        let manager = makeManager(file: file, directory: directory)
        XCTAssertEqual(manager.item(resumable.id)?.record.state, .paused)
        XCTAssertEqual(manager.item(lost.id)?.record.state, .failed)
        XCTAssertNotNil(manager.item(lost.id)?.record.failureReason)
    }

    func testSavedFileIsListedRenamedAndDeleted() throws {
        try prepareFolder()
        let manager = makeManager()
        let url = try savedFile(named: "photo.png")
        manager.addSavedFile(url, folder: folderName, sourceURL: nil, pageURL: nil, isPrivate: false)
        let item = try XCTUnwrap(manager.items.first)
        XCTAssertEqual(item.record.state, .finished)
        XCTAssertEqual(item.record.expectedBytes, 5)
        XCTAssertEqual(item.fileURL.standardizedFileURL, url.standardizedFileURL)

        try manager.rename(item, to: "holiday.png")
        XCTAssertEqual(item.record.fileName, "holiday.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.appendingPathComponent("holiday.png").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))

        manager.deleteFile(item)
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("holiday.png").path))
    }

    func testRenameKeepsNamesUnique() throws {
        try prepareFolder()
        let manager = makeManager()
        _ = try savedFile(named: "taken.txt")
        let url = try savedFile(named: "notes.txt")
        manager.addSavedFile(url, folder: folderName, sourceURL: nil, pageURL: nil, isPrivate: false)
        let item = try XCTUnwrap(manager.items.first)
        try manager.rename(item, to: "taken.txt")
        XCTAssertEqual(item.record.fileName, "taken (2).txt")
    }

    func testClearingAndErasing() throws {
        try prepareFolder()
        let manager = makeManager()
        let normal = try savedFile(named: "normal.txt")
        let secret = try savedFile(named: "secret.txt")
        manager.addSavedFile(normal, folder: folderName, sourceURL: nil, pageURL: nil, isPrivate: false)
        manager.addSavedFile(secret, folder: folderName, sourceURL: nil, pageURL: nil, isPrivate: true)
        XCTAssertEqual(manager.items.count, 2)

        manager.erasePrivateDownloads()
        XCTAssertEqual(manager.items.map(\.record.fileName), ["normal.txt"])
        // Files stay where they are; only the list forgets them.
        XCTAssertTrue(FileManager.default.fileExists(atPath: secret.path))

        manager.clearList()
        XCTAssertTrue(manager.items.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: normal.path))
    }

    func testDefaultFolder() {
        let preferences = Preferences()
        let manager = DownloadManager(
            preferences: preferences, file: TestServices.temporaryStore("downloads.json"),
            directory: TestServices.temporaryDirectory())
        let savedFolder = preferences.downloadFolder
        let savedSorting = preferences.sortDownloadsByType
        defer {
            preferences.downloadFolder = savedFolder
            preferences.sortDownloadsByType = savedSorting
        }
        preferences.sortDownloadsByType = false
        preferences.downloadFolder = "Documents"
        XCTAssertEqual(manager.defaultFolder(forFileNamed: "clip.mp4", mimeType: nil), "Documents")
        preferences.sortDownloadsByType = true
        XCTAssertEqual(manager.defaultFolder(forFileNamed: "clip.mp4", mimeType: nil), "Videos")
        XCTAssertEqual(manager.defaultFolder(forFileNamed: "file.bin", mimeType: nil), "Downloads")
    }

    func testRecordsAreSavedWithoutPrivateOnes() async throws {
        try prepareFolder()
        let file: JSONFileStore<[DownloadRecord]> = TestServices.temporaryStore("downloads.json")
        let manager = makeManager(file: file)
        manager.addSavedFile(try savedFile(named: "keep.txt"), folder: folderName, sourceURL: nil, pageURL: nil, isPrivate: false)
        manager.addSavedFile(try savedFile(named: "drop.txt"), folder: folderName, sourceURL: nil, pageURL: nil, isPrivate: true)
        // Saving is debounced and written in the background.
        for _ in 0..<40 {
            if let saved = file.load(), !saved.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTAssertEqual(file.load()?.map(\.fileName), ["keep.txt"])
    }
}
