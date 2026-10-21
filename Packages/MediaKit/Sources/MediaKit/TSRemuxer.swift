import AVFoundation
import CoreMedia

/// Turns HLS segments into an MP4 (or M4A) file without re-encoding: MPEG-TS segments with H.264
/// or HEVC video and AAC audio, or packed AAC audio segments. Feed the segments in order with
/// `append(segment:discontinuity:)`, then call `finish()`.
///
/// Frames are written in time order across video and audio, a segment at a time, so memory
/// stays small however long the stream is. Timestamps start at zero, survive the 33-bit clock
/// wrapping, and continue smoothly over discontinuities.
public final class TSRemuxer {
    public enum Failure: Error, Equatable {
        /// No video or audio the remuxer understands (it handles H.264, HEVC and AAC).
        case noMedia
        case writer(String)
    }

    private enum Item {
        case video(VideoAccessUnit, duration: Int64)
        case audio([Data], start: Int64)
    }

    private let outputURL: URL
    private let fileType: AVFileType
    private let demuxer = TSDemuxer()
    private var videoParser: VideoStreamParser?
    private var audioParser = ADTSParser()
    private var hasAudioStream = false

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var videoFormat: CMVideoFormatDescription?
    private var audioFormat: CMAudioFormatDescription?
    private var sampleRate = 44100

    private var videoQueue: [Item] = []
    private var audioQueue: [Item] = []
    private var pendingFrame: VideoAccessUnit?
    private var lastFrameDuration: Int64 = 3750
    private var sawKeyframe = false
    /// Next audio frame's start, in samples on the output timeline.
    private var audioClock: Int64?

    // The output timeline: clock value + wrap correction - origin + offset (90 kHz).
    private var origin: Int64?
    private var offset: Int64 = 0
    private var lastRaw: [UInt16: Int64] = [:]
    private var wraps: [UInt16: Int64] = [:]
    /// Where the media read so far ends (90 kHz, output timeline).
    private var end: Int64 = 0

    public init(outputURL: URL, fileType: AVFileType = .mp4) {
        self.outputURL = outputURL
        self.fileType = fileType
    }

    /// Seconds of media so far.
    public var duration: Double {
        Double(end) / 90000
    }

    /// Adds the next segment. `discontinuity` marks a segment whose timestamps start over
    /// (EXT-X-DISCONTINUITY); the output continues where it was.
    public func append(segment: Data, discontinuity: Bool = false) throws {
        if discontinuity {
            process(demuxer.flush())
            if let frame = pendingFrame {
                extendEnd(frame, duration: lastFrameDuration)
            }
            lastRaw.removeAll()
            wraps.removeAll()
        }
        if PackedAudio.isPackedAudio(segment) {
            try appendPackedAudio(segment, discontinuity: discontinuity)
            return
        }
        let packets = demuxer.feed(segment)
        if videoParser == nil, let pid = demuxer.videoPID, let codec = demuxer.codecs[pid] {
            videoParser = VideoStreamParser(codec: codec)
        }
        hasAudioStream = hasAudioStream || demuxer.audioPID != nil
        let earliest = packets.compactMap { packet in (packet.dts ?? packet.pts).map { unwrap($0, pid: packet.pid) } }.min()
        if let earliest {
            if origin == nil {
                origin = earliest
            } else if discontinuity {
                offset = end - (earliest - origin!)
                audioClock = nil
            }
        }
        process(packets)
        try startIfReady(final: false)
        try drain(final: false)
    }

    /// Writes what's left and closes the file.
    public func finish() async throws {
        process(demuxer.flush())
        if let frame = pendingFrame {
            videoQueue.append(.video(frame, duration: lastFrameDuration))
            extendEnd(frame, duration: lastFrameDuration)
            pendingFrame = nil
        }
        try startIfReady(final: true)
        try drain(final: true)
        guard let writer else { throw Failure.noMedia }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        await writer.finishWriting()
        if writer.status != .completed {
            throw Failure.writer(writer.error?.localizedDescription ?? "The file couldn't be written.")
        }
    }

