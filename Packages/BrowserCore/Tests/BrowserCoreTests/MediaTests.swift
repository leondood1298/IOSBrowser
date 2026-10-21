import XCTest
@testable import BrowserCore

final class MediaTests: XCTestCase {
    private func url(_ string: String) -> URL {
        URL(string: string)!
    }

    func testKindByURL() {
        XCTAssertEqual(DetectedMedia.kind(of: url("https://cdn.example.com/clip.MP4?token=1")), .video)
        XCTAssertEqual(DetectedMedia.kind(of: url("https://cdn.example.com/song.mp3")), .audio)
        XCTAssertEqual(DetectedMedia.kind(of: url("https://cdn.example.com/live/index.m3u8")), .hls)
        XCTAssertEqual(DetectedMedia.kind(of: url("https://cdn.example.com/manifest.mpd")), .stream)
        XCTAssertEqual(DetectedMedia.kind(of: url("blob:https://www.youtube.com/0b5c")), .stream)
        XCTAssertNil(DetectedMedia.kind(of: url("https://example.com/page.html")))
        XCTAssertNil(DetectedMedia.kind(of: url("data:video/mp4;base64,AAAA")))
        XCTAssertEqual(DetectedMedia.kind(of: url("https://example.com/watch?id=7"), elementKind: .video), .video)
    }

    func testKindByDeclaredType() {
        XCTAssertEqual(DetectedMedia.kind(of: url("https://a.com/play?id=1"), mimeType: "application/x-mpegURL"), .hls)
        XCTAssertEqual(DetectedMedia.kind(of: url("https://a.com/play?id=1"), mimeType: "application/vnd.apple.mpegurl"), .hls)
        XCTAssertEqual(DetectedMedia.kind(of: url("https://a.com/play?id=1"), mimeType: "application/dash+xml"), .stream)
        XCTAssertEqual(DetectedMedia.kind(of: url("https://a.com/play?id=1"), mimeType: "video/mp4"), .video)
        XCTAssertEqual(DetectedMedia.kind(of: url("https://a.com/play?id=1"), elementKind: .video, mimeType: "audio/mpeg"), .audio)
    }

    func testDownloadable() {
        XCTAssertTrue(DetectedMedia(url: url("https://a.com/v.mp4"), kind: .video).isDownloadable)
        XCTAssertTrue(DetectedMedia(url: url("https://a.com/v.m3u8"), kind: .hls).isDownloadable)
        XCTAssertFalse(DetectedMedia(url: url("blob:https://a.com/x"), kind: .stream).isDownloadable)
        XCTAssertFalse(DetectedMedia(url: url("https://a.com/v.mp4"), kind: .video, isProtected: true).isDownloadable)
    }

    func testQualityLabel() {
        XCTAssertEqual(DetectedMedia(url: url("https://a.com/v.mp4"), kind: .video, width: 1920, height: 1080).qualityLabel, "1080p")
        XCTAssertEqual(DetectedMedia(url: url("https://a.com/v.mp4"), kind: .video, width: 1080, height: 1920).qualityLabel, "1080p")
        XCTAssertEqual(DetectedMedia(url: url("https://a.com/v.mp4"), kind: .video, width: 3840, height: 2160).qualityLabel, "4K")
        XCTAssertNil(DetectedMedia(url: url("https://a.com/v.mp4"), kind: .video).qualityLabel)
        XCTAssertNil(DetectedMedia(url: url("https://a.com/s.mp3"), kind: .audio, width: 0, height: 0).qualityLabel)
    }

    func testSuggestedFileNames() {
        XCTAssertEqual(DetectedMedia(url: url("https://a.com/media/My%20Clip.mp4"), kind: .video).suggestedFileName, "My Clip.mp4")
        XCTAssertEqual(
            DetectedMedia(url: url("https://a.com/hls/index.m3u8"), kind: .hls, pageTitle: "Great Talk: Part 1").suggestedFileName,
            "Great Talk- Part 1.mp4")
        XCTAssertEqual(DetectedMedia(url: url("https://a.com/stream?id=3"), kind: .audio).suggestedFileName, "a.com.m4a")
    }

    func testMergeSkipsDuplicatesAndFillsIn() {
        let clip = DetectedMedia(url: url("https://a.com/v.mp4"), kind: .video)
        let song = DetectedMedia(url: url("https://a.com/s.mp3"), kind: .audio)
        var list = DetectedMedia.merge([], adding: clip)
        list = DetectedMedia.merge(list, adding: song)
        list = DetectedMedia.merge(list, adding: clip)
        XCTAssertEqual(list.map(\.url), [clip.url, song.url])

        let loaded = DetectedMedia(url: clip.url, kind: .video, width: 1280, height: 720, duration: 61, isProtected: true)
        list = DetectedMedia.merge(list, adding: loaded)
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].qualityLabel, "720p")
        XCTAssertEqual(list[0].duration, 61)
        XCTAssertTrue(list[0].isProtected)
        // A later report without the size keeps what's known.
        list = DetectedMedia.merge(list, adding: clip)
        XCTAssertEqual(list[0].width, 1280)
        XCTAssertTrue(list[0].isProtected)
    }

    func testDisplayOrder() {
        let stream = DetectedMedia(url: url("blob:https://a.com/1"), kind: .stream)
        let song = DetectedMedia(url: url("https://a.com/s.mp3"), kind: .audio)
        let clip = DetectedMedia(url: url("https://a.com/v.mp4"), kind: .video)
        let playlist = DetectedMedia(url: url("https://a.com/p.m3u8"), kind: .hls)
        let locked = DetectedMedia(url: url("https://a.com/drm.mp4"), kind: .video, isProtected: true)
        let other = DetectedMedia(url: url("https://a.com/w.webm"), kind: .video)
        let sorted = DetectedMedia.sortedForDisplay([stream, song, clip, locked, playlist, other])
        XCTAssertEqual(sorted.map(\.url), [clip.url, other.url, playlist.url, song.url, stream.url, locked.url])
    }

    func testDurationText() {
        XCTAssertEqual(MediaFormatting.duration(187), "3:07")
        XCTAssertEqual(MediaFormatting.duration(59.6), "1:00")
        XCTAssertEqual(MediaFormatting.duration(3723), "1:02:03")
        XCTAssertEqual(MediaFormatting.duration(0), "0:00")
    }

    func testCookieRules() {
        let page = url("https://video.example.com/watch/42")
        XCTAssertTrue(CookieRules.applies(domain: ".example.com", path: "/", isSecure: true, expires: nil, to: page))
        XCTAssertTrue(CookieRules.applies(domain: "video.example.com", path: "/watch", isSecure: false, expires: nil, to: page))
        XCTAssertFalse(CookieRules.applies(domain: "other.com", path: "/", isSecure: false, expires: nil, to: page))
        XCTAssertFalse(CookieRules.applies(domain: "ample.com", path: "/", isSecure: false, expires: nil, to: page))
        XCTAssertFalse(CookieRules.applies(domain: "video.example.com", path: "/watchlist", isSecure: false, expires: nil, to: page))
        XCTAssertFalse(CookieRules.applies(domain: ".example.com", path: "/", isSecure: true, expires: nil,
                                           to: url("http://video.example.com/")))
        XCTAssertFalse(CookieRules.applies(domain: ".example.com", path: "/", isSecure: false,
                                           expires: Date(timeIntervalSince1970: 0), to: page))
    }
}
