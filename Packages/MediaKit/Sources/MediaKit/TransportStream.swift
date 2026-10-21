import Foundation

/// The codec of an elementary stream, from its stream type in the program map table.
enum StreamCodec: Equatable {
    case h264
    case hevc
    case aac
    case other(UInt8)

    init(streamType: UInt8) {
        switch streamType {
        case 0x1B: self = .h264
        case 0x24: self = .hevc
        case 0x0F: self = .aac
        default: self = .other(streamType)
        }
    }

    var isVideo: Bool {
        self == .h264 || self == .hevc
    }
}

/// A complete PES packet: usually one video frame, or a run of audio frames.
struct PESPacket {
    var pid: UInt16
    var codec: StreamCodec
    /// 90 kHz clock values as found (33 bits, not unwrapped).
    var pts: Int64?
    var dts: Int64?
    var payload: Data
}

/// Splits an MPEG-TS stream into PES packets for its first video and first audio stream.
/// State carries over between calls, since a PES packet can continue into the next segment.
final class TSDemuxer {
    static let packetSize = 188

    private(set) var videoPID: UInt16?
    private(set) var audioPID: UInt16?
    private(set) var codecs: [UInt16: StreamCodec] = [:]
    private var pmtPID: UInt16?
    private var assembling: [UInt16: PESPacket] = [:]
    private var expectedLength: [UInt16: Int] = [:]
    private var carry: [UInt8] = []

    /// Feeds the next part of the stream and returns the PES packets it completed.
    func feed(_ data: Data) -> [PESPacket] {
        let bytes = carry + [UInt8](data)
        carry = []
        var output: [PESPacket] = []
        var offset = 0
        while offset + Self.packetSize <= bytes.count {
            guard bytes[offset] == 0x47 else {
                offset = resync(bytes, from: offset + 1)
                continue
            }
            parsePacket(bytes[offset..<(offset + Self.packetSize)], into: &output)
            offset += Self.packetSize
        }
        if offset < bytes.count {
            carry = Array(bytes[offset...])
        }
        return output
    }

    /// The PES packets still being assembled, for the end of the stream (or before a jump in time).
    func flush() -> [PESPacket] {
        let packets = assembling.values.sorted { $0.pid < $1.pid }
        assembling.removeAll()
        expectedLength.removeAll()
        carry = []
        return packets
    }

    /// The next offset with a sync byte that's followed by another one a packet later.
    private func resync(_ bytes: [UInt8], from start: Int) -> Int {
        var index = start
        while index < bytes.count {
            if bytes[index] == 0x47, index + Self.packetSize >= bytes.count || bytes[index + Self.packetSize] == 0x47 {
                return index
            }
            index += 1
        }
        return bytes.count
    }

    private func parsePacket(_ packet: ArraySlice<UInt8>, into output: inout [PESPacket]) {
        let base = packet.startIndex
        let flags = packet[base + 1]
        guard flags & 0x80 == 0 else { return }  // transport error
        let unitStart = flags & 0x40 != 0
        let pid = UInt16(flags & 0x1F) << 8 | UInt16(packet[base + 2])
        let adaptation = (packet[base + 3] >> 4) & 0x03
        var start = base + 4
        if adaptation & 0x02 != 0 {
            start += 1 + Int(packet[base + 4])
        }
        guard adaptation & 0x01 != 0, start < packet.endIndex else { return }
        let payload = packet[start..<packet.endIndex]
        if pid == 0 {
            if unitStart { parsePAT(payload) }
        } else if pid == pmtPID {
            if unitStart { parsePMT(payload) }
        } else if pid == videoPID || pid == audioPID {
            handlePES(pid: pid, payload: payload, unitStart: unitStart, into: &output)
        }
    }

