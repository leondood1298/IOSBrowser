import BrowserCore
import Foundation
import ZIPFoundation

/// Making and opening archives: ZIP both ways (ZIPFoundation); RAR, 7-Zip, TAR, GZip, BZip2 and
/// XZ open only (see `ArchiveExtractors`).
enum ArchiveService {
    nonisolated enum Failure: LocalizedError, Equatable {
        case needsPassword
        case wrongPassword
        case encryptedNotSupported(String)

        var errorDescription: String? {
            switch self {
            case .needsPassword: return "This archive is protected with a password."
            case .wrongPassword: return "The password is wrong, or the archive is damaged."
            case .encryptedNotSupported(let format): return "Password-protected \(format) archives can't be opened."
            }
        }
    }

    /// Zips files and folders into `destination`. Each keeps its name at the top of the archive.
    nonisolated static func zip(_ urls: [URL], to destination: URL, progress report: @escaping @Sendable (Double) -> Void) throws {
        if urls.count == 1 {
            let progress = Progress()
            let observation = progress.observe(\.fractionCompleted) { progress, _ in report(progress.fractionCompleted) }
            defer { observation.invalidate() }
            try FileManager.default.zipItem(
                at: urls[0], to: destination, shouldKeepParent: true, compressionMethod: .deflate, progress: progress)
            return
        }
        let archive = try ZIPFoundation.Archive(url: destination, accessMode: .create)
        for (index, url) in urls.enumerated() {
            try add(url, relativeTo: url.deletingLastPathComponent(), to: archive)
            report(Double(index + 1) / Double(urls.count))
        }
    }

    nonisolated private static func add(_ url: URL, relativeTo base: URL, to archive: ZIPFoundation.Archive) throws {
        let path = String(url.standardizedFileURL.path.dropFirst(base.standardizedFileURL.path.count))
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        try archive.addEntry(with: path, relativeTo: base, compressionMethod: .deflate)
        let isDirectory = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        guard isDirectory else { return }
        let children = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)) ?? []
        for child in children {
            try add(child, relativeTo: base, to: archive)
        }
    }

    /// Extracts an archive into `folder` (which must exist). Throws `Failure.needsPassword` when a
    /// RAR archive is protected and no password (or the wrong one) was given.
    nonisolated static func extract(
        _ archive: URL, format: ArchiveFormat, to folder: URL, password: String? = nil,
        progress report: @escaping @Sendable (Double) -> Void
    ) throws {
        switch format {
        case .zip:
            let progress = Progress()
            let observation = progress.observe(\.fractionCompleted) { progress, _ in report(progress.fractionCompleted) }
            defer { observation.invalidate() }
            try FileManager.default.unzipItem(at: archive, to: folder, progress: progress)
        case .rar:
            try ArchiveExtractors.extractRAR(archive, to: folder, password: password, progress: report)
        case .sevenZip, .tar, .gzip, .bzip2, .xz:
            try ArchiveExtractors.extractWithSWCompression(archive, format: format, to: folder, progress: report)
        }
    }

    /// The formats Extract is offered for.
    nonisolated static func canExtract(_ format: ArchiveFormat) -> Bool {
        true
    }
}