    // MARK: - Reading

    private func appendPackedAudio(_ segment: Data, discontinuity: Bool) throws {
        let (pts, audio) = PackedAudio.split(segment)
        hasAudioStream = true
        if let pts {
            let time = unwrap(pts, pid: 0x1FFF)
            if origin == nil {
                origin = time
            } else if discontinuity {
                offset = end - (time - origin!)
                audioClock = nil
            }
            processAudio(audio, pts: output(time))
        } else {
            processAudio(audio, pts: nil)
        }
        try startIfReady(final: false)
        try drain(final: false)
    }

    private func process(_ packets: [PESPacket]) {
        for packet in packets {
            if packet.codec.isVideo {
                processVideo(packet)
            } else if packet.codec == .aac {
                processAudio(packet.payload, pts: packet.pts.map { output(unwrap($0, pid: packet.pid)) })
            }
        }
    }

    private func processVideo(_ packet: PESPacket) {
        guard var parser = videoParser else { return }
        let fallback = pendingFrame.map { $0.dts + lastFrameDuration } ?? 0
        let dts = (packet.dts ?? packet.pts).map { output(unwrap($0, pid: packet.pid)) } ?? fallback
        let pts = packet.pts.map { output(unwrap($0, pid: packet.pid)) } ?? dts
        let frame = parser.accessUnit(from: packet.payload, pts: pts, dts: dts)
        videoParser = parser
        guard let frame else { return }
        // Playback has to start at a keyframe.
        guard sawKeyframe || frame.isKeyframe else { return }
        sawKeyframe = true
        if let previous = pendingFrame {
            let gap = frame.dts - previous.dts
            // A frame lasts until the next one; a jump (a discontinuity) keeps the last duration.
            if gap > 0, gap < 90000 {
                lastFrameDuration = gap
            }
            videoQueue.append(.video(previous, duration: lastFrameDuration))
            extendEnd(previous, duration: lastFrameDuration)
        }
        pendingFrame = frame
    }

    private func extendEnd(_ frame: VideoAccessUnit, duration: Int64) {
        end = max(end, frame.pts + duration, frame.dts + duration)
    }

    /// `pts` (90 kHz, output timeline) belongs to the first frame that starts in this payload.
    private func processAudio(_ payload: Data, pts: Int64?) {
        let (frames, firstWasCarried) = audioParser.frames(in: payload)
        guard !frames.isEmpty, let format = audioParser.format else { return }
        sampleRate = format.sampleRate
        if let pts {
            let skipped = firstWasCarried ? 1024 : 0
            let start = pts * Int64(sampleRate) / 90000 - Int64(skipped)
            // Follow the stream's timestamps when they drift from the running count by over half a frame.
            if audioClock == nil || abs(start - audioClock!) > 512 {
                audioClock = start
            }
        }
        let start = audioClock ?? 0
        audioQueue.append(.audio(frames, start: start))
        audioClock = start + Int64(frames.count * 1024)
        end = max(end, audioClock! * 90000 / Int64(sampleRate))
    }

    private func unwrap(_ raw: Int64, pid: UInt16) -> Int64 {
        var wrap = wraps[pid] ?? 0
        if let last = lastRaw[pid] {
            if raw + wrap < last - (1 << 32) {
                wrap += 1 << 33
            } else if raw + wrap > last + (1 << 32), wrap > 0 {
                wrap -= 1 << 33
            }
        }
        wraps[pid] = wrap
        lastRaw[pid] = raw + wrap
        return raw + wrap
    }

    private func output(_ time: Int64) -> Int64 {
        time - (origin ?? time) + offset
    }

    // MARK: - Writing

