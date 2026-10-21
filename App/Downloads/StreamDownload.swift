import AVFoundation
import BrowserCore
import Foundation
import MediaKit

/// The headers a tab's requests carry (cookies, user agent, the page), for fetching its stream
/// outside WebKit.
nonisolated struct StreamRequest: @unchecked Sendable {
    var cookies: [HTTPCookie]
    var userAgent: String?
    var referer: URL?

    func urlRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        let matching = cookies.filter {
            CookieRules.applies(domain: $0.domain, path: $0.path, isSecure: $0.isSecure, expires: $0.expiresDate, to: url)
        }
        for (field, value) in HTTPCookie.requestHeaderFields(with: matching) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        if let referer, ["http", "https"].contains(referer.scheme?.lowercased() ?? "") {
            request.setValue(referer.absoluteString, forHTTPHeaderField: "Referer")
        }
        return request
    }
}

nonisolated enum StreamError: LocalizedError, Equatable {
    case http(Int)
    case notAPlaylist
    case live
    case protected
    case badKey
    case processing(String)

    var errorDescription: String? {
        switch self {
        case .http(let status) where [401, 403, 404, 410].contains(status):
            return "The stream's link stopped working (HTTP \(status)). Open the page again for a fresh one."
        case .http(let status):
            return "The server answered with an error (HTTP \(status))."
        case .notAPlaylist:
            return "This address isn't a stream the browser can read."
        case .live:
            return "This is a live stream, so it can't be saved."
        case .protected:
            return "This stream is copy-protected (DRM), so it can't be saved."
        case .badKey:
            return "The stream's decryption key couldn't be read."
        case .processing(let message):
            return "The video couldn't be put together: \(message)"
        }
    }

    var linkExpired: Bool {
        if case .http(let status) = self {
            return [401, 403, 404, 410].contains(status)
        }
        return false
    }
}

/// Fetches playlists, segments and keys for stream downloads.
nonisolated enum StreamFetcher {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpMaximumConnectionsPerHost = 6
        configuration.timeoutIntervalForRequest = 30
        return URLSession(configuration: configuration)
    }()

    /// The resource's bytes, trying three times; expired links and missing files fail at once.
    static func data(_ url: URL, range: HLSByteRange? = nil, request: StreamRequest) async throws -> Data {
        var lastError: Error = StreamError.http(0)
        for attempt in 0..<3 {
            if attempt > 0 {
                try await Task.sleep(for: .seconds(Double(attempt)))
            }
            var urlRequest = request.urlRequest(for: url)
            if let range {
                urlRequest.setValue(range.rangeHeader, forHTTPHeaderField: "Range")
            }
            do {
                let (data, response) = try await session.data(for: urlRequest)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 200
                switch status {
                case 206:
                    return data
                case 200..<300:
                    // A server that ignores Range sends the whole resource.
                    if let range, data.count >= Int(range.offset + range.length) {
                        return data.subdata(in: Int(range.offset)..<Int(range.offset + range.length))
                    }
                    return data
                case 401, 403, 404, 410:
                    throw StreamError.http(status)
                default:
                    lastError = StreamError.http(status)
                }
            } catch let error as StreamError {
                throw error
            } catch {
                if Task.isCancelled || error is CancellationError {
                    throw CancellationError()
                }
                lastError = error
            }
        }
        throw lastError
    }

    static func playlist(_ url: URL, request: StreamRequest) async throws -> (HLSPlaylist, String) {
        let data = try await data(url, request: request)
        guard let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else {
            throw StreamError.notAPlaylist
        }
        do {
            return (try M3U8Parser.parse(text, baseURL: url), text)
        } catch {
            throw StreamError.notAPlaylist
        }
    }
}

