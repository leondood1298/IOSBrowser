import Foundation

/// Where a download is in its life.
public enum DownloadState: String, Codable, Sendable, CaseIterable {
    /// Waiting for a free slot: only a few downloads the browser starts itself run at once.
    case queued
    case running
    /// Stopped by the user, or interrupted with enough saved to continue later.
    case paused
    case finished
    case failed
    case cancelled

    /// Still to finish: shown in the Active section.
    public var isActive: Bool {
        self == .queued || self == .running || self == .paused
    }

    /// The moves the download manager allows, so a late callback can't revive a cancelled or
    /// finished download.
    public func canMove(to next: DownloadState) -> Bool {
        switch (self, next) {
        case (.queued, .running), (.queued, .paused), (.queued, .failed), (.queued, .cancelled):
            return true
        case (.running, .queued), (.running, .paused), (.running, .finished), (.running, .failed), (.running, .cancelled):
            return true
        case (.paused, .queued), (.paused, .failed), (.paused, .cancelled):
            return true
        case (.failed, .queued), (.cancelled, .queued):
            return true
        default:
            return false
        }
    }
}

/// One download in the list. Saved as JSON (except private ones), so the list survives relaunches.
public struct DownloadRecord: Codable, Sendable, Identifiable, Hashable {
    public var id: UUID
    /// The file's address; nil for files made by the page itself (blob: links).
    public var sourceURL: URL?
    /// The page the download started from, for "Open Source Page".
    public var pageURL: URL?
    public var fileName: String
    /// The folder under Documents the file goes to, e.g. "Downloads".
    public var folder: String
    public var mimeType: String?
    /// Nil while the size isn't known.
    public var expectedBytes: Int64?
    public var receivedBytes: Int64
    public var state: DownloadState
    /// Why it failed, in words for the user.
    public var failureReason: String?
    /// The link stopped working (it expired or is gone); the source page can give a fresh one.
    public var linkExpired: Bool
    public var isPrivate: Bool
    public var created: Date
    public var finished: Date?

    public init(
        id: UUID = UUID(), sourceURL: URL?, pageURL: URL?, fileName: String, folder: String,
        mimeType: String? = nil, expectedBytes: Int64? = nil, receivedBytes: Int64 = 0,
        state: DownloadState = .queued, failureReason: String? = nil, linkExpired: Bool = false,
        isPrivate: Bool = false, created: Date = Date(), finished: Date? = nil
    ) {
        self.id = id
        self.sourceURL = sourceURL
        self.pageURL = pageURL
        self.fileName = fileName
        self.folder = folder
        self.mimeType = mimeType
        self.expectedBytes = expectedBytes
        self.receivedBytes = receivedBytes
        self.state = state
        self.failureReason = failureReason
        self.linkExpired = linkExpired
        self.isPrivate = isPrivate
        self.created = created
        self.finished = finished
    }

    /// 0…1, or nil while the size isn't known.
    public var fractionCompleted: Double? {
        guard let expectedBytes, expectedBytes > 0 else { return nil }
        return min(1, Double(receivedBytes) / Double(expectedBytes))
    }

    /// Whether Retry can start it again from its address (pages' own blob: files can't be fetched again).
    public var canRetry: Bool {
        guard let scheme = sourceURL?.scheme?.lowercased() else { return false }
        return scheme == "http" || scheme == "https" || scheme == "data"
    }
}

/// Decides which downloads run.
public enum DownloadScheduler {
    /// The queued downloads to start now: oldest first, so that no more than `limit` run.
    public static func downloadsToStart(in records: [DownloadRecord], limit: Int) -> [UUID] {
        let running = records.filter { $0.state == .running }.count
        let slots = max(0, limit - running)
        guard slots > 0 else { return [] }
        return records
            .filter { $0.state == .queued }
            .sorted { $0.created < $1.created }
            .prefix(slots)
            .map(\.id)
    }

