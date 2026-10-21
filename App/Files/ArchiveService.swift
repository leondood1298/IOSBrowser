import BrowserCore
import Foundation
import ZIPFoundation

/// Making and opening archives. ZIP works both ways (ZIPFoundation); other formats open only.
enum ArchiveService {
    nonisolated enum Failure: LocalizedError {
        case unsupported(String)

        var errorDescription: String? {
            switch self {
            case .unsupported(let format): return "\(format) archives can't be opened yet."
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
        let archive = try Archive(url: destination, accessMode: .create)
        for (index, url) in urls.enumerated() {
            try add(url, relativeTo: url.deletingLastPathComponent(), to: archive)
            report(Double(index + 1) / Double(urls.count))
        }
    }

    nonisolated private static func add(_ url: URL, relativeTo base: URL, to archive: Archive) throws {
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

    /// Extracts an archive into `folder` (which must exist).
    nonisolated static func extract(
        _ archive: URL, format: ArchiveFormat, to folder: URL, progress report: @escaping @Sendable (Double) -> Void
    ) throws {
        switch format {
        case .zip:
            let progress = Progress()
            let observation = progress.observe(\.fractionCompleted) { progress, _ in report(progress.fractionCompleted) }
            defer { observation.invalidate() }
            try FileManager.default.unzipItem(at: archive, to: folder, progress: progress)
        default:
            throw Failure.unsupported(format.title)
        }
    }

    /// The formats Extract is offered for.
    nonisolated static func canExtract(_ format: ArchiveFormat) -> Bool {
        format == .zip
    }
}
