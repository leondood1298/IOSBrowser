import Foundation

// HLS playlists (RFC 8216), as far as saving a stream needs: the qualities a master playlist
// offers, and the segments, keys and init sections of a media playlist.

public struct HLSByteRange: Hashable, Sendable, Codable {
    public var length: Int64
    public var offset: Int64

    public init(length: Int64, offset: Int64) {
        self.length = length
        self.offset = offset
    }

    /// The Range header value for this byte range.
    public var rangeHeader: String {
        "bytes=\(offset)-\(offset + length - 1)"
    }
}

public struct HLSKey: Hashable, Sendable, Codable {
    public enum Method: String, Sendable, Codable {
        /// METHOD=NONE: the segments that follow aren't encrypted.
        case clear = "NONE"
        case aes128 = "AES-128"
        case sampleAES = "SAMPLE-AES"
        case sampleAESCTR = "SAMPLE-AES-CTR"
        case unknown
    }

    public var method: Method
    public var url: URL?
    /// The 16-byte initialization vector, when the playlist gives one.
    public var iv: Data?
    public var keyFormat: String?

    public init(method: Method, url: URL? = nil, iv: Data? = nil, keyFormat: String? = nil) {
        self.method = method
        self.url = url
        self.iv = iv
        self.keyFormat = keyFormat
    }

    /// The IV for a segment: the playlist's, or else the segment's media sequence number as a
    /// 128-bit big-endian integer.
    public func initializationVector(forSequence sequence: Int) -> Data {
        if let iv, iv.count == 16 {
            return iv
        }
        var bytes = [UInt8](repeating: 0, count: 16)
        var value = UInt64(max(sequence, 0))
        for index in stride(from: 15, through: 8, by: -1) {
            bytes[index] = UInt8(value & 0xFF)
            value >>= 8
        }
        return Data(bytes)
    }
}

/// An init section (EXT-X-MAP), which fragmented-MP4 segments need in front of them.
public struct HLSMap: Hashable, Sendable, Codable {
    public var url: URL
    public var byteRange: HLSByteRange?

    public init(url: URL, byteRange: HLSByteRange? = nil) {
        self.url = url
        self.byteRange = byteRange
    }
}

public struct HLSSegment: Hashable, Sendable, Codable {
    public var url: URL
    public var duration: Double
    /// The media sequence number.
    public var sequence: Int
    public var byteRange: HLSByteRange?
    public var key: HLSKey?
    public var map: HLSMap?
    public var discontinuity: Bool

    public init(
        url: URL, duration: Double, sequence: Int, byteRange: HLSByteRange? = nil, key: HLSKey? = nil,
        map: HLSMap? = nil, discontinuity: Bool = false
    ) {
        self.url = url
        self.duration = duration
        self.sequence = sequence
        self.byteRange = byteRange
        self.key = key
        self.map = map
        self.discontinuity = discontinuity
    }
}

public struct HLSMediaPlaylist: Hashable, Sendable, Codable {
    public var targetDuration: Double
    public var mediaSequence: Int
    public var segments: [HLSSegment]
    /// False for a live stream, which keeps growing (no EXT-X-ENDLIST).
    public var isComplete: Bool

    public init(targetDuration: Double, mediaSequence: Int, segments: [HLSSegment], isComplete: Bool) {
        self.targetDuration = targetDuration
        self.mediaSequence = mediaSequence
        self.segments = segments
        self.isComplete = isComplete
    }

    public var duration: Double {
        segments.reduce(0) { $0 + $1.duration }
    }

    /// Fragmented-MP4 segments (with an init section) rather than MPEG-TS.
    public var usesFragmentedMP4: Bool {
        segments.first?.map != nil
    }

    /// Encryption the browser can't undo: SAMPLE-AES (including FairPlay) or an unknown method.
    public var hasUnsupportedEncryption: Bool {
        segments.contains { segment in
            guard let method = segment.key?.method else { return false }
            return method != .clear && method != .aes128
        }
    }
}

public struct HLSVariant: Hashable, Sendable, Codable {
    public var url: URL
    public var bandwidth: Int
    public var averageBandwidth: Int?
    public var width: Int?
    public var height: Int?
    public var codecs: String?
    public var frameRate: Double?
    public var audioGroup: String?

    public init(
        url: URL, bandwidth: Int, averageBandwidth: Int? = nil, width: Int? = nil, height: Int? = nil,
        codecs: String? = nil, frameRate: Double? = nil, audioGroup: String? = nil
    ) {
        self.url = url
        self.bandwidth = bandwidth
        self.averageBandwidth = averageBandwidth
        self.width = width
        self.height = height
        self.codecs = codecs
        self.frameRate = frameRate
        self.audioGroup = audioGroup
    }

    /// "1080p", or the bit rate when the playlist doesn't give a resolution.
    public var qualityLabel: String {
        if let width, let height, width > 0, height > 0 {
            let lines = min(width, height)
            return lines >= 2160 ? "4K" : "\(lines)p"
        }
        return HLSVariant.bitRate(averageBandwidth ?? bandwidth)
    }