    /// After a relaunch nothing is downloading any more. Downloads that saved enough to continue
    /// become paused; running ones that didn't have failed (Retry starts them again); queued ones
    /// stay queued.
    public static func reconcileAfterLaunch(
        _ records: [DownloadRecord], canResume: (UUID) -> Bool
    ) -> [DownloadRecord] {
        records.map { record in
            var record = record
            switch record.state {
            case .running where canResume(record.id):
                record.state = .paused
            case .running:
                record.state = .failed
                record.failureReason = "The download was interrupted."
            default:
                break
            }
            return record
        }
    }
}

/// Download speed over the last few seconds, and the time left at that speed.
public struct TransferRate: Sendable {
    struct Sample: Sendable {
        var time: TimeInterval
        var bytes: Int64
    }

    public let window: TimeInterval
    private var samples: [Sample] = []

    public init(window: TimeInterval = 5) {
        self.window = window
    }

    /// Adds a reading of the total bytes received so far at `time` (seconds, any clock).
    public mutating func record(totalBytes: Int64, at time: TimeInterval) {
        if let last = samples.last, totalBytes < last.bytes {
            samples.removeAll()
        }
        samples.append(Sample(time: time, bytes: totalBytes))
        // Keep one reading at or before the start of the window as the baseline.
        while samples.count > 2, samples[1].time <= time - window {
            samples.removeFirst()
        }
    }

    public mutating func reset() {
        samples.removeAll()
    }

    /// Bytes per second, once readings cover at least a second.
    public var bytesPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= 1 else { return nil }
        return Double(last.bytes - first.bytes) / (last.time - first.time)
    }

    public func secondsRemaining(expectedBytes: Int64?) -> TimeInterval? {
        guard let expectedBytes, let last = samples.last, let speed = bytesPerSecond, speed > 0 else { return nil }
        return Double(max(0, expectedBytes - last.bytes)) / speed
    }
}

/// Text for download rows.
public enum DownloadFormatting {
    public static func bytes(_ count: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: count, countStyle: .file)
    }

    /// "12.3 MB of 45.6 MB", or "12.3 MB" while the size isn't known.
    public static func progress(received: Int64, expected: Int64?) -> String {
        guard let expected, expected > 0 else { return bytes(received) }
        return "\(bytes(received)) of \(bytes(expected))"
    }

    /// "1.2 MB/s"
    public static func speed(_ bytesPerSecond: Double) -> String {
        bytes(Int64(bytesPerSecond.rounded())) + "/s"
    }

    /// "8 s left", "3 min left", "1 h left", "1 h 5 min left".
    public static func timeLeft(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.up))
        if total < 60 {
            return "\(max(total, 1)) s left"
        }
        let minutes = Int((Double(total) / 60).rounded(.up))
        if minutes < 60 {
            return "\(minutes) min left"
        }
        let hours = minutes / 60
        return minutes % 60 == 0 ? "\(hours) h left" : "\(hours) h \(minutes % 60) min left"
    }
}

/// The kind of file, used to sort downloads into folders.
public enum FileCategory: String, Sendable, CaseIterable {
    case video
    case audio
    case image
    case document
    case archive
    case other

