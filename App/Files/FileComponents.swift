import BrowserCore
import CoreTransferable
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// Quick Look thumbnails, cached by file, size and modification date.
final class Thumbnails {
    static let shared = Thumbnails()
    private let cache = NSCache<NSString, UIImage>()

    func image(for item: FileItem, size: CGFloat, scale: CGFloat) async -> UIImage? {
        guard !item.isDirectory else { return nil }
        return await image(for: item.url, size: size, scale: scale, modified: item.modified)
    }

    func image(for url: URL, size: CGFloat, scale: CGFloat, modified: Date? = nil) async -> UIImage? {
        let stamp = modified
            ?? (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? .distantPast
        let key = "\(url.path)|\(stamp.timeIntervalSince1970)|\(Int(size))" as NSString
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let request = QLThumbnailGenerator.Request(
            fileAt: url, size: CGSize(width: size, height: size), scale: scale, representationTypes: .thumbnail)
        guard let representation = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request) else {
            return nil
        }
        let image = representation.uiImage
        cache.setObject(image, forKey: key)
        return image
    }
}

/// A file's thumbnail, or its type's symbol until (or unless) one is available.
struct FileThumbnail: View {
    let item: FileItem
    let size: CGFloat
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: size * 0.18, style: .continuous)
                    .fill(Color(uiColor: .secondarySystemFill))
                Image(systemName: item.symbolName)
                    .font(.system(size: size * 0.42))
                    .foregroundStyle(item.isDirectory ? Color.accentColor : Color.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.18, style: .continuous))
        .task(id: "\(item.url.path)|\(item.modified.timeIntervalSince1970)") {
            image = await Thumbnails.shared.image(for: item, size: size, scale: displayScale)
        }
    }
}

/// A row in the list layout.
struct FileRow: View {
    let item: FileItem
    var showsLocation: String?

    var body: some View {
        HStack(spacing: 14) {
            FileThumbnail(item: item, size: 40)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.name)
                    .lineLimit(2)
                    .truncationMode(.middle)
                Text(showsLocation.map { "\($0) · \(item.detail)" } ?? item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("file-\(item.name)")
    }
}

/// A tile in the grid layout.
struct FileTile: View {
    let item: FileItem
    var isSelected = false

    var body: some View {
        VStack(spacing: 8) {
            FileThumbnail(item: item, size: 96)
                .overlay(alignment: .bottomTrailing) {
                    if isSelected {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.accentColor)
                            .padding(4)
                    }
                }
            Text(item.name)
                .font(.caption)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .truncationMode(.middle)
            Text(item.detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity)
        .padding(6)
        .background(isSelected ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("file-\(item.name)")
    }
}

/// A photo or video picked from the photo library, copied to a temporary file.
nonisolated struct PickedMedia: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .movie) { received in try copy(received.file) }
        FileRepresentation(importedContentType: .image) { received in try copy(received.file) }
    }

    private static func copy(_ file: URL) throws -> PickedMedia {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appendingPathComponent(file.lastPathComponent)
        try FileManager.default.copyItem(at: file, to: destination)
        return PickedMedia(url: destination)
    }
}
