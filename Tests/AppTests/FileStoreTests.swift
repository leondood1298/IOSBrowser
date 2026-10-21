import BrowserCore
import XCTest
@testable import Browser

@MainActor
final class FileStoreTests: XCTestCase {
    private var root: URL!
    private var trashFolder: URL!

    private func makeStore(useTrash: Bool = true) -> FileStore {
        root = TestServices.temporaryDirectory()
        trashFolder = TestServices.temporaryDirectory()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let rootURL: URL = root
        let trashURL: URL = trashFolder
        addTeardownBlock {
            try? FileManager.default.removeItem(at: rootURL)
            try? FileManager.default.removeItem(at: trashURL)
        }
        let preferences = Preferences()
        preferences.useTrash = useTrash
        let trash = TrashStore(root: root, directory: trashFolder, file: TestServices.temporaryStore("trash.json"))
        return FileStore(preferences: preferences, root: root, trash: trash)
    }

    private func write(_ name: String, in folder: URL? = nil, contents: String = "hello") throws -> URL {
        let url = (folder ?? root).appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    private func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    func testCreateRenameDuplicate() throws {
        let store = makeStore()
        let folder = try store.createFolder(named: "Projects", in: root)
        let second = try store.createFolder(named: "Projects", in: root)
        XCTAssertEqual(second.lastPathComponent, "Projects (2)")
        let file = try write("notes.txt", in: folder)
        let renamed = try store.rename(file, to: "ideas.txt")
        XCTAssertEqual(renamed.lastPathComponent, "ideas.txt")
        XCTAssertFalse(exists(file))
        let copy = try store.duplicate(renamed)
        XCTAssertEqual(copy.lastPathComponent, "ideas copy.txt")
        XCTAssertEqual(store.contents(of: folder).map(\.name).sorted(), ["ideas copy.txt", "ideas.txt"])
        XCTAssertEqual(store.contents(of: root).first { $0.name == "Projects" }?.childCount, 2)
    }

    func testMoveAndCopyKeepNamesUnique() throws {
        let store = makeStore()
        let target = try store.createFolder(named: "Target", in: root)
        _ = try write("a.txt", in: target)
        let a = try write("a.txt")
        try store.copy([a], to: target)
        XCTAssertTrue(exists(target.appendingPathComponent("a (2).txt")))
        try store.move([a], to: target)
        XCTAssertFalse(exists(a))
        XCTAssertTrue(exists(target.appendingPathComponent("a (3).txt")))
        // A folder can't be moved into itself.
        try store.move([target], to: target)
        XCTAssertTrue(exists(target))
    }

    func testDeleteGoesToTrashAndRestores() throws {
        let store = makeStore()
        let folder = try store.createFolder(named: "Docs", in: root)
        let file = try write("report.pdf", in: folder)
        try store.delete([file])
        XCTAssertFalse(exists(file))
        let record = try XCTUnwrap(store.trash.records.first)
        XCTAssertEqual(record.originalPath, "Docs/report.pdf")
        XCTAssertEqual(record.size, 5)
        XCTAssertTrue(exists(store.trash.location(of: record)))

        // Restoring recreates the folder if it's gone.
        try FileManager.default.removeItem(at: folder)
        let restored = try store.restore(record)
        XCTAssertEqual(restored.lastPathComponent, "report.pdf")
        XCTAssertTrue(exists(folder.appendingPathComponent("report.pdf")))
        XCTAssertTrue(store.trash.records.isEmpty)
    }

    func testDeleteWithoutTrash() throws {
        let store = makeStore(useTrash: false)
        defer { Preferences().useTrash = true }
        let file = try write("gone.txt")
        try store.delete([file])
        XCTAssertFalse(exists(file))
        XCTAssertTrue(store.trash.records.isEmpty)
    }

    func testTrashPurgesExpiredItems() throws {
        let store = makeStore()
        let file = try write("old.txt")
        try store.delete([file])
        let record = try XCTUnwrap(store.trash.records.first)
        store.trash.purgeExpired(now: record.deleted.addingTimeInterval(31 * 86_400))
        XCTAssertTrue(store.trash.records.isEmpty)
        XCTAssertFalse(exists(store.trash.location(of: record)))
    }

    func testImportCopiesWithUniqueNames() throws {
        let store = makeStore()
        let source = TestServices.temporaryDirectory()
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        let outside = source.appendingPathComponent("photo.jpg")
        try Data([1, 2, 3]).write(to: outside)
        _ = try write("photo.jpg")
        let imported = try store.importFiles([outside], into: root)
        XCTAssertEqual(imported.map(\.lastPathComponent), ["photo (2).jpg"])
        XCTAssertTrue(exists(outside))
    }

    func testSearchFindsNestedFiles() async throws {
        let store = makeStore()
        let nested = try store.createFolder(named: "Deep", in: root)
        _ = try write("Holiday Photo.jpg", in: nested)
        _ = try write("notes.txt")
        let found = await FileStore.search("holiday", in: root)
        XCTAssertEqual(found.map(\.lastPathComponent), ["Holiday Photo.jpg"])
    }

    func testRelativePaths() {
        let store = makeStore()
        XCTAssertEqual(store.relativePath(of: root.appendingPathComponent("Downloads/a.txt")), "Downloads/a.txt")
        XCTAssertEqual(store.displayPath(of: root), "On My iPad")
        XCTAssertEqual(store.displayPath(of: root.appendingPathComponent("Downloads/Videos")), "Downloads › Videos")
    }

    func testZipAndExtract() throws {
        let store = makeStore()
        let folder = try store.createFolder(named: "Album", in: root)
        _ = try write("one.txt", in: folder, contents: "first")
        _ = try write("two.txt", in: folder, contents: "second")
        let archive = root.appendingPathComponent("Album.zip")
        try ArchiveService.zip([folder], to: archive) { _ in }
        XCTAssertTrue(exists(archive))
        let output = root.appendingPathComponent("Out", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try ArchiveService.extract(archive, format: .zip, to: output) { _ in }
        let text = try String(contentsOf: output.appendingPathComponent("Album/two.txt"), encoding: .utf8)
        XCTAssertEqual(text, "second")
    }
}
