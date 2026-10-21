import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Decodes images for the viewer at screen size (ImageIO downsampling), off the main thread,
/// and keeps the pages around the current one ready so switching is instant.
final class ImageLoader {
    private let cache = NSCache<NSURL, UIImage>()
    private var inFlight: Set<URL> = []
    /// Longest side in pixels images are decoded at.
    private let maxPixelSize: CGFloat

    init(maxPixelSize: CGFloat) {
        self.maxPixelSize = maxPixelSize
        cache.countLimit = 12
    }

    /// The decoded image if it's ready.
    func cached(_ url: URL) -> UIImage? {
        cache.object(forKey: url as NSURL)
    }

    /// Decodes (or returns the cached) image.
    func image(for url: URL) async -> UIImage? {
        if let cached = cached(url) {
            return cached
        }
        let size = maxPixelSize
        let image = await Task.detached(priority: .userInitiated) {
            Self.decode(url, maxPixelSize: size)
        }.value
        if let image {
            cache.setObject(image, forKey: url as NSURL)
        }
        return image
    }

    /// Starts decoding the neighbours of `index` so they're ready when the reader moves on.
    func preload(around index: Int, in urls: [URL], radius: Int = 2) {
        let wanted = (index - radius...index + radius).filter { urls.indices.contains($0) && $0 != index }.map { urls[$0] }
        for url in wanted where cached(url) == nil && !inFlight.contains(url) {
            inFlight.insert(url)
            Task {
                _ = await image(for: url)
                inFlight.remove(url)
            }
        }
    }

    /// A screen-sized image; animated GIFs become animated images (up to a sensible frame count).
    nonisolated static func decode(_ url: URL, maxPixelSize: CGFloat) -> UIImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        let count = CGImageSourceGetCount(source)
        if count > 1, count <= 300, let type = CGImageSourceGetType(source), UTType(type as String)?.conforms(to: .gif) == true {
            var frames: [UIImage] = []
            var duration: Double = 0
            for index in 0..<count {
                guard let frame = CGImageSourceCreateThumbnailAtIndex(source, index, options as CFDictionary) else { continue }
                frames.append(UIImage(cgImage: frame))
                duration += frameDuration(source, index)
            }
            return UIImage.animatedImage(with: frames, duration: max(duration, 0.1))
        }
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: image)
    }

    nonisolated private static func frameDuration(_ source: CGImageSource, _ index: Int) -> Double {
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
              let gif = properties[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        else { return 0.1 }
        let delay = (gif[kCGImagePropertyGIFUnclampedDelayTime] as? Double) ?? (gif[kCGImagePropertyGIFDelayTime] as? Double) ?? 0.1
        return delay < 0.02 ? 0.1 : delay
    }

    /// Whether the viewer can show a file (ImageIO reads it).
    nonisolated static func canShow(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .pdf)
    }
}