    /// A table section, after the pointer field, up to its declared length.
    private func section(_ payload: ArraySlice<UInt8>) -> ArraySlice<UInt8>? {
        guard let pointer = payload.first else { return nil }
        let start = payload.startIndex + 1 + Int(pointer)
        guard start + 3 <= payload.endIndex else { return nil }
        let length = Int(payload[start + 1] & 0x0F) << 8 | Int(payload[start + 2])
        return payload[start..<min(payload.endIndex, start + 3 + length)]
    }

    private func parsePAT(_ payload: ArraySlice<UInt8>) {
        guard let table = section(payload), table.count >= 12, table[table.startIndex] == 0x00 else { return }
        var index = table.startIndex + 8
        while index + 4 <= table.endIndex - 4 {
            let program = Int(table[index]) << 8 | Int(table[index + 1])
            if program != 0 {
                pmtPID = UInt16(table[index + 2] & 0x1F) << 8 | UInt16(table[index + 3])
                return
            }
            index += 4
        }
    }

    private func parsePMT(_ payload: ArraySlice<UInt8>) {
        guard let table = section(payload), table.count >= 16, table[table.startIndex] == 0x02 else { return }
        let base = table.startIndex
        let infoLength = Int(table[base + 10] & 0x0F) << 8 | Int(table[base + 11])
        var index = base + 12 + infoLength
        while index + 5 <= table.endIndex - 4 {
            let codec = StreamCodec(streamType: table[index])
            let pid = UInt16(table[index + 1] & 0x1F) << 8 | UInt16(table[index + 2])
            let descriptors = Int(table[index + 3] & 0x0F) << 8 | Int(table[index + 4])
            if codec.isVideo, videoPID == nil {
                videoPID = pid
                codecs[pid] = codec
            } else if codec == .aac, audioPID == nil {
                audioPID = pid
                codecs[pid] = codec
            }
            index += 5 + descriptors
        }
    }

    private func handlePES(pid: UInt16, payload: ArraySlice<UInt8>, unitStart: Bool, into output: inout [PESPacket]) {
        if unitStart {
            if let finished = assembling.removeValue(forKey: pid) {
                output.append(finished)
            }
            expectedLength[pid] = nil
            let base = payload.startIndex
            guard payload.count >= 9, payload[base] == 0, payload[base + 1] == 0, payload[base + 2] == 1 else { return }
            let packetLength = Int(payload[base + 4]) << 8 | Int(payload[base + 5])
            let flags = payload[base + 7]
            let headerLength = Int(payload[base + 8])
            var pts: Int64?
            var dts: Int64?
            if flags & 0x80 != 0, payload.count >= 14 {
                pts = Self.timestamp(payload, at: base + 9)
            }
            if flags & 0x40 != 0, payload.count >= 19 {
                dts = Self.timestamp(payload, at: base + 14)
            }
            let dataStart = base + 9 + headerLength
            guard dataStart <= payload.endIndex else { return }
            assembling[pid] = PESPacket(
                pid: pid, codec: codecs[pid] ?? .other(0), pts: pts, dts: dts, payload: Data(payload[dataStart...]))
            if packetLength > 0 {
                expectedLength[pid] = packetLength - 3 - headerLength
            }
        } else {
            assembling[pid]?.payload.append(contentsOf: payload)
        }
        // A PES with a declared length is complete as soon as it's all here.
        if let expected = expectedLength[pid], var packet = assembling[pid], packet.payload.count >= expected {
            if packet.payload.count > expected {
                packet.payload = packet.payload.prefix(expected)
            }
            output.append(packet)
            assembling[pid] = nil
            expectedLength[pid] = nil
        }
    }

    /// A 33-bit PTS or DTS from its 5-byte field.
    static func timestamp(_ bytes: ArraySlice<UInt8>, at index: Int) -> Int64 {
        let high = Int64((bytes[index] >> 1) & 0x07) << 30
        let middle = Int64(bytes[index + 1]) << 22 | Int64(bytes[index + 2] >> 1) << 15
        let low = Int64(bytes[index + 3]) << 7 | Int64(bytes[index + 4] >> 1)
        return high | middle | low
    }
}