    /// "5.2 Mbps", "800 kbps".
    public static func bitRate(_ bitsPerSecond: Int) -> String {
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mbps", Double(bitsPerSecond) / 1_000_000)
        }
        return "\(max(1, bitsPerSecond / 1000)) kbps"
    }

    /// Audio-only variants (an audio codec and no video codec, or no resolution with an audio codec).
    public var isAudioOnly: Bool {
        guard let codecs = codecs?.lowercased() else { return false }
        let videoCodecs = ["avc1", "avc3", "hvc1", "hev1", "dvh1", "dvhe", "av01", "vp09"]
        let hasVideo = videoCodecs.contains { codecs.contains($0) }
        return !hasVideo && (codecs.contains("mp4a") || codecs.contains("ac-3") || codecs.contains("ec-3"))
    }
}

/// An alternative rendition (EXT-X-MEDIA), such as a separate audio track.
public struct HLSRendition: Hashable, Sendable, Codable {
    public var type: String
    public var groupID: String
    public var name: String
    public var language: String?
    public var isDefault: Bool
    public var autoselect: Bool
    public var url: URL?

    public init(
        type: String, groupID: String, name: String, language: String? = nil, isDefault: Bool = false,
        autoselect: Bool = false, url: URL? = nil
    ) {
        self.type = type
        self.groupID = groupID
        self.name = name
        self.language = language
        self.isDefault = isDefault
        self.autoselect = autoselect
        self.url = url
    }
}

public struct HLSMasterPlaylist: Hashable, Sendable, Codable {
    public var variants: [HLSVariant]
    public var renditions: [HLSRendition]

    public init(variants: [HLSVariant], renditions: [HLSRendition]) {
        self.variants = variants
        self.renditions = renditions
    }

    /// One variant per quality, best first: the highest bit rate of each resolution.
    public var qualities: [HLSVariant] {
        let video = variants.filter { !$0.isAudioOnly }
        let candidates = video.isEmpty ? variants : video
        var best: [String: HLSVariant] = [:]
        for variant in candidates {
            let label = variant.qualityLabel
            if let current = best[label], current.bandwidth >= variant.bandwidth {
                continue
            }
            best[label] = variant
        }
        return best.values.sorted {
            let left = min($0.width ?? 0, $0.height ?? 0)
            let right = min($1.width ?? 0, $1.height ?? 0)
            return left != right ? left > right : $0.bandwidth > $1.bandwidth
        }
    }

    /// The separate audio playlist to download with `variant`: the group's default rendition
    /// (else its first) that has its own address. Nil when the audio is inside the video segments.
    public func audioRendition(for variant: HLSVariant) -> HLSRendition? {
        guard let group = variant.audioGroup else { return nil }
        let members = renditions.filter { $0.type == "AUDIO" && $0.groupID == group && $0.url != nil }
        return members.first(where: \.isDefault) ?? members.first(where: \.autoselect) ?? members.first
    }
}

public enum HLSPlaylist: Hashable, Sendable {
    case master(HLSMasterPlaylist)
    case media(HLSMediaPlaylist)
}

public enum M3U8Parser {
    public enum Failure: Error, Equatable {
        case notAPlaylist
        case noSegments
    }

