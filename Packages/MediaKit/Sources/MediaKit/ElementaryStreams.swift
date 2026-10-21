import Foundation

/// Annex B byte streams: NAL units separated by 00 00 01 or 00 00 00 01 start codes.
enum AnnexB {
    static func nalUnits(_ data: Data) -> [Data] {
        let bytes = [UInt8](data)
        var units: [Data] = []
        var start: Int?
        var index = 0
        while index + 2 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                if let start {
                    units.append(trimmed(bytes, start, index))
                }
                index += 3
                start = index
            } else {
                index += 1
            }
        }
        if let start, start < bytes.count {
            units.append(trimmed(bytes, start, bytes.count))
        }
        return units.filter { !$0.isEmpty }
    }

    /// `bytes[from..<to]` without trailing zeros (the first byte of a four-byte start code).
    private static func trimmed(_ bytes: [UInt8], _ from: Int, _ to: Int) -> Data {
        var end = to
        while end > from, bytes[end - 1] == 0 {
            end -= 1
        }
        return Data(bytes[from..<end])
    }
}

/// One video frame: its NAL units without parameter sets or delimiters.
struct VideoAccessUnit {
    var nalUnits: [Data]
    var isKeyframe: Bool
    /// 90 kHz, on the output timeline.
    var pts: Int64
    var dts: Int64
}

/// Turns video PES payloads into frames and keeps the stream's parameter sets.
struct VideoStreamParser {
    let codec: StreamCodec
    private(set) var parameterSets: [UInt8: Data] = [:]

    init(codec: StreamCodec) {
        self.codec = codec
    }

    mutating func accessUnit(from payload: Data, pts: Int64, dts: Int64) -> VideoAccessUnit? {
        var units: [Data] = []
        var isKeyframe = false
        var hasPicture = false
        for nal in AnnexB.nalUnits(payload) {
            guard let header = nal.first else { continue }
            if codec == .hevc {
                let type = (header >> 1) & 0x3F
                switch type {
                case 32, 33, 34:
                    parameterSets[type] = nal
                case 35:
                    break  // access unit delimiter
                default:
                    if type <= 31 { hasPicture = true }
                    if (16...21).contains(type) { isKeyframe = true }
                    units.append(nal)
                }
            } else {
                let type = header & 0x1F
                switch type {
                case 7, 8:
                    parameterSets[type] = nal
                case 9:
                    break  // access unit delimiter
                default:
                    if (1...5).contains(type) { hasPicture = true }
                    if type == 5 { isKeyframe = true }
                    units.append(nal)
                }
            }
        }
        guard hasPicture else { return nil }
        return VideoAccessUnit(nalUnits: units, isKeyframe: isKeyframe, pts: pts, dts: dts)
    }

    /// SPS and PPS (H.264) or VPS, SPS and PPS (HEVC), once all have been seen.
    var formatParameterSets: [Data]? {
        let types: [UInt8] = codec == .hevc ? [32, 33, 34] : [7, 8]
        let sets = types.compactMap { parameterSets[$0] }
        return sets.count == types.count ? sets : nil
    }
}

/// The header of an AAC frame in ADTS framing.
struct ADTSHeader: Equatable {
    static let sampleRates = [96000, 88200, 64000, 48000, 44100, 32000, 24000, 22050, 16000, 12000, 11025, 8000, 7350]

    /// MPEG-4 audio object type (2 = AAC-LC).
    var objectType: Int
    var sampleRateIndex: Int
    var channels: Int
    /// The whole frame, header included.
    var frameLength: Int
    var headerLength: Int

    var sampleRate: Int {
        Self.sampleRates[sampleRateIndex]
    }

    init?(_ bytes: [UInt8], at index: Int) {
        guard index + 7 <= bytes.count, bytes[index] == 0xFF, bytes[index + 1] & 0xF6 == 0xF0 else { return nil }
        objectType = Int((bytes[index + 2] >> 6) & 0x03) + 1
        sampleRateIndex = Int((bytes[index + 2] >> 2) & 0x0F)
        channels = Int(bytes[index + 2] & 0x01) << 2 | Int((bytes[index + 3] >> 6) & 0x03)
        frameLength = Int(bytes[index + 3] & 0x03) << 11 | Int(bytes[index + 4]) << 3 | Int((bytes[index + 5] >> 5) & 0x07)
        headerLength = bytes[index + 1] & 0x01 == 1 ? 7 : 9
        guard frameLength > headerLength, sampleRateIndex < Self.sampleRates.count else { return nil }
    }

