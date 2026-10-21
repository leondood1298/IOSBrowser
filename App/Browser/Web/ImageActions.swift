import BrowserCore
import Photos
import UIKit
import UniformTypeIdentifiers
import WebKit

/// Fetches images the user long-pressed and saves, copies or shares them. Requests carry the
/// tab's cookies, user agent and page as referrer, so images behind a login still load.
enum ImageActions {
    enum Failure: LocalizedError {
        case notAnImage
        case photosAccessDenied

        var errorDescription: String? {
            switch self {
            case .notAnImage: return "That doesn't look like an image."
            case .photosAccessDenied: return "Allow Browser to add photos in Settings › Privacy › Photos."
            }
        }
    }

    static func fetch(_ url: URL, for tab: TabModel) async throws -> (data: Data, type: UTType?, filename: String) {
        if url.scheme == "data", let decoded = decodeDataURL(url) {
            return decoded
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let page = tab.url {
            request.setValue(page.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let webView = tab.webView {
            let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
            let matching = cookies.filter { cookie in
                guard let host = url.host else { return false }
                let domain = cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
                return host == domain || host.hasSuffix("." + domain)
            }
            for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
                request.setValue(value, forHTTPHeaderField: field)
            }
            var agent = webView.customUserAgent
            if agent?.isEmpty ?? true {
                let result = try? await webView.callAsyncJavaScript(
                    "return navigator.userAgent;", arguments: [:], in: nil, contentWorld: UserScripts.world)
                agent = result as? String
            }
            if let agent, !agent.isEmpty {
                request.setValue(agent, forHTTPHeaderField: "User-Agent")
            }
        }
        let session = URLSession(configuration: .ephemeral)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        let type = response.mimeType.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: url.pathExtension)
        guard type?.conforms(to: .image) == true || UIImage(data: data) != nil else { throw Failure.notAnImage }
        let name = response.suggestedFilename ?? url.lastPathComponent
        return (data, type, FileNaming.sanitize(name, fallback: "image"))
    }

    static func saveToPhotos(_ data: Data) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw Failure.photosAccessDenied }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
        }
    }

    static func copy(_ data: Data, type: UTType?) {
        if let type, type != .image {
            UIPasteboard.general.setData(data, forPasteboardType: type.identifier)
        } else if let image = UIImage(data: data) {
            UIPasteboard.general.image = image
        }
    }

    /// Writes the image to Documents/Downloads and returns where it went.
    static func saveToDownloads(_ data: Data, filename: String, type: UTType?) throws -> URL {
        var name = filename
        if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let folder = AppFolders.documentsDirectory.appendingPathComponent("Downloads", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = FileNaming.uniqueURL(in: folder, for: name)
        try data.write(to: destination, options: .atomic)
        return destination
    }

    /// A temporary file for sharing, named like the original.
    static func temporaryFile(_ data: Data, filename: String, type: UTType?) throws -> URL {
        var name = filename
        if (name as NSString).pathExtension.isEmpty, let ext = type?.preferredFilenameExtension {
            name += ".\(ext)"
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        return url
    }

    private static func decodeDataURL(_ url: URL) -> (data: Data, type: UTType?, filename: String)? {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: 5)..<comma]
        let payload = String(text[text.index(after: comma)...])
        let mime = header.split(separator: ";").first.map(String.init)
        let data = header.hasSuffix(";base64")
            ? Data(base64Encoded: payload.removingPercentEncoding ?? payload)
            : (payload.removingPercentEncoding ?? payload).data(using: .utf8)
        guard let data else { return nil }
        return (data, mime.flatMap { UTType(mimeType: $0) }, "image")
    }
}