    public static func parse(_ text: String, baseURL: URL) throws -> HLSPlaylist {
        let lines = text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // A byte-order mark may come first.
        guard let first = lines.first, first.replacingOccurrences(of: "\u{FEFF}", with: "").hasPrefix("#EXTM3U") else {
            throw Failure.notAPlaylist
        }
        if lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF") }) {
            return .master(parseMaster(lines, baseURL: baseURL))
        }
        let media = parseMedia(lines, baseURL: baseURL)
        guard !media.segments.isEmpty else { throw Failure.noSegments }
        return .media(media)
    }

    private static func parseMaster(_ lines: [String], baseURL: URL) -> HLSMasterPlaylist {
        var variants: [HLSVariant] = []
        var renditions: [HLSRendition] = []
        var pending: [String: String]?
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pending = attributes(after: "#EXT-X-STREAM-INF:", in: line)
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                let values = attributes(after: "#EXT-X-MEDIA:", in: line)
                guard let type = values["TYPE"], let group = values["GROUP-ID"] else { continue }
                renditions.append(HLSRendition(
                    type: type, groupID: group, name: values["NAME"] ?? group, language: values["LANGUAGE"],
                    isDefault: values["DEFAULT"] == "YES", autoselect: values["AUTOSELECT"] == "YES",
                    url: values["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }))
            } else if !line.hasPrefix("#"), let values = pending {
                pending = nil
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                let resolution = values["RESOLUTION"]?.lowercased().split(separator: "x").compactMap { Int($0) }
                variants.append(HLSVariant(
                    url: url, bandwidth: Int(values["BANDWIDTH"] ?? "") ?? 0,
                    averageBandwidth: values["AVERAGE-BANDWIDTH"].flatMap { Int($0) },
                    width: resolution?.count == 2 ? resolution?[0] : nil,
                    height: resolution?.count == 2 ? resolution?[1] : nil,
                    codecs: values["CODECS"], frameRate: values["FRAME-RATE"].flatMap { Double($0) },
                    audioGroup: values["AUDIO"]))
            }
        }
        return HLSMasterPlaylist(variants: variants, renditions: renditions)
    }

    private static func parseMedia(_ lines: [String], baseURL: URL) -> HLSMediaPlaylist {
        var targetDuration: Double = 0
        var mediaSequence = 0
        var segments: [HLSSegment] = []
        var isComplete = false
        var key: HLSKey?
        var map: HLSMap?
        var duration: Double?
        var byteRange: HLSByteRange?
        var discontinuity = false
        var gap = false
        // Segments (and gaps) so far: each uses up a media sequence number.
        var position = 0
        // Where the previous byte range of each resource ended, for ranges given without an offset.
        var rangeEnds: [URL: Int64] = [:]
        var pendingRange: (length: Int64, offset: Int64?)?

        for line in lines {
            if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                duration = Double(value.trimmingCharacters(in: .whitespaces)) ?? 0
            } else if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-ENDLIST") {
                isComplete = true
            } else if line.hasPrefix("#EXT-X-PLAYLIST-TYPE:") {
                if line.hasSuffix("VOD") { isComplete = true }
            } else if line.hasPrefix("#EXT-X-DISCONTINUITY"), !line.hasPrefix("#EXT-X-DISCONTINUITY-SEQUENCE") {
                discontinuity = true
            } else if line.hasPrefix("#EXT-X-GAP") {
                gap = true
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = parseRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if line.hasPrefix("#EXT-X-KEY:") {
                key = parseKey(attributes(after: "#EXT-X-KEY:", in: line), baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let values = attributes(after: "#EXT-X-MAP:", in: line)
                if let uri = values["URI"], let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL {
                    let range = values["BYTERANGE"].flatMap(parseRange).map {
                        HLSByteRange(length: $0.length, offset: $0.offset ?? 0)
                    }
                    map = HLSMap(url: url, byteRange: range)
                }
            } else if !line.hasPrefix("#") {
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }
                if let pending = pendingRange {
                    let offset = pending.offset ?? rangeEnds[url] ?? 0
                    byteRange = HLSByteRange(length: pending.length, offset: offset)
                    rangeEnds[url] = offset + pending.length
                }
                if !gap {
                    segments.append(HLSSegment(
                        url: url, duration: duration ?? 0, sequence: mediaSequence + position, byteRange: byteRange,
                        key: key?.method == .clear ? nil : key, map: map, discontinuity: discontinuity))
                }
                position += 1
                duration = nil
                byteRange = nil
                pendingRange = nil
                discontinuity = false
                gap = false
            }
        }
        return HLSMediaPlaylist(
            targetDuration: targetDuration, mediaSequence: mediaSequence, segments: segments, isComplete: isComplete)
    }

    private static func parseKey(_ values: [String: String], baseURL: URL) -> HLSKey {
        let method = HLSKey.Method(rawValue: values["METHOD"] ?? "NONE") ?? .unknown
        var iv: Data?
        if var hex = values["IV"] {
            if hex.lowercased().hasPrefix("0x") {
                hex.removeFirst(2)
            }
            iv = data(fromHex: hex)
        }
        return HLSKey(
            method: method, url: values["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL },
            iv: iv, keyFormat: values["KEYFORMAT"])
    }

    /// "length[@offset]".
    private static func parseRange(_ text: String) -> (length: Int64, offset: Int64?)? {
        let parts = text.split(separator: "@")
        guard let length = parts.first.flatMap({ Int64($0) }) else { return nil }
        return (length, parts.count > 1 ? Int64(parts[1]) : nil)
    }

    /// A 32-digit hex string as 16 bytes (shorter strings are padded on the left).
    static func data(fromHex hex: String) -> Data? {
        let digits = String(repeating: "0", count: max(0, 32 - hex.count)) + hex
        guard digits.count == 32 else { return nil }
        var bytes: [UInt8] = []
        var index = digits.startIndex
        while index < digits.endIndex {
            let next = digits.index(index, offsetBy: 2)
            guard let byte = UInt8(digits[index..<next], radix: 16) else { return nil }
            bytes.append(byte)
            index = next
        }
        return Data(bytes)
    }

    /// Parses an attribute list: KEY=VALUE pairs separated by commas, where quoted values may
    /// contain commas.
    static func attributes(after prefix: String, in line: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var quoted = false
        for character in line.dropFirst(prefix.count) {
            if readingKey {
                if character == "=" {
                    readingKey = false
                } else if character != "," {
                    key.append(character)
                }
            } else if character == "\"" {
                quoted.toggle()
            } else if character == ",", !quoted {
                result[key.trimmingCharacters(in: .whitespaces)] = value
                key = ""
                value = ""
                readingKey = true
            } else {
                value.append(character)
            }
        }
        if !key.isEmpty {
            result[key.trimmingCharacters(in: .whitespaces)] = value
        }
        return result
    }
}
