import XCTest
@testable import BrowserCore

final class HLSTests: XCTestCase {
    private let base = URL(string: "https://media.example.com/show/master.m3u8")!

    private func media(_ text: String) throws -> HLSMediaPlaylist {
        guard case .media(let playlist) = try M3U8Parser.parse(text, baseURL: base) else {
            XCTFail("Expected a media playlist")
            throw M3U8Parser.Failure.notAPlaylist
        }
        return playlist
    }

    func testMasterPlaylist() throws {
        let text = """
            #EXTM3U
            #EXT-X-VERSION:6
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="English",LANGUAGE="en",DEFAULT=YES,AUTOSELECT=YES,URI="audio/en.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aac",NAME="Deutsch",LANGUAGE="de",DEFAULT=NO,URI="audio/de.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,AVERAGE-BANDWIDTH=4500000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",FRAME-RATE=30.000,AUDIO="aac"
            1080/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2800000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aac"
            720/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x720,CODECS="avc1.4d401f,mp4a.40.2",AUDIO="aac"
            720-low/index.m3u8
            #EXT-X-STREAM-INF:BANDWIDTH=64000,CODECS="mp4a.40.2"
            audio-only/index.m3u8
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=200000,URI="iframes.m3u8"
            """
        guard case .master(let master) = try M3U8Parser.parse(text, baseURL: base) else {
            return XCTFail("Expected a master playlist")
        }
        XCTAssertEqual(master.variants.count, 4)
        let best = master.variants[0]
        XCTAssertEqual(best.url.absoluteString, "https://media.example.com/show/1080/index.m3u8")
        XCTAssertEqual(best.width, 1920)
        XCTAssertEqual(best.height, 1080)
        XCTAssertEqual(best.codecs, "avc1.640028,mp4a.40.2")
        XCTAssertEqual(best.frameRate, 30)
        XCTAssertEqual(best.averageBandwidth, 4_500_000)
        XCTAssertEqual(best.qualityLabel, "1080p")
        XCTAssertTrue(master.variants[3].isAudioOnly)
        XCTAssertEqual(master.variants[3].qualityLabel, "64 kbps")

        XCTAssertEqual(master.qualities.map(\.qualityLabel), ["1080p", "720p"])
        XCTAssertEqual(master.qualities[1].bandwidth, 2_800_000)

        let audio = try XCTUnwrap(master.audioRendition(for: best))
        XCTAssertEqual(audio.name, "English")
        XCTAssertEqual(audio.url?.absoluteString, "https://media.example.com/show/audio/en.m3u8")
        XCTAssertNil(master.audioRendition(for: master.variants[3]))
    }

    func testEncryptedTransportStreamPlaylist() throws {
        let playlist = try media("""
            #EXTM3U
            #EXT-X-VERSION:3
            #EXT-X-TARGETDURATION:6
            #EXT-X-MEDIA-SEQUENCE:10
            #EXT-X-KEY:METHOD=AES-128,URI="https://keys.example.com/key1",IV=0x00000000000000000000000000000ABC
            #EXTINF:6.0,
            seg10.ts
            #EXTINF:6.0,
            seg11.ts
            #EXT-X-KEY:METHOD=NONE
            #EXTINF:4.5,
            seg12.ts
            #EXT-X-DISCONTINUITY
            #EXT-X-KEY:METHOD=AES-128,URI="key2"
            #EXTINF:5,
            https://cdn2.example.com/seg13.ts
            #EXT-X-ENDLIST
            """)
        XCTAssertEqual(playlist.segments.map(\.sequence), [10, 11, 12, 13])
        XCTAssertEqual(playlist.duration, 21.5, accuracy: 0.001)
        XCTAssertTrue(playlist.isComplete)
        XCTAssertFalse(playlist.usesFragmentedMP4)
        XCTAssertFalse(playlist.hasUnsupportedEncryption)

        let first = playlist.segments[0]
        XCTAssertEqual(first.url.absoluteString, "https://media.example.com/show/seg10.ts")
        XCTAssertEqual(first.key?.method, .aes128)
        XCTAssertEqual(first.key?.url?.absoluteString, "https://keys.example.com/key1")
        XCTAssertEqual(first.key?.initializationVector(forSequence: 10), Data([0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x0A, 0xBC]))
        XCTAssertNil(playlist.segments[2].key)

        let last = playlist.segments[3]
        XCTAssertTrue(last.discontinuity)
        XCTAssertEqual(last.url.absoluteString, "https://cdn2.example.com/seg13.ts")
        XCTAssertEqual(last.key?.url?.absoluteString, "https://media.example.com/show/key2")
        XCTAssertEqual(last.key?.initializationVector(forSequence: last.sequence), Data(repeating: 0, count: 15) + Data([13]))
    }