/// What a stream download saves: the chosen quality's playlist and its separate audio, as text,
/// so a paused or interrupted download can continue without the page.
nonisolated struct StreamJob: Codable, Sendable {
    var videoURL: URL
    var videoText: String
    var audioURL: URL?
    var audioText: String?
    var quality: String?

    func playlists() throws -> (video: HLSMediaPlaylist, audio: HLSMediaPlaylist?) {
        guard case .media(let video) = try M3U8Parser.parse(videoText, baseURL: videoURL) else {
            throw StreamError.notAPlaylist
        }
        var audio: HLSMediaPlaylist?
        if let audioURL, let audioText, case .media(let playlist) = try M3U8Parser.parse(audioText, baseURL: audioURL) {
            audio = playlist
        }
        return (video, audio)
    }

    var segmentCount: Int {
        let lists = (try? playlists()).map { [$0.video] + ($0.audio.map { [$0] } ?? []) } ?? []
        return lists.reduce(0) { $0 + $1.segments.count + ($1.segments.first?.map != nil ? 1 : 0) }
    }

    /// Fetches the playlist at `url`; for a master playlist, `chooseQuality` picks the variant
    /// (nil cancels). Fails for live and copy-protected streams.
    static func make(
        for url: URL, request: StreamRequest, chooseQuality: ([HLSVariant]) async -> HLSVariant?
    ) async throws -> StreamJob? {
        let (playlist, text) = try await StreamFetcher.playlist(url, request: request)
        var job: StreamJob
        switch playlist {
        case .media:
            job = StreamJob(videoURL: url, videoText: text)
        case .master(let master):
            let qualities = master.qualities
            guard !qualities.isEmpty else { throw StreamError.notAPlaylist }
            let chosen: HLSVariant?
            if qualities.count == 1 {
                chosen = qualities[0]
            } else {
                chosen = await chooseQuality(qualities)
            }
            guard let variant = chosen else { return nil }
            let (variantPlaylist, variantText) = try await StreamFetcher.playlist(variant.url, request: request)
            guard case .media = variantPlaylist else { throw StreamError.notAPlaylist }
            job = StreamJob(videoURL: variant.url, videoText: variantText, quality: variant.qualityLabel)
            if let rendition = master.audioRendition(for: variant), let audioURL = rendition.url {
                let (audioPlaylist, audioText) = try await StreamFetcher.playlist(audioURL, request: request)
                if case .media = audioPlaylist {
                    job.audioURL = audioURL
                    job.audioText = audioText
                }
            }
        }
        let lists = try job.playlists()
        for list in [lists.video] + (lists.audio.map { [$0] } ?? []) {
            guard list.isComplete else { throw StreamError.live }
            guard !list.hasUnsupportedEncryption else { throw StreamError.protected }
        }
        return job
    }
}

