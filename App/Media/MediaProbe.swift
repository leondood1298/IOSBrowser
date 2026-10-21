import AVFoundation
import BrowserCore
import Foundation
import WebKit

/// The cookies and user agent a tab's requests carry, for fetching or playing its media outside
/// WebKit as the page would.
struct MediaRequestContext {
    var cookies: [HTTPCookie]
    var userAgent: String?

    static func of(_ webView: WKWebView) async -> MediaRequestContext {
        let cookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        var userAgent = webView.customUserAgent
        if userAgent?.isEmpty ?? true {
            userAgent = try? await webView.callAsyncJavaScript(
                "return navigator.userAgent;", arguments: [:], in: nil, contentWorld: .defaultClient) as? String
        }
        return MediaRequestContext(cookies: cookies, userAgent: userAgent)
    }

    func cookies(for url: URL) -> [HTTPCookie] {
        cookies.filter {
            CookieRules.applies(domain: $0.domain, path: $0.path, isSecure: $0.isSecure, expires: $0.expiresDate, to: url)
        }
    }

    /// Options for an AVURLAsset that plays `url` with the page's cookies and user agent.
    func assetOptions(for url: URL) -> [String: Any] {
        var options: [String: Any] = [AVURLAssetHTTPCookiesKey: cookies(for: url)]
        if let userAgent {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
        }
        return options
    }
}

/// File sizes for the media picker, looked up as it opens.
final class MediaSizes: ObservableObject {
    @Published private(set) var bytes: [URL: Int64] = [:]
    private var started: Set<URL> = []

    func lookUp(_ media: [DetectedMedia], context: MediaRequestContext, referer: URL?) {
        for item in media where item.isDownloadable && item.kind != .hls && !started.contains(item.url) {
            started.insert(item.url)
            let url = item.url
            let cookies = context.cookies(for: url)
            let userAgent = context.userAgent
            Task { [weak self] in
                guard let size = await MediaProbe.size(of: url, cookies: cookies, userAgent: userAgent, referer: referer)
                else { return }
                self?.bytes[url] = size
            }
        }
    }
}

/// Asks a server how big a file is: a HEAD request, or a one-byte ranged GET when HEAD isn't
/// answered. Only the response headers are read.
nonisolated enum MediaProbe {
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    static func size(of url: URL, cookies: [HTTPCookie], userAgent: String?, referer: URL?) async -> Int64? {
        var request = URLRequest(url: url)
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let referer, ["http", "https"].contains(referer.scheme?.lowercased() ?? "") {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        request.httpMethod = "HEAD"
        if let response = await headers(for: request), (200..<300).contains(response.statusCode),
           response.expectedContentLength > 0 {
            return response.expectedContentLength
        }
        request.httpMethod = "GET"
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let response = await headers(for: request) else { return nil }
        if response.statusCode == 206, let range = response.value(forHTTPHeaderField: "Content-Range"),
           let total = range.split(separator: "/").last.flatMap({ Int64($0) }) {
            return total
        }
        return response.statusCode == 200 && response.expectedContentLength > 0 ? response.expectedContentLength : nil
    }

    /// Starts the request and stops it as soon as the headers arrive.
    private static func headers(for request: URLRequest) async -> HTTPURLResponse? {
        guard let (bytes, response) = try? await session.bytes(for: request) else { return nil }
        bytes.task.cancel()
        return response as? HTTPURLResponse
    }
}
