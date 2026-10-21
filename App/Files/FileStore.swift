import BrowserCore
import Combine
import UIKit
import UniformTypeIdentifiers

/// One file or folder in the file manager.
nonisolated struct FileItem: Identifiable, Hashable, Sendable {
    let url: URL
    let name: String
    let isDirectory: Bool
    /// Bytes for files; 0 for folders (see `childCount`).
    let size: Int64
    let modified: Date
    let created: Date?
    let contentType: UTType?
    /// Items inside a folder.
    let childCount: Int?

    var id: URL { url }

    var kind: String {
        if isDirectory { return "Folder" }
        let description = contentType?.localizedDescription ?? "File"
        return description.prefix(1).uppercased() + description.dropFirst()
    }

    var entry: FileEntry {
        FileEntry(name: name, isDirectory: isDirectory, size: size, modified: modified, kind: kind)
    }

    var category: FileCategory {
        FileCategory.of(fileName: name, mimeType: contentType?.preferredMIMEType)
    }

    var symbolName: String {
        isDirectory ? "folder.fill" : category.symbolName
    }

    var isImage: Bool { contentType?.conforms(to: .image) ?? false }
    var isMovie: Bool { contentType?.conforms(to: .movie) ?? false || contentType?.conforms(to: .video) ?? false }
    var archiveFormat: ArchiveFormat? { isDirectory ? nil : ArchiveFormat.byExtension(name) }

    /// "12 MB · Oct 21" for files, "4 items" for folders.
    var detail: String {
        let date = modified.formatted(date: .abbreviated, time: .omitted)
        if isDirectory {
            let count = childCount ?? 0
            return "\(count) item\(count == 1 ? "" : "s") · \(date)"
        }
        return "\(DownloadFormatting.bytes(size)) · \(date)"
    }

    static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey, .contentTypeKey, .isHiddenKey,
    ]

    init?(url: URL) {
        guard let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys)) else { return nil }
        self.url = url
        name = url.lastPathComponent
        isDirectory = values.isDirectory ?? false
        size = Int64(values.fileSize ?? 0)
        modified = values.contentModificationDate ?? .distantPast
        created = values.creationDate
        contentType = values.contentType ?? UTType(filenameExtension: url.pathExtension)
        childCount = isDirectory
            ? (try? FileManager.default.contentsOfDirectory(atPath: url.path).filter { !$0.hasPrefix(".") }.count)
            : nil
    }
}

/// A long-running file operation shown as a progress banner.
nonisolated struct FileOperation: Equatable, Sendable {
    var title: String
    var fraction: Double?
}

/// The file manager's files: everything under the app's Documents folder, which the Files app
/// shows as On My iPad › Browser. All changes go through here so open folders refresh.
final class FileStore: ObservableObject {
    /// Bumped after every change; folder views reload when it moves.
    @Published private(set) var revision = 0
    @Published private(set) var operation: FileOperation?
    let trash: TrashStore
    /// The Documents folder (a temporary folder in tests).
    let root: URL
    private let preferences: Preferences

    init(preferences: Preferences, root: URL = AppFolders.documentsDirectory, trash: TrashStore? = nil) {
        self.preferences = preferences
        self.root = root
        self.trash = trash ?? TrashStore(root: root)
    }

    func changed() {
        revision += 1
    }

    // MARK: Listing

