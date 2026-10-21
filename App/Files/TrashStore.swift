import BrowserCore
import Combine
import Foundation

/// Deleted files, kept 30 days so they can be put back (like Aloha's Bin). They live in
/// Application Support/Trash, outside the folders the Files app shows.
final class TrashStore: ObservableObject {
    @Published private(set) var records: [TrashRecord] = []
    private let root: URL
    private let directory: URL
    private let file: JSONFileStore<[TrashRecord]>

    init(
        root: URL,
        directory: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trash", isDirectory: true),
        file: JSONFileStore<[TrashRecord]> = LibraryFiles.store("trash.json")
    ) {
        self.root = root
        self.directory = directory
        self.file = file
        records = (file.load() ?? []).sorted { $0.deleted > $1.deleted }
        purgeExpired()
    }

    var totalSize: Int64 {
        records.reduce(0) { $0 + $1.size }
    }

    /// Where a trashed item is kept.
    func location(of record: TrashRecord) -> URL {
        directory.appendingPathComponent(record.id.uuidString, isDirectory: true).appendingPathComponent(record.name)
    }

    func add(_ url: URL, relativePath: String) throws {
        let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .totalFileAllocatedSizeKey, .fileSizeKey])
        let isDirectory = values?.isDirectory ?? false
        let record = TrashRecord(
            originalPath: relativePath, isDirectory: isDirectory,
            size: isDirectory ? Self.folderSize(url) : Int64(values?.fileSize ?? 0))
        let destination = location(of: record)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: url, to: destination)
        records.insert(record, at: 0)
        save()
    }

    /// Puts an item back where it was (recreating its folder), renaming it if the name is taken.
    func restore(_ record: TrashRecord) throws -> URL {
        let folderPath = (record.originalPath as NSString).deletingLastPathComponent
        let folder = folderPath.isEmpty ? root : root.appendingPathComponent(folderPath, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = FileNaming.uniqueURL(in: folder, for: record.name)
        try FileManager.default.moveItem(at: location(of: record), to: destination)
        try? FileManager.default.removeItem(at: location(of: record).deletingLastPathComponent())
        records.removeAll { $0.id == record.id }
        save()
        return destination
    }

    func deleteForever(_ record: TrashRecord) {
        try? FileManager.default.removeItem(at: location(of: record).deletingLastPathComponent())
        records.removeAll { $0.id == record.id }
        save()
    }

    func empty() {
        try? FileManager.default.removeItem(at: directory)
        records.removeAll()
        save()
    }

    /// Deletes items kept longer than 30 days, and leftovers without a record.
    func purgeExpired(now: Date = Date()) {
        let expired = records.filter { $0.isExpired(now: now) }
        for record in expired {
            try? FileManager.default.removeItem(at: location(of: record).deletingLastPathComponent())
        }
        records.removeAll { $0.isExpired(now: now) }
        let known = Set(records.map(\.id.uuidString))
        let folders = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in folders where !known.contains(name) {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
        if !expired.isEmpty {
            save()
        }
    }

    private func save() {
        LibraryFiles.write(records, to: file)
    }

    nonisolated static func folderSize(_ url: URL) -> Int64 {
        var total: Int64 = 0
        let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
        while let file = enumerator?.nextObject() as? URL {
            total += Int64((try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