    func testFragmentedMP4WithByteRanges() throws {
        let playlist = try media("""
            #EXTM3U
            #EXT-X-TARGETDURATION:4
            #EXT-X-VERSION:7
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="main.mp4",BYTERANGE="720@0"
            #EXT-X-BYTERANGE:100000@720
            #EXTINF:4.0,
            main.mp4
            #EXT-X-BYTERANGE:90000
            #EXTINF:4.0,
            main.mp4
            #EXT-X-GAP
            #EXTINF:4.0,
            gap.mp4
            #EXTINF:3.0,
            part3.m4s
            #EXT-X-ENDLIST
            """)
        XCTAssertTrue(playlist.usesFragmentedMP4)
        XCTAssertEqual(playlist.segments.map(\.url.lastPathComponent), ["main.mp4", "main.mp4", "part3.m4s"])
        XCTAssertEqual(playlist.segments.map(\.sequence), [0, 1, 3])
        XCTAssertEqual(playlist.segments[0].byteRange, HLSByteRange(length: 100_000, offset: 720))
        XCTAssertEqual(playlist.segments[1].byteRange, HLSByteRange(length: 90_000, offset: 100_720))
        XCTAssertNil(playlist.segments[2].byteRange)
        XCTAssertEqual(playlist.segments[0].map, HLSMap(url: base.deletingLastPathComponent().appendingPathComponent("main.mp4"),
                                                       byteRange: HLSByteRange(length: 720, offset: 0)))
        XCTAssertEqual(playlist.segments[0].byteRange?.rangeHeader, "bytes=720-100719")
    }

    func testSampleAESAndLivePlaylists() throws {
        let playlist = try media("""
            #EXTM3U
            #EXT-X-TARGETDURATION:6
            #EXT-X-KEY:METHOD=SAMPLE-AES,URI="skd://key",KEYFORMAT="com.apple.streamingkeydelivery"
            #EXTINF:6,
            a.ts
            """)
        XCTAssertTrue(playlist.hasUnsupportedEncryption)
        XCTAssertFalse(playlist.isComplete)
        XCTAssertEqual(playlist.segments.first?.key?.keyFormat, "com.apple.streamingkeydelivery")
    }

    func testRejectsWhatIsntAPlaylist() {
        XCTAssertThrowsError(try M3U8Parser.parse("<html><body>Not found</body></html>", baseURL: base)) {
            XCTAssertEqual($0 as? M3U8Parser.Failure, .notAPlaylist)
        }
        XCTAssertThrowsError(try M3U8Parser.parse("#EXTM3U\n#EXT-X-TARGETDURATION:6\n", baseURL: base)) {
            XCTAssertEqual($0 as? M3U8Parser.Failure, .noSegments)
        }
        XCTAssertNoThrow(try M3U8Parser.parse("\u{FEFF}#EXTM3U\r\n#EXTINF:2,\r\na.ts\r\n", baseURL: base))
    }

    func testAttributeLists() {
        let values = M3U8Parser.attributes(after: "#X:", in: #"#X:A=1,B="x,y",C=0x1F, D=YES"#)
        XCTAssertEqual(values, ["A": "1", "B": "x,y", "C": "0x1F", "D": "YES"])
        XCTAssertEqual(HLSVariant.bitRate(5_200_000), "5.2 Mbps")
        XCTAssertEqual(HLSVariant.bitRate(800_000), "800 kbps")
    }
}
