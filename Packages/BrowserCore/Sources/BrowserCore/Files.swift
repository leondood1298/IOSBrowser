import Foundation

/// What the file manager knows about one file or folder, for sorting and display.
public struct FileEntry: Hashable, Sendable {
    public var name: String
    public var isDirectory: Bool
    public var size: Int64
    public var modified: Date
    /// A short description of the type, e.g. "PDF document", used for sorting by kind.
    public var kind: String
    /// Seconds, for audio and video when known.
    public var duration: Double?

    public init(name: String, isDirectory: Bool, size: Int64, modified: Date, kind: String, duration: Double? = nil) {
        self.name = name
        self.isDirectory = isDirectory
        self.size = size
        self.modified = modified
        self.kind = kind
        self.duration = duration
    }
}

/// How the file manager orders a folder. Folders always come first.
public enum FileSort: String, Codable, Sendable, CaseIterable {
    case name
    case date
    case size
    case kind
    case duration

    public var title: String {
        switch self {
        case .name: return "Name"
        case .date: return "Date"
        case .size: return "Size"
        case .kind: return "Kind"
        case .duration: return "Duration"
        }
    }

    /// Names sort like the Files app ("file 2" before "file 10"); dates and sizes newest and
    /// largest first unless reversed.
    public func sorted(_ entries: [FileEntry], reversed: Bool = false) -> [FileEntry] {
        sorted(entries, entry: { $0 }, reversed: reversed)
    }

    /// Sorts any items by the entry each one describes.
    public func sorted<Item>(_ items: [Item], entry: (Item) -> FileEntry, reversed: Bool = false) -> [Item] {
        let keyed = items.map { (item: $0, entry: entry($0)) }
        return keyed.sorted { left, right in
            let a = left.entry
            let b = right.entry
            if a.isDirectory != b.isDirectory {
                return a.isDirectory
            }
            let ordered = isOrderedBefore(a, b)
            let tie = !isOrderedBefore(b, a) && !ordered
            if tie {
                return Self.byName(a, b)
            }
            return reversed ? !ordered : ordered
        }
        .map(\.item)
    }

    private func isOrderedBefore(_ a: FileEntry, _ b: FileEntry) -> Bool {
        switch self {
        case .name:
            return Self.byName(a, b)
        case .date:
            return a.modified > b.modified
        case .size:
            return a.size > b.size
        case .kind:
            return a.kind.localizedStandardCompare(b.kind) == .orderedAscending
        case .duration:
            // Files without a duration go last.
            switch (a.duration, b.duration) {
            case let (x?, y?): return x > y
            case (.some, nil): return true
            default: return false
            }
        }
    }

    private static func byName(_ a: FileEntry, _ b: FileEntry) -> Bool {
        a.name.localizedStandardCompare(b.name) == .orderedAscending
    }
}

/// A file in the Trash: where it came from and when it was deleted. Files stay 30 days.
public struct TrashRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// The file's path under Documents before it was deleted, e.g. "Downloads/report.pdf".
    public var originalPath: String
    public var deleted: Date
    public var isDirectory: Bool
    public var size: Int64

    public init(id: UUID = UUID(), originalPath: String, deleted: Date = Date(), isDirectory: Bool, size: Int64) {
        self.id = id
        self.originalPath = originalPath
        self.deleted = deleted
        self.isDirectory = isDirectory
        self.size = size
    }

    public static let keepDays = 30

    public var name: String {
        (originalPath as NSString).lastPathComponent
    }

    public func expires(calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: Self.keepDays, to: deleted) ?? deleted.addingTimeInterval(30 * 86_400)
    }

    public func isExpired(now: Date = Date(), calendar: Calendar = .current) -> Bool {
        now >= expires(calendar: calendar)
    }

    /// Whole days left before the file is deleted for good (0 on the last day).
    public func daysLeft(now: Date = Date(), calendar: Calendar = .current) -> Int {
        max(0, calendar.dateComponents([.day], from: now, to: expires(calendar: calendar)).day ?? 0)
    }
}

