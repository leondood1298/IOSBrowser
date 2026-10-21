import BrowserCore
import Combine
import UIKit

/// Site icons for tabs, shortcuts and lists, cached by host. Icons seen in private tabs are
/// kept in memory only.
final class FaviconStore: ObservableObject {
    /// Changes whenever a new icon arrives, so views can refresh.
    @Published private(set) var revision = 0

    private var memory: [String: UIImage] = [:]
    private var inFlight: Set<String> = []
    private let directory: URL

    init() {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        directory = caches.appendingPathComponent("Favicons", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    func icon(for url: URL?) -> UIImage? {
        guard let key = SiteSettingsIndex.key(for: url) else { return nil }
        if let image = memory[key] {
            return image
        }
        if let data = try? Data(contentsOf: file(for: key)), let image = UIImage(data: data) {
            memory[key] = image
            return image
        }
        return nil
    }

    /// Downloads the best icon among `candidates` (falling back to /favicon.ico) unless one is cached.
    func fetchIcon(for pageURL: URL, candidates: [URL], isPrivate: Bool) {
        guard let key = SiteSettingsIndex.key(for: pageURL), icon(for: pageURL) == nil, !inFlight.contains(key) else {
            return
        }
        inFlight.insert(key)
        var urls = candidates
        if let fallback = URL(string: "/favicon.ico", relativeTo: pageURL)?.absoluteURL {
            urls.append(fallback)
        }
        let target = file(for: key)
        Task {
            let image = await Self.download(urls, isPrivate: isPrivate)
            inFlight.remove(key)
            guard let image else { return }
            memory[key] = image
            if !isPrivate, let data = image.pngData() {
                try? data.write(to: target, options: .atomic)
            }
            revision += 1
        }
    }

    func removeAll() {
        memory.removeAll()
        try? FileManager.default.removeItem(at: directory)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        revision += 1
    }

    private func file(for key: String) -> URL {
        directory.appendingPathComponent(key.replacingOccurrences(of: "/", with: "_") + ".png")
    }

    nonisolated private static func download(_ urls: [URL], isPrivate: Bool) async -> UIImage? {
        let configuration = isPrivate ? URLSessionConfiguration.ephemeral : URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        for url in urls {
            guard let result = try? await session.data(from: url) else { continue }
            let status = (result.1 as? HTTPURLResponse)?.statusCode ?? 200
            guard status < 400, let image = UIImage(data: result.0), image.size.width >= 16 else { continue }
            return await image.byPreparingThumbnail(ofSize: CGSize(width: 64, height: 64)) ?? image
        }
        return nil
    }
}