    private static let extensions: [String: FileCategory] = {
        var map: [String: FileCategory] = [:]
        let groups: [(FileCategory, [String])] = [
            (.video, ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "ts", "3gp", "mpg", "mpeg", "ogv"]),
            (.audio, ["mp3", "m4a", "aac", "wav", "flac", "ogg", "oga", "opus", "aiff", "aif", "wma", "alac"]),
            (.image, ["jpg", "jpeg", "png", "gif", "heic", "heif", "webp", "avif", "bmp", "tif", "tiff", "svg", "ico"]),
            (.document, ["pdf", "txt", "rtf", "md", "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages",
                         "numbers", "key", "csv", "epub", "html", "htm", "json", "xml"]),
            (.archive, ["zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "dmg", "ipa", "apk"]),
        ]
        for (category, list) in groups {
            for ext in list {
                map[ext] = category
            }
        }
        return map
    }()

    public static func of(fileName: String, mimeType: String? = nil) -> FileCategory {
        let ext = (fileName as NSString).pathExtension.lowercased()
        if let category = extensions[ext] {
            return category
        }
        guard let mime = mimeType?.lowercased() else { return .other }
        if mime.hasPrefix("video/") { return .video }
        if mime.hasPrefix("audio/") { return .audio }
        if mime.hasPrefix("image/") { return .image }
        if mime == "application/pdf" || mime.hasPrefix("text/") { return .document }
        if ["zip", "rar", "7z", "compressed", "tar", "gzip"].contains(where: { mime.contains($0) }) { return .archive }
        return .other
    }

    /// Where files of this kind go when downloads are sorted by type.
    public var folderName: String {
        switch self {
        case .video: return "Videos"
        case .audio: return "Music"
        case .image: return "Pictures"
        case .document: return "Documents"
        case .archive, .other: return "Downloads"
        }
    }
}

/// The contents of a `data:` URL (RFC 2397), for links that carry the file itself.
public struct DataURL: Sendable, Equatable {
    public var data: Data
    public var mimeType: String

    public init?(string: String) {
        guard string.count > 5, string.prefix(5).lowercased() == "data:",
              let comma = string.firstIndex(of: ",")
        else { return nil }
        let header = string[string.index(string.startIndex, offsetBy: 5)..<comma]
        let payload = String(string[string.index(after: comma)...])
        var parameters = header.split(separator: ";", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        let isBase64 = parameters.last?.lowercased() == "base64"
        if isBase64 {
            parameters.removeLast()
        }
        let type = parameters.first.map { $0.lowercased() } ?? ""
        mimeType = type.isEmpty ? "text/plain" : type
        if isBase64 {
            let cleaned = (payload.removingPercentEncoding ?? payload).filter { !$0.isWhitespace }
            let padded = cleaned + String(repeating: "=", count: (4 - cleaned.count % 4) % 4)
            guard let decoded = Data(base64Encoded: padded) else { return nil }
            data = decoded
        } else {
            guard let text = payload.removingPercentEncoding else { return nil }
            data = Data(text.utf8)
        }
    }

    public init?(_ url: URL) {
        self.init(string: url.absoluteString)
    }

    private static let extensions: [String: String] = [
        "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif", "image/webp": "webp",
        "image/svg+xml": "svg", "image/avif": "avif", "image/heic": "heic", "text/plain": "txt",
        "text/html": "html", "text/csv": "csv", "application/json": "json", "application/pdf": "pdf",
        "application/zip": "zip", "audio/mpeg": "mp3", "audio/wav": "wav", "video/mp4": "mp4",
    ]

    /// "download.png" and so on; "download" when the type is unknown.
    public var suggestedFileName: String {
        Self.extensions[mimeType].map { "download.\($0)" } ?? "download"
    }
}

/// Byte ranges for fetching one file in several parts at once.
public enum RangePlanner {
    /// Splits `0..<totalBytes` into at most `parts` back-to-back ranges, none smaller than
    /// `minimumPartSize` (except a lone range for a small file).
    public static func ranges(totalBytes: Int64, parts: Int, minimumPartSize: Int64 = 1 << 20) -> [ClosedRange<Int64>] {
        guard totalBytes > 0 else { return [] }
        let byMinimum = max(1, Int(totalBytes / max(minimumPartSize, 1)))
        let count = max(1, min(parts, byMinimum))
        let size = totalBytes / Int64(count)
        return (0..<count).map { index in
            let start = Int64(index) * size
            let end = index == count - 1 ? totalBytes - 1 : start + size - 1
            return start...end
        }
    }

    /// The Range header value for a part, e.g. "bytes=0-1048575".
    public static func header(for range: ClosedRange<Int64>) -> String {
        "bytes=\(range.lowerBound)-\(range.upperBound)"
    }
}