    private func startIfReady(final: Bool) throws {
        guard writer == nil else { return }
        if videoFormat == nil, let sets = videoParser?.formatParameterSets, let parser = videoParser {
            videoFormat = SampleBuffers.videoFormat(codec: parser.codec, parameterSets: sets)
        }
        if audioFormat == nil, let header = audioParser.format {
            audioFormat = SampleBuffers.audioFormat(header)
        }
        let videoReady = videoParser == nil || videoFormat != nil
        let audioReady = !hasAudioStream || audioFormat != nil
        guard (videoReady && audioReady) || final else { return }
        guard videoFormat != nil || audioFormat != nil else {
            if final { throw Failure.noMedia }
            return
        }

        try? FileManager.default.removeItem(at: outputURL)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(outputURL: outputURL, fileType: fileType)
        } catch {
            throw Failure.writer(error.localizedDescription)
        }
        writer.shouldOptimizeForNetworkUse = true
        if let videoFormat {
            let input = AVAssetWriterInput(mediaType: .video, outputSettings: nil, sourceFormatHint: videoFormat)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                videoInput = input
            }
        }
        if let audioFormat {
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: audioFormat)
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                writer.add(input)
                audioInput = input
            }
        }
        guard writer.startWriting() else {
            throw Failure.writer(writer.error?.localizedDescription ?? "The file couldn't be started.")
        }
        writer.startSession(atSourceTime: .zero)
        self.writer = writer
    }

    private func time(of item: Item) -> CMTime {
        switch item {
        case .video(let frame, _): return CMTime(value: frame.dts, timescale: 90000)
        case .audio(_, let start): return CMTime(value: start, timescale: CMTimeScale(sampleRate))
        }
    }

    /// Appends queued frames in time order. Until the end, only up to where both streams have
    /// data, so a stream never runs ahead of one that's still coming.
    private func drain(final: Bool) throws {
        guard writer != nil else { return }
        if videoInput == nil { videoQueue.removeAll() }
        if audioInput == nil { audioQueue.removeAll() }
        var limit: CMTime?
        if !final, videoInput != nil, audioInput != nil {
            guard let lastVideo = videoQueue.last, let lastAudio = audioQueue.last else { return }
            limit = CMTimeMinimum(time(of: lastVideo), time(of: lastAudio))
        }
        var videoIndex = 0
        var audioIndex = 0
        defer {
            videoQueue.removeFirst(videoIndex)
            audioQueue.removeFirst(audioIndex)
        }
        while true {
            let nextVideo = videoIndex < videoQueue.count ? videoQueue[videoIndex] : nil
            let nextAudio = audioIndex < audioQueue.count ? audioQueue[audioIndex] : nil
            let takeVideo: Bool
            switch (nextVideo, nextAudio) {
            case (nil, nil): return
            case (.some, nil): takeVideo = true
            case (nil, .some): takeVideo = false
            case (.some(let video), .some(let audio)): takeVideo = time(of: video) <= time(of: audio)
            }
            let item = takeVideo ? nextVideo! : nextAudio!
            if let limit, time(of: item) > limit { return }
            try append(item)
            if takeVideo { videoIndex += 1 } else { audioIndex += 1 }
        }
    }

    private func append(_ item: Item) throws {
        let input: AVAssetWriterInput?
        let sample: CMSampleBuffer?
        switch item {
        case .video(let frame, let duration):
            input = videoInput
            sample = videoFormat.flatMap { SampleBuffers.videoSample(frame, duration: duration, format: $0, offset: 0) }
        case .audio(let frames, let start):
            input = audioInput
            sample = audioFormat.flatMap { SampleBuffers.audioSample(frames, start: start, sampleRate: sampleRate, format: $0) }
        }
        guard let input, let sample, let writer else { return }
        var waited = 0
        while !input.isReadyForMoreMediaData {
            if writer.status == .failed {
                throw Failure.writer(writer.error?.localizedDescription ?? "Writing failed.")
            }
            waited += 1
            if waited > 30_000 {
                throw Failure.writer("The file writer stopped taking frames.")
            }
            usleep(1000)
        }
        if !input.append(sample) {
            throw Failure.writer(writer.error?.localizedDescription ?? "A frame couldn't be written.")
        }
    }
}
