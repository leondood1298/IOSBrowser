import BrowserCore
import Foundation
import SWCompression
import Unrar

/// Opening RAR (the unrar library) and 7-Zip, TAR, GZip, BZip2 and XZ (SWCompression).
/// Entry paths are cleaned so nothing lands outside the destination folder.
enum ArchiveExtractors {
    /// RAR4 and RAR5, written to disk as they're unpacked, so big files don't fill memory.
    nonisolated static func extractRAR(
        _ url: URL, to folder: URL, password: String?, progress report: @escaping @Sendable (Double) -> Void
    ) throws {
        let archive: Unrar.Archive
        let entries: [Unrar.Entry]
        do {
            archive = try Unrar.Archive(fileURL: url, password: password)
            entries = try archive.entries()
        } catch UnrarError.missingPassword {
            throw ArchiveService.Failure.needsPassword
        }
        if password == nil && (archive.isHeaderEncrypted || entries.contains(where: \.encrypted)) {
            throw ArchiveService.Failure.needsPassword
        }
        let total = max(entries.reduce(UInt64(0)) { $0 + $1.uncompressedSize }, 1)
        var done: UInt64 = 0
        for entry in entries {
            guard let path = ArchivePaths.safeRelativePath(entry.fileName) else { continue }
            let destination = folder.appendingPathComponent(path)
            if entry.directory {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                continue
            }
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: destination.path, contents: nil)
            let handle = try FileHandle(forWritingTo: destination)
            var writeError: Error?
            do {
                try archive.extract(entry) { data, _ in
                    guard writeError == nil else { return }
                    do {
                        try handle.write(contentsOf: data)
                    } catch {
                        writeError = error
                    }
                    done += UInt64(data.count)
                    report(Double(done) / Double(total))
                }
            } catch UnrarError.missingPassword {
                try? handle.close()
                throw ArchiveService.Failure.needsPassword
            } catch UnrarError.badData where entry.encrypted {
                try? handle.close()
                throw ArchiveService.Failure.wrongPassword
            }
            try handle.close()
            if let writeError {
                throw writeError
            }
        }
    }

    /// 7-Zip, TAR, and single files compressed with GZip, BZip2 or XZ (a compressed TAR is
    /// unpacked too). These libraries work in memory, so very large archives may not open.
    nonisolated static func extractWithSWCompression(
        _ url: URL, format: ArchiveFormat, to folder: URL, progress report: @escaping @Sendable (Double) -> Void
    ) throws {
        let input = try Data(contentsOf: url, options: .alwaysMapped)
        switch format {
        case .sevenZip:
            do {
                try write(try SevenZipContainer.open(container: input), to: folder, progress: report)
            } catch SevenZipError.encryptionNotSupported {
                throw ArchiveService.Failure.encryptedNotSupported(format.title)
            }
        case .tar:
            try write(try TarContainer.open(container: input), to: folder, progress: report)
        case .gzip, .bzip2, .xz:
            let output: Data
            switch format {
            case .gzip: output = try GzipArchive.unarchive(archive: input)
            case .bzip2: output = try BZip2.decompress(data: input)
            default: output = try XZArchive.unarchive(archive: input)
            }
            report(0.5)
            if ArchiveFormat.detect(fileName: "", header: output.prefix(262)) == .tar {
                try write(try TarContainer.open(container: output), to: folder, progress: report)
            } else {
                let name = ArchivePaths.decompressedName(for: url.lastPathComponent)
                try output.write(to: folder.appendingPathComponent(FileNaming.sanitize(name)), options: .atomic)
            }
        case .zip, .rar:
            break
        }
        report(1)
    }

    nonisolated private static func write<Entry: ContainerEntry>(
        _ entries: [Entry], to folder: URL, progress report: @Sendable (Double) -> Void
    ) throws {
        for (index, entry) in entries.enumerated() {
            guard let path = ArchivePaths.safeRelativePath(entry.info.name) else { continue }
            let destination = folder.appendingPathComponent(path)
            switch entry.info.type {
            case .directory:
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            case .regular:
                try FileManager.default.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try (entry.data ?? Data()).write(to: destination, options: .atomic)
            default:
                // Links and special files are skipped.
                break
            }
            report(Double(index + 1) / Double(max(entries.count, 1)))
        }
    }
}