    /// The two-byte AudioSpecificConfig an MP4 stores for this stream.
    var audioSpecificConfig: [UInt8] {
        let channelConfig = channels == 0 ? 2 : channels
        return [
            UInt8(objectType << 3 | sampleRateIndex >> 1),
            UInt8((sampleRateIndex & 1) << 7 | channelConfig << 3),
        ]
    }

    /// The AudioSpecificConfig wrapped in an MPEG-4 ES descriptor: the AAC magic cookie Core
    /// Media uses (the contents of an MP4's esds box).
    var esdsCookie: [UInt8] {
        let specific: [UInt8] = [0x05, UInt8(audioSpecificConfig.count)] + audioSpecificConfig
        // Object type 0x40 (MPEG-4 audio), stream type 5 (audio), buffer size and bit rates unknown.
        let decoderConfig: [UInt8] = [0x04, UInt8(13 + specific.count), 0x40, 0x15] + [UInt8](repeating: 0, count: 11) + specific
        let sync: [UInt8] = [0x06, 0x01, 0x02]
        let body: [UInt8] = [0x00, 0x00, 0x00] + decoderConfig + sync
        return [0x03, UInt8(body.count)] + body
    }
}

/// Raw AAC frames from ADTS data. A frame cut off at the end waits for the next payload.
struct ADTSParser {
    private var carry: [UInt8] = []
    private(set) var format: ADTSHeader?

    /// The frames that are complete, and whether the first began in data from an earlier call.
    mutating func frames(in payload: Data) -> (frames: [Data], firstWasCarried: Bool) {
        let carried = !carry.isEmpty
        let bytes = carry + [UInt8](payload)
        carry = []
        var frames: [Data] = []
        var index = 0
        while index + 7 <= bytes.count {
            guard let header = ADTSHeader(bytes, at: index) else {
                index += 1
                continue
            }
            guard index + header.frameLength <= bytes.count else { break }
            if format == nil {
                format = header
            }
            frames.append(Data(bytes[(index + header.headerLength)..<(index + header.frameLength)]))
            index += header.frameLength
        }
        if index < bytes.count {
            carry = Array(bytes[index...])
        }
        return (frames, carried)
    }
}

/// HLS packed audio: an ID3 tag carrying the segment's start time, then ADTS frames.
enum PackedAudio {
    static func isPackedAudio(_ data: Data) -> Bool {
        data.count > 10 && data.prefix(3) == Data("ID3".utf8)
    }

    /// The 90 kHz start time from the tag's transport-stream timestamp, and the data after the tag.
    static func split(_ data: Data) -> (pts: Int64?, audio: Data) {
        let bytes = [UInt8](data)
        guard bytes.count > 10 else { return (nil, data) }
        let size = Int(bytes[6] & 0x7F) << 21 | Int(bytes[7] & 0x7F) << 14 | Int(bytes[8] & 0x7F) << 7 | Int(bytes[9] & 0x7F)
        let end = min(bytes.count, 10 + size)
        let owner = Array("com.apple.streaming.transportStreamTimestamp".utf8) + [0]
        var pts: Int64?
        var index = 10
        while index + 10 <= end {
            let frameID = String(decoding: bytes[index..<(index + 4)], as: UTF8.self)
            let frameSize = Int(bytes[index + 4]) << 24 | Int(bytes[index + 5]) << 16 | Int(bytes[index + 6]) << 8 | Int(bytes[index + 7])
            let body = index + 10
            guard frameSize > 0, body + frameSize <= end else { break }
            if frameID == "PRIV", frameSize >= owner.count + 8, Array(bytes[body..<(body + owner.count)]) == owner {
                var value: Int64 = 0
                for byte in bytes[(body + owner.count)..<(body + owner.count + 8)] {
                    value = value << 8 | Int64(byte)
                }
                pts = value & 0x1_FFFF_FFFF
            }
            index = body + frameSize
        }
        return (pts, Data(bytes[end...]))
    }
}
