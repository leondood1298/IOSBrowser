import AVFoundation
import XCTest
@testable import MediaKit

/// Uses the HLS fixtures the UI tests serve, in TestSite/hls (made with ffmpeg: 6 seconds of
/// 24 fps video in 2-second segments, with AAC audio).
final class RemuxTests: XCTestCase {
    private var fixtures: URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 {
            url.deleteLastPathComponent()
        }
        return url.appendingPathComponent("TestSite/hls")
    }

    private func segments(_ folder: String, count: Int) throws -> [Data] {
        try (0..<count).map { try Data(contentsOf: fixtures.appendingPathComponent("\(folder)/seg\($0).ts")) }
    }

    private func remux(_ segments: [Data], fileType: AVFileType = .mp4, extension ext: String = "mp4") async throws -> URL {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
        let remuxer = TSRemuxer(outputURL: output, fileType: fileType)
        for segment in segments {
            try remuxer.append(segment: segment)
        }
        try await remuxer.finish()
        return output
    }

    /// Decodes every sample of the track and returns how many there were.
    private func decodedSamples(of track: AVAssetTrack, in asset: AVAsset) throws -> Int {
        let reader = try AVAssetReader(asset: asset)
        let settings: [String: Any] = track.mediaType == .video
            ? [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
            : [AVFormatIDKey: kAudioFormatLinearPCM]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        reader.add(output)
        XCTAssertTrue(reader.startReading(), reader.error?.localizedDescription ?? "")
        var samples = 0
        while let buffer = output.copyNextSampleBuffer() {
            samples += CMSampleBufferGetNumSamples(buffer)
        }
        XCTAssertEqual(reader.status, .completed, reader.error?.localizedDescription ?? "")
        return samples
    }

    func testDemuxerFindsStreamsAndFrames() throws {
        let demuxer = TSDemuxer()
        let packets = demuxer.feed(try segments("ts360", count: 1)[0]) + demuxer.flush()
        let videoPID = try XCTUnwrap(demuxer.videoPID)
        let audioPID = try XCTUnwrap(demuxer.audioPID)
        XCTAssertEqual(demuxer.codecs[videoPID], .h264)
        XCTAssertEqual(demuxer.codecs[audioPID], .aac)
        XCTAssertEqual(packets.filter { $0.pid == videoPID }.count, 48)
        XCTAssertTrue(packets.filter { $0.pid == videoPID }.allSatisfy { $0.pts != nil })
        XCTAssertFalse(packets.filter { $0.pid == audioPID }.isEmpty)
    }

    func testRemuxesVideoAndAudio() async throws {
        let asset = AVURLAsset(url: try await remux(try segments("ts360", count: 3)))
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.25)
        let video = try await asset.loadTracks(withMediaType: .video)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertEqual(video.count, 1)
        XCTAssertEqual(audio.count, 1)
        let size = try await video[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 640, height: 360))
        XCTAssertEqual(try decodedSamples(of: video[0], in: asset), 144)
        XCTAssertGreaterThan(try decodedSamples(of: audio[0], in: asset), 44100 * 5)
    }

    func testRemuxesVideoOnlyAndAudioOnlyStreams() async throws {
        let video = AVURLAsset(url: try await remux(try segments("video", count: 3)))
        let videoTracks = try await video.loadTracks(withMediaType: .video)
        let silentTracks = try await video.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1)
        XCTAssertEqual(silentTracks.count, 0)
        XCTAssertEqual(try decodedSamples(of: videoTracks[0], in: video), 144)

        let audio = AVURLAsset(url: try await remux(try segments("audio", count: 4), fileType: .m4a, extension: "m4a"))
        let audioTracks = try await audio.loadTracks(withMediaType: .audio)
        XCTAssertEqual(audioTracks.count, 1)
        let duration = try await audio.load(.duration).seconds
        XCTAssertEqual(duration, 6, accuracy: 0.25)
    }

    func testDiscontinuityContinuesTheTimeline() async throws {
        // The same segment twice, the second time marked as starting over.
        let first = try segments("ts360", count: 1)[0]
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let remuxer = TSRemuxer(outputURL: output)
        try remuxer.append(segment: first)
        try remuxer.append(segment: first, discontinuity: true)
        try await remuxer.finish()
        let asset = AVURLAsset(url: output)
        let duration = try await asset.load(.duration).seconds
        XCTAssertEqual(duration, 4, accuracy: 0.25)
        let video = try await asset.loadTracks(withMediaType: .video)
        XCTAssertEqual(try decodedSamples(of: video[0], in: asset), 96)
    }

    func testRejectsWhatIsntMedia() async throws {
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let remuxer = TSRemuxer(outputURL: output)
        try remuxer.append(segment: Data("<html>Not found</html>".utf8))
        do {
            try await remuxer.finish()
            XCTFail("Expected an error")
        } catch {
            XCTAssertEqual(error as? TSRemuxer.Failure, .noMedia)
        }
    }

    func testDecryptsAES128Segments() throws {
        let key = Data(0..<16)
        let iv = Data(0..<16)
        let encrypted = try Data(contentsOf: fixtures.appendingPathComponent("aes/seg0.ts"))
        XCTAssertNotEqual(encrypted.first, 0x47)
        let plain = try SegmentDecryptor.decrypt(encrypted, key: key, iv: iv)
        XCTAssertEqual(plain.first, 0x47)
        XCTAssertEqual(plain.count % 188, 0)
        XCTAssertThrowsError(try SegmentDecryptor.decrypt(encrypted, key: Data(count: 8), iv: iv))
    }

    func testAnnexBAndADTS() {
        let stream = Data([0, 0, 0, 1, 0x67, 0xAA, 0, 0, 1, 0x68, 0xBB, 0, 0, 0, 1, 0x65, 0xCC, 0xDD])
        XCTAssertEqual(AnnexB.nalUnits(stream), [Data([0x67, 0xAA]), Data([0x68, 0xBB]), Data([0x65, 0xCC, 0xDD])])

        // AAC-LC, 44.1 kHz (index 4), stereo, a 20-byte frame without CRC.
        let header: [UInt8] = [0xFF, 0xF1, 0x50, 0x80, 0x02, 0x9F, 0xFC]
        let parsed = ADTSHeader(header + [UInt8](repeating: 0, count: 13), at: 0)
        XCTAssertEqual(parsed?.objectType, 2)
        XCTAssertEqual(parsed?.sampleRate, 44100)
        XCTAssertEqual(parsed?.channels, 2)
        XCTAssertEqual(parsed?.frameLength, 20)
        XCTAssertEqual(parsed?.audioSpecificConfig, [0x12, 0x10])
    }
}
