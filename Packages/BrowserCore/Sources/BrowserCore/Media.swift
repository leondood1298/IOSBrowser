import Foundation

/// Video or audio found on a page: a media element's source, or a media or playlist file the
/// page requested.
public struct DetectedMedia: Hashable, Sendable, Identifiable {
    public enum Kind: String, Sendable {
        /// A plain video file (MP4, WebM…).
        case video
        case audio
        /// An HLS playlist (.m3u8), saved as a video by the stream downloader.
        case hls
        /// A DASH manifest, or media streamed in pieces through Media Source (blob: addresses, as
        /// on YouTube): it plays on the page but can't be saved.
        case stream
    }

    public var url: URL
    public var kind: Kind
    /// The page's title when it was found, for naming the download.
    public var pageTitle: String
    public var width: Int?
    public var height: Int?
    /// Seconds, once the element knows.
    public var duration: Double?
    /// The element plays copy-protected (DRM) media.
    public var isProtected: Bool
    /// Found among the page's requests rather than as a media element's source.
    public var isFromRequest: Bool

    public var id: URL { url }

    public init(
        url: URL, kind: Kind, pageTitle: String = "", width: Int? = nil, height: Int? = nil,
        duration: Double? = nil, isProtected: Bool = false, isFromRequest: Bool = false
    ) {
        self.url = url
        self.kind = kind
        self.pageTitle = pageTitle
        self.width = width
        self.height = height
        self.duration = duration
        self.isProtected = isProtected
        self.isFromRequest = isFromRequest
    }

    public var isDownloadable: Bool {
        kind != .stream && !isProtected
    }

    /// "1080p", counted on the shorter side so portrait video reads the same; "4K" from 2160 up.
    public var qualityLabel: String? {
        guard let width, let height, width > 0, height > 0 else { return nil }
        let lines = min(width, height)
        return lines >= 2160 ? "4K" : "\(lines)p"
    }

    /// A file name for saving it: the address's own name, or the page title with a fitting extension.
    public var suggestedFileName: String {
        let last = url.lastPathComponent
        let ext = (last as NSString).pathExtension.lowercased()
        if !ext.isEmpty, ext != "m3u8", ext != "mpd", last.count > ext.count + 1 {
            return FileNaming.sanitize(last.removingPercentEncoding ?? last)
        }
        let base = pageTitle.isEmpty ? (url.host ?? "video") : pageTitle
        let fallback = kind == .audio ? "m4a" : "mp4"
        return FileNaming.sanitize(base, fallback: "video") + ".\(fallback)"
    }

    private static let videoExtensions: Set<String> = [
        "mp4", "m4v", "mov", "webm", "mkv", "avi", "flv", "3gp", "ts", "wmv", "ogv",
    ]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "ogg", "oga", "opus", "flac"]

    /// What an address points to, judging by its scheme, extension and declared type; nil when it
    /// isn't media. An element's source without a telling extension is the element's kind.
    public static func kind(of url: URL, elementKind: Kind? = nil, mimeType: String? = nil) -> Kind? {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "blob" || scheme == "mediasource" {
            return .stream
        }
        guard scheme == "http" || scheme == "https" else { return nil }
        let ext = url.pathExtension.lowercased()
        let mime = mimeType?.lowercased() ?? ""
        if ext == "m3u8" || mime.contains("mpegurl") { return .hls }
        if ext == "mpd" || mime.contains("dash+xml") { return .stream }
        if videoExtensions.contains(ext) || mime.hasPrefix("video/") { return .video }
        if audioExtensions.contains(ext) || mime.hasPrefix("audio/") { return .audio }
        return elementKind
    }

    /// Adds `new` to the list, or fills in what an earlier report of the same address lacked: the
    /// picture size arrives once the video's metadata loads, protection once it asks for keys.
    public static func merge(_ existing: [DetectedMedia], adding new: DetectedMedia) -> [DetectedMedia] {
        guard let index = existing.firstIndex(where: { $0.url == new.url }) else {
            return existing + [new]
        }
        var list = existing
        list[index].width = new.width ?? list[index].width
        list[index].height = new.height ?? list[index].height
        list[index].duration = new.duration ?? list[index].duration
        list[index].isProtected = list[index].isProtected || new.isProtected
        list[index].isFromRequest = list[index].isFromRequest && new.isFromRequest
        return list
    }

    /// An HLS player fetches a master playlist and then the playlist of the quality it plays, so
    /// the stream is listed once: the playlists media elements play, or else the first one fetched.
    public static func collapsingPlaylists(_ list: [DetectedMedia]) -> [DetectedMedia] {
        let playlists = list.filter { $0.kind == .hls }
        guard playlists.count > 1 else { return list }
        let first = playlists.first { !$0.isFromRequest } ?? playlists[0]
        return list.filter { $0.kind != .hls || $0.url == first.url || !$0.isFromRequest }
    }

    /// The order for listing: videos, then streams that can be saved (HLS), then audio, then
    /// what can't be saved. Otherwise in the order found.
    public static func sortedForDisplay(_ list: [DetectedMedia]) -> [DetectedMedia] {
        func rank(_ media: DetectedMedia) -> Int {
            guard media.isDownloadable else { return 3 }
            switch media.kind {
            case .video: return 0
            case .hls: return 1
            case .audio: return 2
            case .stream: return 3
            }
        }
        return list.enumerated()
            .sorted { rank($0.element) != rank($1.element) ? rank($0.element) < rank($1.element) : $0.offset < $1.offset }
            .map(\.element)
    }
}

/// Which cookies go with a request, for fetching a page's media outside WebKit with that page's
/// cookies (RFC 6265 domain and path matching).
public enum CookieRules {
    public static func applies(
        domain: String, path: String, isSecure: Bool, expires: Date?, to url: URL, now: Date = Date()
    ) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        var cookieDomain = domain.lowercased()
        if cookieDomain.hasPrefix(".") {
            cookieDomain.removeFirst()
        }
        guard !cookieDomain.isEmpty, host == cookieDomain || host.hasSuffix("." + cookieDomain) else { return false }
        if isSecure, url.scheme?.lowercased() != "https" {
            return false
        }
        if let expires, expires < now {
            return false
        }
        let requestPath = url.path.isEmpty ? "/" : url.path
        guard !path.isEmpty, path != "/" else { return true }
        // "/docs" matches "/docs" and "/docs/…" but not "/docsearch".
        return requestPath == path || requestPath.hasPrefix(path.hasSuffix("/") ? path : path + "/")
    }
}

public enum MediaFormatting {
    /// "3:07", or "1:02:03" from an hour up.
    public static func duration(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        let rest = total % 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, rest)
            : String(format: "%d:%02d", minutes, rest)
    }
}