/// Archive formats the file manager can open.
public enum ArchiveFormat: String, Sendable, CaseIterable {
    case zip
    case sevenZip
    case rar
    case tar
    case gzip
    case bzip2
    case xz

    public var title: String {
        switch self {
        case .zip: return "ZIP"
        case .sevenZip: return "7-Zip"
        case .rar: return "RAR"
        case .tar: return "TAR"
        case .gzip: return "GZip"
        case .bzip2: return "BZip2"
        case .xz: return "XZ"
        }
    }

    /// By the file's first bytes, falling back to its extension.
    public static func detect(fileName: String, header: Data) -> ArchiveFormat? {
        let bytes = [UInt8](header.prefix(262))
        func starts(with prefix: [UInt8]) -> Bool {
            bytes.count >= prefix.count && Array(bytes.prefix(prefix.count)) == prefix
        }
        if starts(with: [0x50, 0x4B, 0x03, 0x04]) || starts(with: [0x50, 0x4B, 0x05, 0x06]) { return .zip }
        if starts(with: [0x37, 0x7A, 0xBC, 0xAF, 0x27, 0x1C]) { return .sevenZip }
        if starts(with: [0x52, 0x61, 0x72, 0x21, 0x1A, 0x07]) { return .rar }
        if starts(with: [0x1F, 0x8B]) { return .gzip }
        if starts(with: [0x42, 0x5A, 0x68]) { return .bzip2 }
        if starts(with: [0xFD, 0x37, 0x7A, 0x58, 0x5A, 0x00]) { return .xz }
        if bytes.count >= 262, Array(bytes[257..<262]) == Array("ustar".utf8) { return .tar }
        return byExtension(fileName)
    }

    public static func byExtension(_ fileName: String) -> ArchiveFormat? {
        let lower = fileName.lowercased()
        let ext = (lower as NSString).pathExtension
        switch ext {
        case "zip": return .zip
        case "7z": return .sevenZip
        case "rar": return .rar
        case "tar": return .tar
        case "gz", "tgz": return .gzip
        case "bz2", "tbz", "tbz2": return .bzip2
        case "xz", "txz": return .xz
        default: return nil
        }
    }
}

/// Paths for files taken out of archives.
public enum ArchivePaths {
    /// The path of an archive entry, cleaned so it stays inside the destination folder: no
    /// leading "/", no "." or ".." parts, backslashes treated as separators. Nil when nothing is left.
    public static func safeRelativePath(_ entryPath: String) -> String? {
        let parts = entryPath
            .replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
            .map { FileNaming.sanitize($0, fallback: "item") }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
    }

    /// The folder an archive is extracted into: "Photos.zip" → "Photos", "data.tar.gz" → "data".
    public static func folderName(forArchive fileName: String) -> String {
        var name = fileName
        let compound = [".tar.gz", ".tar.bz2", ".tar.xz"]
        if let suffix = compound.first(where: { name.lowercased().hasSuffix($0) }) {
            name.removeLast(suffix.count)
        } else {
            name = (name as NSString).deletingPathExtension
        }
        return FileNaming.sanitize(name, fallback: "Archive")
    }

    /// The name of a single file inside a compressed (not archived) file: "notes.txt.gz" → "notes.txt".
    public static func decompressedName(for fileName: String) -> String {
        let lower = fileName.lowercased()
        for (suffix, replacement) in [(".tgz", ".tar"), (".tbz2", ".tar"), (".tbz", ".tar"), (".txz", ".tar")] where lower.hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count)) + replacement
        }
        for suffix in [".gz", ".bz2", ".xz"] where lower.hasSuffix(suffix) {
            return String(fileName.dropLast(suffix.count))
        }
        return fileName + ".out"
    }
}