/// Downloads a stream's segments into a folder, several at a time (decrypting AES-128), then
/// joins them into one MP4 ("Processing"). Segments already in the folder are skipped, so a
/// paused or interrupted download continues where it stopped.
nonisolated final class StreamDownload: @unchecked Sendable {
    nonisolated struct Progress: Sendable {
        var completed: Int
        var total: Int
        var bytes: Int64
        var isProcessing: Bool
    }

    nonisolated private struct Piece: Sendable {
        var url: URL
        var range: HLSByteRange?
        var key: HLSKey?
        var sequence: Int
        var file: URL
    }

    let folder: URL
    private let video: HLSMediaPlaylist
    private let audio: HLSMediaPlaylist?
    private let request: StreamRequest
    private let keys = Locked<[URL: Data]>([:])
    private static let parallelSegments = 4

    init(folder: URL, job: StreamJob, request: StreamRequest) throws {
        let lists = try job.playlists()
        self.folder = folder
        video = lists.video
        audio = lists.audio
        self.request = request
    }

    /// Downloads what's missing, then writes the joined video to `output`.
    func run(to output: URL, progress: @escaping @Sendable (Progress) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let pieces = pieces(of: video, prefix: "v") + (audio.map { pieces(of: $0, prefix: "a") } ?? [])
        var done = 0
        var bytes: Int64 = 0
        var missing: [Piece] = []
        for piece in pieces {
            if let size = (try? piece.file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size > 0 {
                done += 1
                bytes += Int64(size)
            } else {
                missing.append(piece)
            }
        }
        progress(Progress(completed: done, total: pieces.count, bytes: bytes, isProcessing: false))

        try await withThrowingTaskGroup(of: Int64.self) { group in
            var queue = missing.makeIterator()
            for _ in 0..<Self.parallelSegments {
                guard let piece = queue.next() else { break }
                group.addTask { try await self.fetch(piece) }
            }
            while let size = try await group.next() {
                done += 1
                bytes += size
                progress(Progress(completed: done, total: pieces.count, bytes: bytes, isProcessing: false))
                if let piece = queue.next() {
                    group.addTask { try await self.fetch(piece) }
                }
            }
        }
        try Task.checkCancellation()

        progress(Progress(completed: done, total: pieces.count, bytes: bytes, isProcessing: true))
        do {
            try await assemble(to: output)
        } catch let error as StreamError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw StreamError.processing(error.localizedDescription)
        }
    }

    /// The init section (for fragmented MP4) and every segment of a playlist, with their files.
    private func pieces(of playlist: HLSMediaPlaylist, prefix: String) -> [Piece] {
        var pieces: [Piece] = []
        if let map = playlist.segments.first?.map {
            pieces.append(Piece(url: map.url, range: map.byteRange, key: nil, sequence: 0, file: file(prefix, "init")))
        }
        for (index, segment) in playlist.segments.enumerated() {
            pieces.append(Piece(
                url: segment.url, range: segment.byteRange, key: segment.key, sequence: segment.sequence,
                file: file(prefix, String(index))))
        }
        return pieces
    }

    private func file(_ prefix: String, _ name: String) -> URL {
        folder.appendingPathComponent("\(prefix)-\(name).seg")
    }

    private func fetch(_ piece: Piece) async throws -> Int64 {
        var data = try await StreamFetcher.data(piece.url, range: piece.range, request: request)
        if let key = piece.key, key.method == .aes128, let keyURL = key.url {
            let keyData = try await self.key(at: keyURL)
            do {
                data = try SegmentDecryptor.decrypt(data, key: keyData, iv: key.initializationVector(forSequence: piece.sequence))
            } catch {
                throw StreamError.badKey
            }
        }
        try data.write(to: piece.file, options: .atomic)
        return Int64(data.count)
    }

    private func key(at url: URL) async throws -> Data {
        if let cached = keys.mutate({ $0[url] }) {
            return cached
        }
        let data = try await StreamFetcher.data(url, request: request)
        guard data.count == 16 else { throw StreamError.badKey }
        keys.mutate { $0[url] = data }
        return data
    }

    // MARK: Processing

    private func assemble(to output: URL) async throws {
        let videoFile = try await join(video, prefix: "v", fileType: .mp4, extension: "mp4")
        if let audio {
            let audioFile = try await join(audio, prefix: "a", fileType: .m4a, extension: "m4a")
            try await Self.merge(video: videoFile, audio: audioFile, to: output)
        } else if video.usesFragmentedMP4 {
            // Rewrite the fragmented file as a plain MP4; the fragmented one plays too, if that fails.
            do {
                try await Self.export(AVURLAsset(url: videoFile), to: output)
            } catch {
                try? FileManager.default.removeItem(at: output)
                try FileManager.default.moveItem(at: videoFile, to: output)
            }
        } else {
            try? FileManager.default.removeItem(at: output)
            try FileManager.default.moveItem(at: videoFile, to: output)
        }
    }

    /// One file from a playlist's pieces: fragmented-MP4 segments are joined behind their init
    /// section; MPEG-TS and packed audio are rewritten as MP4 without re-encoding.
    private func join(_ playlist: HLSMediaPlaylist, prefix: String, fileType: AVFileType, extension ext: String) async throws -> URL {
        let joined = folder.appendingPathComponent("\(prefix)-joined.\(ext)")
        try? FileManager.default.removeItem(at: joined)
        if playlist.usesFragmentedMP4 {
            FileManager.default.createFile(atPath: joined.path, contents: nil)
            let handle = try FileHandle(forWritingTo: joined)
            defer { try? handle.close() }
            try handle.write(contentsOf: Data(contentsOf: file(prefix, "init")))
            for index in playlist.segments.indices {
                try handle.write(contentsOf: Data(contentsOf: file(prefix, String(index))))
            }
            return joined
        }
        let remuxer = TSRemuxer(outputURL: joined, fileType: fileType)
        for (index, segment) in playlist.segments.enumerated() {
            try Task.checkCancellation()
            let data = try Data(contentsOf: file(prefix, String(index)))
            try remuxer.append(segment: data, discontinuity: index > 0 && segment.discontinuity)
        }
        try await remuxer.finish()
        return joined
    }

    /// Puts the video and the separate audio in one file.
    static func merge(video: URL, audio: URL, to output: URL) async throws {
        let composition = AVMutableComposition()
        let videoAsset = AVURLAsset(url: video)
        let audioAsset = AVURLAsset(url: audio)
        for track in try await videoAsset.loadTracks(withMediaType: .video) {
            guard let target = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try target.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
            target.preferredTransform = try await track.load(.preferredTransform)
        }
        for track in try await audioAsset.loadTracks(withMediaType: .audio) {
            guard let target = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)
            else { continue }
            try target.insertTimeRange(try await track.load(.timeRange), of: track, at: .zero)
        }
        try await export(composition, to: output)
    }

    static func export(_ asset: AVAsset, to output: URL) async throws {
        try? FileManager.default.removeItem(at: output)
        guard let session = AVAssetExportSession(asset: asset, presetName: AVAssetExportPresetPassthrough) else {
            throw StreamError.processing("The video couldn't be prepared for saving.")
        }
        try await session.export(to: output, as: .mp4)
    }
}