    func contents(of folder: URL) -> [FileItem] {
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: FileItem.resourceKeys, options: [.skipsHiddenFiles])) ?? []
        return urls.compactMap(FileItem.init(url:))
    }

    /// Files and folders under `folder` whose names contain `query`, at most `limit`.
    nonisolated static func search(_ query: String, in folder: URL, limit: Int = 300) async -> [URL] {
        await Task.detached(priority: .userInitiated) {
            let needle = query.trimmingCharacters(in: .whitespaces)
            guard !needle.isEmpty,
                  let enumerator = FileManager.default.enumerator(
                    at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])
            else { return [] }
            var results: [URL] = []
            while let url = enumerator.nextObject() as? URL, results.count < limit {
                if url.lastPathComponent.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive]) != nil {
                    results.append(url)
                }
            }
            return results
        }.value
    }

    /// How much the app's files take and how much space the iPad has left.
    nonisolated static func storage(of folder: URL) async -> (used: Int64, available: Int64?) {
        await Task.detached(priority: .utility) {
            var used: Int64 = 0
            if let enumerator = FileManager.default.enumerator(
                at: folder, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey]) {
                while let url = enumerator.nextObject() as? URL {
                    let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
                    used += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
                }
            }
            let available = (try? folder.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            return (used, available)
        }.value
    }

    /// The path of `url` under Documents, e.g. "Downloads/report.pdf".
    func relativePath(of url: URL) -> String {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard path.hasPrefix(base) else { return url.lastPathComponent }
        return String(path.dropFirst(base.count)).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// "Downloads › Videos" for display.
    func displayPath(of folder: URL) -> String {
        let relative = relativePath(of: folder)
        return relative.isEmpty ? "On My iPad" : relative.replacingOccurrences(of: "/", with: " › ")
    }

    // MARK: Changes

    @discardableResult
    func createFolder(named name: String, in folder: URL) throws -> URL {
        let url = FileNaming.uniqueURL(in: folder, for: name.isEmpty ? "New Folder" : name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        changed()
        return url
    }

    @discardableResult
    func rename(_ url: URL, to newName: String) throws -> URL {
        let name = FileNaming.sanitize(newName)
        guard name != url.lastPathComponent else { return url }
        let destination = FileNaming.uniqueURL(in: url.deletingLastPathComponent(), for: name)
        try FileManager.default.moveItem(at: url, to: destination)
        changed()
        return destination
    }

    @discardableResult
    func duplicate(_ url: URL) throws -> URL {
        let ext = url.pathExtension
        let stem = url.deletingPathExtension().lastPathComponent
        let name = "\(stem) copy" + (ext.isEmpty ? "" : ".\(ext)")
        let destination = FileNaming.uniqueURL(in: url.deletingLastPathComponent(), for: name)
        try FileManager.default.copyItem(at: url, to: destination)
        changed()
        return destination
    }

    /// Moves items into `folder`, renaming on name clashes. A folder can't go inside itself.
    func move(_ urls: [URL], to folder: URL) throws {
        for url in urls where !isSameOrInside(folder, url) && url.deletingLastPathComponent().standardizedFileURL != folder.standardizedFileURL {
            let destination = FileNaming.uniqueURL(in: folder, for: url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: destination)
        }
        changed()
    }

    func copy(_ urls: [URL], to folder: URL) throws {
        for url in urls where !isSameOrInside(folder, url) {
            let destination = FileNaming.uniqueURL(in: folder, for: url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
        }
        changed()
    }

    /// Moves items to the Trash (kept 30 days), or deletes them right away when the Trash is off.
    func delete(_ urls: [URL]) throws {
        for url in urls {
            if preferences.useTrash {
                try trash.add(url, relativePath: relativePath(of: url))
            } else {
                try FileManager.default.removeItem(at: url)
            }
        }
        changed()
    }

    @discardableResult
    func restore(_ record: TrashRecord) throws -> URL {
        let url = try trash.restore(record)
        changed()
        return url
    }

    /// Copies files from elsewhere (the Files app, other apps, Photos) into `folder`.
    @discardableResult
    func importFiles(_ urls: [URL], into folder: URL) throws -> [URL] {
        var imported: [URL] = []
        for url in urls {
            let scoped = url.startAccessingSecurityScopedResource()
            defer {
                if scoped { url.stopAccessingSecurityScopedResource() }
            }
            let destination = FileNaming.uniqueURL(in: folder, for: url.lastPathComponent)
            try FileManager.default.copyItem(at: url, to: destination)
            imported.append(destination)
        }
        changed()
        return imported
    }

    func isSameOrInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path
        let base = folder.standardizedFileURL.path
        return path == base || path.hasPrefix(base + "/")
    }

    // MARK: Long operations

    /// Runs `work` off the main thread with a progress banner, then refreshes folders.
    func perform(
        _ title: String, work: @escaping @Sendable (_ progress: @escaping @Sendable (Double) -> Void) throws -> Void
    ) async throws {
        operation = FileOperation(title: title, fraction: nil)
        defer {
            operation = nil
            changed()
        }
        let report: @Sendable (Double) -> Void = { [weak self] fraction in
            Task { @MainActor in
                self?.operation?.fraction = fraction
            }
        }
        try await Task.detached(priority: .userInitiated) {
            try work(report)
        }.value
    }
}
